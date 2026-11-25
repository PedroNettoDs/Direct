// docs/vetores/grupos/ contra o código Dart (protocolo-grupos §13).
import 'dart:convert';
import 'dart:typed_data';

import 'package:direct/core/b64.dart';
import 'package:direct/core/chat_crypto.dart';
import 'package:direct/core/chat_models.dart';
import 'package:direct/core/crypto.dart';
import 'package:direct/core/group_proto.dart';
import 'package:direct/core/invite.dart';
import 'package:flutter_test/flutter_test.dart';

import 'group_support.dart';
import 'support.dart';

Map<String, dynamic> m(Object? o) => o! as Map<String, dynamic>;
List<Map<String, dynamic>> l(Object? o) => (o! as List).cast<Map<String, dynamic>>();

void main() {
  late DirectCrypto c;
  late ChatCrypto cc;
  setUpAll(() async {
    c = await loadCrypto();
    cc = ChatCrypto(c);
  });

  void checkState(GroupState s, Map<String, dynamic> want) {
    expect(s.n, want['n']);
    expect(toHex(s.head), want['head']);
    expect(
      s.members,
      {for (final x in l(want['membros'])) x['user_id'] as String: x['role'] == 'admin' ? roleAdmin : roleMember},
    );
    expect(s.closedAt, want['encerrado_em']);
    expect(s.adminLabel, want['admin_label']);
    expect(toHex(s.metaCommit), want['meta_commit']);
  }

  group('cadeia.json', () {
    for (final name in ['grupo_comum', 'grupo_oficial']) {
      test('$name: bytes, hashes e estados', () {
        final g = m(vetor('grupos/cadeia')[name]);
        final keys = vecChainKeys();
        final s = GroupState(c, g['conversation_id'] as String);
        final states = name == 'grupo_comum' ? l(g['estado_depois_de_cada_registro']) : null;
        for (final (i, r) in l(g['registros']).indexed) {
          final rec = vecRecord(r);
          final change = GroupChange.decode(rec.bytes)!;
          expect(toHex(change.encode()), r['change_bytes']);
          if (r['body'] != null) expect(toHex(change.body), r['body']);
          s.apply(rec, keys);
          expect(toHex(changeHash(c, rec)), r['record_hash']);
          if (states != null) checkState(s, states[i]);
        }
        checkState(s, m(g['estado_final']));
      });
    }

    test('consultas membro_em e pode_reembrulhar', () {
      final g = m(vetor('grupos/cadeia')['grupo_comum']);
      final recs = l(g['registros']).map(vecRecord).toList();
      for (final q in l(g['consultas'])) {
        final s = GroupState.verify(c, g['conversation_id'] as String, recs.take(q['apos_registro'] as int), vecChainKeys());
        final u = q['user_id'] as String, n = q['chain_n'] as int;
        expect(s.memberAt(u, n), q['membro_em_n'], reason: '$q');
        expect(s.mayRewrap(u, n), q['pode_reembrulhar'], reason: '$q');
      }
    });

    test('recusa todo deve_falhar com o código e a posição', () {
      final falhas = l(vetor('grupos/cadeia')['deve_falhar']);
      expect(falhas.length, 21);
      for (final f in falhas) {
        final recs = l(f['registros']).map(vecRecord).toList();
        final conv = (f['conversation_id'] as String?) ??
            m(vetor('grupos/cadeia')['grupo_comum'])['conversation_id'] as String;
        final first = GroupChange.decode(recs.first.bytes);
        // Cada caso é de um dos dois grupos do vetor: vale o id do primeiro registro.
        final id = first?.conversationId ?? conv;
        ChainError? got;
        try {
          GroupState.verify(c, f['caso'] == 'outra_conversa' ? conv : id, recs, vecChainKeys());
        } on ChainError catch (e) {
          got = e;
        }
        expect(got, isNotNull, reason: f['caso'] as String);
        expect((got!.code, got.n), (f['codigo'], f['n']), reason: f['caso'] as String);
      }
    });

    test('sem a chave do moderador fixada, registro dele é recusado', () {
      final g = m(vetor('grupos/cadeia')['grupo_oficial']);
      expect(
        () => GroupState.verify(c, g['conversation_id'] as String, l(g['registros']).map(vecRecord), vecChainKeys(mod: false)),
        throwsA(isA<ChainError>().having((e) => e.code, 'código', 'autor')),
      );
    });

    test('corpos montados batem com os do vetor', () {
      final g = m(vetor('grupos/cadeia')['grupo_comum']);
      for (final r in l(g['registros'])) {
        final change = GroupChange.decode(vecRecord(r).bytes)!;
        final b = parseBody(change.kind, change.body)!;
        final built = switch (change.kind) {
          kindCreate => createBody(b.adminLabel, b.metaCommit, b.members),
          kindAdd => addBody(history: b.history, users: b.users),
          kindRemove || kindPromote => usersBody(b.users),
          kindRename => b.metaCommit,
          _ => Uint8List(0),
        };
        expect(toHex(built), toHex(change.body), reason: 'registro ${change.n}');
      }
    });
  });

  group('epoca.json', () {
    test('declaração, embrulhos, assinatura e metadados', () {
      final v = vetor('grupos/epoca');
      final conv = v['conversation_id'] as String;
      final devs = vecDevices();
      final escrow = fromHex(v['escrow_pub'] as String);
      for (final e in l(v['epocas'])) {
        final creator = devs[e['creator']]!;
        final recipients = (e['recipients_ordenados'] as List).cast<String>();
        final commitment = fromHex(e['key_commitment'] as String);
        final key = fromHex(e['chave_epoca'] as String);
        expect(toHex(cc.keyCommitment(conv, e['epoch'] as int, key)), e['key_commitment']);
        final bytes = groupEpochBytes(
          conversationId: conv,
          epoch: e['epoch'] as int,
          creatorDeviceId: creator.cert.deviceId,
          commitment: commitment,
          escrowPub: escrow,
          chainN: e['chain_n'] as int,
          chainHash: fromHex(e['chain_hash'] as String),
          recipients: recipients,
        );
        expect(toHex(bytes), e['statement_bytes']);
        expect(toHex(c.sign(creator.signSeed, bytes)), e['statement_sig']);
        for (final w in l(e['embrulhos'])) {
          final to = devs[w['destino']];
          if (to == null) continue; // escrow
          final got = openGroupEpoch(
            cc,
            conversationId: conv,
            epoch: e['epoch'] as int,
            creator: creator.cert,
            commitment: commitment,
            recipients: recipients,
            signature: fromHex(e['statement_sig'] as String),
            wrappedKey: fromHex(w['wrapped_key'] as String),
            escrowPub: escrow,
            chainN: e['chain_n'] as int,
            chainHash: fromHex(e['chain_hash'] as String),
            self: to.keys,
          );
          expect(toHex(got), e['chave_epoca']);
        }

        final meta = m(e['meta']);
        final plain = Uint8List.fromList(utf8.encode(meta['meta_json'] as String));
        expect(toHex(metaCommitOf(c, conv, plain)), meta['meta_commit']);
        expect(toHex(metaAad(conv, e['epoch'] as int, metaCommitOf(c, conv, plain))), meta['aad']);
        final sealed = sealGroupMeta(
          cc,
          key: key,
          conversationId: conv,
          epoch: e['epoch'] as int,
          meta: plain,
          nonce: fromHex(meta['nonce'] as String),
        );
        expect(toHex(sealed.ciphertext), meta['ciphertext']);
        final wire = GroupMeta.fromJson(m(meta['json']));
        final opened = openGroupMeta(cc, key: key, conversationId: conv, meta: wire, commit: wire.metaCommit);
        expect(utf8.decode(opened), meta['meta_json']);
        expect(GroupProfile.decode(opened), isNotNull);
        expect(
          () => openGroupMeta(cc, key: key, conversationId: conv, meta: wire, commit: Uint8List(32)),
          throwsA(isA<ChatCryptoException>()),
        );
      }
    });

    test('épocas recusadas pela cadeia', () {
      final g = m(vetor('grupos/cadeia')['grupo_comum']);
      final s = GroupState(c, g['conversation_id'] as String);
      final recs = l(g['registros']).map(vecRecord).toList();
      // o vetor confere contra o estado depois do registro 2
      s.apply(recs[0], vecChainKeys());
      s.apply(recs[1], vecChainKeys());
      for (final f in l(vetor('grupos/epoca')['deve_falhar'])) {
        expect(
          s.checkEpoch(
            chainN: f['chain_n'] as int,
            chainHash: fromHex(f['chain_hash'] as String),
            creatorUserId: f['creator_user_id'] as String,
            recipientOwners: (f['recipient_owners'] as List).cast<String>(),
          ),
          f['codigo'],
          reason: f['caso'] as String,
        );
      }
    });

    test('liberação de histórico: o embrulho abre a época antiga', () {
      final v = vetor('grupos/epoca');
      final h = m(v['historico_liberado']);
      final e = l(v['epocas']).first;
      final d = vecDevices().values.firstWhere((x) => x.cert.deviceId == h['device_id']);
      final got = openGroupEpoch(
        cc,
        conversationId: v['conversation_id'] as String,
        epoch: h['epoch'] as int,
        creator: vecDevices()[e['creator']]!.cert,
        commitment: fromHex(e['key_commitment'] as String),
        recipients: (e['recipients_ordenados'] as List).cast<String>(),
        signature: fromHex(e['statement_sig'] as String),
        wrappedKey: fromHex(h['wrapped_key'] as String),
        escrowPub: fromHex(v['escrow_pub'] as String),
        chainN: e['chain_n'] as int,
        chainHash: fromHex(e['chain_hash'] as String),
        self: d.keys,
      );
      expect(toHex(got), e['chave_epoca']);
    });
  });

  test('selada.json: mesmo embaralhado', () {
    for (final x in l(vetor('grupos/selada')['exemplos'])) {
      final s = SealedWire.fromJson(m(x['selada']));
      expect(scrambleLength(x['len_ciphertext'] as int), x['scramble_len']);
      expect(s.scrambleLength, x['scramble_len']);
      expect(scramble(c, s.conversationId, s.seq, s.scrambleLength), m(x['selada'])['scramble']);
    }
    for (final e in l(m(vetor('grupos/selada')['access_events'])['events'])) {
      AccessEvent.fromJson(e);
    }
  });

  test('revogacao.json', () {
    final v = vetor('grupos/revogacao');
    final a = vecDevices()['A']!;
    final server = vecServerPub();
    final created = v['created_at'] as int;
    expect(toHex(selfRevokeBytes(server, a.cert.deviceId, created)), v['self_revoke_bytes']);
    final req = signSelfRevoke(
      c,
      signSeed: a.signSeed,
      serverSignPub: server,
      deviceId: a.cert.deviceId,
      createdAt: created,
    );
    expect(req, m(v['requisicao']));
    for (final f in l(v['deve_falhar'])) {
      final r = m(f['requisicao']);
      final ok = c.verify(
        a.cert.signPub,
        selfRevokeBytes(server, r['device_id'] as String, r['created_at'] as int),
        b64uDecode(r['sig'] as String),
      );
      // "outro servidor" é verificado com a chave errada do lado do servidor
      if (f['caso'] != 'outro_servidor') expect(ok, isFalse, reason: f['caso'] as String);
    }
  });

  group('chaves.json: QR e códigos', () {
    late Map<String, dynamic> qr;
    setUp(() => qr = m(vetor('grupos/chaves')['qr']));

    test('QR v=2 fixa a chave do moderador; v=1 continua sem ela', () {
      final inv = parseInviteUri(qr['qr_uri_v2'] as String);
      expect(toHex(inv.modPub!), toHex(vecModPub()));
      expect(parseInviteUri(vetor('convite')['qr_uri'] as String).modPub, isNull);
    });

    test('QR de fixação e QRs que devem ser recusados', () {
      final inv = parseInviteUri(qr['qr_uri_v2'] as String);
      Uint8List pin(String uri) =>
          parsePinUri(uri, host: inv.host, serverSignPub: inv.serverSignPub, escrowPub: inv.escrowPub);
      expect(toHex(pin(qr['pin_uri'] as String)), toHex(vecModPub()));
      for (final bad in l(qr['qr_invalidos'])) {
        final uri = bad['uri'] as String;
        expect(
          () => uri.startsWith('direct://pin') ? pin(uri) : parseInviteUri(uri),
          throwsA(isA<InviteException>()),
          reason: bad['caso'] as String,
        );
      }
    });

    test('código de 20 dígitos com m', () {
      final inv = parseInviteUri(qr['qr_uri_v2'] as String);
      expect(serverCodeMod(c, inv.serverSignPub, inv.escrowPub, inv.modPub!), qr['codigo_verificacao_m']);
      expect(c.serverCode(inv.serverSignPub, inv.escrowPub), qr['codigo_verificacao_v1']);
    });
  });

  test('perfil do grupo: regras de §6.1', () {
    final salt = Uint8List(32);
    expect(GroupProfile.decode(GroupProfile(name: 'Atlas').encode(salt))!.name, 'Atlas');
    expect(() => GroupProfile(name: '').encode(salt), throwsFormatException);
    expect(() => GroupProfile(name: 'a' * 65).encode(salt), throwsFormatException);
    expect(() => GroupProfile(name: 'a\nb').encode(salt), throwsFormatException);
    expect(
      () => GroupProfile(name: 'a', photo: Uint8List(groupPhotoMaxBytes + 1)).encode(salt),
      throwsFormatException,
    );
  });
}

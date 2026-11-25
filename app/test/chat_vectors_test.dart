import 'dart:typed_data';

import 'package:direct/core/b64.dart';
import 'package:direct/core/chat_crypto.dart';
import 'package:direct/core/crypto.dart';
import 'package:direct/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  late DirectCrypto c;
  late ChatCrypto cc;
  late Map<String, dynamic> chaves, epoca, mensagem;

  setUpAll(() async {
    c = await loadCrypto();
    cc = ChatCrypto(c);
    chaves = vetor('chaves');
    epoca = vetor('epoca');
    mensagem = vetor('mensagem');
  });

  Map<String, dynamic> aparelho(String nome) =>
      (chaves['aparelhos'] as List).cast<Map<String, dynamic>>().firstWhere((a) => a['nome'] == nome);

  DeviceKeys keysOf(String nome) {
    final a = aparelho(nome);
    return DeviceKeys(
      signSeed: fromHex(a['sign_seed'] as String),
      signPub: fromHex(a['sign_pub'] as String),
      kexSk: fromHex(a['kex_sk'] as String),
      kexPub: fromHex(a['kex_pub'] as String),
    );
  }

  DeviceCert certOf(String nome) {
    final a = aparelho(nome);
    return DeviceCert(
      deviceId: a['device_id'] as String,
      userId: a['user_id'] as String,
      adminLabel: a['admin_label'] as String,
      signPub: fromHex(a['sign_pub'] as String),
      kexPub: fromHex(a['kex_pub'] as String),
      enrolledAt: 0,
      expiresAt: 0,
      sig: Uint8List(64),
    );
  }

  Uint8List escrowPubOf() => fromHex((chaves['escrow'] as Map<String, dynamic>)['kex_pub'] as String);

  group('epoca.json', () {
    test('compromisso e declaração assinada', () {
      final cid = epoca['conversation_id'] as String;
      final k = fromHex(epoca['chave_epoca'] as String);
      expect(toHex(cc.keyCommitment(cid, 1, k)), epoca['key_commitment']);
      final rec = (epoca['recipients_ordenados'] as List).cast<String>();
      final eb = cc.epochBytes(
        conversationId: cid,
        epoch: 1,
        creatorDeviceId: aparelho('A')['device_id'] as String,
        commitment: fromHex(epoca['key_commitment'] as String),
        escrowPub: escrowPubOf(),
        recipients: rec,
      );
      expect(toHex(eb), epoca['statement_bytes']);
      expect(toHex(c.sign(keysOf('A').signSeed, eb)), epoca['statement_sig']);
      expect(ChatCrypto.sortedUnique(rec.reversed), rec);
    });

    test('todo embrulho abre e dá K; validação completa de A e B', () {
      final cid = epoca['conversation_id'] as String;
      final k = fromHex(epoca['chave_epoca'] as String);
      final rec = (epoca['recipients_ordenados'] as List).cast<String>();
      for (final e in (epoca['embrulhos'] as List).cast<Map<String, dynamic>>()) {
        final dest = e['destino'] as String;
        if (dest == 'escrow') {
          final esk = fromHex((chaves['escrow'] as Map<String, dynamic>)['kex_sk'] as String);
          final opened = cc.sodium.crypto.box.sealOpen(
            cipherText: fromHex(e['wrapped_key'] as String),
            publicKey: escrowPubOf(),
            secretKey: cc.sodium.secureCopy(esk),
          );
          expect(opened, k);
          continue;
        }
        final got = cc.openEpoch(
          conversationId: cid,
          epoch: 1,
          creator: certOf('A'),
          commitment: fromHex(epoca['key_commitment'] as String),
          recipients: rec,
          signature: fromHex(epoca['statement_sig'] as String),
          wrappedKey: fromHex(e['wrapped_key'] as String),
          escrowPub: escrowPubOf(),
          self: keysOf(dest),
        );
        expect(got, k);
      }
    });

    test('recusa: assinatura, outra escrow_pub, compromisso, embrulho de outro', () {
      final cid = epoca['conversation_id'] as String;
      final rec = (epoca['recipients_ordenados'] as List).cast<String>();
      final wrapA = fromHex(((epoca['embrulhos'] as List)[0] as Map<String, dynamic>)['wrapped_key'] as String);
      Uint8List open({
        Uint8List? sig,
        Uint8List? escrow,
        Uint8List? commit,
        Uint8List? wrap,
        String self = 'A',
        int epoch = 1,
      }) => cc.openEpoch(
        conversationId: cid,
        epoch: epoch,
        creator: certOf('A'),
        commitment: commit ?? fromHex(epoca['key_commitment'] as String),
        recipients: rec,
        signature: sig ?? fromHex(epoca['statement_sig'] as String),
        wrappedKey: wrap ?? wrapA,
        escrowPub: escrow ?? escrowPubOf(),
        self: keysOf(self),
      );
      expect(open, returnsNormally);
      final badSig = fromHex(epoca['statement_sig'] as String)..[0] ^= 1;
      expect(() => open(sig: badSig), throwsA(isA<ChatCryptoException>()));
      expect(() => open(escrow: keysOf('B').kexPub), throwsA(isA<ChatCryptoException>()));
      expect(() => open(self: 'B'), throwsA(isA<ChatCryptoException>())); // embrulho de A, chave de B
      expect(() => open(epoch: 2), throwsA(isA<ChatCryptoException>()));
      // compromisso trocado: precisa de nova assinatura para chegar ao passo 4
      final fake = Uint8List(32);
      final eb = cc.epochBytes(
        conversationId: cid,
        epoch: 1,
        creatorDeviceId: aparelho('A')['device_id'] as String,
        commitment: fake,
        escrowPub: escrowPubOf(),
        recipients: rec,
      );
      expect(
        () => open(commit: fake, sig: c.sign(keysOf('A').signSeed, eb)),
        throwsA(isA<ChatCryptoException>()),
      );
    });

    test('createEpoch: todos abrem, escrow abre, declaração confere', () {
      final a = certOf('A'), b = certOf('B');
      final cid = epoca['conversation_id'] as String;
      final ne = cc.createEpoch(
        conversationId: cid,
        epoch: 3,
        self: keysOf('A'),
        selfDeviceId: a.deviceId,
        escrowPub: escrowPubOf(),
        certs: [b, a, a],
      );
      expect(ne.recipients, ChatCrypto.sortedUnique([a.deviceId, b.deviceId]));
      for (final who in ['A', 'B']) {
        final cert = certOf(who);
        final k = cc.openEpoch(
          conversationId: cid,
          epoch: 3,
          creator: a,
          commitment: ne.commitment,
          recipients: ne.recipients,
          signature: ne.signature,
          wrappedKey: ne.wraps[cert.deviceId]!,
          escrowPub: escrowPubOf(),
          self: keysOf(who),
        );
        expect(k, ne.key);
      }
      final esk = fromHex((chaves['escrow'] as Map<String, dynamic>)['kex_sk'] as String);
      expect(
        cc.sodium.crypto.box.sealOpen(
          cipherText: ne.escrowWrap,
          publicKey: escrowPubOf(),
          secretKey: cc.sodium.secureCopy(esk),
        ),
        ne.key,
      );
    });
  });

  group('mensagem.json', () {
    MessageHeader hdr() => MessageHeader(
      conversationId: mensagem['conversation_id'] as String,
      epoch: mensagem['epoch'] as int,
      senderDeviceId: aparelho('A')['device_id'] as String,
      messageId: mensagem['message_id'] as String,
      sentAt: mensagem['sent_at'] as int,
    );
    SealedMessage sealed() => SealedMessage(
      fromHex(mensagem['nonce'] as String),
      fromHex(mensagem['ciphertext'] as String),
      fromHex(mensagem['signature'] as String),
    );
    Uint8List k() => fromHex(mensagem['chave_epoca'] as String);

    test('cabeçalho, AAD, bytes assinados, assinatura', () {
      final h = hdr();
      expect(toHex(cc.headerBytes(h)), mensagem['cabecalho']);
      expect(toHex(cc.aad(h)), mensagem['aad']);
      final s = sealed();
      expect(toHex(cc.sigBytes(h, s.nonce, s.ciphertext)), mensagem['assinado_bytes']);
      expect(toHex(c.sign(keysOf('A').signSeed, cc.sigBytes(h, s.nonce, s.ciphertext))), mensagem['signature']);
    });

    test('preenchimento', () {
      final plain = fromHex(mensagem['texto_claro_bytes'] as String);
      expect(toHex(cc.pad(plain)), mensagem['texto_preenchido']);
      for (final p in (mensagem['preenchimento_bloco_256'] as List).cast<Map<String, dynamic>>()) {
        final padded = cc.pad(Uint8List(p['entrada_len'] as int)..fillRange(0, p['entrada_len'] as int, 0x61));
        expect(padded.length, p['saida_len']);
        expect(cc.unpad(padded).length, p['entrada_len']);
      }
    });

    test('abre e devolve o texto', () {
      final plain = cc.open(
        header: hdr(),
        msg: sealed(),
        epochKey: k(),
        senderSignPub: keysOf('A').signPub,
      );
      expect(toHex(plain), mensagem['texto_claro_bytes']);
      expect(ChatCrypto.parseText(plain), 'Olá, João! Reunião às 15h ✅');
    });

    test('cifra de novo e o outro lado abre (nonce novo)', () {
      final plain = fromHex(mensagem['texto_claro_bytes'] as String);
      final s = cc.seal(header: hdr(), epochKey: k(), plaintext: plain, signSeed: keysOf('A').signSeed);
      expect(s.nonce, isNot(fromHex(mensagem['nonce'] as String)));
      expect(s.ciphertext.length, 272); // 256 + 16
      expect(
        cc.open(header: hdr(), msg: s, epochKey: k(), senderSignPub: keysOf('A').signPub),
        plain,
      );
    });

    test('casos que devem falhar', () {
      for (final f in (mensagem['deve_falhar'] as List).cast<Map<String, dynamic>>()) {
        final caso = f['caso'] as String;
        final h = hdr();
        if (caso.startsWith('assinatura')) {
          final pub = fromHex(f['sign_pub'] as String);
          expect(
            c.verify(pub, fromHex(f['assinado_bytes'] as String), fromHex(f['signature'] as String)),
            isFalse,
            reason: caso,
          );
          continue;
        }
        // Decifra direto: a assinatura original não cobre o ciphertext/AAD trocado.
        final ct = fromHex(f['ciphertext'] as String);
        final aad = fromHex(f['aad'] as String);
        expect(
          () => cc.sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
            cipherText: ct,
            nonce: fromHex(mensagem['nonce'] as String),
            key: cc.sodium.secureCopy(k()),
            additionalData: aad,
          ),
          throwsA(anything),
          reason: caso,
        );
        expect(h.epoch, 1);
      }
    });

    test('adulterações em open()', () {
      final h = hdr();
      final s = sealed();
      final pub = keysOf('A').signPub;
      void bad(MessageHeader hh, SealedMessage m, {Uint8List? key, Uint8List? signPub}) => expect(
        () => cc.open(header: hh, msg: m, epochKey: key ?? k(), senderSignPub: signPub ?? pub),
        throwsA(isA<ChatCryptoException>()),
      );
      bad(h, s, signPub: keysOf('B').signPub);
      bad(
        MessageHeader(
          conversationId: h.conversationId,
          epoch: h.epoch,
          senderDeviceId: aparelho('B')['device_id'] as String,
          messageId: h.messageId,
          sentAt: h.sentAt,
        ),
        s,
      );
      bad(h, s, key: Uint8List(32));
      final ct = Uint8List.fromList(s.ciphertext)..[0] ^= 1;
      bad(h, SealedMessage(s.nonce, ct, s.signature));
    });

    test('parseText', () {
      expect(ChatCrypto.parseText(cc.textPlain('oi')), 'oi');
      expect(ChatCrypto.parseText(Uint8List.fromList('{"type":"img"}'.codeUnits)), isNull);
      expect(() => ChatCrypto.parseText(Uint8List.fromList('x'.codeUnits)), throwsA(isA<ChatCryptoException>()));
    });
  });
}

import 'dart:convert';

import 'package:direct/core/b64.dart';
import 'package:direct/core/crypto.dart';
import 'package:direct/core/invite.dart';
import 'package:direct/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  late DirectCrypto c;
  late Map<String, dynamic> chaves, convite, cadastro, login;

  setUpAll(() async {
    c = await loadCrypto();
    chaves = vetor('chaves');
    convite = vetor('convite');
    cadastro = vetor('cadastro');
    login = vetor('login');
  });

  Map<String, dynamic> aparelho(String nome) =>
      (chaves['aparelhos'] as List).cast<Map<String, dynamic>>().firstWhere((a) => a['nome'] == nome);

  group('chaves.json', () {
    test('Ed25519 e X25519 derivam das sementes', () {
      final srv = chaves['servidor'] as Map<String, dynamic>;
      expect(toHex(c.signPubFromSeed(fromHex(srv['sign_seed'] as String))), srv['sign_pub']);
      final esc = chaves['escrow'] as Map<String, dynamic>;
      expect(toHex(c.x25519Pub(fromHex(esc['kex_sk'] as String))), esc['kex_pub']);
      for (final a in (chaves['aparelhos'] as List).cast<Map<String, dynamic>>()) {
        expect(toHex(c.signPubFromSeed(fromHex(a['sign_seed'] as String))), a['sign_pub']);
        expect(toHex(c.x25519Pub(fromHex(a['kex_sk'] as String))), a['kex_pub']);
      }
    });

    test('código do aparelho (§13.4) é o mesmo da CLI', () {
      for (final a in (chaves['aparelhos'] as List).cast<Map<String, dynamic>>()) {
        expect(c.deviceCode(fromHex(a['sign_pub'] as String), fromHex(a['kex_pub'] as String)), a['codigo_aparelho']);
      }
    });

    test('chaves geradas no app são consistentes', () {
      final k = c.generateDeviceKeys();
      expect(k.signSeed.length, 32);
      expect(c.signPubFromSeed(k.signSeed), k.signPub);
      expect(c.x25519Pub(k.kexSk), k.kexPub);
      final m = utf8.encode('x');
      expect(c.verify(k.signPub, m, c.sign(k.signSeed, m)), isTrue);
    });
  });

  group('convite.json', () {
    test('QR válido é lido e as chaves são fixadas', () {
      final inv = parseInviteUri(convite['qr_uri'] as String);
      expect(inv.host, convite['host']);
      expect(toHex(inv.seed), convite['invite_seed']);
      expect(b64uEncode(inv.serverSignPub), convite['server_sign_pub_b64u']);
      expect(b64uEncode(inv.escrowPub), convite['escrow_pub_b64u']);
    });

    test('invite_pub deriva da semente', () {
      final seed = fromHex(convite['invite_seed'] as String);
      expect(toHex(c.signPubFromSeed(seed)), convite['invite_pub']);
    });

    test('código de verificação do servidor', () {
      final inv = parseInviteUri(convite['qr_uri'] as String);
      expect(c.serverCode(inv.serverSignPub, inv.escrowPub), convite['codigo_verificacao']);
      final entrada = fromHex(convite['codigo_entrada'] as String);
      expect(toHex(c.blake2b256(entrada)), convite['codigo_blake2b256']);
    });

    test('todos os QR inválidos são recusados', () {
      final lista = (convite['qr_invalidos'] as List).cast<Map<String, dynamic>>();
      expect(lista, isNotEmpty);
      for (final q in lista) {
        expect(() => parseInviteUri(q['uri'] as String), throwsA(isA<InviteException>()),
            reason: q['motivo'] as String);
      }
    });

    test('ordem diferente dos parâmetros é aceita; sem esquema é recusado', () {
      final inv = parseInviteUri(convite['qr_uri'] as String);
      final q = Uri.parse(convite['qr_uri'] as String).query.split('&').reversed.join('&');
      expect(parseInviteUri('direct://enroll?$q').host, inv.host);
      expect(() => parseInviteUri('https://enroll?$q'), throwsA(isA<InviteException>()));
      expect(() => parseInviteUri('direct://enroll?v=1&h=a.b'), throwsA(isA<InviteException>()));
    });
  });

  group('cadastro.json', () {
    test('enroll_bytes, invite_sig e proof (Ed25519 é determinístico)', () {
      final a = aparelho('A');
      final invSeed = fromHex(cadastro['invite_seed'] as String);
      final invPub = fromHex(cadastro['invite_pub'] as String);
      final eb = c.enrollBytes(invPub, fromHex(a['sign_pub'] as String), fromHex(a['kex_pub'] as String));
      expect(toHex(eb), cadastro['enroll_bytes']);
      expect(toHex(c.sign(invSeed, eb)), cadastro['invite_sig']);
      expect(toHex(c.sign(fromHex(a['sign_seed'] as String), eb)), cadastro['proof_sig']);
    });

    test('requisição JSON usa base64url sem padding', () {
      final r = cadastro['requisicao'] as Map<String, dynamic>;
      final a = aparelho('A');
      expect(r['sign_pub'], b64uEncode(fromHex(a['sign_pub'] as String)));
      expect(r['kex_pub'], b64uEncode(fromHex(a['kex_pub'] as String)));
      expect(r['invite_sig'], b64uEncode(fromHex(cadastro['invite_sig'] as String)));
      expect(r['proof'], b64uEncode(fromHex(cadastro['proof_sig'] as String)));
    });

    test('certificados: bytes e assinatura do servidor', () {
      final srvPub = fromHex((chaves['servidor'] as Map<String, dynamic>)['sign_pub'] as String);
      final certs = (cadastro['certificados'] as List).cast<Map<String, dynamic>>();
      expect(certs.length, 3);
      for (final e in certs) {
        final cert = DeviceCert.fromJson(e['json'] as Map<String, dynamic>);
        expect(toHex(c.certBytes(cert)), e['cert_bytes']);
        expect(toHex(cert.sig), e['cert_sig']);
        expect(c.verifyCert(cert, srvPub), isTrue);
        // adulterado: troca do admin_label invalida
        final bad = DeviceCert.fromJson({...cert.toJson(), 'admin_label': 'Outro'});
        expect(c.verifyCert(bad, srvPub), isFalse);
      }
    });
  });

  group('login.json', () {
    test('auth_bytes e assinatura', () {
      final a = aparelho('A');
      final srvPub = fromHex((chaves['servidor'] as Map<String, dynamic>)['sign_pub'] as String);
      final ch = fromHex(login['challenge'] as String);
      final ab = c.authBytes(srvPub, a['device_id'] as String, ch);
      expect(toHex(ab), login['auth_bytes']);
      expect(toHex(c.sign(fromHex(a['sign_seed'] as String), ab)), login['auth_sig']);
      final req = login['requisicao_verify'] as Map<String, dynamic>;
      expect(req['challenge'], b64uEncode(ch));
      expect(req['sig'], b64uEncode(fromHex(login['auth_sig'] as String)));
    });

    test('prova de revogação confere com a chave fixada e falha com outra', () {
      final a = aparelho('A');
      final srvPub = fromHex((chaves['servidor'] as Map<String, dynamic>)['sign_pub'] as String);
      final ch = fromHex(login['challenge'] as String);
      final rb = c.revokedBytes(a['device_id'] as String, ch);
      expect(toHex(rb), login['revogado_bytes']);
      final sig = fromHex(login['revogado_sig'] as String);
      expect(c.verify(srvPub, rb, sig), isTrue);
      expect(c.verify(fromHex(a['sign_pub'] as String), rb, sig), isFalse);
      expect(c.verify(srvPub, c.revokedBytes(a['device_id'] as String, c.random(32)), sig), isFalse);
    });
  });

  test('base64url estrito', () {
    expect(() => b64uDecode('AAAA=', length: 3), throwsFormatException);
    expect(() => b64uDecode('AAB', length: 2), throwsFormatException); // não canônico
    expect(() => b64uDecode('+AAA'), throwsFormatException);
    expect(b64uDecode('AAAA', length: 3).length, 3);
  });
}

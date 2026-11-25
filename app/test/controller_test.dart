import 'dart:convert';
import 'dart:typed_data';

import 'package:direct/app_controller.dart';
import 'package:direct/core/api.dart';
import 'package:direct/core/b64.dart';
import 'package:direct/core/bio.dart';
import 'package:direct/core/crypto.dart';
import 'package:direct/core/kv_store.dart';
import 'package:direct/core/models.dart';
import 'package:direct/core/vault.dart';
import 'package:direct/data/db.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fake_bio.dart';
import 'support.dart';

/// `directd` de mentira: aplica as conferências do protocolo §5.4 e §6.2.
class MockServer {
  MockServer(this.c, this.serverSeed, this.inviteSeed)
    : serverPub = c.signPubFromSeed(serverSeed),
      invitePub = c.signPubFromSeed(inviteSeed);
  final DirectCrypto c;
  final Uint8List serverSeed, inviteSeed, serverPub, invitePub;
  final escrowPub = Uint8List(32)..fillRange(0, 32, 7);
  bool tamperCert = false, revoked = false;
  DeviceCert? cert;
  Uint8List? lastChallenge;
  String? profileName, token;

  http.Client get client => MockClient((req) async {
    Map<String, dynamic> body() => jsonDecode(req.body) as Map<String, dynamic>;
    http.Response ok(Object j) => http.Response.bytes(utf8.encode(jsonEncode(j)), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
    http.Response err(int s, String code, [Map<String, dynamic> extra = const {}]) =>
        http.Response(jsonEncode({'error': {'code': code, 'message': ''}, ...extra}), s);
    switch ((req.method, req.url.path)) {
      case ('GET', '/v1/server-info'):
        return ok({'server_sign_pub': b64uEncode(serverPub), 'escrow_pub': b64uEncode(escrowPub)});
      case ('POST', '/v1/enroll'):
        final b = body();
        final signPub = b64uDecode(b['sign_pub'] as String, length: 32);
        final kexPub = b64uDecode(b['kex_pub'] as String, length: 32);
        final eb = c.enrollBytes(b64uDecode(b['invite_pub'] as String, length: 32), signPub, kexPub);
        if (!c.verify(invitePub, eb, b64uDecode(b['invite_sig'] as String, length: 64)) ||
            !c.verify(signPub, eb, b64uDecode(b['proof'] as String, length: 64))) {
          return err(401, 'invite_invalid');
        }
        final unsigned = DeviceCert(
          deviceId: '8e7d6c5b-4a39-4281-b7c6-d5e4f3a2b1c0',
          userId: '2b4d6f81-3a5c-4e7a-9b1d-3f5a7c9e1b2d',
          adminLabel: 'João - Financeiro',
          signPub: signPub,
          kexPub: tamperCert ? Uint8List(32) : kexPub,
          enrolledAt: 1795003600000,
          expiresAt: 1810555600000,
          sig: Uint8List(64),
        );
        cert = DeviceCert(
          deviceId: unsigned.deviceId,
          userId: unsigned.userId,
          adminLabel: unsigned.adminLabel,
          signPub: signPub,
          kexPub: unsigned.kexPub,
          enrolledAt: unsigned.enrolledAt,
          expiresAt: unsigned.expiresAt,
          sig: c.sign(serverSeed, c.certBytes(unsigned)),
        );
        return ok({'new_user': true, 'cert': cert!.toJson()});
      case ('POST', '/v1/auth/challenge'):
        lastChallenge = c.random(32);
        return ok({'challenge': b64uEncode(lastChallenge!), 'expires_at': 1});
      case ('POST', '/v1/auth/verify'):
        final b = body();
        final ch = b64uDecode(b['challenge'] as String, length: 32);
        final sig = b64uDecode(b['sig'] as String, length: 64);
        if (!c.verify(cert!.signPub, c.authBytes(serverPub, cert!.deviceId, ch), sig)) {
          return err(401, 'auth_failed');
        }
        if (revoked) {
          return err(401, 'device_revoked', {
            'revoked_sig': b64uEncode(c.sign(serverSeed, c.revokedBytes(cert!.deviceId, ch))),
          });
        }
        token = b64uEncode(c.random(32));
        return ok({'access_token': token, 'expires_at': 1, 'server_time': 1});
      case ('PUT', '/v1/me/profile'):
        if (req.headers['Authorization'] != 'Bearer $token') return err(401, 'unauthorized');
        profileName = body()['display_name'] as String;
        return http.Response('', 204);
    }
    return err(404, 'not_found');
  });
}

void main() {
  late DirectCrypto c;
  late MockServer server;
  late MemoryKv kv;
  late AppController ctl;
  late FakeBio bio;
  late String qr;
  var wipes = 0;
  var firstRun = true;
  Uint8List? lastDbKey;
  late Map<String, dynamic> convite;

  AppController build() => AppController(
    crypto: c,
    kv: kv,
    vault: Vault(
      c.sodium,
      kv,
      opsLimit: c.sodium.crypto.pwhash.opsLimitMin,
      memLimit: c.sodium.crypto.pwhash.memLimitMin,
      bio: bio,
    ),
    openDb: (key) async {
      lastDbKey = key;
      return AppDatabase(NativeDatabase.memory());
    },
    wipeDbFiles: () async => wipes++,
    apiFor: (host) => DirectApi(host, client: server.client),
    wsConnector: (_) async => throw StateError('sem rede nos testes'),
    deviceInfo: () async => const DeviceInfoData('android', 'Pixel 8', '15'),
    firstRunMarker: () async {
      final r = firstRun;
      firstRun = false;
      return r;
    },
  );

  setUpAll(() async {
    c = await loadCrypto();
    convite = vetor('convite');
  });

  setUp(() async {
    final chaves = vetor('chaves');
    final srvSeed = fromHex((chaves['servidor'] as Map<String, dynamic>)['sign_seed'] as String);
    server = MockServer(c, srvSeed, fromHex(convite['invite_seed'] as String));
    // o QR do vetor leva a chave de escrow real do vetor; o mock usa a mesma
    qr = convite['qr_uri'] as String;
    kv = MemoryKv();
    bio = FakeBio();
    wipes = 0;
    firstRun = true;
    ctl = build();
    await ctl.init();
  });

  test('primeiro início apaga Keychain herdado e começa no cadastro', () async {
    wipes = 0;
    kv = MemoryKv()..data['identity'] = 'lixo';
    firstRun = true;
    ctl = build();
    await ctl.init();
    expect(kv.data, isEmpty);
    expect(wipes, 1);
    expect(ctl.stage, Stage.enroll);
  });

  test('marca de instalação só depois da limpeza terminar (A6)', () async {
    var marked = false, fail = true;
    AppController first() => AppController(
      crypto: c,
      kv: kv,
      vault: Vault(c.sodium, kv, bio: bio),
      openDb: (_) async => AppDatabase(NativeDatabase.memory()),
      wipeDbFiles: () async {
        if (fail) throw StateError('app morto no meio');
      },
      apiFor: (host) => DirectApi(host, client: server.client),
      deviceInfo: () async => const DeviceInfoData('android', 'Pixel 8', '15'),
      firstRunMarker: () async => !marked,
      markInstalled: () async => marked = true,
    );
    await expectLater(first().init(), throwsStateError);
    expect(marked, isFalse);
    fail = false;
    await first().init();
    expect(marked, isTrue);
  });

  test('cadastro → perfil → bloqueio → desbloqueio', () async {
    final inv = ctl.inviteFromQr(qr);
    await ctl.enroll(inv, 'senha-boa-123');
    expect(ctl.stage, Stage.profile);
    expect(ctl.adminLabel, 'João - Financeiro');
    expect(lastDbKey!.length, 32);
    // chaves privadas não ficam em claro no armazenamento
    expect(kv.data['secrets'], isNotNull);
    expect(kv.data.keys, containsAll(['vault', 'identity', 'secrets']));

    await ctl.saveProfile('João', 'Disponível');
    expect(ctl.stage, Stage.ready);
    expect(server.profileName, 'João');
    expect(ctl.profile!.status, 'Disponível');

    await ctl.lock();
    expect(ctl.stage, Stage.locked);
    expect(ctl.profile, isNull);

    // reinício do app: nova instância lê o estado do armazenamento
    firstRun = false;
    ctl = build();
    await ctl.init();
    expect(ctl.stage, Stage.locked);
    await expectLater(ctl.unlock('errada-errada'), throwsA(isA<WrongPassword>()));
    await ctl.unlock('senha-boa-123');
    expect(ctl.stage, Stage.profile); // banco do mock é em memória: perfil local não persiste
  });

  test('certificado com chave trocada é recusado e nada é gravado', () async {
    server.tamperCert = true;
    await expectLater(
      ctl.enroll(ctl.inviteFromQr(qr), 'senha-boa-123'),
      throwsA(isA<UserFacingError>()),
    );
    expect(kv.data, isEmpty);
    expect(ctl.stage, Stage.enroll);
  });

  test('certificado assinado por outra chave de servidor é recusado', () async {
    final other = MockServer(c, c.random(32), fromHex(convite['invite_seed'] as String));
    server = other; // servidor com chave diferente da fixada no QR
    await expectLater(
      ctl.enroll(ctl.inviteFromQr(qr), 'senha-boa-123'),
      throwsA(isA<UserFacingError>()),
    );
    expect(kv.data, isEmpty);
  });

  test('prova de revogação válida apaga tudo', () async {
    await ctl.enroll(ctl.inviteFromQr(qr), 'senha-boa-123');
    server.revoked = true;
    await expectLater(ctl.saveProfile('João', ''), throwsA(isA<UserFacingError>()));
    expect(ctl.stage, Stage.enroll);
    expect(kv.data, isEmpty);
    expect(wipes, greaterThan(0));
  });

  test('"Apagar tudo" limpa armazenamento e banco', () async {
    await ctl.enroll(ctl.inviteFromQr(qr), 'senha-boa-123');
    await ctl.lock();
    await ctl.wipeAll();
    expect(kv.data, isEmpty);
    expect(ctl.stage, Stage.enroll);
  });

  test('entrada manual confere o código de verificação', () async {
    await expectLater(
      ctl.inviteFromManual(
        convite['host'] as String,
        convite['invite_seed_b64u'] as String,
        '00000 00000 00000 00000',
      ),
      throwsA(isA<UserFacingError>()),
    );
    // código certo calculado com as chaves que o servidor entrega
    final code = c.serverCode(server.serverPub, server.escrowPub);
    final ok = await ctl.inviteFromManual(
      convite['host'] as String,
      convite['invite_seed_b64u'] as String,
      code,
    );
    expect(ok.serverSignPub, server.serverPub);
  });

  test('perfil: valida tamanhos antes de falar com o servidor', () async {
    await ctl.enroll(ctl.inviteFromQr(qr), 'senha-boa-123');
    await expectLater(ctl.saveProfile('', ''), throwsA(isA<UserFacingError>()));
    await expectLater(ctl.saveProfile('a' * 65, ''), throwsA(isA<UserFacingError>()));
    expect(server.profileName, isNull);
  });

  group('digital', () {
    Future<void> ready() async {
      await ctl.enroll(ctl.inviteFromQr(qr), 'senha-boa-123');
      await ctl.saveProfile('João', 'ok');
    }

    test('ativar pede senha certa e a digital; usar abre o app', () async {
      await ready();
      await expectLater(ctl.enableBio('errada'), throwsA(isA<WrongPassword>()));
      expect(ctl.bioEnabled, isFalse);
      bio.touch = false;
      await expectLater(ctl.enableBio('senha-boa-123'), throwsA(isA<BioCanceled>()));
      expect(ctl.bioEnabled, isFalse);
      bio.touch = true;
      await ctl.enableBio('senha-boa-123');
      expect(ctl.bioEnabled, isTrue);

      await ctl.lock();
      expect(ctl.stage, Stage.locked);
      // reinício do app: a marca persiste
      ctl = build();
      await ctl.init();
      expect(ctl.bioEnabled, isTrue);
      await ctl.unlockWithBio();
      // (o banco de teste é em memória: reabre vazio, daí o passo do perfil)
      expect(ctl.stage, Stage.profile);
    });

    test('digital cancelada não abre e a senha segue valendo', () async {
      await ready();
      await ctl.enableBio('senha-boa-123');
      await ctl.lock();
      bio.touch = false;
      await expectLater(ctl.unlockWithBio(), throwsA(isA<BioCanceled>()));
      expect(ctl.stage, Stage.locked);
      expect(ctl.bioEnabled, isTrue);
      await ctl.unlock('senha-boa-123');
      expect(ctl.stage, isNot(Stage.locked));
    });

    test('desativar apaga o segredo', () async {
      await ready();
      await ctl.enableBio('senha-boa-123');
      await ctl.disableBio();
      expect(ctl.bioEnabled, isFalse);
      expect(kv.data.containsKey('bio'), isFalse);
      await ctl.lock();
      await expectLater(ctl.unlockWithBio(), throwsA(isA<BioUnavailable>()));
    });

    test('digital nova invalida: volta a pedir senha e desativa', () async {
      await ready();
      await ctl.enableBio('senha-boa-123');
      await ctl.lock();
      bio.enroll();
      await expectLater(ctl.unlockWithBio(), throwsA(isA<BioInvalidated>()));
      expect(ctl.bioEnabled, isFalse);
      expect(ctl.stage, Stage.locked);
      expect(kv.data.containsKey('bio'), isFalse);
      await ctl.unlock('senha-boa-123');
      expect(ctl.stage, isNot(Stage.locked));
    });

    test('reauth: senha e digital, sem trocar de tela nem gastar o desbloqueio', () async {
      await ready();
      await ctl.enableBio('senha-boa-123');
      final db = ctl.profile;
      expect((await ctl.reauth(password: 'senha-boa-123')).ok, isTrue);
      final wrong = await ctl.reauth(password: 'errada');
      expect(wrong.ok, isFalse);
      expect(wrong.retryAfter, isNotNull);
      expect((await ctl.reauth()).ok, isTrue);
      bio.touch = false;
      expect((await ctl.reauth()).canceled, isTrue);
      bio.touch = true;
      expect(ctl.stage, Stage.ready);
      expect(ctl.profile, same(db));
      bio.enroll();
      expect((await ctl.reauth()).invalidated, isTrue);
      expect(ctl.bioEnabled, isFalse);
      expect((await ctl.reauth(password: 'senha-boa-123')).ok, isTrue);
    });

    test('apagar tudo remove a digital', () async {
      await ready();
      await ctl.enableBio('senha-boa-123');
      await ctl.wipeAll();
      expect(ctl.bioEnabled, isFalse);
      expect(await bio.read(), isNull);
    });
  });
}

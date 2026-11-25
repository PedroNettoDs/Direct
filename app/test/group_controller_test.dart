// Chave do moderador (protocolo-grupos §3) e revogação pré-assinada (§8) no
// AppController.
import 'dart:convert';
import 'dart:typed_data';

import 'package:direct/app_controller.dart';
import 'package:direct/core/api.dart';
import 'package:direct/core/b64.dart';
import 'package:direct/core/crypto.dart';
import 'package:direct/core/group_proto.dart';
import 'package:direct/core/kv_store.dart';
import 'package:direct/core/vault.dart';
import 'package:direct/data/db.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'controller_test.dart' show MockServer;
import 'fake_bio.dart';
import 'support.dart';

void main() {
  late DirectCrypto c;
  late MockServer server;
  late MemoryKv kv;
  late AppController ctl;
  late Map<String, dynamic> convite;
  late String qr;
  final revokes = <Map<String, dynamic>>[];
  Uint8List? modPub;
  var offline = false;
  var kvAtRevoke = -1;

  setUpAll(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    c = await loadCrypto();
    convite = vetor('convite');
    qr = convite['qr_uri'] as String;
  });

  http.Client client() => MockClient((req) async {
    if (offline) throw http.ClientException('sem rede');
    if (req.url.path == '/v1/devices/self-revoke') {
      expect(req.headers.containsKey('Authorization'), isFalse);
      kvAtRevoke = kv.data.length;
      revokes.add(jsonDecode(req.body) as Map<String, dynamic>);
      return http.Response('{"revoked_at": 1}', 200);
    }
    final inner = server.client;
    final res = await inner.send(
      http.Request(req.method, req.url)
        ..headers.addAll(req.headers)
        ..bodyBytes = req.bodyBytes,
    );
    final out = await http.Response.fromStream(res);
    if (req.url.path == '/v1/server-info' && modPub != null) {
      final j = jsonDecode(out.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({...j, 'mod_pub': b64uEncode(modPub!)}), 200);
    }
    return out;
  });

  AppController build() => AppController(
    crypto: c,
    kv: kv,
    vault: Vault(
      c.sodium,
      kv,
      opsLimit: c.sodium.crypto.pwhash.opsLimitMin,
      memLimit: c.sodium.crypto.pwhash.memLimitMin,
      bio: FakeBio(),
    ),
    openDb: (_) async => AppDatabase(NativeDatabase.memory()),
    wipeDbFiles: () async {},
    apiFor: (host) => DirectApi(host, client: client()),
    wsConnector: (_) async => throw StateError('sem rede nos testes'),
    deviceInfo: () async => const DeviceInfoData('android', 'Pixel 8', '15'),
    firstRunMarker: () async => false,
  );

  setUp(() async {
    final chaves = vetor('chaves');
    server = MockServer(
      c,
      fromHex((chaves['servidor'] as Map<String, dynamic>)['sign_seed'] as String),
      fromHex(convite['invite_seed'] as String),
    );
    kv = MemoryKv();
    revokes.clear();
    modPub = null;
    offline = false;
    ctl = build();
    await ctl.init();
  });

  Future<void> ready([String? invite]) async {
    await ctl.enroll(ctl.inviteFromQr(invite ?? qr), 'senha-boa-123');
    await ctl.saveProfile('João', '');
  }

  void checkRevoke(Map<String, dynamic> r) {
    final inv = ctl.inviteFromQr(qr);
    expect(r['device_id'], server.cert!.deviceId);
    expect(
      c.verify(
        server.cert!.signPub,
        selfRevokeBytes(inv.serverSignPub, server.cert!.deviceId, r['created_at'] as int),
        b64uDecode(r['sig'] as String),
      ),
      isTrue,
    );
  }

  test('revogação pré-assinada é gerada no cadastro, fora do cofre', () async {
    await ready();
    checkRevoke(jsonDecode(kv.data['self_revoke']!) as Map<String, dynamic>);
  });

  test('aparelho antigo gera no próximo desbloqueio', () async {
    await ready();
    kv.data.remove('self_revoke');
    await ctl.lock();
    expect(kv.data.containsKey('self_revoke'), isFalse);
    await ctl.unlock('senha-boa-123');
    checkRevoke(jsonDecode(kv.data['self_revoke']!) as Map<String, dynamic>);
  });

  test('"Esqueci a senha" envia a revogação antes de apagar', () async {
    await ready();
    await ctl.lock();
    await ctl.forgotPassword();
    expect(revokes, hasLength(1));
    expect(kvAtRevoke, greaterThan(0), reason: 'enviada antes de apagar');
    checkRevoke(revokes.single);
    expect(kv.data, isEmpty);
    expect(ctl.stage, Stage.enroll);
  });

  test('"Esqueci a senha" sem internet apaga do mesmo jeito', () async {
    await ready();
    await ctl.lock();
    offline = true;
    await ctl.forgotPassword();
    expect(revokes, isEmpty);
    expect(kv.data, isEmpty);
    expect(ctl.stage, Stage.enroll);
  });

  String pinQr(List<int> mod) {
    final inv = ctl.inviteFromQr(qr);
    return 'direct://pin?v=1&h=${inv.host}&s=${b64uEncode(inv.serverSignPub)}'
        '&e=${b64uEncode(inv.escrowPub)}&m=${b64uEncode(mod)}';
  }

  test('QR v=2 fixa a chave no cadastro; v=1 fica sem grupos', () async {
    await ready();
    expect(ctl.groupsEnabled, isFalse);
    await ctl.wipeAll();
    final mod = c.random(32);
    await ready('${qr.replaceFirst('v=1', 'v=2')}&m=${b64uEncode(mod)}');
    expect(ctl.groupsEnabled, isTrue);
    expect(ctl.chat!.modPub, mod);
  });

  test('QR de fixação: aceita o do próprio servidor e não troca de chave', () async {
    await ready();
    final mod = c.random(32);
    await expectLater(
      ctl.pinModeratorQr(pinQr(mod).replaceFirst('h=', 'h=outro.')),
      throwsA(isA<UserFacingError>()),
    );
    expect(ctl.groupsEnabled, isFalse);
    await ctl.pinModeratorQr(pinQr(mod));
    expect(ctl.groupsEnabled, isTrue);
    expect(ctl.chat!.modPub, mod);
    await expectLater(ctl.pinModeratorQr(pinQr(c.random(32))), throwsA(isA<UserFacingError>()));
    // continua fixada depois de trancar
    await ctl.lock();
    await ctl.unlock('senha-boa-123');
    expect(ctl.groupsEnabled, isTrue);
  });

  test('código em Ajustes: só fixa se o digitado confere com as chaves já fixadas', () async {
    await ready();
    await expectLater(ctl.moderatorKeyFromServer(), throwsA(isA<UserFacingError>()));
    modPub = c.random(32);
    final mod = await ctl.moderatorKeyFromServer();
    final inv = ctl.inviteFromQr(qr);
    await expectLater(ctl.pinModeratorCode(mod, '00000 00000 00000 00000'), throwsA(isA<UserFacingError>()));
    expect(ctl.groupsEnabled, isFalse);
    await ctl.pinModeratorCode(mod, serverCodeMod(c, inv.serverSignPub, inv.escrowPub, mod));
    expect(ctl.groupsEnabled, isTrue);
  });

  test('entrada manual: o código com a chave do moderador a fixa; o antigo não', () async {
    final host = convite['host'] as String, token = convite['invite_seed_b64u'] as String;
    modPub = c.random(32);
    final plain = await ctl.inviteFromManual(host, token, c.serverCode(server.serverPub, server.escrowPub));
    expect(plain.modPub, isNull);
    final announced = Uint8List.fromList(modPub!);
    await expectLater(
      ctl.inviteFromManual(host, token, serverCodeMod(c, server.serverPub, server.escrowPub, c.random(32))),
      throwsA(isA<UserFacingError>()),
    );
    final ok = await ctl.inviteFromManual(host, token, serverCodeMod(c, server.serverPub, server.escrowPub, announced));
    expect(ok.modPub, modPub);
  });
}

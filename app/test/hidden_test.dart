// Conversas ocultas (D12): cifra no banco, mensagens que chegam fechadas, senha
// própria sem digital, "Mostrar conversa" e grupo oculto.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:direct/app_controller.dart';
import 'package:direct/bubble/mini.dart';
import 'package:direct/chat/chat_service.dart';
import 'package:direct/core/api.dart';
import 'package:direct/core/b64.dart';
import 'package:direct/core/chat_crypto.dart';
import 'package:direct/core/chat_models.dart';
import 'package:direct/core/crypto.dart';
import 'package:direct/core/kv_store.dart';
import 'package:direct/core/models.dart';
import 'package:direct/core/vault.dart';
import 'package:direct/data/db.dart';
import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'chat_ws_test.dart' show FakeLink;
import 'controller_test.dart' show MockServer;
import 'fake_bio.dart';
import 'fake_directd.dart';
import 'support.dart';

const me = '2b4d6f81-3a5c-4e7a-9b1d-3f5a7c9e1b2d';
const myDevice = '8e7d6c5b-4a39-4281-b7c6-d5e4f3a2b1c0';
const ana = '7d0c9b8a-1e2f-4a3b-9c4d-5e6f7a8b9c0d';
const anaDevice = '33333333-3333-4333-8333-333333333331';
const convId = '22222222-2222-4222-8222-222222222222';
const pw = 'senha-da-conversa';

/// Cofre com atraso de verdade e relógios sob controle do teste.
class Clocks {
  int up = 0;
  var wall = DateTime(2026, 11, 25, 20);
  void pass(Duration d) {
    up += d.inMilliseconds;
    wall = wall.add(d);
  }
}

AppController hiddenController(DirectCrypto c, FakeBio bio, Clocks clocks) => AppController(
  uptime: () async => clocks.up,
  crypto: c,
  kv: MemoryKv(),
  vault: Vault(
    c.sodium,
    MemoryKv(),
    bio: bio,
    now: () => clocks.wall,
    uptime: () async => clocks.up,
    opsLimit: c.sodium.crypto.pwhash.opsLimitMin,
    memLimit: c.sodium.crypto.pwhash.memLimitMin,
  ),
  openDb: (_) async => AppDatabase(NativeDatabase.memory()),
  wipeDbFiles: () async {},
  apiFor: (host) => DirectApi(host),
  deviceInfo: () async => const DeviceInfoData('android', 'Teste', '15'),
  firstRunMarker: () async => false,
);

bool contains(List<int> hay, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= hay.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

Future<void> until(String what, FutureOr<bool> Function() cond) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(end)) {
    if (await cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('timeout: $what');
}

void main() {
  late DirectCrypto c;
  late ChatCrypto cc;

  setUpAll(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    c = await loadCrypto();
    cc = ChatCrypto(c);
  });

  test('1:1: some, é selada no banco, recebe fechada, só a senha abre e "Mostrar" restaura', () async {
    final dir = await Directory.systemTemp.createTemp('direct-ocultas');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/t.db');

    final serverSeed = c.random(32);
    final myKeys = c.generateDeviceKeys(), anaKeys = c.generateDeviceKeys();
    DeviceCert certFor(String deviceId, String userId, String label, DeviceKeys k) {
      final unsigned = DeviceCert(
        deviceId: deviceId,
        userId: userId,
        adminLabel: label,
        signPub: k.signPub,
        kexPub: k.kexPub,
        enrolledAt: 1795003600000,
        expiresAt: 1810555600000,
        sig: Uint8List(64),
      );
      return DeviceCert.fromJson({...unsigned.toJson(), 'sig': b64uEncode(c.sign(serverSeed, c.certBytes(unsigned)))});
    }

    final myCert = certFor(myDevice, me, 'Eu', myKeys);
    final anaCert = certFor(anaDevice, ana, 'Ana', anaKeys);
    final escrowPub = c.x25519Pub(c.random(32));

    final epochs = <NewEpoch>[];
    Map<String, dynamic> newEpoch() {
      final ne = cc.createEpoch(
        conversationId: convId,
        epoch: epochs.length + 1,
        self: anaKeys,
        selfDeviceId: anaDevice,
        escrowPub: escrowPub,
        certs: [anaCert, myCert],
      );
      epochs.add(ne);
      return {
        'wrap_id': epochs.length,
        'conversation_id': convId,
        'epoch': epochs.length,
        'creator_device_id': anaDevice,
        'key_commitment': b64uEncode(ne.commitment),
        'recipients': ne.recipients,
        'signature': b64uEncode(ne.signature),
        'wrapped_key': b64uEncode(ne.wraps[myDevice]!),
      };
    }

    final first = newEpoch();
    var seq = 0;
    Map<String, dynamic> message(String text) {
      final id = '44444444-4444-4444-8444-${(++seq).toString().padLeft(12, '0')}';
      final header = MessageHeader(
        conversationId: convId,
        epoch: epochs.length,
        senderDeviceId: anaDevice,
        messageId: id,
        sentAt: seq,
      );
      final sealed = cc.seal(
        header: header,
        epochKey: epochs.last.key,
        plaintext: cc.textPlain(text),
        signSeed: anaKeys.signSeed,
      );
      final wire = WireMessage(
        conversationId: convId,
        epoch: epochs.length,
        senderDeviceId: anaDevice,
        messageId: id,
        sentAt: seq,
        nonce: sealed.nonce,
        ciphertext: sealed.ciphertext,
        signature: sealed.signature,
      );
      return {'type': 'message', 'message': {...wire.toSendJson(), 'seq': seq}};
    }

    final client = MockClient((req) async {
      final body = switch (req.url.path) {
        '/v1/directory' => {
          'users': [
            {'user_id': ana, 'admin_label': 'Ana', 'display_name': '', 'status': '', 'devices': [anaCert.toJson()]},
          ],
        },
        '/v1/epochs/mine' => {
          'items': int.parse(req.url.queryParameters['after'] ?? '0') < 1 ? [first] : <Object>[],
          'has_more': false,
        },
        '/v1/conversations' => {
          'conversations': [
            {'conversation_id': convId, 'members': [me, ana], 'latest_epoch': 1, 'last_seq': 0},
          ],
        },
        _ => <String, Object>{},
      };
      return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    });
    final db = AppDatabase(NativeDatabase(file));
    late FakeLink link;
    final svc = ChatService(
      db: db,
      api: DirectApi('h.example', client: client),
      crypto: cc,
      keys: myKeys,
      cert: myCert,
      serverSignPub: c.signPubFromSeed(serverSeed),
      escrowPub: escrowPub,
      login: () async => AccessToken('tok', DateTime.now().millisecondsSinceEpoch + 900000),
      connector: (_) async => link = FakeLink(),
    );
    final bio = FakeBio();
    final clocks = Clocks();
    final ctl = hiddenController(c, bio, clocks)..chat = svc;
    addTearDown(() async {
      await svc.stop();
      await db.close();
    });
    await ctl.vault.enableBio(c.random(32));
    ctl.bioEnabled = true;
    final prompts = bio.prompts;

    svc.start();
    await until('online', () => svc.status == ChatStatus.online);
    const antigo = 'texto-conhecido-antes-de-esconder';
    const novo = 'texto-conhecido-depois-de-esconder';
    link.push(message(antigo));
    await until('recebida', () async => (await svc.messages(convId)).any((m) => m.body == antigo));
    final anexo = utf8.encode('bytes-conhecidos-do-anexo');
    await db.into(db.attachments).insert(
      AttachmentsCompanion.insert(conversationId: convId, messageId: 'a', data: Value(Uint8List.fromList(anexo))),
    );
    expect(contains(await file.readAsBytes(), utf8.encode(antigo)), isTrue, reason: 'o teste enxerga o banco bruto');

    await ctl.hideConversation(convId, pw);

    expect(await svc.conversations(), isEmpty);
    expect(await svc.directory(), isEmpty, reason: 'o contato some junto');
    expect((await svc.hiddenConversations()).single.title, 'Ana');
    expect((await svc.hiddenConversations()).single.lastText, isEmpty);
    expect(await svc.messages(convId), isEmpty);
    await expectLater(svc.send(convId, 'x'), throwsA(isA<UserFacingError>()));
    var raw = await file.readAsBytes();
    expect(contains(raw, utf8.encode(antigo)), isFalse);
    expect(contains(raw, anexo), isFalse);
    expect(contains(raw, epochs.first.key), isFalse, reason: 'chave de época selada');

    // chega com a conversa fechada: época nova e mensagem, sem senha
    link.push({'type': 'epoch', 'item': newEpoch()});
    link.push(message(novo));
    await until('guardada', () async => (await db.select(db.chatMessages).get()).length == 2);
    await until('época guardada', () async => (await db.select(db.epochKeys).get()).length == 2);
    final waiting = (await db.select(db.chatMessages).get()).firstWhere((m) => m.seq == 2);
    expect((waiting.state, waiting.body), (msgWaitingKey, null));
    raw = await file.readAsBytes();
    expect(contains(raw, utf8.encode(novo)), isFalse);
    expect(contains(raw, epochs.last.key), isFalse);

    // senha errada: atraso crescente, conferido no relógio monotônico
    for (var i = 0; i < 3; i++) {
      final r = await ctl.openHiddenConversation(convId, 'errada-$i');
      expect((r.ok, r.retryAfter != null), (false, true));
    }
    clocks.wall = clocks.wall.add(const Duration(hours: 1)); // só o relógio de parede
    expect((await ctl.openHiddenConversation(convId, pw)).ok, isFalse);
    expect(svc.isShut(convId), isTrue);

    // nenhum outro caminho: nem senha do app, nem digital
    expect((await ctl.unlockConversation(convId)).ok, isFalse);
    expect((await ctl.unlockConversation(convId, password: pw)).ok, isFalse);
    expect(bio.prompts, prompts, reason: 'a digital nunca é oferecida');

    clocks.pass(const Duration(minutes: 1));
    expect((await ctl.openHiddenConversation(convId, pw)).ok, isTrue);
    await until(
      'tudo legível',
      () async => {for (final m in await svc.messages(convId)) m.body}.containsAll([antigo, novo]),
    );
    expect(bio.prompts, prompts);
    expect(contains(await file.readAsBytes(), utf8.encode(novo)), isFalse, reason: 'decifrada só em memória');
    expect(await svc.conversations(), isEmpty, reason: 'aberta continua fora da lista');

    // trocar a senha e sair: só a nova abre
    await ctl.changeHiddenPassword(convId, 'outra-senha-boa');
    svc.closeHidden(convId);
    expect(await svc.messages(convId), isEmpty);
    expect((await ctl.openHiddenConversation(convId, pw)).ok, isFalse);
    await expectLater(ctl.showHiddenConversation(convId), throwsA(isA<UserFacingError>()));
    expect((await ctl.openHiddenConversation(convId, 'outra-senha-boa')).ok, isTrue);

    // ir para segundo plano fecha
    await ctl.background();
    expect(svc.isShut(convId), isTrue);
    expect((await ctl.openHiddenConversation(convId, 'outra-senha-boa')).ok, isTrue);

    await ctl.showHiddenConversation(convId);
    expect((await svc.conversations()).single.lastText, novo);
    expect((await svc.directory()).single.adminLabel, 'Ana');
    expect([for (final m in await db.select(db.chatMessages).get()) m.body], [antigo, novo]);
    expect([for (final e in await db.select(db.epochKeys).get()) e.key], [for (final e in epochs) e.key]);
    expect((await db.select(db.attachments).getSingle()).data, anexo);
    expect(await db.select(db.hiddenConversations).get(), isEmpty);
  });

  test('grupo oculto: nada é buscado nem mostrado sem a senha', () async {
    final server = FakeDirectd(c);
    final g = server.createGroup(server.ana, members: [meId]);
    server.say(g, server.ana, 'segredo do grupo', push: false);
    final db = AppDatabase(NativeDatabase.memory());
    final svc = server.service(db: db);
    final ctl = hiddenController(c, FakeBio(), Clocks())..chat = svc;
    addTearDown(() async {
      await svc.stop();
      await db.close();
    });
    Future<List<String>> said() async => [
      for (final l in await svc.groupLines(g.id)) if (l.message.state != msgNotice) l.message.body ?? '',
    ];

    svc.start();
    await until('online', () => svc.status == ChatStatus.online);
    await svc.openGroup(g.id);
    expect(await said(), ['segredo do grupo']);

    await ctl.hideConversation(g.id, pw);
    expect(await svc.conversations(), isEmpty);
    expect((await svc.hiddenConversations()).single.isGroup, isTrue);
    expect((await svc.hiddenConversations()).single.title, isNot('Projeto Atlas'), reason: 'o nome é cifrado');
    expect(await said(), isEmpty);
    expect(await svc.groupInfo(g.id), isNull);
    expect(await svc.groupTitle(g.id), 'Grupo');

    // reconecta: nem chaves, nem nome, nem mensagens deste grupo são pedidos
    server.requests.clear();
    await svc.openGroup(g.id);
    await svc.stop();
    final again = server.service(db: db);
    ctl.chat = again;
    addTearDown(again.stop);
    again.start();
    await until('online', () => again.status == ChatStatus.online);
    server.say(g, server.ana, 'chegou fechado');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(server.requests.where((r) => r.contains(g.id) && !r.endsWith('/changes')), isEmpty);
    expect(again.isShut(g.id), isTrue);

    expect((await ctl.openHiddenConversation(g.id, 'errada')).ok, isFalse);
    expect((await ctl.openHiddenConversation(g.id, pw)).ok, isTrue);
    await until('grupo aberto', () async => (await again.groupLines(g.id)).any((l) => l.message.body == 'chegou fechado'));
    expect(await again.groupTitle(g.id), 'Projeto Atlas');

    await ctl.showHiddenConversation(g.id);
    expect((await again.conversations()).single.title, 'Projeto Atlas');
  });

  test('app de verdade: persiste, pop-up não abre, segundo plano e bloqueio fecham', () async {
    final dir = await Directory.systemTemp.createTemp('direct-ocultas');
    final convite = vetor('convite');
    final server = MockServer(
      c,
      fromHex((vetor('chaves')['servidor'] as Map<String, dynamic>)['sign_seed'] as String),
      fromHex(convite['invite_seed'] as String),
    );
    final bio = FakeBio();
    final kv = MemoryKv();
    AppController build() => AppController(
      uptime: () async => 0,
      crypto: c,
      kv: kv,
      vault: Vault(
        c.sodium,
        kv,
        opsLimit: c.sodium.crypto.pwhash.opsLimitMin,
        memLimit: c.sodium.crypto.pwhash.memLimitMin,
        bio: bio,
      ),
      openDb: (_) async => AppDatabase(NativeDatabase(File('${dir.path}/t.db'))),
      wipeDbFiles: () async {},
      apiFor: (host) => DirectApi(host, client: server.client),
      wsConnector: (_) async => throw StateError('sem rede nos testes'),
      deviceInfo: () async => const DeviceInfoData('android', 'Pixel 8', '15'),
      firstRunMarker: () async => false,
    );
    var ctl = build();
    addTearDown(() async {
      await ctl.lock();
      await dir.delete(recursive: true);
    });
    const appPw = 'senha-boa-123';
    await ctl.init();
    await ctl.enroll(ctl.inviteFromQr(convite['qr_uri'] as String), appPw);
    await ctl.saveProfile('João', 'ok');
    await ctl.enableBio(appPw);
    expect(ctl.secretsEnabled, isFalse);
    await ctl.setSecrets(true);
    final db = ctl.chat!.db;
    await db.into(db.conversations).insert(
      ConversationsCompanion.insert(
        conversationId: convId,
        peerUserId: ana,
        membersJson: jsonEncode([me, ana]),
        latestEpoch: 0,
        syncedSeq: 0,
      ),
    );

    final closed = <String>[];
    ctl.closeBubble = (id) async => closed.add(id);
    await ctl.setBubbles({convId});
    ctl.floating = convId;
    await ctl.hideConversation(convId, pw);
    expect(closed, [convId]);
    expect(ctl.floating, isNull);
    expect(ctl.bubbles, isEmpty);

    final mini = LocalMiniBackend(ctl);
    var state = await mini.load(convId);
    expect((state.phase, state.title, state.messages.length), (MiniPhase.hidden, '', 0));
    expect(await mini.send(convId, 'oi'), isNotNull);
    final prompts = bio.prompts;
    expect(await mini.unlockChat(convId, password: pw), isNotNull);
    expect(await mini.unlockChat(convId), isNotNull);
    expect(bio.prompts, prompts);

    // bloquear e reabrir com a digital: continua escondida e fechada
    expect((await ctl.openHiddenConversation(convId, pw)).ok, isTrue);
    await ctl.lock();
    ctl = build();
    await ctl.init();
    await ctl.unlockWithBio();
    expect(ctl.secretsEnabled, isTrue);
    await ctl.setSecrets(false);
    expect(ctl.isHidden(convId), isTrue);
    expect(ctl.chat!.isShut(convId), isTrue);
    expect(await ctl.chat!.conversations(), isEmpty);
    expect(await ctl.chat!.messages(convId), isEmpty);
    state = await mini.load(convId);
    expect(state.title, '');

    // segundo plano com a bolha de outra conversa: a oculta fecha
    expect((await ctl.openHiddenConversation(convId, pw)).ok, isTrue);
    await ctl.setBubbles({'11111111-1111-4111-8111-111111111111'});
    await ctl.background();
    expect(ctl.sessionOpen, isTrue);
    expect(ctl.chat!.isShut(convId), isTrue);
    expect((await LocalMiniBackend(ctl).load(convId)).phase, MiniPhase.appLocked);
  });
}

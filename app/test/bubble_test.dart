import 'dart:io';
import 'dart:typed_data';

import 'package:direct/app_controller.dart';
import 'package:direct/bubble/mini.dart';
import 'package:direct/bubble/port.dart';
import 'package:direct/core/api.dart';
import 'package:direct/core/b64.dart';
import 'package:direct/core/crypto.dart';
import 'package:direct/core/kv_store.dart';
import 'package:direct/core/vault.dart';
import 'package:direct/data/db.dart';
import 'package:direct/ui/floating_chat.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'controller_test.dart' show MockServer;
import 'fake_bio.dart';
import 'support.dart';

const pw = 'senha-boa-123';
const a = '11111111-1111-4111-8111-111111111111';
const b = '22222222-2222-4222-8222-222222222222';

void main() {
  late DirectCrypto c;
  late Directory dir;
  late MockServer server;
  late MemoryKv kv;
  late FakeBio bio;
  late AppController ctl;
  late String qr;

  var up = 0; // relógio monotônico de mentira, em ms
  var idle = bubbleIdleTimeout;

  AppController build() => AppController(
    uptime: () async => up,
    bubbleIdle: idle,
    crypto: c,
    kv: kv,
    vault: Vault(
      c.sodium,
      kv,
      opsLimit: c.sodium.crypto.pwhash.opsLimitMin,
      memLimit: c.sodium.crypto.pwhash.memLimitMin,
      bio: bio,
    ),
    // banco em arquivo: a tranca tem de sobreviver a fechar e reabrir
    openDb: (_) async => AppDatabase(NativeDatabase(File('${dir.path}/t.db'))),
    wipeDbFiles: () async {},
    apiFor: (host) => DirectApi(host, client: server.client),
    wsConnector: (_) async => throw StateError('sem rede nos testes'),
    deviceInfo: () async => const DeviceInfoData('android', 'Pixel 8', '15'),
    firstRunMarker: () async => false,
  );

  setUpAll(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    c = await loadCrypto();
  });

  setUp(() async {
    up = 0;
    idle = bubbleIdleTimeout;
    dir = await Directory.systemTemp.createTemp('direct');
    final convite = vetor('convite');
    server = MockServer(
      c,
      fromHex((vetor('chaves')['servidor'] as Map<String, dynamic>)['sign_seed'] as String),
      fromHex(convite['invite_seed'] as String),
    );
    qr = convite['qr_uri'] as String;
    kv = MemoryKv();
    bio = FakeBio();
    ctl = build();
    await ctl.init();
  });

  tearDown(() async {
    await ctl.lock();
    await dir.delete(recursive: true);
  });

  Future<void> ready() async {
    await ctl.enroll(ctl.inviteFromQr(qr), pw);
    await ctl.saveProfile('João', 'ok');
  }

  test('trancar vale só para a conversa e sobrevive a reinício e desbloqueio do app', () async {
    await ready();
    await ctl.lockConversation(a);
    expect(ctl.isConversationLocked(a), isTrue);
    expect(ctl.isConversationLocked(b), isFalse);
    expect(ctl.stage, Stage.ready); // o resto do app segue aberto

    await ctl.lock();
    ctl = build();
    await ctl.init();
    await ctl.unlock(pw);
    expect(ctl.isConversationLocked(a), isTrue);
  });

  test('destrancar exige senha certa ou digital', () async {
    await ready();
    await ctl.enableBio(pw);
    await ctl.lockConversation(a);

    expect((await ctl.unlockConversation(a, password: 'errada')).ok, isFalse);
    bio.touch = false;
    expect((await ctl.unlockConversation(a)).canceled, isTrue);
    expect(ctl.isConversationLocked(a), isTrue);

    bio.touch = true;
    expect((await ctl.unlockConversation(a)).ok, isTrue);
    expect(ctl.isConversationLocked(a), isFalse);

    await ctl.lockConversation(a);
    expect((await ctl.unlockConversation(a, password: pw)).ok, isTrue);
    await ctl.lock();
    await ctl.unlock(pw);
    expect(ctl.isConversationLocked(a), isFalse);
  });

  test('bolha jogada no lixo com o app trancado: grava ao abrir', () async {
    await ready();
    await ctl.lock();
    var pending = [a];
    ctl.dismissedSource = () async => pending;
    ctl.dismissedAck = (ids) async => pending = pending.where((x) => !ids.contains(x)).toList();

    await ctl.applyDismissed();
    expect(pending, [a], reason: 'sem banco aberto não dá baixa');
    await ctl.unlock(pw);
    expect(ctl.isConversationLocked(a), isTrue);
    expect(pending, isEmpty);
  });

  test('segundo plano com bolha mantém a sessão só dela; fechar a última tranca tudo', () async {
    await ready();
    await ctl.setBubbles({a});
    await ctl.background();
    expect(ctl.stage, Stage.locked);
    expect(ctl.sessionOpen, isTrue);
    expect(ctl.chat!.scope, {a});

    await ctl.background(); // `paused` depois de `hidden`
    expect(ctl.sessionOpen, isTrue);

    await ctl.unlock(pw);
    expect(ctl.stage, Stage.ready);
    expect(ctl.chat!.scope, isNull);

    await ctl.background();
    await ctl.lockConversation(a);
    await ctl.setBubbles({});
    expect(ctl.sessionOpen, isFalse);
    await ctl.unlock(pw);
    expect(ctl.isConversationLocked(a), isTrue);

    await ctl.background(); // sem bolha: como antes
    expect(ctl.sessionOpen, isFalse);
  });

  Future<void> bubbleOnly() async {
    await ready();
    await ctl.setBubbles({a});
    await ctl.background();
  }

  Future<void> expectBubbleLocked() async {
    expect(ctl.sessionOpen, isFalse, reason: 'a chave-mestra sai da memória');
    await ctl.unlock(pw);
    expect(ctl.isConversationLocked(a), isTrue);
  }

  test('tela desligada tranca a conversa da bolha e esquece a chave (B1)', () async {
    await bubbleOnly();
    await ctl.lockBubbles();
    await expectBubbleLocked();
  });

  test('tela desligada antes de o app sair da frente também esquece a chave', () async {
    await ready();
    await ctl.setBubbles({a});
    await ctl.lockBubbles(); // interface ainda aberta
    expect(ctl.stage, Stage.ready);
    expect(ctl.isConversationLocked(a), isTrue);
    await ctl.background();
    await expectBubbleLocked();
  });

  test('5 minutos sem interação trancam; toque e envio recomeçam, carregar não (B1)', () async {
    await bubbleOnly();
    final mini = LocalMiniBackend(ctl);
    up += const Duration(minutes: 4).inMilliseconds;
    await mini.touch();
    up += const Duration(minutes: 4).inMilliseconds;
    // a conversa não existe no banco de teste; o que importa é não estar trancada
    expect(await mini.send(a, 'oi'), isNot('Conversa trancada.'));
    up += const Duration(minutes: 4).inMilliseconds;
    expect((await mini.load(a)).phase, MiniPhase.ready);
    up += const Duration(minutes: 1).inMilliseconds; // 5 desde o envio
    final s = await mini.load(a);
    expect(s.phase, MiniPhase.appLocked);
    expect(s.messages, isEmpty);
    await expectBubbleLocked();
  });

  test('toque depois do prazo não ressuscita a sessão', () async {
    await bubbleOnly();
    up += bubbleIdleTimeout.inMilliseconds;
    expect(await LocalMiniBackend(ctl).send(a, 'tarde demais'), isNotNull);
    await expectBubbleLocked();
  });

  test('o prazo vence sozinho, sem ninguém tocar na bolha', () async {
    idle = const Duration(milliseconds: 100);
    ctl = build();
    await ctl.init();
    await bubbleOnly();
    up += 100;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await expectBubbleLocked();
  });

  test('com a interface trancada a ponte só serve conversa que tem bolha (B2)', () async {
    await bubbleOnly();
    final mini = LocalMiniBackend(ctl);
    expect((await mini.load(b)).phase, MiniPhase.appLocked);
    expect(await mini.send(b, 'oi'), isNotNull);
    expect((await mini.load(a)).phase, MiniPhase.ready);
  });

  test('chave errada pela ponte não desliga a digital (B2)', () async {
    await ready();
    await ctl.enableBio(pw);
    await ctl.lock();
    expect(await LocalMiniBackend(ctl).unlockApp(master: Uint8List(32)), isNotNull);
    expect(ctl.bioEnabled, isTrue);
  });

  test('mini-chat: app trancado, conversa trancada e conversa', () async {
    await ready();
    await ctl.enableBio(pw);
    await ctl.setBubbles({a});
    await ctl.lock(); // botão "Bloquear": nem a bolha fica aberta
    final close = serveMini(LocalMiniBackend(ctl), name: 'teste');
    final mini = PortMiniBackend(bio: bio, name: 'teste');
    addTearDown(() {
      mini.dispose();
      close();
    });

    expect((await mini.load(a)).phase, MiniPhase.appLocked);
    expect(await mini.unlockApp(password: 'errada'), isNotNull);
    expect(await mini.unlockApp(), isNull); // digital lida no lado da bolha
    expect(ctl.stage, Stage.locked, reason: 'a interface principal segue pedindo senha');
    expect((await mini.load(a)).phase, MiniPhase.ready);

    await ctl.lockConversation(a);
    final s = await mini.load(a);
    expect(s.phase, MiniPhase.chatLocked);
    expect(s.messages, isEmpty);
    expect(await mini.send(a, 'oi'), isNotNull);
    bio.touch = false;
    expect(await mini.unlockChat(a), '');
    expect(await mini.unlockChat(a, password: 'errada'), isNotNull);
    expect(ctl.isConversationLocked(a), isTrue);
    bio.touch = true;
    expect(await mini.unlockChat(a), isNull);
    expect((await mini.load(a)).phase, MiniPhase.ready);
  });

  for (final byDrag in [false, true]) {
    testWidgets('iOS: fechar o flutuante ${byDrag ? "no lixo" : "no X"} tranca a conversa', (tester) async {
      kv = MemoryKv();
      final ui = build()..openFloating(a); // sem init: mostra a trava, o que basta
      await tester.pumpWidget(
        MaterialApp(home: ListenableBuilder(listenable: ui, builder: (_, _) {
          return ui.floating == null ? const SizedBox() : FloatingChat(controller: ui, conversationId: a);
        })),
      );
      await tester.pump();
      if (byDrag) {
        final head = tester.getCenter(find.byKey(const Key('floating-head')));
        final size = tester.getSize(find.byType(MaterialApp));
        await tester.dragFrom(head, Offset(size.width / 2, size.height - 56) - head);
      } else {
        await tester.tap(find.byTooltip('Fechar e trancar'));
      }
      await tester.pump();
      expect(ui.floating, isNull);
      expect(ui.isConversationLocked(a), isTrue);
    });
  }

  testWidgets('iOS: o app por baixo do flutuante continua recebendo toques', (tester) async {
    kv = MemoryKv();
    final ui = build()..openFloating(a);
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            Align(alignment: Alignment.topLeft, child: TextButton(onPressed: () => taps++, child: const Text('embaixo'))),
            Overlay.wrap(child: FloatingChat(controller: ui, conversationId: a)),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('embaixo'));
    expect(taps, 1);
  });
}

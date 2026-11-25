// Telas de grupo contra o `directd` de mentira, com os goldens da conversa e
// das informações. Regerar: flutter test --update-goldens test/group_ui_test.dart
import 'dart:async';
import 'dart:io';

import 'package:direct/app_controller.dart';
import 'package:direct/bubble/mini.dart';
import 'package:direct/bubble/mini_view.dart';
import 'package:direct/chat/chat_service.dart';
import 'package:direct/core/api.dart';
import 'package:direct/core/crypto.dart';
import 'package:direct/core/group_proto.dart';
import 'package:direct/core/kv_store.dart';
import 'package:direct/core/media.dart';
import 'package:direct/core/vault.dart';
import 'package:direct/data/db.dart';
import 'package:direct/ui/chat_screen.dart';
import 'package:direct/ui/home_screen.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'fake_bio.dart';
import 'fake_directd.dart';
import 'golden_test.dart' show fakePhoto, loadFonts, themed;
import 'support.dart';

final now = DateTime(2026, 11, 25, 20, 30);

void main() {
  late DirectCrypto c;
  final skipGolden = Platform.environment['CI'] == 'true';

  setUpAll(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    c = await loadCrypto();
    await loadFonts();
  });

  AppController controller() => AppController(
    uptime: () async => 0,
    crypto: c,
    kv: MemoryKv(),
    vault: Vault(c.sodium, MemoryKv(), bio: FakeBio()),
    openDb: (_) async => AppDatabase(NativeDatabase.memory()),
    wipeDbFiles: () async {},
    apiFor: (host) => DirectApi(host),
    deviceInfo: () async => const DeviceInfoData('android', 'Teste', '15'),
    firstRunMarker: () async => false,
  );

  /// Grupo com mensagens, imagem, linhas de sistema e um membro sem acesso.
  Future<({FakeDirectd server, ChatService svc, FakeGroup g})> scene(WidgetTester tester, AppController ctl) async {
    var t = DateTime(2026, 11, 25, 20, 0).millisecondsSinceEpoch;
    final server = FakeDirectd(c, clock: () => t += 20000);
    final g = server.createGroup(server.ana, members: [meId, marcosId, paulaId]);
    server.say(g, server.ana, 'Reunião do Atlas às 9h', push: false);
    server.say(g, server.marcos, 'Levo o relatório', push: false);
    server.say(g, server.paula, 'Eu confirmo a sala', push: false);
    server.sayImage(g, server.paula, prepareImageSync(fakePhoto()));
    server.say(g, server.ana, 'Fechado', push: false);
    server.inactive.add(marcosId);
    g.access.add({'id': 1, 'user_id': marcosId, 'active': false, 'at': server.clock()});

    late final ChatService svc;
    await tester.runAsync(() async {
      // criado aqui: futuros e banco precisam do relógio real
      svc = server.service(isLocked: ctl.isConversationLocked);
      ctl.chat = svc;
      svc.start();
      for (var i = 0; i < 500 && svc.status != ChatStatus.online; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await svc.openGroup(g.id);
      await svc.send(g.id, 'Combinado');
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    expect(svc.status, ChatStatus.online, reason: '${svc.alerts}');
    return (server: server, svc: svc, g: g);
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  void phone(WidgetTester tester) {
    debugDisableShadows = false;
    tester.view.physicalSize = const Size(1080, 2250);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  /// Para o serviço (timers) e devolve as sombras, que o teste confere.
  Future<void> finish(WidgetTester tester, ChatService svc) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(svc.stop);
    await tester.pump(const Duration(seconds: 1));
    debugDisableShadows = true;
  }

  Widget app(Widget home) => MaterialApp(debugShowCheckedModeBanner: false, theme: themed(Brightness.dark), home: home);

  Future<void> golden(WidgetTester tester, String name) async {
    if (!skipGolden) await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
  }

  Widget chat(AppController ctl, ChatService svc, FakeGroup g) =>
      ChatScreen(controller: ctl, svc: svc, conversationId: g.id, title: 'Projeto Atlas', group: true);

  testWidgets('conversa de grupo: nomes, selada, linhas de acesso', (tester) async {
    phone(tester);
    final ctl = controller();
    final s = await scene(tester, ctl);
    // empilhada, como no app (aparece a seta de voltar)
    await tester.pumpWidget(app(const SizedBox()));
    unawaited(
      tester.state<NavigatorState>(find.byType(Navigator)).push(
        MaterialPageRoute<void>(builder: (_) => chat(ctl, s.svc, s.g)),
      ),
    );
    await settle(tester);

    expect(find.byType(BackButton), findsOneWidget);
    expect(find.text('Projeto Atlas'), findsOneWidget);
    expect(find.text('4 pessoas'), findsOneWidget);
    expect(find.text('Ana Souza - Diretoria'), findsWidgets);
    expect(find.text('Levo o relatório'), findsNothing, reason: 'autor sem acesso');
    expect(find.text(scramble(c, s.g.id, 2, 12)), findsOneWidget);
    expect(find.text('Marcos Lima - TI perdeu o acesso'), findsOneWidget);
    expect(find.text('Combinado'), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
    await golden(tester, 'grupo_dark');
    await finish(tester, s.svc);
  });

  testWidgets('informações do grupo: membros, ações de admin e histórico', (tester) async {
    phone(tester);
    final ctl = controller();
    final s = await scene(tester, ctl);
    await tester.pumpWidget(app(chat(ctl, s.svc, s.g)));
    await settle(tester);
    await tester.tap(find.byTooltip('Informações do grupo'));
    await settle(tester);
    expect(find.text('4 PESSOAS'), findsOneWidget);
    expect(find.text('João - Financeiro (você)'), findsOneWidget);
    expect(find.text('Admin'), findsOneWidget);
    expect(find.text('Adicionar pessoas'), findsNothing, reason: 'não é admin');
    expect(find.text('Esconder conversa'), findsNothing);
    await golden(tester, 'grupo_info_dark');
    await tester.scrollUntilVisible(find.text('Sair do grupo'), 200);
    expect(find.text('Encerrar grupo'), findsNothing);

    // vira admin: aparecem as ações
    s.server.change(s.g, kindPromote, s.server.ana, usersBody([meId]));
    await settle(tester);
    await tester.scrollUntilVisible(find.text('Adicionar pessoas'), -200);
    await tester.tap(find.text('Adicionar pessoas'));
    await settle(tester);
    expect(find.text('Mostrar o histórico para quem entra'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value, isFalse);
    await finish(tester, s.svc);
  });

  testWidgets('lista mista, trancar grupo e sem conexão', (tester) async {
    phone(tester);
    final ctl = controller();
    final s = await scene(tester, ctl);
    await tester.pumpWidget(app(HomeScreen(controller: ctl)));
    await settle(tester);
    expect(find.text('Projeto Atlas'), findsOneWidget);
    expect(find.byIcon(Icons.group), findsOneWidget);

    await tester.runAsync(() async {
      s.server.down = true;
      await s.server.link!.serverClose(1006);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await settle(tester);
    expect(find.text('Projeto Atlas'), findsNothing);
    expect(find.text('Grupos indisponíveis sem conexão'), findsOneWidget);
    await finish(tester, s.svc);
  });

  testWidgets('nome do grupo não vai para a notificação da bolha', (tester) async {
    phone(tester);
    final ctl = controller();
    final s = await scene(tester, ctl);
    final shown = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('direct/bubble'), (call) async {
      if (call.method == 'status') return <String, bool>{'notifications': true, 'bubbles': true};
      if (call.method == 'show') shown.add((call.arguments as Map)['title'] as String);
      return null;
    });
    await tester.pumpWidget(app(chat(ctl, s.svc, s.g)));
    await settle(tester);
    await tester.tap(find.byTooltip('Abrir em pop-up'));
    await settle(tester);
    expect(shown, ['Grupo']);
    await finish(tester, s.svc);
  });

  testWidgets('mini-chat de grupo mostra remetentes', (tester) async {
    phone(tester);
    final ctl = controller();
    final s = await scene(tester, ctl);
    final state = await tester.runAsync(() async {
      final lines = await s.svc.groupLines(s.g.id);
      return MiniState(
        MiniPhase.ready,
        title: 'Projeto Atlas',
        group: true,
        messages: [
          for (final l in lines)
            MiniMessage(
              id: l.message.id,
              mine: l.message.mine,
              state: l.message.state,
              sentAt: l.message.sentAt,
              text: l.message.kind == kindImage ? 'Foto' : l.message.body ?? '',
              sender: l.senderName,
              senderId: l.senderId,
            ),
        ],
      );
    });
    // atravessa a ponte entre isolates como na bolha
    final copy = MiniState.fromMap(state!.toMap());
    await tester.pumpWidget(
      app(Scaffold(body: MiniChatView(backend: _Fixed(copy), conversationId: s.g.id))),
    );
    await settle(tester);
    expect(find.text('Ana Souza - Diretoria'), findsWidgets);
    await finish(tester, s.svc);
  });
}

class _Fixed extends ChangeNotifier implements MiniBackend {
  _Fixed(this.state);
  final MiniState state;
  @override
  Future<MiniState> load(String conversationId) async => state;
  @override
  Future<String?> unlockApp({String? password}) async => null;
  @override
  Future<String?> unlockChat(String conversationId, {String? password}) async => null;
  @override
  Future<String?> send(String conversationId, String text) async => null;
  @override
  Future<void> retry(int rowId) async {}
  @override
  Future<void> touch() async {}
}

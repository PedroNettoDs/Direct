// Aparência das telas, com dados inventados. Regerar:
// flutter test --update-goldens test/golden_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:direct/app_controller.dart';
import 'package:direct/bubble/mini.dart';
import 'package:direct/bubble/mini_view.dart';
import 'package:direct/chat/chat_service.dart';
import 'package:direct/core/api.dart';
import 'package:direct/core/chat_crypto.dart';
import 'package:direct/core/crypto.dart';
import 'package:direct/core/kv_store.dart';
import 'package:direct/core/media.dart';
import 'package:direct/core/models.dart';
import 'package:direct/core/vault.dart';
import 'package:direct/data/db.dart';
import 'package:direct/ui/chat_screen.dart';
import 'package:direct/ui/home_screen.dart';
import 'package:direct/ui/theme.dart';
import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';

import 'fake_bio.dart';
import 'support.dart';

const me = '2b4d6f81-3a5c-4e7a-9b1d-3f5a7c9e1b2d';
const myDevice = '8e7d6c5b-4a39-4281-b7c6-d5e4f3a2b1c0';
final now = DateTime(2026, 11, 25, 20, 30);

String uuid(int n) => '33333333-3333-4333-8333-${n.toString().padLeft(12, '0')}';
int at(int day, int hour, int minute) => DateTime(2026, 11, day, hour, minute).millisecondsSinceEpoch;

const _emoji = '/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf';

/// Sem fontes de verdade o teste desenha caixas no lugar do texto.
Future<void> loadFonts() async {
  final dir = '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts';
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      loader.addFont(File(f).readAsBytes().then((b) => ByteData.sublistView(b)));
    }
    await loader.load();
  }

  await load('Roboto', [
    for (final w in ['Regular', 'Medium', 'Bold', 'Italic']) '$dir/Roboto-$w.ttf',
  ]);
  await load('MaterialIcons', ['$dir/MaterialIcons-Regular.otf']);
  if (File(_emoji).existsSync()) await load('Emoji', [_emoji]);
}

ThemeData themed(Brightness b) {
  final t = directTheme(b);
  return t.copyWith(textTheme: t.textTheme.apply(fontFamilyFallback: ['Emoji']));
}

Uint8List fakePhoto() {
  final p = img.Image(width: 120, height: 90);
  for (final px in p) {
    final hill = px.y > 55 + ((px.x - 70).abs() ~/ 3);
    px
      ..r = hill ? 40 : 250 - px.y
      ..g = hill ? 110 + px.x ~/ 3 : 170 - px.y ~/ 2
      ..b = hill ? 80 : 140 + px.y;
  }
  final jpg = img.encodeJpg(p, quality: 60);
  assert(jpg.length <= thumbMaxBytes, 'miniatura de ${jpg.length} bytes');
  return jpg;
}

/// Mensagens inventadas: (minha, quando, texto).
final script = <(bool, int, String)>[
  (false, at(23, 18, 10), 'Oi! Você vem no sábado?'),
  (true, at(23, 18, 12), 'Vou sim'),
  (true, at(23, 18, 12), 'Levo o bolo'),
  (false, at(24, 9, 2), 'Bom dia'),
  (false, at(24, 9, 2), 'Pode ser de cenoura?'),
  (false, at(24, 9, 3), 'Com bastante cobertura, por favor, que da última vez acabou rápido'),
  (true, at(24, 9, 5), 'Pode deixar'),
];
final today = <(bool, int, String)>[
  (false, at(25, 20, 3), 'Olha a vista daqui'),
  (true, at(25, 20, 5), 'Que lindo'),
  (true, at(25, 20, 5), 'Onde é isso?'),
  (true, at(25, 20, 6), 'Quero ir também'),
  (false, at(25, 20, 8), 'No mirante, perto de casa'),
  (false, at(25, 20, 8), '💙'),
  (true, at(25, 20, 9), 'Combinado então'),
];

class _FakeMini extends ChangeNotifier implements MiniBackend {
  _FakeMini(this.state);
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

void main() {
  late DirectCrypto c;

  setUpAll(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    c = await loadCrypto();
    await loadFonts();
  });

  // Renderização de fonte muda de máquina para máquina: no CI não compara.
  final skip = Platform.environment['CI'] == 'true';

  AppController controller({Future<int> Function()? uptime, FakeBio? bio}) => AppController(
    uptime: uptime ?? () async => 0,
    crypto: c,
    kv: MemoryKv(),
    vault: Vault(c.sodium, MemoryKv(), bio: bio ?? FakeBio()),
    openDb: (_) async => AppDatabase(NativeDatabase.memory()),
    wipeDbFiles: () async {},
    apiFor: (host) => DirectApi(host),
    deviceInfo: () async => const DeviceInfoData('android', 'Teste', '15'),
    firstRunMarker: () async => false,
  );

  Future<void> addConversation(AppDatabase db, int n, String name, String status, List<(bool, int, String)> msgs) async {
    final id = uuid(n), peer = uuid(100 + n);
    await db.into(db.dirUsers).insert(
      DirUsersCompanion.insert(userId: peer, adminLabel: name, displayName: '', status: status),
    );
    await db.into(db.conversations).insert(
      ConversationsCompanion.insert(
        conversationId: id,
        peerUserId: peer,
        membersJson: jsonEncode([me, peer]),
        latestEpoch: 1,
        syncedSeq: msgs.length,
      ),
    );
    var seq = 0;
    for (final (mine, time, text) in msgs) {
      seq++;
      await db.into(db.chatMessages).insert(
        ChatMessagesCompanion.insert(
          conversationId: id,
          messageId: '$n-$seq',
          seq: Value(seq),
          epoch: 1,
          senderDeviceId: myDevice,
          sentAt: time,
          body: Value(text),
          state: msgOk,
          mine: mine,
        ),
      );
    }
  }

  /// Banco com a conversa principal (foto, aviso A1, envio em andamento) e outras.
  Future<ChatService> service() async {
    final db = AppDatabase(NativeDatabase.memory());
    await addConversation(db, 1, 'Bia Souza', 'No trabalho', script);
    final id = uuid(1);
    Future<void> add(int seq, bool mine, int when, String body, {int state = msgOk, int kind = kindText}) =>
        db.into(db.chatMessages).insert(
          ChatMessagesCompanion.insert(
            conversationId: id,
            messageId: 'x-$seq-$state-$kind-$when',
            seq: Value(state == msgSending ? null : seq),
            epoch: 1,
            senderDeviceId: myDevice,
            sentAt: when,
            body: Value(body),
            kind: Value(kind),
            state: state,
            mine: mine,
          ),
        );
    await add(7, false, at(25, 19, 0), 'Bia Souza conectou um aparelho novo em 25/11/2026 19:00', state: msgNotice);
    await add(8, false, today.first.$2, today.first.$3);
    final photo = ImageRef(
      blobId: uuid(900),
      key: Uint8List(32),
      sha256: Uint8List(32),
      width: 120,
      height: 90,
      thumb: fakePhoto(),
    );
    await add(9, false, at(25, 20, 3), photo.toJson(), kind: kindImage);
    var seq = 10;
    for (final (mine, time, text) in today.skip(1)) {
      await add(seq++, mine, time, text);
    }
    await add(seq, true, at(25, 20, 10), 'Até sábado!', state: msgSending);

    await addConversation(db, 2, 'Caio Lima', '', [(false, at(25, 14, 40), 'Mandei o arquivo, confere?')]);
    await addConversation(db, 3, 'Dona Rosa', '', [(true, at(24, 21, 15), 'Boa noite!')]);
    await addConversation(db, 4, 'Marcos', '', [
      (false, at(20, 8, 0), 'Essa é uma mensagem bem comprida que não cabe inteira na linha da lista'),
    ]);

    final keys = c.generateDeviceKeys();
    final svc = ChatService(
      db: db,
      api: DirectApi('h.example'),
      crypto: ChatCrypto(c),
      keys: keys,
      cert: DeviceCert(
        deviceId: myDevice,
        userId: me,
        adminLabel: 'Eu',
        signPub: keys.signPub,
        kexPub: keys.kexPub,
        enrolledAt: 0,
        expiresAt: 0,
        sig: Uint8List(64),
      ),
      serverSignPub: Uint8List(32),
      escrowPub: Uint8List(32),
      modPub: Uint8List(32), // grupos ativados: sem a linha "Ative os grupos"
      login: () => throw StateError('sem rede'),
      clock: () => now,
    );
    svc.status = ChatStatus.online;
    return svc;
  }

  /// Deixa o banco responder e as imagens decodificarem.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  /// Tela de celular, com sombras de verdade em vez dos blocos pretos do teste.
  /// Quem chama termina com `debugDisableShadows = true` (o teste confere).
  void phone(WidgetTester tester) {
    debugDisableShadows = false;
    tester.view.physicalSize = const Size(1080, 2250);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  Widget app(Brightness b, Widget home) =>
      MaterialApp(debugShowCheckedModeBanner: false, theme: themed(b), home: home);

  /// Monta [screen] empilhada sobre outra, como no app (aparece a seta de voltar).
  Future<void> push(WidgetTester tester, Brightness b, Widget screen) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: nav, debugShowCheckedModeBanner: false, theme: themed(b), home: const SizedBox()),
    );
    nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => screen));
    await settle(tester);
  }

  Future<void> golden(WidgetTester tester, String name) =>
      expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));

  for (final b in Brightness.values) {
    testWidgets('conversa, tema ${b.name}', skip: skip, (tester) async {
      phone(tester);
      final svc = (await tester.runAsync(service))!;
      await push(tester, b, ChatScreen(controller: controller(), svc: svc, conversationId: uuid(1), title: 'Bia Souza'));
      expect(find.byType(BackButton), findsOneWidget);
      expect(find.byType(Image), findsOneWidget, reason: 'a foto aparece como imagem');
      await golden(tester, 'conversa_${b.name}');
      debugDisableShadows = true;
    });

    testWidgets('lista, tema ${b.name}', skip: skip, (tester) async {
      phone(tester);
      final svc = (await tester.runAsync(service))!;
      final ctl = controller()..chat = svc;
      await tester.pumpWidget(app(b, HomeScreen(controller: ctl)));
      await settle(tester);
      await golden(tester, 'lista_${b.name}');
      debugDisableShadows = true;
    });
  }

  testWidgets('informações do contato', skip: skip, (tester) async {
    phone(tester);
    final svc = (await tester.runAsync(service))!;
    await tester.runAsync(() async {
      final cert = DeviceCert(
        deviceId: uuid(500),
        userId: uuid(101),
        adminLabel: 'Bia Souza',
        signPub: Uint8List(32),
        kexPub: Uint8List(32),
        enrolledAt: 0,
        expiresAt: 0,
        sig: Uint8List(64),
      );
      await svc.db.into(svc.db.knownDevices).insert(
        KnownDevicesCompanion.insert(
          deviceId: cert.deviceId,
          userId: cert.userId,
          certJson: jsonEncode(cert.toJson()),
          active: true,
        ),
      );
    });
    await push(
      tester,
      Brightness.dark,
      ChatScreen(controller: controller(), svc: svc, conversationId: uuid(1), title: 'Bia Souza'),
    );
    await tester.tap(find.byTooltip('Informações do contato'));
    await settle(tester);
    expect(find.text('Código do aparelho'), findsOneWidget);
    expect(find.text('Trancar conversa'), findsOneWidget);
    expect(find.text('Esconder conversa'), findsNothing, reason: '"Adicionar secrets" vem desligado');
    await golden(tester, 'contato_dark');
    debugDisableShadows = true;

    // trancar pela folha fecha a folha e esconde o conteúdo
    await tester.tap(find.text('Trancar conversa'));
    await settle(tester);
    expect(find.text('Desbloquear conversa'), findsOneWidget);
    expect(find.text('Que lindo'), findsNothing);
  });

  testWidgets('ocultas: 6 toques nada, 7 mostram, sair da tela esconde; pedido de senha', skip: skip, (tester) async {
    phone(tester);
    final svc = (await tester.runAsync(service))!;
    await tester.runAsync(() async {
      for (final n in [2, 3]) {
        await svc.hide(uuid(n), c.x25519Pub(c.random(32)), '{}');
      }
    });
    var up = 0;
    final bio = FakeBio();
    final ctl = controller(uptime: () async => up, bio: bio)
      ..chat = svc
      ..bioEnabled = true;
    await tester.pumpWidget(app(Brightness.dark, HomeScreen(controller: ctl)));
    await settle(tester);

    Future<void> tapTitle(int times, {int gap = 100}) async {
      for (var i = 0; i < times; i++) {
        up += gap;
        await tester.tap(find.text('Conversas'));
        await tester.pump();
      }
      await settle(tester);
    }

    expect(find.text('Caio Lima'), findsNothing);
    await tapTitle(6);
    expect(find.text('OCULTAS'), findsNothing);
    expect(find.text('Caio Lima'), findsNothing);
    up += 10000; // os 6 de antes vencem
    await tapTitle(7, gap: 600); // devagar demais: mais de 3 s
    expect(find.text('OCULTAS'), findsNothing);
    up += 10000;
    await tapTitle(7, gap: 400);
    expect(find.text('Caio Lima'), findsOneWidget);
    expect(find.text('Dona Rosa'), findsOneWidget);
    expect(find.text('Mandei o arquivo, confere?'), findsNothing, reason: 'sem prévia');
    await golden(tester, 'lista_ocultas_dark');

    await tester.tap(find.text('Caio Lima'));
    await settle(tester);
    expect(find.text('Abrir'), findsOneWidget);
    expect(find.byIcon(Icons.fingerprint), findsNothing);
    expect(find.text('Mandei o arquivo, confere?'), findsNothing);
    expect(bio.prompts, 0);
    await golden(tester, 'oculta_senha_dark');

    await tester.tap(find.byType(BackButton));
    await settle(tester);
    expect(find.text('Bia Souza'), findsOneWidget);
    expect(find.text('Caio Lima'), findsNothing, reason: 'sair da tela esconde de novo');
    debugDisableShadows = true;
  });

  testWidgets('ocultas: esconder pela folha, abrir com a senha e mostrar de novo', skip: skip, (tester) async {
    phone(tester);
    final svc = (await tester.runAsync(service))!;
    final ctl = controller()
      ..chat = svc
      ..secretsEnabled = true;
    await tester.pumpWidget(app(Brightness.dark, HomeScreen(controller: ctl)));
    await settle(tester);
    await tester.tap(find.text('Bia Souza'));
    await settle(tester);

    Future<void> info(String item) async {
      await tester.tap(find.byTooltip('Informações do contato'));
      await settle(tester);
      await tester.ensureVisible(find.text(item));
      await tester.tap(find.text(item));
      await settle(tester);
    }

    await info('Esconder conversa');
    await tester.enterText(find.byKey(const Key('hidden-new')), 'senha-oculta');
    await tester.enterText(find.byKey(const Key('hidden-again')), 'senha-outra-x');
    await tester.tap(find.text('Esconder'));
    await tester.pump();
    expect(find.text('As senhas não são iguais.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('hidden-again')), 'senha-oculta');
    await tester.tap(find.text('Esconder'));
    await settle(tester);
    expect(svc.isHidden(uuid(1)), isTrue);
    expect(find.text('Conversas'), findsOneWidget, reason: 'voltou para a lista');
    expect(find.text('Bia Souza'), findsNothing);

    for (var i = 0; i < 7; i++) {
      await tester.tap(find.text('Conversas'));
      await tester.pump();
    }
    await settle(tester);
    await tester.tap(find.text('Bia Souza'));
    await settle(tester);
    await tester.enterText(find.byKey(const Key('hidden-password')), 'senha-errada');
    await tester.tap(find.text('Abrir'));
    await settle(tester);
    expect(find.text('Senha errada.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('hidden-password')), 'senha-oculta');
    await tester.tap(find.text('Abrir'));
    await settle(tester);
    expect(find.text('Que lindo'), findsOneWidget);
    expect(find.byTooltip('Abrir em pop-up'), findsNothing);

    await info('Mostrar conversa');
    expect(svc.isHidden(uuid(1)), isFalse);
    expect(find.text('Que lindo'), findsOneWidget);
    expect(find.byTooltip('Abrir em pop-up'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    debugDisableShadows = true;
  });

  testWidgets('mini-chat, tema dark', skip: skip, (tester) async {
    phone(tester);
    final state = MiniState(
      MiniPhase.ready,
      title: 'Bia Souza',
      messages: [
        for (final (i, (mine, time, text)) in today.indexed)
          MiniMessage(id: i, mine: mine, state: msgOk, sentAt: time, text: text),
      ],
    );
    await tester.pumpWidget(
      app(Brightness.dark, Scaffold(body: SafeArea(child: MiniChatView(backend: _FakeMini(state), conversationId: uuid(1))))),
    );
    await settle(tester);
    await golden(tester, 'mini_dark');
    debugDisableShadows = true;
  });
}

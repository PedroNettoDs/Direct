// Integração com um `directd` real (Postgres de teste). Só roda com
//   DIRECTD_E2E=127.0.0.1:8080 flutter test test/e2e_test.dart
// Precisa de `python3` com PyNaCl e do contêiner `direct-test-pg` (server/scripts/dev_invite.py).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:direct/app_controller.dart';
import 'package:direct/chat/chat_service.dart';
import 'package:direct/core/api.dart';
import 'package:direct/core/kv_store.dart';
import 'package:direct/core/media.dart';
import 'package:direct/core/vault.dart';
import 'package:direct/core/ws.dart';
import 'package:direct/data/db.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'support.dart';

final addr = Platform.environment['DIRECTD_E2E'];

Future<void> until(String what, Future<bool> Function() cond, {int secs = 20}) async {
  final end = DateTime.now().add(Duration(seconds: secs));
  while (DateTime.now().isBefore(end)) {
    if (await cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('timeout: $what');
}

Future<List<String>> bodies(ChatService s, String conv) async =>
    [for (final m in await s.messages(conv)) '${m.mine ? "eu" : "outro"}:${m.body}'];

void main() {
  test('dois aparelhos trocam mensagens nos dois sentidos pelo directd real', () async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final c = await loadCrypto();
    final links = <WsLink>[];
    final tmp = await Directory.systemTemp.createTemp('direct_e2e');
    addTearDown(() => tmp.delete(recursive: true));

    String invite(String label) {
      final r = Process.runSync('python3', ['../server/scripts/dev_invite.py', '10.0.2.2', label]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      return (r.stdout as String).trim();
    }

    AppController build(String name) {
      final kv = MemoryKv();
      final file = File('${tmp.path}/$name.db');
      return AppController(
        crypto: c,
        kv: kv,
        vault: Vault(
          c.sodium,
          kv,
          opsLimit: c.sodium.crypto.pwhash.opsLimitMin,
          memLimit: c.sodium.crypto.pwhash.memLimitMin,
        ),
        openDb: (key) async => AppDatabase(NativeDatabase(file)),
        wipeDbFiles: () async {},
        apiFor: (h) => DirectApi(h, debugBase: Uri.parse('http://$addr')),
        deviceInfo: () async => const DeviceInfoData('android', 'Teste', '15'),
        firstRunMarker: () async => false,
        wsConnector: name == 'a'
            ? (u) async {
                final l = await connectWs(u);
                links.add(l);
                return l;
              }
            : null,
      );
    }

    final stamp = DateTime.now().millisecondsSinceEpoch % 100000;
    final a = build('a'), b = build('b');
    for (final (ctl, label) in [(a, 'Ana E2E $stamp'), (b, 'Beto E2E $stamp')]) {
      await ctl.init();
      await ctl.enroll(ctl.inviteFromQr(invite(label)), 'senha-de-teste-1');
      await ctl.saveProfile(label.split(' ').first, 'status');
      expect(ctl.stage, Stage.ready);
    }
    ChatService svcA() => a.chat!;
    ChatService svcB() => b.chat!;

    await until('A online', () async => svcA().status == ChatStatus.online);
    await until('B online', () async => svcB().status == ChatStatus.online);

    String? peer;
    await until('B no diretório de A', () async {
      final d = await svcA().directory();
      peer = d.where((u) => u.adminLabel == 'Beto E2E $stamp').firstOrNull?.userId;
      return peer != null;
    });

    final conv = await svcA().openConversationWith(peer!);
    await svcA().send(conv, 'oi Beto 👋');
    await until('B recebe', () async => (await bodies(svcB(), conv)).contains('outro:oi Beto 👋'));

    await svcB().send(conv, 'oi Ana, recebi');
    await until('A recebe', () async => (await bodies(svcA(), conv)).contains('outro:oi Ana, recebi'));
    await until('envios com ack', () async {
      final ms = [...await svcA().messages(conv), ...await svcB().messages(conv)];
      return ms.where((m) => m.mine).every((m) => m.seq != null);
    });

    // fecha e abre o app de A: o histórico volta do banco local e a sincronização continua
    await a.lock();
    expect(a.chat, isNull);
    await b.chat!.send(conv, 'enquanto você estava fora');
    await until('B ack', () async => (await svcB().messages(conv)).every((m) => m.seq != null));
    await a.unlock('senha-de-teste-1');
    final histAntes = await bodies(svcA(), conv);
    expect(histAntes.take(2), ['eu:oi Beto 👋', 'outro:oi Ana, recebi']);
    await until('A sincroniza o que perdeu', () async {
      return (await bodies(svcA(), conv)).contains('outro:enquanto você estava fora');
    });
    await svcA().send(conv, 'voltei');
    await until('B recebe depois da reconexão', () async => (await bodies(svcB(), conv)).contains('outro:voltei'));

    // queda da conexão de A: reconecta sozinho e volta a receber
    final before = links.length;
    await links.last.close();
    await until('A reconecta', () async => links.length > before && svcA().status == ChatStatus.online, secs: 30);
    await svcB().send(conv, 'depois da queda');
    await until('A recebe após reconectar', () async => (await bodies(svcA(), conv)).contains('outro:depois da queda'));

    final lista = await svcA().conversations();
    expect(lista.single.lastText, 'depois da queda');

    // ---- imagem (protocolo §18): A envia, B baixa/decifra, B salva com EXIF e registro ----
    final im = img.Image(width: 2600, height: 1800, numChannels: 3);
    for (final p in im) {
      p.setRgb(p.x % 256, p.y % 256, (p.x ~/ 7 + p.y ~/ 5) % 256);
    }
    im.exif.imageIfd.make = 'AparelhoSecreto';
    final prepared = await prepareImage(Uint8List.fromList(img.encodeJpg(im, quality: 90)));
    expect(prepared.width, 2048);
    await svcA().sendImage(conv, prepared);
    await until('B recebe a imagem', () async {
      return (await svcB().messages(conv)).any((m) => m.kind == kindImage && m.state == msgOk && !m.mine);
    });
    final recebida = (await svcB().messages(conv)).firstWhere((m) => m.kind == kindImage);
    final antes = await svcB().db.select(svcB().db.attachments).get();
    expect(antes.where((a) => a.messageId == recebida.messageId), isEmpty, reason: 'só baixa ao abrir');
    final jpegB = await svcB().loadImage(recebida);
    expect(jpegB, prepared.jpeg); // a foto volta idêntica
    final guardado = (await svcB().db.select(svcB().db.attachments).get()).firstWhere((a) => a.messageId == recebida.messageId);
    expect(guardado.data, isNot(prepared.jpeg)); // no banco, só o blob cifrado
    expect(guardado.data!.length, prepared.jpeg.length + 40);
    // o remetente também abre a própria imagem, do blob cifrado local
    await until('A com ack da imagem', () async {
      return (await svcA().messages(conv)).where((m) => m.kind == kindImage).every((m) => m.seq != null);
    });
    final minha = (await svcA().messages(conv)).firstWhere((m) => m.kind == kindImage);
    expect(await svcA().loadImage(minha), prepared.jpeg);
    // salvar na galeria: registra no servidor e devolve o JPEG com EXIF
    final salvo = await svcB().prepareSave(recebida);
    final ex = readSaveExif(salvo);
    expect(ex.artist, 'Beto E2E $stamp');
    expect(ex.description, startsWith('Direct save_id='));
    expect(ex.comment, ex.description);
    expect(ex.description, contains('user=${svcB().selfUserId} device=${svcB().selfDeviceId} at='));
    // ignore: avoid_print
    print('E2E_SAVE ${ex.description}');
    File('${Platform.environment['DIRECTD_E2E_OUT'] ?? tmp.path}/salvo.jpg').writeAsBytesSync(salvo);
    expect(latin1.decode(prepared.jpeg).contains('AparelhoSecreto'), isFalse);
    expect(svcA().alerts, isEmpty);
    expect(svcB().alerts, isEmpty);

    await a.lock();
    await b.lock();
  }, skip: addr == null ? 'defina DIRECTD_E2E=host:porta' : false, timeout: const Timeout(Duration(minutes: 2)));
}

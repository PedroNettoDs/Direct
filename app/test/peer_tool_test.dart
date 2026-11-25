// Ferramenta de dev, não é teste: faz o papel do "outro aparelho" para provar o
// chat no emulador. Cadastra o usuário "Peer Bot", responde "eco: <texto>" a tudo
// e cumprimenta toda conversa nova. Termina sozinho.
//   DIRECTD_PEER=127.0.0.1:8080 PEER_MINUTES=5 [PEER_TO=<admin_label>] flutter test test/peer_tool_test.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:direct/app_controller.dart';
import 'package:direct/core/api.dart';
import 'package:direct/core/kv_store.dart';
import 'package:direct/core/media.dart';
import 'package:direct/core/vault.dart';
import 'package:direct/data/db.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'support.dart';

void main() {
  final addr = Platform.environment['DIRECTD_PEER'];
  test('peer bot', () async {
    final c = await loadCrypto();
    final kv = MemoryKv();
    final ctl = AppController(
      crypto: c,
      kv: kv,
      vault: Vault(
        c.sodium,
        kv,
        opsLimit: c.sodium.crypto.pwhash.opsLimitMin,
        memLimit: c.sodium.crypto.pwhash.memLimitMin,
      ),
      openDb: (key) async => AppDatabase(NativeDatabase.memory()),
      wipeDbFiles: () async {},
      apiFor: (h) => DirectApi(h, debugBase: Uri.parse('http://$addr')),
      deviceInfo: () async => const DeviceInfoData('android', 'Peer', '15'),
      firstRunMarker: () async => false,
    );
    await ctl.init();
    final r = Process.runSync('python3', ['../server/scripts/dev_invite.py', '10.0.2.2', 'Peer Bot']);
    await ctl.enroll(ctl.inviteFromQr((r.stdout as String).trim()), 'senha-de-teste-1');
    await ctl.saveProfile('Peer', 'bot de teste');
    final svc = ctl.chat!;
    stdout.writeln('PEER pronto');
    // PEER_TO=<admin_label>: o bot abre a conversa em vez de esperar.
    final to = Platform.environment['PEER_TO'];
    if (to != null) {
      String? peer;
      while (peer == null) {
        peer = (await svc.directory()).where((u) => u.adminLabel == to).firstOrNull?.userId;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      await svc.openConversationWith(peer);
    }
    final done = <String>{};
    final greeted = <String>{};
    final end = DateTime.now().add(Duration(minutes: int.parse(Platform.environment['PEER_MINUTES'] ?? '5')));
    while (DateTime.now().isBefore(end)) {
      for (final cv in await svc.conversations()) {
        if (greeted.add(cv.conversationId)) {
          await svc.send(cv.conversationId, 'olá, aqui é o Peer Bot');
          await svc.sendImage(cv.conversationId, await prepareImage(_demoJpeg()));
        }
        for (final m in await svc.messages(cv.conversationId)) {
          if (!m.mine && m.kind == kindImage && m.state == msgOk && done.add(m.messageId)) {
            final jpeg = await svc.loadImage(m);
            stdout.writeln('PEER recebeu imagem de ${jpeg.length} bytes');
          } else if (!m.mine && m.kind == kindText && m.body != null && done.add(m.messageId)) {
            stdout.writeln('PEER recebeu: ${m.body}');
            await svc.send(cv.conversationId, 'eco: ${m.body}');
          }
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    await ctl.lock();
  }, skip: addr == null ? 'ferramenta de dev' : false, timeout: const Timeout(Duration(minutes: 30)));
}

Uint8List _demoJpeg() {
  final im = img.Image(width: 1600, height: 1200, numChannels: 3);
  for (final p in im) {
    p.setRgb(p.x * 255 ~/ 1600, p.y * 255 ~/ 1200, 160);
  }
  return Uint8List.fromList(img.encodeJpg(im, quality: 90));
}

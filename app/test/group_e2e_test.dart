// Grupos com `directd` e `direct-admin` reais. Só roda com
//   DIRECTD_E2E=127.0.0.1:18097 DIRECT_E2E_DIR=<pasta> flutter test test/group_e2e_test.dart
// A pasta tem: `direct-admin` compilado, `env.sh` (variáveis do banco e da CLI),
// `escrow.key` (senha "senha-escrow-de-teste-123") e `mod.key`
// ("senha-moderador-de-teste-123"), com `moderator register` já feito.
import 'dart:io';
import 'dart:typed_data';

import 'package:direct/app_controller.dart';
import 'package:direct/chat/chat_service.dart';
import 'package:direct/core/api.dart';
import 'package:direct/core/group_proto.dart';
import 'package:direct/core/kv_store.dart';
import 'package:direct/core/media.dart';
import 'package:direct/core/vault.dart';
import 'package:direct/data/db.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'support.dart';

final addr = Platform.environment['DIRECTD_E2E'];
final dir = Platform.environment['DIRECT_E2E_DIR'];

Future<void> until(String what, Future<bool> Function() cond, {int secs = 20}) async {
  final end = DateTime.now().add(Duration(seconds: secs));
  while (DateTime.now().isBefore(end)) {
    if (await cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('timeout: $what');
}

/// Roda a CLI do moderador; [input] vai para a entrada padrão (senhas, "sim").
Future<String> admin(String args, [String input = '']) async {
  final p = await Process.start('bash', ['-c', '. ./env.sh && ./direct-admin $args'], workingDirectory: dir);
  p.stdin.write(input);
  await p.stdin.close();
  final out = await p.stdout.transform(const SystemEncoding().decoder).join();
  final err = await p.stderr.transform(const SystemEncoding().decoder).join();
  expect(await p.exitCode, 0, reason: 'direct-admin $args\n$out\n$err');
  return out;
}

String invite(String out) => RegExp(r'direct://enroll\?\S+').firstMatch(out)!.group(0)!;

Future<List<String>> said(AppController c, String id) async => [
  for (final l in await c.chat!.groupLines(id))
    if (l.message.state != msgNotice) l.message.kind == kindImage ? 'foto' : l.message.body ?? '',
];

Future<List<String>> notices(AppController c, String id) async => [
  for (final l in await c.chat!.groupLines(id))
    if (l.message.state == msgNotice) l.message.body ?? '',
];

void main() {
  test('grupos de ponta a ponta no directd real', () async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final c = await loadCrypto();
    final tmp = await Directory.systemTemp.createTemp('direct_group_e2e');
    addTearDown(() => tmp.delete(recursive: true));
    var n = 0;

    final files = <AppController, File>{};
    AppController build() {
      final kv = MemoryKv();
      final file = File('${tmp.path}/${n++}.db');
      final ctl = AppController(
        crypto: c,
        kv: kv,
        vault: Vault(c.sodium, kv, opsLimit: c.sodium.crypto.pwhash.opsLimitMin, memLimit: c.sodium.crypto.pwhash.memLimitMin),
        openDb: (key) async => AppDatabase(NativeDatabase(file)),
        wipeDbFiles: () async {},
        apiFor: (h) => DirectApi(h, debugBase: Uri.parse('http://$addr')),
        deviceInfo: () async => const DeviceInfoData('android', 'Teste', '15'),
        firstRunMarker: () async => false,
      );
      files[ctl] = file;
      return ctl;
    }

    Future<AppController> join(String qr, String name) async {
      final ctl = build();
      await ctl.init();
      await ctl.enroll(ctl.inviteFromQr(qr), 'senha-de-teste-1');
      await ctl.saveProfile(name, '');
      expect(ctl.groupsEnabled, isTrue, reason: 'o convite v=2 fixa a chave do moderador');
      await until('$name online', () async => ctl.chat!.status == ChatStatus.online);
      return ctl;
    }

    final stamp = DateTime.now().millisecondsSinceEpoch % 100000;
    Future<String> newInvite(String label) async => invite(await admin('token create --new-user "$label $stamp"'));

    final ana = await join(await newInvite('Ana'), 'Ana');
    final beto = await join(await newInvite('Beto'), 'Beto');
    final caio = await join(await newInvite('Caio'), 'Caio');
    final anaId = ana.chat!.selfUserId, betoId = beto.chat!.selfUserId, caioId = caio.chat!.selfUserId;
    String label(String who) => '$who $stamp';

    // ---- criar, enviar, receber ----
    final id = await ana.chat!.createGroup(GroupProfile(name: 'Projeto Atlas', description: 'equipe'), [betoId]);
    await until('Beto vê o grupo', () async => (await beto.chat!.conversations()).any((v) => v.conversationId == id));
    await beto.chat!.openGroup(id);
    await until('Beto lê o nome', () async => await beto.chat!.groupTitle(id) == 'Projeto Atlas');
    await ana.chat!.send(id, 'bom dia, grupo');
    await until('Beto recebe', () async => (await said(beto, id)).contains('bom dia, grupo'));
    await beto.chat!.send(id, 'bom dia, Ana');
    await until('Ana recebe', () async => (await said(ana, id)).contains('bom dia, Ana'));

    // ---- imagem ----
    final im = img.Image(width: 640, height: 480, numChannels: 3);
    for (final p in im) {
      p.setRgb(p.x % 256, p.y % 256, (p.x + p.y) % 256);
    }
    final photo = await prepareImage(Uint8List.fromList(img.encodeJpg(im, quality: 90)));
    await ana.chat!.sendImage(id, photo);
    await until('Beto recebe a foto', () async => (await said(beto, id)).contains('foto'));
    final received = (await beto.chat!.groupLines(id)).lastWhere((l) => l.message.kind == kindImage).message;
    expect(await beto.chat!.loadImage(received), photo.jpeg);
    expect(readSaveExif(await beto.chat!.prepareSave(received)).artist, label('Beto'));

    // ---- adicionar com histórico ----
    await ana.chat!.addMembers(id, [caioId], history: true);
    await until('Caio vê o grupo', () async => (await caio.chat!.conversations()).any((v) => v.conversationId == id));
    await caio.chat!.openGroup(id);
    await until('Caio lê o passado', () async => (await said(caio, id)).contains('bom dia, grupo'));
    expect(await caio.chat!.groupTitle(id), 'Projeto Atlas');

    // ---- renomear com foto, promover, remover ----
    await ana.chat!.editGroup(
      id,
      GroupProfile(name: 'Atlas 2', photo: await prepareGroupPhoto(Uint8List.fromList(img.encodeJpg(im)))),
    );
    await until('Beto vê o nome novo', () async => await beto.chat!.groupTitle(id) == 'Atlas 2');
    expect(beto.chat!.groupPhoto(id), isNotNull);
    await ana.chat!.promoteMember(id, betoId);
    await ana.chat!.removeMember(id, caioId);
    await until('Caio perde o grupo', () async => !(await caio.chat!.conversations()).any((v) => v.conversationId == id));
    await ana.chat!.send(id, 'sem o Caio');
    await until('Beto recebe', () async => (await said(beto, id)).contains('sem o Caio'));

    // ---- trancar o app e voltar: tudo vem de novo do servidor ----
    await beto.lock();
    await beto.unlock('senha-de-teste-1');
    await until('Beto online', () async => beto.chat?.status == ChatStatus.online);
    await beto.chat!.openGroup(id);
    await until('histórico de volta', () async => (await said(beto, id)).contains('sem o Caio'));

    // nada do grupo no disco: nem texto, nem nome
    final raw = String.fromCharCodes(await files[beto]!.readAsBytes());
    for (final secret in ['bom dia', 'Atlas', 'sem o Caio']) {
      expect(raw.contains(secret), isFalse, reason: secret);
    }

    // ---- "Esqueci a senha": revogação pré-assinada e mensagens seladas (D11) ----
    await beto.lock();
    await beto.forgotPassword();
    expect(beto.stage, Stage.enroll);
    await until('Ana vê Beto sem acesso', () async {
      return (await notices(ana, id)).contains('${label('Beto')} perdeu o acesso') &&
          !(await said(ana, id)).contains('bom dia, Ana');
    });
    expect((await ana.chat!.groupLines(id)).where((l) => l.message.state == msgSealed), hasLength(1));

    // ---- o moderador restaura: novo convite, cadastro e rewrap do escrow ----
    final again = await join(invite(await admin('token create --user $betoId')), 'Beto');
    await until('Ana vê Beto de volta', () async {
      return (await notices(ana, id)).contains('${label('Beto')} voltou ao grupo') &&
          (await said(ana, id)).contains('bom dia, Ana');
    });
    final device = again.chat!.selfDeviceId;
    await admin('escrow rewrap --device $device --key escrow.key', 'sim\nsenha-escrow-de-teste-123\nsim\n');
    await again.lock();
    await again.unlock('senha-de-teste-1');
    await until('Beto online de novo', () async => again.chat?.status == ChatStatus.online);
    await again.chat!.openGroup(id);
    await until('rewrap devolve o histórico', () async => (await said(again, id)).contains('bom dia, grupo'));

    // ---- grupo oficial do moderador ----
    await admin(
      'group create --label "Diretoria $stamp" --admin $anaId --member $caioId --mod-key mod.key',
      'senha-moderador-de-teste-123\nsim\n',
    );
    String? official;
    await until('Ana vê o oficial', () async {
      official = (await ana.chat!.conversations()).where((v) => v.title == 'Diretoria $stamp').firstOrNull?.conversationId;
      return official != null;
    });
    final o = official!;
    await ana.chat!.openGroup(o);
    await ana.chat!.send(o, 'primeira do oficial');
    await until('Caio recebe no oficial', () async {
      await caio.chat!.openGroup(o);
      return (await said(caio, o)).contains('primeira do oficial');
    });
    await admin('group remove-member $o $caioId --mod-key mod.key', 'senha-moderador-de-teste-123\nsim\n');
    await until('Caio sai do oficial', () async => !(await caio.chat!.conversations()).any((v) => v.conversationId == o));
    await admin('group close $o --mod-key mod.key', 'senha-moderador-de-teste-123\nsim\n');
    await until('Ana vê encerrado', () async => ana.chat!.groupNotice(o) == 'Este grupo foi encerrado.');

    // ---- sair ----
    await again.chat!.leaveGroup(id);
    // o registro feito por aparelho recém-cadastrado vem destacado (§12)
    await until('Ana vê a saída', () async {
      return (await notices(ana, id)).contains('${label('Beto')} saiu do grupo (por um aparelho novo)');
    });

    expect(ana.chat!.alerts, isEmpty);
    expect(caio.chat!.alerts, isEmpty);
    expect(again.chat!.alerts, isEmpty);
    for (final ctl in [ana, caio, again]) {
      await ctl.lock();
    }
  }, skip: addr == null || dir == null ? 'defina DIRECTD_E2E e DIRECT_E2E_DIR' : false, timeout: const Timeout(Duration(minutes: 4)));
}

// Grupos de ponta a ponta no cliente, contra o `directd` de mentira.
import 'dart:async';
import 'dart:typed_data';

import 'package:direct/chat/chat_service.dart';
import 'package:direct/core/crypto.dart';
import 'package:direct/core/errors.dart';
import 'package:direct/core/group_proto.dart';
import 'package:direct/core/media.dart';
import 'package:direct/data/db.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'fake_directd.dart';
import 'support.dart';

Uint8List jpeg() => img.encodeJpg(img.Image(width: 40, height: 30), quality: 60);

void main() {
  late DirectCrypto c;
  late FakeDirectd server;
  late ChatService svc;
  late AppDatabase db;
  final locked = <String>{};
  var purges = 0;

  setUpAll(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    c = await loadCrypto();
  });

  Future<void> until(String what, FutureOr<bool> Function() cond) async {
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(end)) {
      if (await cond()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('timeout: $what (alertas: ${svc.alerts})');
  }

  setUp(() {
    server = FakeDirectd(c);
    db = AppDatabase(NativeDatabase.memory());
    locked.clear();
    purges = 0;
  });

  tearDown(() async {
    await svc.stop();
    await db.close();
  });

  Future<void> online({bool pinned = true}) async {
    svc = server.service(db: db, pinned: pinned, isLocked: locked.contains);
    svc.addListener(() {});
    svc.start();
    await until('online', () => svc.status == ChatStatus.online);
  }

  Future<List<String>> texts(String id) async => [for (final l in await svc.groupLines(id)) l.message.body ?? ''];

  Future<List<String>> said(String id) async => [
    for (final l in await svc.groupLines(id)) if (l.message.state != msgNotice) l.message.body ?? '',
  ];

  Future<void> open(String id) async {
    await svc.openGroup(id);
    await until('grupo aberto', () => svc.groupNotice(id) == null);
  }

  /// Tudo o que há no banco, como texto.
  Future<String> disk() async {
    final out = StringBuffer();
    for (final t in db.allTables) {
      final rows = await db.customSelect('SELECT * FROM ${t.actualTableName}').get();
      for (final r in rows) {
        out.writeln('${t.actualTableName}: ${r.data}');
      }
    }
    return out.toString();
  }

  test('sem a chave do moderador fixada, nada de grupo aparece', () async {
    server.createGroup(server.ana, members: [meId]);
    await online(pinned: false);
    expect(await svc.conversations(), isEmpty);
    expect(server.requests.where((r) => r.contains('/v1/groups')), isEmpty);
  });

  test('criar, enviar e receber; nada do grupo vai para o disco', () async {
    await online();
    final id = await svc.createGroup(
      GroupProfile(name: 'Segredo Atlas', description: 'descrição secreta'),
      [anaId, marcosId],
    );
    final g = server.groups[id]!;
    expect(g.state.members, {meId: roleAdmin, anaId: roleMember, marcosId: roleMember});
    expect(g.epochs[1]!.recipients.length, 3);

    await svc.send(id, 'oi grupo secreto');
    await until('ack', () => g.messages.length == 1);
    server.say(g, server.ana, 'resposta secreta');
    await until('recebida', () async => (await said(id)).length == 2);
    expect(await said(id), ['oi grupo secreto', 'resposta secreta']);

    final lines = await svc.groupLines(id);
    expect(lines.first.message.body, startsWith('João - Financeiro criou o grupo'));
    expect(lines.last.senderName, 'Ana Souza - Diretoria');
    final list = await svc.conversations();
    expect(list.single.isGroup, isTrue);
    expect(list.single.title, 'Segredo Atlas');
    expect(list.single.lastText, 'Ana Souza - Diretoria: resposta secreta');

    final dump = await disk();
    for (final secret in ['Segredo Atlas', 'descrição secreta', 'oi grupo', 'resposta secreta']) {
      expect(dump, isNot(contains(secret)));
    }
    expect(await db.select(db.conversations).get(), isEmpty);
    expect(await db.select(db.epochKeys).get(), isEmpty);
    expect(await db.select(db.chatMessages).get(), isEmpty);
    expect(await db.select(db.attachments).get(), isEmpty);
    expect((await db.select(db.groupAnchors).get()).single.conversationId, id);
  });

  test('imagem de grupo fica em memória; autor sem acesso vira cadeado', () async {
    final g = server.createGroup(server.ana, members: [meId]);
    await online();
    await open(g.id);
    await svc.sendImage(g.id, prepareImageSync(jpeg()));
    await until('enviada', () => g.messages.length == 1);
    server.sayImage(g, server.ana, prepareImageSync(jpeg()));
    await until('recebida', () async => (await said(g.id)).length == 2);
    final theirs = (await svc.groupLines(g.id)).where((l) => l.message.kind == kindImage && !l.message.mine).single;
    expect(await svc.loadImage(theirs.message), isNotEmpty);
    expect(await db.select(db.attachments).get(), isEmpty);

    expect(svc.imageAvailable(theirs.message), isTrue);
    server.setActive(g, anaId, false);
    await until('selada', () async => !svc.imageAvailable(theirs.message));
    await expectLater(svc.loadImage(theirs.message), throwsA(isA<UserFacingError>()));
  });

  test('403 sender_inactive no blob: miniatura com cadeado', () async {
    final g = server.createGroup(server.ana, members: [meId]);
    await online();
    await open(g.id);
    server.sayImage(g, server.ana, prepareImageSync(jpeg()));
    await until('recebida', () async => (await said(g.id)).length == 1);
    server.inactive.add(anaId);
    final line = (await svc.groupLines(g.id)).where((l) => l.message.kind == kindImage).single;
    await expectLater(svc.loadImage(line.message), throwsA(isA<UserFacingError>()));
    expect((await svc.groupLines(g.id)).where((l) => l.thumbLocked), hasLength(1));
  });

  test('perdeu o acesso sela as mensagens; voltou mostra de novo (D11)', () async {
    final g = server.createGroup(server.ana, members: [meId, marcosId]);
    server.say(g, server.marcos, 'texto do Marcos', push: false);
    server.say(g, server.ana, 'texto da Ana', push: false);
    await online();
    await open(g.id);
    expect(await said(g.id), ['texto do Marcos', 'texto da Ana']);
    final before = purges;

    server.setActive(g, marcosId, false);
    await until('selada', () async => !(await said(g.id)).contains('texto do Marcos'));
    var lines = await svc.groupLines(g.id);
    final sealed = lines.singleWhere((l) => l.message.state == msgSealed);
    expect(sealed.senderName, 'Marcos Lima - TI');
    expect(sealed.message.body, scramble(c, g.id, 1, 12));
    expect(await texts(g.id), contains('Marcos Lima - TI perdeu o acesso'));
    expect((await svc.conversations()).single.lastText, isNot(contains('texto do Marcos')));
    expect(purges, greaterThanOrEqualTo(before));

    server.setActive(g, marcosId, true);
    await until('de volta', () async => (await said(g.id)).contains('texto do Marcos'));
    expect(await texts(g.id), contains('Marcos Lima - TI voltou ao grupo'));
  });

  test('embaralhado do servidor não é exibido: o app recalcula', () async {
    final g = server.createGroup(server.ana, members: [meId, marcosId]);
    await online();
    await open(g.id);
    server.push({
      'type': 'message',
      'message': {
        'conversation_id': g.id,
        'seq': 1,
        'message_id': server.newId(),
        'sender_device_id': server.marcos.id,
        'sender_user_id': marcosId,
        'created_at': server.clock(),
        'sealed': true,
        'scramble': 'transfira tudo agora',
      },
    });
    await until('selada', () async => (await said(g.id)).length == 1);
    expect((await said(g.id)).single, scramble(c, g.id, 1, 20));
  });

  test('servidor forja membro: não recebe chave (A2 em grupo)', () async {
    final g = server.createGroup(server.me, members: [anaId]);
    server.extraMembers = [paulaId]; // lista informativa mentirosa
    server.addDevice(anaId, 'Ana Souza - Diretoria'); // força época nova
    await online();
    await open(g.id);
    await svc.send(g.id, 'oi');
    await until('ack', () => g.messages.length == 1);
    expect(g.epochs.length, 2);
    expect(g.epochs[2]!.recipients, isNot(contains(server.paula.id)));
    expect(g.epochs[2]!.recipients.length, 3);
  });

  test('aparelho novo de um membro vira linha no grupo (A1)', () async {
    final g = server.createGroup(server.ana, members: [meId]);
    await online();
    await open(g.id);
    server.addDevice(anaId, 'Ana Souza - Diretoria');
    server.push({'type': 'directory_changed'});
    await until(
      'aviso',
      () async => (await texts(g.id)).contains('Ana Souza - Diretoria (admin do grupo) conectou um aparelho novo'),
    );
  });

  test('época com destinatário de fora bloqueia o grupo', () async {
    final g = server.createGroup(server.ana, members: [meId]);
    server.newEpoch(g, server.ana, extra: [server.paula]);
    server.say(g, server.ana, 'não deve aparecer', push: false);
    await online();
    await svc.openGroup(g.id);
    expect(svc.groupNotice(g.id), contains('quem não é membro'));
    expect(await svc.groupLines(g.id), isEmpty);
    await expectLater(svc.send(g.id, 'x'), throwsA(isA<UserFacingError>()));
  });

  test('cadeia escondida depois de vista bloqueia o grupo (âncora)', () async {
    final g = server.createGroup(server.ana, members: [meId, marcosId]);
    server.change(g, kindRemove, server.ana, usersBody([marcosId]));
    server.newEpoch(g, server.ana);
    await online();
    expect((await db.select(db.groupAnchors).get()).single.n, 2);
    await svc.stop();

    // o servidor volta ao estado de antes da remoção
    g.changes.removeLast();
    g.state = GroupState.verify(c, g.id, g.changes, server.chainKeys);
    await online();
    expect(svc.groupNotice(g.id), contains('escondeu ou trocou'));
  });

  test('registro com assinatura inválida: a lista não confere', () async {
    final g = server.createGroup(server.ana, members: [meId]);
    final r = server.sign(g, kindLeave, server.me, Uint8List(0));
    g.changes.add(SignedChange(r.bytes, Uint8List(64), n: 2));
    await online();
    expect(svc.groupNotice(g.id), 'A lista de membros deste grupo não confere.');
    expect((await svc.conversations()).single.lastText, 'A lista de membros deste grupo não confere.');
  });

  test('adicionar com histórico reembrulha só o permitido; sem histórico, nada', () async {
    await online();
    final id = await svc.createGroup(GroupProfile(name: 'G'), [anaId]);
    final g = server.groups[id]!;
    await svc.send(id, 'antes');
    await until('ack', () => g.messages.length == 1);

    await svc.addMembers(id, [marcosId], history: true);
    expect(g.state.members, contains(marcosId));
    expect(g.epochs[2]!.recipients, contains(server.marcos.id));
    expect(server.keyFor(g, 1, server.marcos), server.keyFor(g, 1, server.ana));

    await svc.addMembers(id, [paulaId], history: false);
    expect(g.epochs[3]!.recipients, contains(server.paula.id));
    expect(server.keyFor(g, 1, server.paula), isNull);
    expect(server.keyFor(g, 2, server.paula), isNull);
    expect(await texts(id), contains('João - Financeiro adicionou Paula Reis - RH sem acesso ao histórico'));
    // o nome continua abrindo para quem entrou: recifrado na época nova
    expect(g.metas.keys, containsAll([1, 2, 3]));
  });

  test('liberação de histórico: um aviso de época antiga traz todas', () async {
    final g = server.createGroup(server.ana, members: [marcosId]);
    server.say(g, server.marcos, 'primeira', push: false);
    server.newEpoch(g, server.ana);
    server.say(g, server.marcos, 'segunda', push: false);
    server.apply(g, server.sign(g, kindAdd, server.ana, addBody(history: true, users: [meId])));
    server.newEpoch(g, server.ana);
    await online();
    await open(g.id);
    expect(await said(g.id), hasLength(2));
    expect(await said(g.id), isNot(contains('primeira')));
    // o admin libera as duas épocas; o servidor avisa só a primeira
    server.release(g, [1, 2]);
    server.push({'type': 'epoch', 'item': server.epochItem(g, g.wraps.firstWhere((w) => w.$2 == 1 && w.$3 == server.me.id))});
    await until('histórico', () async => (await said(g.id)).join() == 'primeirasegunda');
  });

  test('remover, promover, renomear, sair', () async {
    await online();
    final id = await svc.createGroup(GroupProfile(name: 'G'), [anaId, marcosId]);
    final g = server.groups[id]!;
    await svc.removeMember(id, marcosId);
    expect(g.epochs[2]!.recipients, isNot(contains(server.marcos.id)));
    await svc.promoteMember(id, anaId);
    expect(g.state.isAdmin(anaId), isTrue);
    await svc.editGroup(id, GroupProfile(name: 'Novo nome', photo: prepareGroupPhotoSync(jpeg())));
    expect((await svc.groupInfo(id))!.title, 'Novo nome');
    expect((await svc.groupInfo(id))!.profile!.photo, isNotNull);
    final info = (await svc.groupInfo(id))!;
    expect(info.members.map((m) => m.userId), unorderedEquals([meId, anaId]));
    expect(info.history, hasLength(4));
    await svc.leaveGroup(id);
    expect(g.state.members, {anaId: roleAdmin});
    expect(await svc.conversations(), isEmpty);
  });

  test('entrar sem histórico: o que veio antes não aparece', () async {
    final g = server.createGroup(server.ana, members: [marcosId]);
    server.say(g, server.marcos, 'conversa antiga', push: false);
    final add = server.sign(g, kindAdd, server.ana, addBody(history: false, users: [meId]));
    server.apply(g, add);
    server.newEpoch(g, server.ana);
    server.say(g, server.ana, 'bem-vindo', push: false);
    await online();
    await open(g.id);
    expect(await said(g.id), ['bem-vindo']);
    expect((await svc.groupInfo(g.id))!.title, 'Projeto Atlas');
  });

  test('grupo do moderador: rótulo como nome, primeiro envio cria a época', () async {
    final g = server.createGroup(null, members: [meId, anaId]);
    await online();
    await open(g.id);
    final view = (await svc.conversations()).single;
    expect(view.title, 'Diretoria - oficial');
    expect(view.subtitle, 'oficial: Diretoria - oficial');
    await svc.send(g.id, 'primeira');
    await until('ack', () => g.messages.length == 1);
    expect(g.epochs.keys, [1]);
  });

  test('removido pelo moderador: o grupo some', () async {
    final g = server.createGroup(server.ana, members: [meId]);
    await online();
    await open(g.id);
    server.change(g, kindRemove, null, usersBody([meId]));
    await until('sumiu', () async => (await svc.conversations()).isEmpty);
    expect(await svc.groupLines(g.id), isEmpty);
    await expectLater(svc.send(g.id, 'x'), throwsA(isA<UserFacingError>()));
  });

  test('sem conexão só 1:1; o conteúdo de grupo sai da memória', () async {
    final g = server.createGroup(server.ana, members: [meId]);
    server.say(g, server.ana, 'só com internet', push: false);
    await online();
    await open(g.id);
    server.down = true;
    await server.link!.serverClose(1006);
    await until('offline', () => svc.status != ChatStatus.online);
    await until('sem grupos', () async => (await svc.conversations()).isEmpty);
    expect(svc.groupsAvailable, isFalse);
    expect(await svc.groupLines(g.id), isEmpty);
    await expectLater(svc.send(g.id, 'x'), throwsA(isA<UserFacingError>()));

    server.down = false;
    await until('voltou', () => svc.status == ChatStatus.online);
    await until('recarregado', () async => (await said(g.id)).contains('só com internet'));
  });

  test('trancar o grupo apaga da memória; destrancar busca de novo', () async {
    final g = server.createGroup(server.ana, members: [meId]);
    server.say(g, server.ana, 'conteúdo', push: false);
    await online();
    await open(g.id);
    locked.add(g.id);
    svc.forgetGroup(g.id);
    expect(await svc.groupLines(g.id), isEmpty);
    expect((await svc.conversations()).single.title, startsWith('Grupo '));
    server.say(g, server.ana, 'enquanto trancado');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await svc.openGroup(g.id);
    expect(await svc.groupLines(g.id), isEmpty);

    locked.clear();
    await svc.openGroup(g.id);
    expect(await said(g.id), ['conteúdo', 'enquanto trancado']);
  });

  test('parar o serviço (trancar o app) esvazia tudo', () async {
    final g = server.createGroup(server.ana, members: [meId]);
    server.say(g, server.ana, 'conteúdo', push: false);
    await online();
    await open(g.id);
    await svc.stop();
    expect(await svc.groupLines(g.id), isEmpty);
    expect(await disk(), isNot(contains('conteúdo')));
  });

  test('servidor não consegue apresentar grupo conhecido como 1:1', () async {
    final g = server.createGroup(server.ana, members: [meId]);
    await online();
    expect(svc.isGroup(g.id), isTrue);
    await svc.stop();
    server.groups.clear(); // nova sessão: só a âncora lembra que é grupo
    await online();
    server.push({
      'type': 'conversation',
      'conversation': {
        'conversation_id': g.id,
        'kind': 'direct',
        'members': [meId, anaId],
        'latest_epoch': 0,
        'last_seq': 0,
      },
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(await db.select(db.conversations).get(), isEmpty);
  });
}

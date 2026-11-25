import 'dart:convert';
import 'dart:typed_data';

import 'package:direct/chat/chat_service.dart';
import 'package:direct/core/api.dart';
import 'package:direct/core/b64.dart';
import 'package:direct/core/chat_crypto.dart';
import 'package:direct/core/chat_models.dart';
import 'package:direct/core/crypto.dart';
import 'package:direct/core/errors.dart';
import 'package:direct/core/media.dart';
import 'package:direct/core/models.dart';
import 'package:direct/data/db.dart';
import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'chat_ws_test.dart' show FakeLink;
import 'support.dart';

const me = '2b4d6f81-3a5c-4e7a-9b1d-3f5a7c9e1b2d';
const myDevice = '8e7d6c5b-4a39-4281-b7c6-d5e4f3a2b1c0';
const ana = '7d0c9b8a-1e2f-4a3b-9c4d-5e6f7a8b9c0d';
const marcos = '11111111-1111-4111-8111-111111111111';
const convId = '22222222-2222-4222-8222-222222222222';

String devId(int n) => '33333333-3333-4333-8333-33333333333$n';

/// Servidor sob controle do teste: o diretório e as respostas mudam à vontade.
void main() {
  late DirectCrypto c;
  late ChatCrypto crypto;
  late ChatService svc;
  late AppDatabase db;
  late FakeLink link;
  late DeviceKeys myKeys;
  late Uint8List serverSeed, serverPub, escrowPub;
  late List<Map<String, dynamic>> anaDevices;
  late Map<String, dynamic> conversation;
  late List<Map<String, dynamic>> Function(int after) epochs;
  late Map<String, dynamic> save;

  setUpAll(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    c = await loadCrypto();
    crypto = ChatCrypto(c);
  });

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
    return DeviceCert.fromJson({
      ...unsigned.toJson(),
      'sig': b64uEncode(c.sign(serverSeed, c.certBytes(unsigned))),
    });
  }

  Future<void> until(String what, Future<bool> Function() cond) async {
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(end)) {
      if (await cond()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('timeout: $what');
  }

  Future<List<String>> notices() async => [
    for (final m in await svc.messages(convId))
      if (m.state == msgNotice) m.body!,
  ];

  late DeviceKeys anaKeys1;
  late DeviceCert anaCert1;
  late DeviceCert myCert;

  setUp(() async {
    serverSeed = c.random(32);
    serverPub = c.signPubFromSeed(serverSeed);
    escrowPub = c.x25519Pub(c.random(32));
    myKeys = c.generateDeviceKeys();
    myCert = certFor(myDevice, me, 'Eu', myKeys);
    anaKeys1 = c.generateDeviceKeys();
    anaCert1 = certFor(devId(1), ana, 'Ana', anaKeys1);
    anaDevices = [anaCert1.toJson()];
    conversation = {'conversation_id': convId, 'members': [me, ana], 'latest_epoch': 0, 'last_seq': 0};
    epochs = (_) => [];
    save = {};

    final client = MockClient((req) async {
      final body = switch (req.url.path) {
        '/v1/directory' => {
          'users': [
            {'user_id': ana, 'admin_label': 'Ana', 'display_name': '', 'status': '', 'devices': anaDevices},
          ],
        },
        '/v1/epochs/mine' => {
          'items': epochs(int.parse(req.url.queryParameters['after'] ?? '0')),
          'has_more': false,
        },
        '/v1/conversations' => req.method == 'GET' ? {'conversations': [conversation]} : conversation,
        '/v1/media/saves' => save,
        _ => <String, Object>{},
      };
      return http.Response(
        jsonEncode(body),
        req.url.path == '/v1/media/saves' ? 201 : 200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    db = AppDatabase(NativeDatabase.memory());
    svc = ChatService(
      db: db,
      api: DirectApi('h.example', client: client),
      crypto: crypto,
      keys: myKeys,
      cert: myCert,
      serverSignPub: serverPub,
      escrowPub: escrowPub,
      login: () async => AccessToken('tok', DateTime.now().millisecondsSinceEpoch + 900000),
      connector: (_) async => link = FakeLink(),
    );
  });

  tearDown(() async {
    await svc.stop();
    await db.close();
  });

  Future<void> online() async {
    svc.start();
    await until('online', () async => svc.status == ChatStatus.online);
  }

  Future<void> directory(List<DeviceCert> certs) async {
    anaDevices = [for (final x in certs) x.toJson()];
    link.push({'type': 'directory_changed', 'user_id': ana});
  }

  test('§7.3: aparelho novo e aparelho que some viram aviso na conversa', () async {
    await online();
    expect(await notices(), isEmpty, reason: 'primeira sincronização só registra');

    final cert2 = certFor(devId(2), ana, 'Ana', c.generateDeviceKeys());
    await directory([anaCert1, cert2]);
    await until('aviso de aparelho novo', () async => (await notices()).length == 1);
    expect((await notices()).single, startsWith('Ana conectou um aparelho novo em '));

    await directory([cert2]);
    await until('aviso de saída', () async => (await notices()).length == 2);
    expect((await notices()).last, 'Ana desconectou um aparelho');

    // a mesma chave de volta não é nova; sumir de novo avisa de novo
    await directory([anaCert1, cert2]);
    await until('de volta', () async => (await db.select(db.seenKeys).get()).every((r) => r.present));
    await directory([cert2]);
    await until('segunda saída', () async => (await notices()).length == 3);
    expect((await notices()).where((n) => n.contains('conectou um aparelho novo')), hasLength(1));
    expect((await svc.conversations()).single.lastText, 'Ana desconectou um aparelho');
  });

  test('membros trocados pelo servidor são recusados', () async {
    await online();
    conversation = {...conversation, 'members': [me, marcos]};
    link.push({'type': 'conversation', 'conversation': conversation});
    await until('aviso', () async => (await notices()).isNotEmpty);
    expect((await db.select(db.conversations).getSingle()).peerUserId, ana);
    expect((await notices()).single, contains('trocar os participantes'));
    await expectLater(svc.openConversationWith(marcos), throwsA(isA<UserFacingError>()));
    await expectLater(svc.openConversationWith(ana), throwsA(isA<UserFacingError>()));
  });

  test('mensagem de época sem chave busca epochs/mine de novo a partir de 0', () async {
    final ne = crypto.createEpoch(
      conversationId: convId,
      epoch: 1,
      self: anaKeys1,
      selfDeviceId: devId(1),
      escrowPub: escrowPub,
      certs: [anaCert1, myCert],
    );
    final item = {
      'wrap_id': 10,
      'conversation_id': convId,
      'epoch': 1,
      'creator_device_id': devId(1),
      'key_commitment': b64uEncode(ne.commitment),
      'recipients': ne.recipients,
      'signature': b64uEncode(ne.signature),
      'wrapped_key': b64uEncode(ne.wraps[myDevice]!),
    };
    // o cursor já passou do embrulho 10 (commit fora de ordem no servidor)
    await db.into(db.chatMeta).insert(ChatMetaCompanion.insert(k: 'max_wrap_id', v: '11'));
    epochs = (after) => after < 10 ? [item] : [];
    await online();

    const header = '44444444-4444-4444-8444-444444444444';
    final sealed = crypto.seal(
      header: MessageHeader(conversationId: convId, epoch: 1, senderDeviceId: devId(1), messageId: header, sentAt: 5),
      epochKey: ne.key,
      plaintext: crypto.textPlain('oi'),
      signSeed: anaKeys1.signSeed,
    );
    final wire = WireMessage(
      conversationId: convId,
      epoch: 1,
      senderDeviceId: devId(1),
      messageId: header,
      sentAt: 5,
      nonce: sealed.nonce,
      ciphertext: sealed.ciphertext,
      signature: sealed.signature,
    );
    link.push({'type': 'message', 'message': {...wire.toSendJson(), 'seq': 1}});
    await until('mensagem aberta', () async => (await svc.messages(convId)).any((m) => m.body == 'oi'));
  });

  test('salvar foto recusa resposta com ids de outra pessoa', () async {
    await online();
    final key = c.random(32);
    final blob = crypto.sealBlob(conversationId: convId, key: key, jpeg: Uint8List.fromList(List.filled(64, 1)));
    final ref = ImageRef(blobId: devId(3), key: key, sha256: sha256Of(blob), width: 1, height: 1, thumb: Uint8List(1));
    await db.into(db.attachments).insert(
      AttachmentsCompanion.insert(conversationId: convId, messageId: 'm', data: Value(blob)),
    );
    final row = ChatMessage(
      id: 1,
      conversationId: convId,
      messageId: 'm',
      seq: 1,
      epoch: 1,
      senderDeviceId: devId(1),
      sentAt: 0,
      body: ref.toJson(),
      kind: kindImage,
      state: msgOk,
      mine: false,
    );
    save = {'save_id': devId(4), 'saved_at': 1, 'user_id': marcos, 'device_id': myDevice};
    await expectLater(
      svc.prepareSave(row),
      throwsA(isA<UserFacingError>().having((e) => e.message, 'message', contains('adulterada'))),
    );
  });
}

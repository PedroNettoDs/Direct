import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:direct/chat/chat_service.dart';
import 'package:direct/core/api.dart';
import 'package:direct/core/chat_crypto.dart';
import 'package:direct/core/models.dart';
import 'package:direct/core/ws.dart';
import 'package:direct/data/db.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support.dart';

class FakeLink implements WsLink {
  FakeLink({this.answerPing = true});
  final bool answerPing;
  final _in = StreamController<String>();
  final sent = <Map<String, dynamic>>[];
  @override
  int? closeCode;
  bool closed = false;

  @override
  Stream<String> get incoming => _in.stream;

  void push(Map<String, dynamic> f) => _in.add(jsonEncode(f));

  @override
  void send(String text) {
    final f = jsonDecode(text) as Map<String, dynamic>;
    sent.add(f);
    switch (f['type']) {
      case 'auth':
        push({'type': 'ready', 'device_id': 'x', 'server_time': 1, 'token_expires_at': 1});
      case 'ping':
        if (answerPing) push({'type': 'pong', 'ts': f['ts']});
    }
  }

  @override
  Future<void> close([int code = 1000]) async {
    if (closed) return;
    closed = true;
    closeCode ??= code;
    await _in.close();
  }

  /// O servidor fecha com [code].
  Future<void> serverClose(int code) async {
    closeCode = code;
    await close(code);
  }
}

void main() {
  late ChatService svc;
  late AppDatabase db;
  late List<FakeLink> links;
  late FakeLink Function() nextLink;
  var logins = 0;

  Future<void> until(String what, bool Function() cond) async {
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(end)) {
      if (cond()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('timeout: $what');
  }

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final c = await loadCrypto();
    final keys = c.generateDeviceKeys();
    final client = MockClient((req) async {
      final body = switch (req.url.path) {
        '/v1/directory' => {'users': []},
        '/v1/epochs/mine' => {'items': [], 'has_more': false},
        '/v1/conversations' => {'conversations': []},
        _ => {},
      };
      return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
    });
    db = AppDatabase(NativeDatabase.memory());
    links = [];
    logins = 0;
    nextLink = () => FakeLink();
    svc = ChatService(
      db: db,
      api: DirectApi('h.example', client: client),
      crypto: ChatCrypto(c),
      keys: keys,
      cert: DeviceCert(
        deviceId: '8e7d6c5b-4a39-4281-b7c6-d5e4f3a2b1c0',
        userId: '2b4d6f81-3a5c-4e7a-9b1d-3f5a7c9e1b2d',
        adminLabel: 'x',
        signPub: keys.signPub,
        kexPub: keys.kexPub,
        enrolledAt: 0,
        expiresAt: 0,
        sig: Uint8List(64),
      ),
      serverSignPub: Uint8List(32),
      escrowPub: Uint8List(32),
      login: () async {
        logins++;
        return AccessToken('tok$logins', DateTime.now().millisecondsSinceEpoch + 900000);
      },
      connector: (uri) async {
        final l = nextLink();
        links.add(l);
        return l;
      },
      pingInterval: const Duration(milliseconds: 100),
      pongTimeout: const Duration(milliseconds: 100),
      maxBackoff: const Duration(milliseconds: 200),
    );
  });

  tearDown(() async {
    await svc.stop();
    await db.close();
  });

  test('autentica, fica online e manda ping periódico', () async {
    svc.start();
    await until('online', () => svc.status == ChatStatus.online);
    final auth = links.single.sent.first;
    expect(auth['type'], 'auth');
    expect(auth['access_token'], 'tok1');
    expect(auth['conversations'], isNull);
    await until('2 pings', () => links.single.sent.where((f) => f['type'] == 'ping').length >= 2);
    expect(svc.status, ChatStatus.online);
    expect(links, hasLength(1));
  });

  test('sem pong: fecha e reconecta', () async {
    nextLink = () => links.isEmpty ? FakeLink(answerPing: false) : FakeLink();
    svc.start();
    await until('segunda conexão', () => links.length == 2);
    expect(links.first.closed, isTrue);
    await until('online de novo', () => svc.status == ChatStatus.online);
  });

  test('4001 renova o token e reconecta; 4004 para de vez', () async {
    svc.start();
    await until('online', () => svc.status == ChatStatus.online);
    await links[0].serverClose(4001);
    await until('reconectou', () => links.length == 2 && svc.status == ChatStatus.online);
    expect(links[1].sent.first['access_token'], 'tok2');
    await links[1].serverClose(4004);
    await until('vencido', () => svc.status == ChatStatus.expired);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(links, hasLength(2));
  });

  test('queda comum reconecta com espera e não repete login', () async {
    svc.start();
    await until('online', () => svc.status == ChatStatus.online);
    await links[0].serverClose(1001);
    await until('reconectou', () => links.length == 2 && svc.status == ChatStatus.online);
    expect(logins, 1);
  });

  test('escopo da bolha reconecta pedindo só aquelas conversas e volta a tudo', () async {
    svc.start();
    await until('online', () => svc.status == ChatStatus.online);
    svc.setScope({'c1'});
    await until('escopo restrito', () => links.length == 2 && svc.status == ChatStatus.online);
    expect(links[1].sent.first['conversations'], ['c1']);
    svc.setScope({'c1'}); // igual: não reconecta
    svc.setScope(null);
    await until('tudo de novo', () => links.length == 3 && svc.status == ChatStatus.online);
    expect(links[2].sent.first['conversations'], isNull);
  });
}

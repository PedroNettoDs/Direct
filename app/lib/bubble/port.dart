import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../core/b64.dart';
import '../core/bio.dart';
import 'mini.dart';

/// Ponte entre o isolate principal (chaves, banco, WebSocket) e o isolate da
/// bolha (só tela). Mensagens em memória, no mesmo processo: nada vai a disco
/// nem a extra de `Intent`.
const corePortName = 'direct.core';

/// Lado principal. Devolve o fechamento.
VoidCallback serveMini(LocalMiniBackend backend, {String name = corePortName}) {
  final port = ReceivePort();
  final watchers = <SendPort>{};
  void changed() {
    for (final w in watchers) {
      w.send('changed');
    }
  }

  IsolateNameServer.removePortNameMapping(name);
  IsolateNameServer.registerPortWithName(port.sendPort, name);
  backend.addListener(changed);

  port.listen((raw) async {
    final m = raw as Map<Object?, Object?>;
    final reply = m['reply'] as SendPort;
    final conv = m['conv'] as String? ?? '';
    final password = m['password'] as String?;
    final master = m['master'] as Uint8List?;
    Object? out;
    try {
      switch (m['cmd']) {
        case 'watch':
          watchers.add(reply);
          return;
        case 'unwatch':
          watchers.remove(reply);
          return;
        case 'load':
          out = (await backend.load(conv)).toMap();
        case 'unlockApp':
          out = await backend.unlockApp(password: password, master: master);
        case 'unlockChat':
          out = await backend.unlockChat(conv, password: password, master: master);
        case 'send':
          out = await backend.send(conv, m['text'] as String);
        case 'retry':
          await backend.retry(m['id'] as int);
        case 'touch':
          await backend.touch();
        case 'bioInvalidated':
          await backend.c.disableBio();
      }
      reply.send({'ok': out});
    } on Object catch (e) {
      debugPrint('[direct] bolha: ${e.runtimeType}');
      reply.send({'error': true});
    }
  });

  return () {
    backend.removeListener(changed);
    IsolateNameServer.removePortNameMapping(name);
    port.close();
  };
}

/// Lado da bolha. A digital é lida aqui (o diálogo precisa da Activity da
/// bolha) e vai em memória para o principal conferir.
class PortMiniBackend extends ChangeNotifier implements MiniBackend {
  PortMiniBackend({BioStore? bio, this.name = corePortName}) : bio = bio ?? PluginBioStore();
  final BioStore bio;
  final String name;
  final _events = ReceivePort();
  SendPort? _core;
  bool _closed = false;

  /// Espera o principal registrar a porta (processo recém-aberto pela bolha).
  Future<SendPort> _connect() async {
    for (var i = 0; ; i++) {
      final p = IsolateNameServer.lookupPortByName(name);
      if (p != null) {
        if (_core == null) {
          _events.listen((_) {
            if (!_closed) notifyListeners();
          });
        }
        if (p != _core) {
          _core = p;
          p.send({'cmd': 'watch', 'reply': _events.sendPort});
        }
        return p;
      }
      if (i >= 100 || _closed) throw StateError('app indisponível');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<Object?> _call(String cmd, [Map<String, Object?> args = const {}]) async {
    final core = await _connect();
    final reply = ReceivePort();
    try {
      core.send({'cmd': cmd, ...args, 'reply': reply.sendPort});
      final r = await reply.first.timeout(const Duration(seconds: 30)) as Map<Object?, Object?>;
      if (r['error'] == true) throw StateError('falha no app');
      return r['ok'];
    } finally {
      reply.close();
    }
  }

  @override
  Future<MiniState> load(String conversationId) async =>
      MiniState.fromMap(await _call('load', {'conv': conversationId}) as Map<Object?, Object?>);

  Future<String?> _unlock(String cmd, String conv, String? password) async {
    if (password != null) return await _call(cmd, {'conv': conv, 'password': password}) as String?;
    try {
      final raw = await bio.read();
      if (raw == null) throw BioInvalidated();
      return await _call(cmd, {'conv': conv, 'master': b64uDecode(raw, length: 32)}) as String?;
    } on BioCanceled {
      return '';
    } on BioInvalidated {
      await _call('bioInvalidated');
      return 'A digital mudou. Use a senha.';
    } on BioUnavailable {
      return 'Digital indisponível agora. Use a senha.';
    }
  }

  @override
  Future<String?> unlockApp({String? password}) => _unlock('unlockApp', '', password);

  @override
  Future<String?> unlockChat(String conversationId, {String? password}) =>
      _unlock('unlockChat', conversationId, password);

  @override
  Future<String?> send(String conversationId, String text) async =>
      await _call('send', {'conv': conversationId, 'text': text}) as String?;

  @override
  Future<void> retry(int rowId) async => _call('retry', {'id': rowId});

  @override
  Future<void> touch() async => _call('touch');

  @override
  void dispose() {
    _closed = true;
    _core?.send({'cmd': 'unwatch', 'reply': _events.sendPort});
    _events.close();
    super.dispose();
  }
}

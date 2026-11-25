import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../core/api.dart';
import '../core/b64.dart';
import '../core/chat_crypto.dart';
import '../core/chat_models.dart';
import '../core/errors.dart';
import '../core/group_proto.dart';
import '../core/media.dart';
import '../core/models.dart';
import '../core/ws.dart';
import '../data/db.dart';

part 'groups.dart';
part 'hidden.dart';

enum ChatStatus { offline, connecting, online, revoked, expired }

/// Linha da lista de conversas.
class ConversationView {
  ConversationView({
    required this.conversationId,
    required this.peerUserId,
    required this.title,
    required this.subtitle,
    required this.lastText,
    required this.lastAt,
    this.isGroup = false,
  });
  final bool isGroup;
  final String conversationId;
  final String peerUserId;
  final String title;
  final String subtitle;
  final String lastText;
  final int lastAt;
}

/// Contato de uma conversa, para o topo e a folha de informações.
class PeerInfo {
  PeerInfo(this.name, this.displayName, this.status, this.deviceCodes);
  final String name;
  final String displayName;
  final String status;

  /// Código (§13.4) de cada aparelho ativo conhecido.
  final List<String> deviceCodes;
}

class DirectoryEntry {
  DirectoryEntry(this.userId, this.adminLabel, this.displayName, this.status);
  final String userId;
  final String adminLabel;
  final String displayName;
  final String status;
}

class _Offline implements Exception {}

/// Chat 1:1 e grupos: sincronização, épocas, cifra e WebSocket (protocolo §9–§11;
/// a parte de grupo está em `groups.dart`).
/// Um por sessão destravada; `start()` liga, `stop()` desliga e zera as chaves.
class ChatService extends ChangeNotifier {
  ChatService({
    required this.db,
    required this.api,
    required this.crypto,
    required this.keys,
    required this.cert,
    required this.serverSignPub,
    required this.escrowPub,
    required this.login,
    this.modPub,
    this.isLocked = _never,
    this.onPurge,
    WsConnector? connector,
    DateTime Function()? clock,
    this.pingInterval = const Duration(seconds: 30),
    this.pongTimeout = const Duration(seconds: 10),
    this.maxBackoff = const Duration(seconds: 60),
  }) : _connector = connector ?? connectWs,
       _now = clock ?? DateTime.now;

  static bool _never(String _) => false;

  /// Chave do moderador fixada. Sem ela o app não mostra nem verifica grupos.
  Uint8List? modPub;

  /// Conversa trancada (D7): de grupo trancado nada é carregado.
  final bool Function(String conversationId) isLocked;

  /// Conteúdo de grupo saiu da memória (limpar caches da interface).
  final void Function()? onPurge;

  /// Grupos só existem em memória (D11): somem ao trancar e ao cair a conexão.
  final _groups = <String, _Group>{};
  final _groupIds = <String>{};

  /// Chaves privadas das conversas ocultas abertas agora (D12). Só em memória.
  final _hiddenKeys = <String, Uint8List>{};
  final _opened = <String>{};
  final _outbox = <String, List<_GroupMsg>>{};
  int _groupRowId = 0;

  /// Reconexão pedida pelo próprio app (token, escopo): não conta como "sem internet".
  bool _planned = false;

  final AppDatabase db;
  final DirectApi api;
  final ChatCrypto crypto;
  final DeviceKeys keys;
  final DeviceCert cert;
  final Uint8List serverSignPub;
  final Uint8List escrowPub;

  /// Login por desafio (protocolo §6). Pode apagar tudo se houver prova de revogação.
  final Future<AccessToken> Function() login;
  final WsConnector _connector;
  final DateTime Function() _now;
  final Duration pingInterval, pongTimeout, maxBackoff;

  String get selfDeviceId => cert.deviceId;
  String get selfUserId => cert.userId;

  ChatStatus status = ChatStatus.offline;

  /// Alertas locais (sem conteúdo de mensagem), mais novo por último.
  final List<String> alerts = [];

  bool _running = false;
  bool _disposed = false;
  AccessToken? _tok;
  WsLink? _link;
  bool _synced = false;
  Completer<void>? _stopSignal;
  Completer<void>? _wake;

  /// Escopo do WebSocket (§11.2): null = tudo; senão só as conversas das bolhas.
  Set<String>? _scope;
  Set<String>? get scope => _scope;
  Timer? _timer;
  Timer? _pingTimer;
  Timer? _pongTimer;
  Timer? _tokenTimer;
  int _reqSeq = 0;
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  int _dirAt = 0;
  final _rng = Random();

  int _ms() => _now().millisecondsSinceEpoch;

  /// Relógio do serviço, para os horários na tela.
  DateTime now() => _now();

  void _alert(String s) {
    alerts.add(s);
    if (alerts.length > 100) alerts.removeAt(0);
    debugPrint('[direct] alerta: $s');
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  // ---- exclusão mútua: uma tarefa de sincronização/envio por vez ----

  Future<void> _tail = Future.value();
  Future<T> _locked<T>(Future<T> Function() f) {
    final c = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        c.complete(await f());
      } on Object catch (e, s) {
        c.completeError(e, s);
      }
    });
    return c.future;
  }

  // ---- ciclo de vida ----

  void start() {
    if (_running) return;
    _running = true;
    _stopSignal = Completer<void>();
    unawaited(_run());
  }

  Future<void> stop() async {
    _running = false;
    _cancelTimers();
    if (_stopSignal?.isCompleted == false) _stopSignal!.complete();
    final l = _link;
    _link = null;
    _synced = false;
    _failPending();
    status = ChatStatus.offline;
    _tok = null;
    try {
      await l?.close();
    } on Object {
      // já fechado
    }
    closeAllHidden();
    _wipeGroups();
    _outbox.clear();
    keys.signSeed.fillRange(0, keys.signSeed.length, 0);
    keys.kexSk.fillRange(0, keys.kexSk.length, 0);
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _cancelTimers() {
    _timer?.cancel();
    _pingTimer?.cancel();
    _pongTimer?.cancel();
    _tokenTimer?.cancel();
    _timer = _pingTimer = _pongTimer = _tokenTimer = null;
  }

  void _failPending() {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(_Offline());
    }
    _pending.clear();
  }

  Future<void> _sleep(Duration d) {
    final c = _wake = Completer<void>();
    _timer = Timer(d, () {
      if (!c.isCompleted) c.complete();
    });
    _stopSignal!.future.then((_) {
      if (!c.isCompleted) c.complete();
    });
    return c.future;
  }

  /// Troca o escopo e reconecta (o escopo só vai no `auth`).
  void setScope(Set<String>? ids) {
    if (ids == null ? _scope == null : setEquals(ids, _scope)) return;
    _scope = ids == null ? null : Set.of(ids);
    _synced = false;
    _dropOutOfScope();
    final l = _link;
    if (l != null) {
      _planned = true;
      unawaited(l.close(1000));
    }
    if (_wake?.isCompleted == false) _wake!.complete();
  }

  bool _inScope(String conversationId) => _scope?.contains(conversationId) ?? true;

  // ---- token ----

  Future<String> _token() async {
    final t = _tok;
    if (t == null || _ms() > t.expiresAt - 60000) _tok = await login();
    return _tok!.token;
  }

  Future<T> _authed<T>(Future<T> Function(String token) f) async {
    try {
      return await f(await _token());
    } on ApiException catch (e) {
      if (e.code == 'unauthorized') {
        _tok = null;
        return f(await _token());
      }
      if (e.code == 'device_revoked') {
        _tok = null;
        await login(); // obtém a prova e apaga tudo, se confere
      }
      rethrow;
    }
  }

  // ---- conexão (protocolo §11) ----

  Future<void> _run() async {
    var attempt = 0;
    while (_running) {
      int? code;
      try {
        status = ChatStatus.connecting;
        _changed();
        code = await _session(() => attempt = 0);
      } on ApiException catch (e) {
        if (e.code == 'device_expired') {
          status = ChatStatus.expired;
          _changed();
          return;
        }
        _alert('conexão: ${e.code}');
      } on UserFacingError {
        // login falhou (revogado e apagado, vencido, sem rede)
        if (!_running) return;
      } on Object catch (e) {
        debugPrint('[direct] conexão caiu: ${e.runtimeType}');
      }
      if (!_running) return;
      if (!_planned) _wipeGroups(); // sem internet, só 1:1
      status = _planned ? ChatStatus.connecting : ChatStatus.offline;
      final planned = _planned;
      _planned = false;
      _synced = false;
      _link = null;
      _failPending();
      _cancelTimers();
      _changed();
      switch (code) {
        case 4003:
          try {
            await login();
          } on Object {
            // sem prova válida: trata como erro de rede (protocolo §6.4)
          }
          if (!_running) return;
        case 4004:
          status = ChatStatus.expired;
          _changed();
          return;
        case 4009:
          return;
        case 4001:
          _tok = null;
          attempt = 0;
          continue;
      }
      if (planned) {
        attempt = 0;
        continue;
      }
      final base = min(maxBackoff.inMilliseconds, 1000 * (1 << min(attempt, 6)));
      attempt++;
      await _sleep(Duration(milliseconds: (base * (0.8 + 0.4 * _rng.nextDouble())).round()));
    }
  }

  /// Uma conexão do `auth` ao fechamento. Devolve o código de fechamento.
  Future<int?> _session(void Function() onReady) async {
    final token = await _token();
    final scope = _scope;
    final link = await _connector(api.wsUri);
    final done = Completer<int?>();
    final ready = Completer<void>();
    final buffer = <Map<String, dynamic>>[];
    var live = false;
    var buffering = true;

    link.incoming.listen(
      (raw) {
        final Map<String, dynamic> f;
        try {
          f = jsonDecode(raw) as Map<String, dynamic>;
        } on Object {
          unawaited(link.close(4000));
          return;
        }
        switch (f['type']) {
          case 'ready':
            if (!ready.isCompleted) ready.complete();
          case 'pong':
            _pongTimer?.cancel();
            _pongTimer = null;
          case 'ack' || 'error':
            final c = _pending.remove(f['req_id']);
            if (c != null && !c.isCompleted) c.complete(f);
          default:
            if (buffering) {
              buffer.add(f);
            } else if (live) {
              unawaited(_locked(() => _handleEvent(f)).catchError((Object e) => _logEvt(f, e)));
            }
        }
      },
      onDone: () {
        if (!done.isCompleted) done.complete(link.closeCode);
      },
      onError: (Object _) {
        if (!done.isCompleted) done.complete(null);
      },
      cancelOnError: true,
    );

    link.send(jsonEncode({'type': 'auth', 'access_token': token, 'conversations': scope?.toList()}));
    try {
      await Future.any<void>([
        ready.future.timeout(const Duration(seconds: 10)),
        done.future.then((_) => throw _Offline()),
      ]);
    } on Object {
      await link.close();
      return done.isCompleted ? await done.future : null;
    }
    if (scope != _scope) {
      await link.close();
      return null;
    }
    _link = link;
    onReady();

    // §11.8: sincroniza com o buffer ligado; depois aplica o buffer.
    try {
      await _locked(() async {
        await _syncAll();
        _synced = true;
        status = ChatStatus.online;
        _changed();
        for (var i = 0; i < buffer.length; i++) {
          final f = buffer[i];
          try {
            await _handleEvent(f);
          } on Object catch (e) {
            _logEvt(f, e);
          }
        }
        buffer.clear();
        buffering = false;
        live = true;
        await _flushPending();
      });
    } on Object catch (e) {
      debugPrint('[direct] sincronização falhou: ${e.runtimeType}');
      await link.close(1000);
      if (e is ApiException && e.code == 'device_expired') rethrow;
      if (e is UserFacingError) rethrow;
      return done.future;
    }

    _startPing(link);
    final t = _tok;
    if (t != null) {
      // renova o token e reconecta antes de vencer (§6.3, §11.7)
      final wait = max(5000, t.expiresAt - 60000 - _ms());
      _tokenTimer = Timer(Duration(milliseconds: wait), () {
        _tok = null;
        _planned = true;
        unawaited(link.close(1000));
      });
    }
    return done.future;
  }

  void _logEvt(Map<String, dynamic> f, Object e) =>
      debugPrint('[direct] evento ${f['type']} falhou: ${e.runtimeType}');

  void _startPing(WsLink link) {
    _pingTimer = Timer.periodic(pingInterval, (_) {
      if (_link != link) return;
      try {
        link.send(jsonEncode({'type': 'ping', 'ts': _ms()}));
      } on Object {
        return;
      }
      _pongTimer ??= Timer(pongTimeout, () {
        debugPrint('[direct] sem pong: fechando');
        unawaited(link.close(1000));
      });
    });
  }

  Future<Map<String, dynamic>> _request(Map<String, dynamic> frame) async {
    final link = _link;
    if (link == null || !_synced) throw _Offline();
    final id = 'r${++_reqSeq}';
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    link.send(jsonEncode({...frame, 'req_id': id}));
    try {
      return await c.future.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      _pending.remove(id);
      unawaited(link.close(1000)); // reconecta; o reenvio usa o mesmo message_id
      throw _Offline();
    }
  }

  // ---- sincronização (§11.8) ----

  Future<void> _syncAll() async {
    await _refreshDirectory();
    await _syncEpochs();
    await _syncConversations();
    await _retryWaiting();
  }

  Future<void> _handleEvent(Map<String, dynamic> f) async {
    switch (f['type']) {
      case 'message':
        switch (DirectApi.groupWire(f['message'] as Map<String, dynamic>)) {
          case final WireMessage m:
            await _receive(m);
          case final SealedWire s:
            await _receiveSealed(s);
        }
      case 'group_change':
        await _onGroupChange(f);
      case 'member_access':
        await _onMemberAccess(f);
      case 'epoch':
        final item = EpochItem.fromJson(f['item'] as Map<String, dynamic>);
        if (item.isGroup) {
          await _onGroupEpoch(item);
        } else {
          await _processEpoch(item);
        }
        // Com escopo restrito, épocas de outras conversas não chegam: não
        // avançar o cursor, senão a sincronização completa as pularia.
        if (_scope == null) await _setMaxWrap((f['item'] as Map<String, dynamic>)['wrap_id'] as int);
        await _retryWaiting();
      case 'conversation':
        final ci = ConvInfo.fromJson(f['conversation'] as Map<String, dynamic>);
        if (ci.isGroup) {
          await _addGroup(ci);
        } else {
          await _upsertConv(ci);
        }
      case 'directory_changed':
        await _refreshDirectory();
    }
    _changed();
  }

  // ---- diretório e certificados (§7) ----

  bool _certOk(DeviceCert c, String userId, String adminLabel) =>
      c.userId == userId && c.adminLabel == adminLabel && crypto.c.verifyCert(c, serverSignPub);

  Future<void> _storeCert(DeviceCert c, {required bool active}) =>
      db.into(db.knownDevices).insertOnConflictUpdate(
        KnownDevicesCompanion.insert(
          deviceId: c.deviceId,
          userId: c.userId,
          certJson: jsonEncode(c.toJson()),
          active: active,
        ),
      );

  Future<void> _refreshDirectory() async {
    final users = await _authed(api.directory);
    final activeIds = <String>{};
    await db.transaction(() async {
      final present = <String, List<DeviceCert>>{};
      for (final u in users) {
        await db.into(db.dirUsers).insertOnConflictUpdate(
          DirUsersCompanion.insert(
            userId: u.userId,
            adminLabel: u.adminLabel,
            displayName: u.displayName,
            status: u.status,
          ),
        );
        for (final d in u.devices) {
          if (!_certOk(d, u.userId, u.adminLabel)) {
            _alert('certificado inválido no diretório (${u.userId})');
            continue;
          }
          activeIds.add(d.deviceId);
          (present[u.userId] ??= []).add(d);
          await _storeCert(d, active: true);
        }
      }
      // §7.3: inclui quem sumiu do diretório (usuário desativado).
      final seen = await db.select(db.seenKeys).get();
      for (final userId in {...present.keys, for (final r in seen) r.userId}) {
        await _noteDevices(userId, present[userId] ?? const [], directory: true);
      }
      final rows = await db.select(db.knownDevices).get();
      for (final r in rows) {
        if (!activeIds.contains(r.deviceId) && r.active) {
          await (db.update(db.knownDevices)..where((t) => t.deviceId.equals(r.deviceId)))
              .write(const KnownDevicesCompanion(active: Value(false)));
        }
      }
    });
    _dirUserIds = {for (final u in users) u.userId};
    _dirAt = _ms();
    _changed();
  }

  Set<String> _dirUserIds = {};

  // ---- aviso de aparelho novo (§7.3) ----

  /// Compara [certs] (já verificados) com os `sign_pub` vistos do contato e
  /// registra o aviso local. Com [directory], [certs] é o conjunto ativo inteiro:
  /// o que faltar foi desconectado. Na primeira vez só registra.
  Future<void> _noteDevices(String userId, List<DeviceCert> certs, {required bool directory}) async {
    if (userId == selfUserId) return;
    final rows = await (db.select(db.seenKeys)..where((t) => t.userId.equals(userId))).get();
    final seen = {for (final r in rows) r.signPub: r.present};
    final conv = await (db.select(db.conversations)..where((t) => t.peerUserId.equals(userId))).get();
    final user = await (db.select(db.dirUsers)..where((t) => t.userId.equals(userId))).getSingleOrNull();

    Future<void> warn(String text) async {
      for (final c in conv) {
        await _notice(c, text);
      }
      if (conv.isNotEmpty) _changed();
    }

    Future<void> mark(String key, bool present, {bool isNew = false}) => db.into(db.seenKeys).insertOnConflictUpdate(
      SeenKeysCompanion.insert(
        userId: userId,
        signPub: key,
        present: present,
        noticedAt: isNew ? Value(_ms()) : const Value.absent(),
      ),
    );

    final now = <String>{};
    for (final c in certs) {
      final key = b64uEncode(c.signPub);
      now.add(key);
      if (!seen.containsKey(key)) {
        if (seen.isNotEmpty) {
          await warn('${c.adminLabel} conectou um aparelho novo em ${_date(c.enrolledAt)}');
        }
        await mark(key, directory, isNew: seen.isNotEmpty);
      } else if (directory && seen[key] == false) {
        await mark(key, true);
      }
    }
    if (!directory) return;
    for (final e in seen.entries) {
      if (e.value && !now.contains(e.key)) {
        await warn('${user?.adminLabel ?? 'O contato'} desconectou um aparelho');
        await mark(e.key, false);
      }
    }
  }

  static String _date(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
  }

  /// Linha local na conversa, na posição atual do histórico.
  Future<void> _notice(Conversation conv, String text, {String? id}) => db.transaction(() async {
    await db.into(db.chatMessages).insert(
      ChatMessagesCompanion.insert(
        conversationId: conv.conversationId,
        messageId: id ?? 'aviso-${_uuid4()}',
        seq: Value(conv.syncedSeq),
        epoch: 0,
        senderDeviceId: '',
        sentAt: _ms(),
        body: Value(await _sealText(conv.conversationId, text)),
        state: msgNotice,
        mine: false,
      ),
      mode: InsertMode.insertOrIgnore,
    );
  });

  /// Certificado verificado de qualquer aparelho (diretório, cache ou `/v1/devices`).
  Future<DeviceCert?> _cert(String deviceId) async {
    final row = await (db.select(db.knownDevices)..where((t) => t.deviceId.equals(deviceId)))
        .getSingleOrNull();
    if (row != null) {
      return DeviceCert.fromJson(jsonDecode(row.certJson) as Map<String, dynamic>);
    }
    final List<DeviceCert> got;
    try {
      got = await _authed((t) => api.devices(t, [deviceId]));
    } on ApiException {
      return null;
    }
    for (final c in got) {
      if (c.deviceId != deviceId || !crypto.c.verifyCert(c, serverSignPub)) continue;
      final u = await (db.select(db.dirUsers)..where((t) => t.userId.equals(c.userId))).getSingleOrNull();
      if (u != null && u.adminLabel != c.adminLabel) continue;
      await _storeCert(c, active: false);
      await _noteDevices(c.userId, [c], directory: false);
      return c;
    }
    return null;
  }

  Future<List<DeviceCert>> _activeCerts(Iterable<String> userIds) async {
    final rows = await (db.select(db.knownDevices)
          ..where((t) => t.userId.isIn(userIds) & t.active.equals(true)))
        .get();
    return [for (final r in rows) DeviceCert.fromJson(jsonDecode(r.certJson) as Map<String, dynamic>)];
  }

  // ---- conversas ----

  Future<Conversation?> _conv(String id) =>
      (db.select(db.conversations)..where((t) => t.conversationId.equals(id))).getSingleOrNull();

  /// Na v1 (só 1:1) os membros de uma conversa nunca mudam: ficam os da
  /// primeira vez. Devolve false se recusou o que veio do servidor.
  Future<bool> _upsertConv(ConvInfo ci) async {
    if (ci.isGroup) {
      _groupIds.add(ci.conversationId);
      return false; // grupo não vai para o banco (D11)
    }
    // Um grupo já conhecido apresentado como 1:1 gravaria o conteúdo em disco.
    if (await _isKnownGroup(ci.conversationId)) {
      _alert('o servidor apresentou um grupo como conversa direta');
      return false;
    }
    final old = await _conv(ci.conversationId);
    final peers = ci.members.where((m) => m != selfUserId).toList();
    if (old != null &&
        !setEquals(ci.members.toSet(), (jsonDecode(old.membersJson) as List).cast<String>().toSet())) {
      _alert('o servidor tentou trocar os membros de uma conversa');
      await _notice(
        old,
        'O servidor tentou trocar os participantes desta conversa. A mudança foi recusada.',
        id: 'aviso-membros',
      );
      _changed();
      return false;
    }
    if (peers.length != 1 || ci.members.length != 2) {
      _alert('conversa com membros inesperados');
      return false;
    }
    await db.into(db.conversations).insertOnConflictUpdate(
      ConversationsCompanion.insert(
        conversationId: ci.conversationId,
        peerUserId: peers.single,
        membersJson: jsonEncode(ci.members),
        latestEpoch: max(old?.latestEpoch ?? 0, ci.latestEpoch),
        syncedSeq: old?.syncedSeq ?? 0,
      ),
    );
    if (!_dirUserIds.contains(peers.single) &&
        await (db.select(db.dirUsers)..where((t) => t.userId.equals(peers.single))).getSingleOrNull() == null) {
      await _refreshDirectory();
    }
    _changed();
    return true;
  }

  Future<void> _syncConversations() async {
    final list = await _authed(api.conversations);
    for (final ci in list) {
      if (ci.isGroup) {
        _groupIds.add(ci.conversationId);
        continue;
      }
      await _upsertConv(ci);
      final local = await _conv(ci.conversationId);
      if (local == null || !_inScope(ci.conversationId)) continue; // §11.8
      var after = local.syncedSeq;
      while (ci.lastSeq > after) {
        final page = await _authed((t) => api.messages(t, ci.conversationId, after));
        if (page.messages.isEmpty) break;
        for (final m in page.messages) {
          await _receive(m);
          after = max(after, m.seq ?? after);
        }
        if (!page.hasMore) break;
      }
    }
    await _syncGroups(list);
  }

  /// Abre (ou cria) a conversa direta com [peerUserId].
  Future<String> openConversationWith(String peerUserId) async {
    final ci = await _authed((t) => api.createConversation(t, peerUserId));
    if (!ci.members.contains(peerUserId) || !await _upsertConv(ci)) {
      throw UserFacingError('O servidor devolveu uma conversa com outra pessoa.');
    }
    return ci.conversationId;
  }

  // ---- épocas (§9) ----

  Future<void> _setMaxWrap(int id) async {
    final cur = await _maxWrap();
    if (id > cur) {
      await db.into(db.chatMeta).insertOnConflictUpdate(
        ChatMetaCompanion.insert(k: 'max_wrap_id', v: '$id'),
      );
    }
  }

  Future<int> _maxWrap() async {
    final r = await (db.select(db.chatMeta)..where((t) => t.k.equals('max_wrap_id'))).getSingleOrNull();
    return r == null ? 0 : int.parse(r.v);
  }

  bool _epochsResynced = false;

  /// Mensagem de época sem chave: o cursor pode ter pulado um embrulho (corrida
  /// no `wrap_id`). Pede tudo de novo, uma vez por sessão.
  Future<void> _resyncEpochsOnce() async {
    if (_epochsResynced) return;
    _epochsResynced = true;
    try {
      await _syncEpochs(fromStart: true);
    } on Object catch (e) {
      debugPrint('[direct] ressincronização de épocas: ${e.runtimeType}');
      _epochsResynced = false;
    }
  }

  Future<void> _syncEpochs({bool fromStart = false}) async {
    var after = fromStart ? 0 : await _maxWrap();
    var more = true;
    while (more) {
      final page = await _authed((t) => api.epochsMine(t, after));
      for (final it in page.items) {
        try {
          // Chaves de grupo não vão para o banco: vêm ao carregar o grupo.
          if (!it.isGroup) await _processEpoch(it);
        } on Object catch (e) {
          _alert('época descartada: ${e.runtimeType}');
        }
        await _setMaxWrap(it.wrapId);
        after = max(after, it.wrapId);
      }
      more = page.hasMore && page.items.isNotEmpty;
    }
  }

  Future<EpochKey?> _epochRow(String conversationId, int epoch) => (db.select(db.epochKeys)
        ..where((t) => t.conversationId.equals(conversationId) & t.epoch.equals(epoch)))
      .getSingleOrNull();

  /// Null se não há chave ou se a conversa está oculta e fechada.
  Future<Uint8List?> _epochKey(String conversationId, int epoch) async {
    if (_shut(conversationId)) return null;
    final r = await _epochRow(conversationId, epoch);
    return r == null ? null : _openBytes(conversationId, r.key);
  }

  Future<void> _storeEpochKey(String conversationId, int epoch, Uint8List key, List<String> recipients) =>
      db.transaction(() async {
        await db.into(db.epochKeys).insertOnConflictUpdate(
          EpochKeysCompanion.insert(
            conversationId: conversationId,
            epoch: epoch,
            key: await _sealBytes(conversationId, key),
            recipientsJson: jsonEncode(recipients),
          ),
        );
      });

  /// §9.8. Erros viram alerta e descarte; nunca derrubam a sincronização.
  Future<void> _processEpoch(EpochItem it) async {
    var conv = await _conv(it.conversationId);
    if (conv == null) {
      for (final ci in await _authed(api.conversations)) {
        await _upsertConv(ci);
      }
      conv = await _conv(it.conversationId);
    }
    if (conv == null) {
      _alert('época de conversa desconhecida');
      return;
    }
    if (await _epochRow(it.conversationId, it.epoch) != null) {
      await _bumpEpoch(conv, it.epoch);
      return;
    }
    final creator = await _cert(it.creatorDeviceId);
    final members = (jsonDecode(conv.membersJson) as List).cast<String>();
    if (creator == null || !members.contains(creator.userId)) {
      _alert('época com criador inválido');
      return;
    }
    final Uint8List k;
    try {
      k = crypto.openEpoch(
        conversationId: it.conversationId,
        epoch: it.epoch,
        creator: creator,
        commitment: it.commitment,
        recipients: it.recipients,
        signature: it.signature,
        wrappedKey: it.wrappedKey,
        escrowPub: escrowPub,
        self: keys,
      );
    } on ChatCryptoException catch (e) {
      _alert('época ${it.epoch} descartada: ${e.message}');
      return;
    }
    await _storeEpochKey(it.conversationId, it.epoch, k, it.recipients);
    await _bumpEpoch(conv, it.epoch);
  }

  Future<void> _bumpEpoch(Conversation conv, int epoch) async {
    if (epoch <= conv.latestEpoch) return;
    await (db.update(db.conversations)..where((t) => t.conversationId.equals(conv.conversationId)))
        .write(ConversationsCompanion(latestEpoch: Value(epoch)));
  }

  /// §9.5: devolve a época a usar, criando a seguinte se o conjunto de
  /// aparelhos mudou (inclui o embrulho para a chave de escrow).
  Future<int> _ensureEpoch(String conversationId) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0 || _ms() - _dirAt > 30000) await _refreshDirectory();
      final conv = (await _conv(conversationId))!;
      final members = (jsonDecode(conv.membersJson) as List).cast<String>();
      final certs = await _activeCerts(members);
      final s = ChatCrypto.sortedUnique(certs.map((c) => c.deviceId));
      if (!s.contains(selfDeviceId)) throw UserFacingError('Este aparelho não está ativo no diretório.');
      final l = conv.latestEpoch;
      if (l > 0) {
        final row = await _epochRow(conversationId, l);
        if (row != null && listEquals((jsonDecode(row.recipientsJson) as List).cast<String>(), s)) {
          return l;
        }
      }
      final ne = crypto.createEpoch(
        conversationId: conversationId,
        epoch: l + 1,
        self: keys,
        selfDeviceId: selfDeviceId,
        escrowPub: escrowPub,
        certs: certs,
      );
      try {
        await _authed((t) => api.createEpoch(t, conversationId, l + 1, selfDeviceId, ne));
      } on ApiException catch (e) {
        if (e.code == 'epoch_conflict' || e.code == 'device_set_changed') {
          await _syncEpochs();
          for (final ci in await _authed(api.conversations)) {
            await _upsertConv(ci);
          }
          continue;
        }
        rethrow;
      }
      await _storeEpochKey(conversationId, l + 1, ne.key, ne.recipients);
      await _bumpEpoch(conv, l + 1);
      return l + 1;
    }
    throw UserFacingError('Não foi possível criar a chave da conversa. Tente de novo.');
  }

  // ---- receber (§10.7) ----

  Future<ChatMessage?> _msg(String conversationId, String messageId) =>
      (db.select(db.chatMessages)
            ..where((t) => t.conversationId.equals(conversationId) & t.messageId.equals(messageId)))
          .getSingleOrNull();

  Future<void> _advanceSeq(String conversationId, int? seq) async {
    if (seq == null) return;
    final conv = await _conv(conversationId);
    if (conv != null && seq > conv.syncedSeq) {
      await (db.update(db.conversations)..where((t) => t.conversationId.equals(conversationId)))
          .write(ConversationsCompanion(syncedSeq: Value(seq)));
    }
  }

  Future<void> _receive(WireMessage m) async {
    if (_groupIds.contains(m.conversationId)) return _receiveGroup(m);
    final existing = await _msg(m.conversationId, m.messageId);
    if (existing != null) {
      if (existing.state == msgSending && m.seq != null) {
        // ack perdido: o histórico traz a minha mensagem com seq
        await (db.update(db.chatMessages)..where((t) => t.id.equals(existing.id)))
            .write(ChatMessagesCompanion(seq: Value(m.seq), state: const Value(msgOk)));
      }
      await _advanceSeq(m.conversationId, m.seq);
      return;
    }
    var conv = await _conv(m.conversationId);
    if (conv == null) {
      for (final ci in await _authed(api.conversations)) {
        await _upsertConv(ci);
      }
      conv = await _conv(m.conversationId);
      if (conv == null) {
        if (_groupIds.contains(m.conversationId)) return _receiveGroup(m);
        _alert('mensagem de conversa desconhecida');
        return;
      }
    }
    // Oculta e fechada: guarda o envelope; só a senha da conversa o decifra.
    final shut = _shut(m.conversationId);
    var key = await _epochKey(m.conversationId, m.epoch);
    if (key == null && !shut) {
      await _resyncEpochsOnce();
      key = await _epochKey(m.conversationId, m.epoch);
    }
    if (key == null) {
      await _insertRow(m, state: msgWaitingKey, mine: m.senderDeviceId == selfDeviceId, keepRaw: true);
    } else {
      final (state, body, mine, kind) = await _decrypt(conv, m, key);
      if (state == msgDiscarded) {
        await _insertRow(m, state: state, mine: false);
      } else {
        await _insertRow(m, state: state, body: body, mine: mine, kind: kind);
      }
    }
    await _advanceSeq(m.conversationId, m.seq);
    _changed();
  }

  /// (estado, corpo, minha, tipo). Em imagem, o corpo é o JSON de §18.1.
  Future<(int, String?, bool, int)> _decrypt(Conversation conv, WireMessage m, Uint8List key) async {
    final sender = await _cert(m.senderDeviceId);
    final members = (jsonDecode(conv.membersJson) as List).cast<String>();
    if (sender == null || !members.contains(sender.userId)) {
      _alert('mensagem de remetente inválido');
      return (msgDiscarded, null, false, kindText);
    }
    return _decryptFrom(sender, m, key);
  }

  /// Assinatura, decifração e tipo; o remetente já foi conferido por quem chama.
  (int, String?, bool, int) _decryptFrom(DeviceCert sender, WireMessage m, Uint8List key) {
    try {
      final plain = crypto.open(
        header: MessageHeader(
          conversationId: m.conversationId,
          epoch: m.epoch,
          senderDeviceId: m.senderDeviceId,
          messageId: m.messageId,
          sentAt: m.sentAt,
        ),
        msg: SealedMessage(m.nonce, m.ciphertext, m.signature),
        epochKey: key,
        senderSignPub: sender.signPub,
      );
      final mine = sender.userId == selfUserId;
      final text = ChatCrypto.parseText(plain);
      if (text != null) return (msgOk, text, mine, kindText);
      try {
        final ref = ImageRef.tryParse(plain);
        if (ref != null) return (msgOk, ref.toJson(), mine, kindImage);
      } on ChatCryptoException catch (e) {
        _alert('imagem recusada: ${e.message}'); // §18.1: "não suportada"
      }
      return (msgUnsupported, null, mine, kindText);
    } on ChatCryptoException catch (e) {
      _alert('mensagem descartada: ${e.message}');
      return (msgDiscarded, null, false, kindText);
    }
  }

  Future<void> _insertRow(
    WireMessage m, {
    required int state,
    String? body,
    required bool mine,
    int kind = kindText,
    bool keepRaw = false,
  }) => db.transaction(() async {
    await db.into(db.chatMessages).insert(
      ChatMessagesCompanion.insert(
        conversationId: m.conversationId,
        messageId: m.messageId,
        seq: Value(m.seq),
        epoch: m.epoch,
        senderDeviceId: m.senderDeviceId,
        sentAt: m.sentAt,
        body: Value(await _sealText(m.conversationId, body)),
        kind: Value(kind),
        state: state,
        mine: mine,
        nonce: Value(keepRaw ? m.nonce : null),
        ciphertext: Value(keepRaw ? m.ciphertext : null),
        signature: Value(keepRaw ? m.signature : null),
      ),
      mode: InsertMode.insertOrIgnore,
    );
  });

  /// Tenta de novo as mensagens que esperavam chave (§10.7, passo 2).
  Future<void> _retryWaiting() async {
    final rows = await (db.select(db.chatMessages)..where((t) => t.state.equals(msgWaitingKey))).get();
    for (final r in rows) {
      if (_shut(r.conversationId)) continue;
      if (await _epochKey(r.conversationId, r.epoch) == null) await _resyncEpochsOnce();
      final key = await _epochKey(r.conversationId, r.epoch);
      final conv = await _conv(r.conversationId);
      if (key == null || conv == null) continue;
      final m = WireMessage(
        conversationId: r.conversationId,
        epoch: r.epoch,
        senderDeviceId: r.senderDeviceId,
        messageId: r.messageId,
        sentAt: r.sentAt,
        nonce: r.nonce!,
        ciphertext: r.ciphertext!,
        signature: r.signature!,
        seq: r.seq,
      );
      final (state, body, mine, kind) = await _decrypt(conv, m, key);
      await db.transaction(() async {
        await (db.update(db.chatMessages)..where((t) => t.id.equals(r.id))).write(
          ChatMessagesCompanion(
            state: Value(state),
            body: Value(await _sealText(r.conversationId, body)),
            kind: Value(kind),
            mine: Value(mine),
            nonce: const Value(null),
            ciphertext: const Value(null),
            signature: const Value(null),
          ),
        );
      });
    }
    if (rows.isNotEmpty) _changed();
  }

  // ---- enviar (§10, §11.4) ----

  static const _uuidHex = '0123456789abcdef';

  String _uuid4() {
    final b = crypto.c.random(16);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = [for (final x in b) _uuidHex[x >> 4] + _uuidHex[x & 15]].join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20)}';
  }

  /// Grava a mensagem local e a envia em segundo plano. Sem conexão, fica
  /// pendente e sai assim que a sincronização terminar.
  Future<void> send(String conversationId, String text) async {
    if (text.trim().isEmpty) return;
    if (utf8.encode(text).length > ChatCrypto.maxText) {
      throw UserFacingError('Mensagem longa demais (máximo 12000 bytes).');
    }
    _requireOpen(conversationId);
    if (_groupIds.contains(conversationId)) return _sendGroup(conversationId, kindText, text);
    if (await _conv(conversationId) == null) throw UserFacingError('Conversa não encontrada.');
    final id = await db.transaction(
      () async => db.into(db.chatMessages).insert(
        ChatMessagesCompanion.insert(
          conversationId: conversationId,
          messageId: _uuid4(),
          epoch: 0,
          senderDeviceId: selfDeviceId,
          sentAt: _ms(),
          body: Value(await _sealText(conversationId, text)),
          state: msgSending,
          mine: true,
        ),
      ),
    );
    _changed();
    if (_synced && _inScope(conversationId)) unawaited(_locked(() => _transmitOne(id)).catchError((Object _) {}));
  }

  /// Cifra [prepared] (§18.2), guarda o blob cifrado e enfileira a mensagem `image`.
  /// O upload e o envio saem em segundo plano, como no texto.
  Future<void> sendImage(String conversationId, PreparedImage prepared) async {
    _requireOpen(conversationId);
    final isGroup = _groupIds.contains(conversationId);
    if (!isGroup && await _conv(conversationId) == null) throw UserFacingError('Conversa não encontrada.');
    final key = crypto.c.random(32);
    final blob = crypto.sealBlob(conversationId: conversationId, key: key, jpeg: prepared.jpeg);
    if (blob.length > maxBlobBytes) throw UserFacingError('Imagem grande demais (máximo 10 MB).');
    final ref = ImageRef(
      blobId: '',
      key: key,
      sha256: sha256Of(blob),
      width: prepared.width,
      height: prepared.height,
      thumb: prepared.thumb,
    );
    if (isGroup) return _sendGroup(conversationId, kindImage, ref.toJson(), blob: blob);
    final messageId = _uuid4();
    final id = await db.transaction(() async {
      await db.into(db.attachments).insert(
        AttachmentsCompanion.insert(
          conversationId: conversationId,
          messageId: messageId,
          data: Value(await _sealBytes(conversationId, blob)),
        ),
      );
      return db.into(db.chatMessages).insert(
        ChatMessagesCompanion.insert(
          conversationId: conversationId,
          messageId: messageId,
          epoch: 0,
          senderDeviceId: selfDeviceId,
          sentAt: _ms(),
          body: Value(await _sealText(conversationId, ref.toJson())),
          kind: const Value(kindImage),
          state: msgSending,
          mine: true,
        ),
      );
    });
    _changed();
    if (_synced && _inScope(conversationId)) unawaited(_locked(() => _transmitOne(id)).catchError((Object _) {}));
  }

  /// Sobe o blob se ainda não subiu e devolve o JSON da mensagem com `blob_id` (§18.4).
  Future<String> _ensureBlobUploaded(ChatMessage row) async {
    final ref = ImageRef.fromJson(row.body!, allowPendingBlob: true);
    if (ref.blobId.isNotEmpty) return row.body!;
    final data = await _attachmentData(row.conversationId, row.messageId);
    if (_shut(row.conversationId)) throw _Offline(); // fechou no meio: fica pendente
    if (data == null) throw UserFacingError('Imagem local perdida.');
    final up = await _authed((t) => api.uploadBlob(t, row.conversationId, data));
    if (!_sameBytes(up.sha256, ref.sha256) || up.size != data.length) {
      throw UserFacingError('O servidor guardou um blob diferente.');
    }
    final body = ref.withBlobId(up.blobId).toJson();
    await db.transaction(() async {
      await (db.update(db.chatMessages)..where((t) => t.id.equals(row.id)))
          .write(ChatMessagesCompanion(body: Value(await _sealText(row.conversationId, body))));
    });
    return body;
  }

  /// Blob cifrado guardado (já aberto, se a conversa é oculta).
  Future<Uint8List?> _attachmentData(String conversationId, String messageId) async {
    final row = await (db.select(db.attachments)
          ..where((t) => t.conversationId.equals(conversationId) & t.messageId.equals(messageId)))
        .getSingleOrNull();
    final data = row?.data;
    return data == null ? null : _openBytes(conversationId, data);
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var d = 0;
    for (var i = 0; i < a.length; i++) {
      d |= a[i] ^ b[i];
    }
    return d == 0;
  }

  /// Imagem completa em memória (JPEG). Baixa o blob se preciso, confere o SHA-256 da mensagem
  /// (§18.5), guarda só o blob cifrado e decifra. Nada em claro vai para o disco.
  Future<Uint8List> loadImage(ChatMessage row) async {
    _requireOpen(row.conversationId);
    if (row.kind != kindImage || row.body == null) throw UserFacingError('Não é uma imagem.');
    if (_groupIds.contains(row.conversationId)) return _loadGroupImage(row);
    final ref = ImageRef.fromJson(row.body!, allowPendingBlob: true);
    final Uint8List data;
    final stored = await _attachmentData(row.conversationId, row.messageId);
    if (stored != null) {
      data = stored;
    } else {
      final Uint8List got;
      try {
        got = await _authed((t) => api.downloadBlob(t, ref.blobId));
      } on ApiException {
        throw UserFacingError('Imagem indisponível.');
      } on Object {
        throw UserFacingError('Sem conexão para baixar a imagem.');
      }
      if (!_sameBytes(sha256Of(got), ref.sha256)) {
        _alert('imagem descartada: hash não confere');
        throw UserFacingError('Imagem indisponível (arquivo adulterado).');
      }
      await db.transaction(() async {
        await db.into(db.attachments).insertOnConflictUpdate(
          AttachmentsCompanion.insert(
            conversationId: row.conversationId,
            messageId: row.messageId,
            data: Value(await _sealBytes(row.conversationId, got)),
          ),
        );
      });
      data = got;
    }
    try {
      return crypto.openBlob(conversationId: row.conversationId, key: ref.key, blob: data);
    } on ChatCryptoException catch (e) {
      _alert('imagem descartada: ${e.message}');
      throw UserFacingError('Imagem indisponível.');
    }
  }

  /// Registra o salvamento no servidor (sem conexão, não salva) e devolve o JPEG com o EXIF de
  /// identificação (§18.6), pronto para a galeria.
  Future<Uint8List> prepareSave(ChatMessage row) async {
    if (row.seq == null) throw UserFacingError('A mensagem ainda não foi enviada.');
    final jpeg = await loadImage(row);
    final SaveTicket t;
    try {
      t = await _authed((tok) => api.createSave(tok, row.conversationId, row.seq!));
    } on ApiException catch (e) {
      if (e.code == 'sender_inactive') {
        _lockThumb(row.conversationId, row.messageId);
        throw UserFacingError('Quem enviou está sem acesso. A foto não foi salva.');
      }
      throw UserFacingError('O servidor recusou o registro. A foto não foi salva.');
    } on Object {
      throw UserFacingError('Sem conexão. Para salvar a foto é preciso estar conectado.');
    }
    // O EXIF leva os ids deste aparelho; resposta com outros é adulterada.
    if (t.userId != cert.userId || t.deviceId != cert.deviceId) {
      throw UserFacingError('Resposta do servidor adulterada. A foto não foi salva.');
    }
    final at = DateTime.fromMillisecondsSinceEpoch(t.savedAt, isUtc: true);
    // marca d'água só na cópia da galeria (D10), depois do save_id e antes do EXIF
    final marked = await applyWatermark(jpeg, watermarkText(label: artistLabel(cert), at: at, saveId: t.saveId));
    return addSaveExif(
      marked,
      artist: artistLabel(cert),
      description: saveDescription(saveId: t.saveId, userId: cert.userId, deviceId: cert.deviceId, at: at),
    );
  }

  Future<void> _flushPending() async {
    final rows = await (db.select(db.chatMessages)
          ..where((t) => t.state.equals(msgSending))
          ..orderBy([(t) => OrderingTerm.asc(t.sentAt)]))
        .get();
    for (final r in rows) {
      if (!_synced) return;
      // Fora do escopo o `ack` avançaria o `seq` sem ter lido o histórico.
      if (_inScope(r.conversationId)) await _transmitOne(r.id);
    }
    await _flushGroups();
  }

  Future<void> _transmitOne(int rowId) async {
    var row = await (db.select(db.chatMessages)..where((t) => t.id.equals(rowId))).getSingleOrNull();
    // Oculta e fechada: fica pendente até a senha da conversa.
    if (row == null || row.state != msgSending || _shut(row.conversationId)) return;
    row = row.copyWith(body: Value(_openText(row.conversationId, row.body)));
    try {
      String? body = row.body;
      if (row.kind == kindImage) body = await _ensureBlobUploaded(row);
      for (var attempt = 0; attempt < 3; attempt++) {
        final epoch = await _ensureEpoch(row.conversationId);
        final key = await _epochKey(row.conversationId, epoch);
        if (key == null) return; // a conversa oculta fechou no meio do envio
        final header = MessageHeader(
          conversationId: row.conversationId,
          epoch: epoch,
          senderDeviceId: selfDeviceId,
          messageId: row.messageId,
          sentAt: row.sentAt,
        );
        final sealed = crypto.seal(
          header: header,
          epochKey: key,
          plaintext: row.kind == kindImage ? Uint8List.fromList(utf8.encode(body!)) : crypto.textPlain(row.body!),
          signSeed: keys.signSeed,
        );
        final wire = WireMessage(
          conversationId: row.conversationId,
          epoch: epoch,
          senderDeviceId: selfDeviceId,
          messageId: row.messageId,
          sentAt: row.sentAt,
          nonce: sealed.nonce,
          ciphertext: sealed.ciphertext,
          signature: sealed.signature,
        );
        final res = await _request({'type': 'send', 'message': wire.toSendJson()});
        if (res['type'] == 'ack') {
          final seq = res['seq'] as int;
          await (db.update(db.chatMessages)..where((t) => t.id.equals(rowId))).write(
            ChatMessagesCompanion(seq: Value(seq), state: const Value(msgOk), epoch: Value(epoch)),
          );
          await _advanceSeq(row.conversationId, seq);
          _changed();
          return;
        }
        if (res['code'] == 'epoch_required') {
          final latest = res['latest_epoch'];
          final conv = await _conv(row.conversationId);
          if (conv != null && latest is int) await _bumpEpoch(conv, latest);
          await _refreshDirectory();
          await _syncEpochs();
          continue;
        }
        break; // erro definitivo do servidor
      }
      await _markFailed(rowId);
    } on _Offline {
      // fica pendente; reenvia com o mesmo message_id na próxima conexão
    } on ApiException catch (e) {
      debugPrint('[direct] envio: ${e.code}');
      if (e.status >= 400 && e.status < 500 && e.code != 'unauthorized') await _markFailed(rowId);
    } on UserFacingError {
      await _markFailed(rowId);
    }
  }

  Future<void> _markFailed(int rowId) async {
    await (db.update(db.chatMessages)..where((t) => t.id.equals(rowId)))
        .write(const ChatMessagesCompanion(state: Value(msgFailed)));
    _changed();
  }

  /// Reenvia uma mensagem que falhou.
  Future<void> retry(int rowId) async {
    if (rowId < 0) return _retryGroup(rowId);
    await (db.update(db.chatMessages)..where((t) => t.id.equals(rowId)))
        .write(const ChatMessagesCompanion(state: Value(msgSending)));
    _changed();
    if (_synced) unawaited(_locked(() => _transmitOne(rowId)).catchError((Object _) {}));
  }

  // ---- consultas para a interface ----

  Future<List<DirectoryEntry>> directory() async {
    final rows = await db.select(db.dirUsers).get();
    // Contato de conversa 1:1 oculta some junto (D12).
    final hidden = {
      for (final c in await db.select(db.conversations).get())
        if (isHidden(c.conversationId)) c.peerUserId,
    };
    final out = [
      for (final r in rows)
        if (r.userId != selfUserId && !hidden.contains(r.userId) && (_dirUserIds.isEmpty || _dirUserIds.contains(r.userId)))
          DirectoryEntry(r.userId, r.adminLabel, r.displayName, r.status),
    ]..sort((a, b) => a.adminLabel.toLowerCase().compareTo(b.adminLabel.toLowerCase()));
    return out;
  }

  Future<List<ConversationView>> conversations() async {
    final convs = await db.select(db.conversations).get();
    final out = <ConversationView>[
      for (final g in await _groupViews())
        if (!isHidden(g.conversationId)) g,
    ];
    for (final c in convs) {
      if (isHidden(c.conversationId)) continue;
      final u = await (db.select(db.dirUsers)..where((t) => t.userId.equals(c.peerUserId))).getSingleOrNull();
      final last = await (db.select(db.chatMessages)
            ..where((t) => t.conversationId.equals(c.conversationId) & t.state.isNotIn([msgDiscarded]))
            ..orderBy([(t) => OrderingTerm.desc(t.sentAt)])
            ..limit(1))
          .getSingleOrNull();
      out.add(
        ConversationView(
          conversationId: c.conversationId,
          peerUserId: c.peerUserId,
          title: u?.adminLabel ?? 'Usuário removido',
          subtitle: u?.displayName ?? '',
          lastText: last == null ? '' : _preview(last),
          lastAt: last?.sentAt ?? 0,
        ),
      );
    }
    out.sort((a, b) => b.lastAt.compareTo(a.lastAt));
    return out;
  }

  static int _noticeLast(ChatMessage m) => m.state == msgNotice ? 1 : 0;

  static String _preview(ChatMessage m) => switch (m.state) {
    msgWaitingKey => 'Aguardando chave…',
    msgUnsupported => 'Mensagem não suportada nesta versão',
    _ => m.kind == kindImage ? 'Foto' : (m.body ?? ''),
  };

  /// Mensagens da conversa em ordem: por `seq`, pendentes por último.
  Future<List<ChatMessage>> messages(String conversationId) async {
    if (_groupIds.contains(conversationId)) {
      return [for (final l in await groupLines(conversationId)) l.message];
    }
    if (_shut(conversationId)) return const [];
    var rows = await (db.select(db.chatMessages)
          ..where((t) => t.conversationId.equals(conversationId) & t.state.isNotIn([msgDiscarded])))
        .get();
    rows.sort((a, b) {
      if (a.seq != null && b.seq != null) {
        // o aviso fica depois da mensagem de mesmo `seq`
        final c = a.seq!.compareTo(b.seq!);
        if (c != 0) return c;
        final n = _noticeLast(a).compareTo(_noticeLast(b));
        return n != 0 ? n : a.sentAt.compareTo(b.sentAt);
      }
      if (a.seq != null) return -1;
      if (b.seq != null) return 1;
      return a.sentAt.compareTo(b.sentAt);
    });
    if (isHidden(conversationId)) {
      rows = [for (final m in rows) m.copyWith(body: Value(_openText(conversationId, m.body)))];
    }
    return rows;
  }

  Future<PeerInfo?> peerInfo(String conversationId) async {
    final c = await _conv(conversationId);
    if (c == null) return null;
    final u = await (db.select(db.dirUsers)..where((t) => t.userId.equals(c.peerUserId))).getSingleOrNull();
    final certs = await _activeCerts([c.peerUserId]);
    return PeerInfo(u?.adminLabel ?? 'Usuário removido', u?.displayName ?? '', u?.status ?? '', [
      for (final d in certs) crypto.c.deviceCode(d.signPub, d.kexPub),
    ]);
  }

  Future<String> peerTitle(String conversationId) async {
    if (_groupIds.contains(conversationId)) return groupTitle(conversationId);
    final c = await _conv(conversationId);
    if (c == null) return '';
    final u = await (db.select(db.dirUsers)..where((t) => t.userId.equals(c.peerUserId))).getSingleOrNull();
    return u?.adminLabel ?? 'Usuário removido';
  }
}

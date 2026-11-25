import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'b64.dart';
import 'chat_crypto.dart';
import 'chat_models.dart';
import 'group_proto.dart';
import 'models.dart';

class ApiException implements Exception {
  ApiException(this.code, this.status, this.message, {this.revokedSig, this.latestEpoch});
  final String code;
  final int status;
  final String message;

  /// Prova de revogação (protocolo §6.4), só em `device_revoked` do `verify`.
  final Uint8List? revokedSig;

  /// `latest_epoch` em `epoch_conflict` (§9.6).
  final int? latestEpoch;

  @override
  String toString() => '$code ($status): $message';
}

class AccessToken {
  AccessToken(this.token, this.expiresAt);
  final String token;
  final int expiresAt;
}

class EnrollResult {
  EnrollResult(this.newUser, this.cert);
  final bool newUser;
  final DeviceCert cert;
}

/// Resposta de `POST /v1/blobs` (protocolo §18.4).
class BlobUpload {
  BlobUpload(this.blobId, this.size, this.sha256);
  final String blobId;
  final int size;
  final Uint8List sha256;
}

/// Resposta de `POST /v1/media/saves` (§18.6).
class SaveTicket {
  SaveTicket(this.saveId, this.savedAt, this.userId, this.deviceId);
  final String saveId;
  final int savedAt; // ms
  final String userId;
  final String deviceId;
}

class ServerInfo {
  ServerInfo(this.serverSignPub, this.escrowPub, [this.modPub]);

  /// Não assinado: só vale depois da conferência de protocolo-grupos §3.4.
  final Uint8List? modPub;
  final Uint8List serverSignPub;
  final Uint8List escrowPub;
}

/// Cliente HTTP do `directd` (protocolo §4.3, §5, §6, §7.4). TLS pelo sistema.
class DirectApi {
  DirectApi(this.host, {http.Client? client, this.debugBase})
    : _http = client ?? http.Client();
  final String host;

  /// Só debug: base HTTP no lugar de https://host (emulador → 10.0.2.2:8080).
  final Uri? debugBase;
  final http.Client _http;

  /// `wss://host/v1/ws` (ou `ws://` com a base de debug).
  Uri get wsUri => debugBase != null
      ? debugBase!.replace(scheme: 'ws', path: '/v1/ws')
      : Uri(scheme: 'wss', host: host, path: '/v1/ws');
  static const _timeout = Duration(seconds: 15);

  Future<Map<String, dynamic>> _call(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? token,
    Map<String, String>? query,
  }) async {
    final req = http.Request(
      method,
      debugBase?.replace(path: path, queryParameters: query) ?? Uri.https(host, path, query),
    );
    req.headers['Accept'] = 'application/json';
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    if (token != null) req.headers['Authorization'] = 'Bearer $token';
    final res = await http.Response.fromStream(
      await _http.send(req).timeout(_timeout),
    ).timeout(_timeout);
    Map<String, dynamic> json = {};
    if (res.bodyBytes.isNotEmpty) {
      try {
        final d = jsonDecode(utf8.decode(res.bodyBytes));
        if (d is Map<String, dynamic>) json = d;
      } on FormatException {
        // corpo não JSON: tratado abaixo conforme o status
      }
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return json;
    final err = json['error'];
    Uint8List? revoked;
    final rs = json['revoked_sig'];
    if (rs is String) {
      try {
        revoked = b64uDecode(rs, length: 64);
      } on FormatException {
        revoked = null;
      }
    }
    throw ApiException(
      err is Map && err['code'] is String ? err['code'] as String : 'http_error',
      res.statusCode,
      err is Map && err['message'] is String ? err['message'] as String : '',
      revokedSig: revoked,
      latestEpoch: err is Map && err['latest_epoch'] is int ? err['latest_epoch'] as int : null,
    );
  }

  Future<ServerInfo> serverInfo() async {
    final j = await _call('GET', '/v1/server-info');
    return ServerInfo(
      b64uDecode(j['server_sign_pub'] as String, length: 32),
      b64uDecode(j['escrow_pub'] as String, length: 32),
      j['mod_pub'] == null ? null : b64uDecode(j['mod_pub'] as String, length: 32),
    );
  }

  Future<EnrollResult> enroll(Map<String, dynamic> body) async {
    final j = await _call('POST', '/v1/enroll', body: body);
    return EnrollResult(
      j['new_user'] == true,
      DeviceCert.fromJson(j['cert'] as Map<String, dynamic>),
    );
  }

  Future<Uint8List> challenge(String deviceId) async {
    final j = await _call('POST', '/v1/auth/challenge', body: {'device_id': deviceId});
    return b64uDecode(j['challenge'] as String, length: 32);
  }

  Future<AccessToken> verify(
    String deviceId,
    Uint8List challenge,
    Uint8List sig,
  ) async {
    final j = await _call('POST', '/v1/auth/verify', body: {
      'device_id': deviceId,
      'challenge': b64uEncode(challenge),
      'sig': b64uEncode(sig),
    });
    return AccessToken(j['access_token'] as String, j['expires_at'] as int);
  }

  Future<void> putProfile(String token, String displayName, String status) =>
      _call('PUT', '/v1/me/profile',
          token: token, body: {'display_name': displayName, 'status': status});

  Future<List<DirectoryUser>> directory(String token) async {
    final j = await _call('GET', '/v1/directory', token: token);
    return [
      for (final u in (j['users'] as List)) DirectoryUser.fromJson(u as Map<String, dynamic>),
    ];
  }

  /// Certificados de qualquer aparelho, inclusive revogados (§7.2).
  Future<List<DeviceCert>> devices(String token, List<String> ids) async {
    final out = <DeviceCert>[];
    for (var i = 0; i < ids.length; i += 100) {
      final chunk = ids.sublist(i, i + 100 > ids.length ? ids.length : i + 100);
      final j = await _call('GET', '/v1/devices', token: token, query: {'ids': chunk.join(',')});
      for (final d in (j['devices'] as List)) {
        out.add(DeviceCert.fromJson((d as Map<String, dynamic>)['cert'] as Map<String, dynamic>));
      }
    }
    return out;
  }

  Future<List<ConvInfo>> conversations(String token) async {
    final j = await _call('GET', '/v1/conversations', token: token);
    return [
      for (final c in (j['conversations'] as List)) ConvInfo.fromJson(c as Map<String, dynamic>),
    ];
  }

  Future<ConvInfo> createConversation(String token, String peerUserId) async {
    final j = await _call(
      'POST',
      '/v1/conversations',
      token: token,
      body: {'kind': 'direct', 'peer_user_id': peerUserId},
    );
    return ConvInfo.fromJson(j);
  }

  Future<void> createEpoch(
    String token,
    String conversationId,
    int epoch,
    String creatorDeviceId,
    NewEpoch e,
  ) => _call(
    'POST',
    '/v1/conversations/$conversationId/epochs',
    token: token,
    body: epochJson(epoch, creatorDeviceId, e),
  );

  /// Corpo de época (§9.6).
  static Map<String, dynamic> epochJson(int epoch, String creatorDeviceId, NewEpoch e) => {
    'epoch': epoch,
    'creator_device_id': creatorDeviceId,
    'key_commitment': b64uEncode(e.commitment),
    'recipients': e.recipients,
    'wraps': [
      for (final id in e.recipients) {'device_id': id, 'wrapped_key': b64uEncode(e.wraps[id]!)},
    ],
    'escrow_wrap': b64uEncode(e.escrowWrap),
    'signature': b64uEncode(e.signature),
  };

  /// Época de grupo: com a posição da cadeia e, fora de `POST /v1/groups`, os metadados.
  Future<void> createGroupEpoch(String token, String conversationId, Map<String, dynamic> body) =>
      _call('POST', '/v1/conversations/$conversationId/epochs', token: token, body: body);

  Future<({List<EpochItem> items, bool hasMore})> epochsMine(String token, int after) async {
    final j = await _call('GET', '/v1/epochs/mine', token: token, query: {'after': '$after'});
    return (
      items: [for (final i in (j['items'] as List)) EpochItem.fromJson(i as Map<String, dynamic>)],
      hasMore: j['has_more'] == true,
    );
  }

  Future<({List<WireMessage> messages, bool hasMore})> messages(
    String token,
    String conversationId,
    int after,
  ) async {
    final j = await _call(
      'GET',
      '/v1/conversations/$conversationId/messages',
      token: token,
      query: {'after': '$after'},
    );
    return (
      messages: [for (final m in (j['messages'] as List)) WireMessage.fromJson(m as Map<String, dynamic>)],
      hasMore: j['has_more'] == true,
    );
  }

  // ---- grupos (protocolo-grupos §10) ----

  Future<ConvInfo> createGroup(String token, Map<String, dynamic> body) async =>
      ConvInfo.fromJson(await _call('POST', '/v1/groups', token: token, body: body));

  Future<void> groupChange(String token, String id, Map<String, dynamic> body) =>
      _call('POST', '/v1/groups/$id/changes', token: token, body: body);

  /// Registros com número maior que [after], em ordem.
  Future<List<SignedChange>> groupChanges(String token, String id, int after) async {
    final out = <SignedChange>[];
    var more = true;
    while (more) {
      final j = await _call('GET', '/v1/groups/$id/changes', token: token, query: {'after': '$after'});
      final page = [for (final r in j['changes'] as List) SignedChange.fromJson(r as Map<String, dynamic>)];
      out.addAll(page);
      more = j['has_more'] == true && page.isNotEmpty;
      after += page.length;
    }
    return out;
  }

  Future<List<GroupMeta>> groupMeta(String token, String id) async {
    final j = await _call('GET', '/v1/groups/$id/meta', token: token);
    return [for (final m in j['items'] as List) GroupMeta.fromJson(m as Map<String, dynamic>)];
  }

  Future<void> historyWraps(String token, String id, int addN, List<Map<String, dynamic>> items) =>
      _call('POST', '/v1/groups/$id/history-wraps', token: token, body: {'add_n': addN, 'items': items});

  Future<List<EpochItem>> conversationEpochs(String token, String id) async {
    final out = <EpochItem>[];
    var after = 0;
    var more = true;
    while (more) {
      final j = await _call(
        'GET',
        '/v1/conversations/$id/epochs/mine',
        token: token,
        query: after == 0 ? null : {'after': '$after'},
      );
      final page = [for (final i in j['items'] as List) EpochItem.fromJson(i as Map<String, dynamic>)];
      out.addAll(page);
      for (final i in page) {
        if (i.wrapId > after) after = i.wrapId;
      }
      more = j['has_more'] == true && page.isNotEmpty;
    }
    return out;
  }

  /// Histórico de grupo: normal ou selado. [before] busca para trás.
  Future<({List<Object> items, bool hasMore})> groupMessages(
    String token,
    String id, {
    int? after,
    int? before,
    int limit = 200,
  }) async {
    final j = await _call(
      'GET',
      '/v1/conversations/$id/messages',
      token: token,
      query: {
        if (after != null) 'after': '$after',
        if (before != null) 'before': '$before',
        'limit': '$limit',
      },
    );
    return (
      items: [for (final m in j['messages'] as List) groupWire(m as Map<String, dynamic>)],
      hasMore: j['has_more'] == true,
    );
  }

  /// [SealedWire] ou [WireMessage].
  static Object groupWire(Map<String, dynamic> j) =>
      j['sealed'] == true ? SealedWire.fromJson(j) : WireMessage.fromJson(j);

  Future<({List<AccessEvent> events, bool hasMore})> accessEvents(String token, String id, int after) async {
    final j = await _call('GET', '/v1/conversations/$id/access-events', token: token, query: {'after': '$after'});
    return (
      events: [for (final e in j['events'] as List) AccessEvent.fromJson(e as Map<String, dynamic>)],
      hasMore: j['has_more'] == true,
    );
  }

  /// Sem token (§8.3).
  Future<void> selfRevoke(Map<String, dynamic> body) => _call('POST', '/v1/devices/self-revoke', body: body);

  static const _blobTimeout = Duration(minutes: 3);

  Uri _uri(String path, [Map<String, String>? query]) =>
      debugBase?.replace(path: path, queryParameters: query) ?? Uri.https(host, path, query);

  ApiException _errorOf(http.Response res) {
    Map<String, dynamic> j = {};
    try {
      final d = jsonDecode(utf8.decode(res.bodyBytes));
      if (d is Map<String, dynamic>) j = d;
    } on FormatException {
      // corpo não JSON
    }
    final err = j['error'];
    return ApiException(
      err is Map && err['code'] is String ? err['code'] as String : 'http_error',
      res.statusCode,
      err is Map && err['message'] is String ? err['message'] as String : '',
    );
  }

  /// `POST /v1/blobs?conversation_id=` com o blob cifrado como corpo (§18.4).
  Future<BlobUpload> uploadBlob(String token, String conversationId, Uint8List blob) async {
    final req = http.Request('POST', _uri('/v1/blobs', {'conversation_id': conversationId}))
      ..headers['Authorization'] = 'Bearer $token'
      ..headers['Content-Type'] = 'application/octet-stream'
      ..bodyBytes = blob;
    final res = await http.Response.fromStream(await _http.send(req).timeout(_blobTimeout)).timeout(_blobTimeout);
    if (res.statusCode != 201) throw _errorOf(res);
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return BlobUpload(j['blob_id'] as String, j['size'] as int, b64uDecode(j['sha256'] as String, length: 32));
  }

  /// `GET /v1/blobs/{id}` (§18.5). O hash é conferido por quem chama.
  Future<Uint8List> downloadBlob(String token, String blobId) async {
    final req = http.Request('GET', _uri('/v1/blobs/$blobId'))..headers['Authorization'] = 'Bearer $token';
    final res = await http.Response.fromStream(await _http.send(req).timeout(_blobTimeout)).timeout(_blobTimeout);
    if (res.statusCode != 200) throw _errorOf(res);
    if (res.bodyBytes.length > 10 * 1024 * 1024) throw ApiException('too_large', 200, 'blob grande demais');
    return res.bodyBytes;
  }

  /// `POST /v1/media/saves` (§18.6): registra o salvamento e devolve o `save_id`.
  Future<SaveTicket> createSave(String token, String conversationId, int seq) async {
    final j = await _call(
      'POST',
      '/v1/media/saves',
      token: token,
      body: {'conversation_id': conversationId, 'seq': seq},
    );
    final user = j['user_id'] as String, dev = j['device_id'] as String, id = j['save_id'] as String;
    uuidToBytes(id);
    uuidToBytes(user);
    uuidToBytes(dev);
    return SaveTicket(id, j['saved_at'] as int, user, dev);
  }

  void close() => _http.close();
}

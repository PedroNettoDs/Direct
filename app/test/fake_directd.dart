// `directd` de mentira com as rotas de protocolo-grupos §10, para os testes de
// grupo. Também age pelos outros usuários (assina registros, cria épocas, envia).
import 'dart:convert';
import 'dart:typed_data';

import 'package:direct/chat/chat_service.dart';
import 'package:direct/core/api.dart';
import 'package:direct/core/b64.dart';
import 'package:direct/core/chat_crypto.dart';
import 'package:direct/core/chat_models.dart';
import 'package:direct/core/crypto.dart';
import 'package:direct/core/group_proto.dart';
import 'package:direct/core/media.dart';
import 'package:direct/core/models.dart';
import 'package:direct/data/db.dart';
import 'package:drift/native.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'chat_ws_test.dart' show FakeLink;

class FakeDevice {
  FakeDevice(this.cert, this.keys);
  final DeviceCert cert;
  final DeviceKeys keys;
  bool active = true;
  String get id => cert.deviceId;
  String get userId => cert.userId;
}

class FakeEpoch {
  FakeEpoch(this.creator, this.commitment, this.recipients, this.signature, this.chainN, this.chainHash);
  final String creator;
  final String commitment;
  final List<String> recipients;
  final String signature;
  final int chainN;
  final String chainHash;
}

class FakeGroup {
  FakeGroup(this.id, this.state);
  final String id;
  GroupState state;
  final changes = <SignedChange>[];
  final epochs = <int, FakeEpoch>{};

  /// (wrap_id, epoch, device_id, wrapped_key)
  final wraps = <(int, int, String, String)>[];
  final metas = <int, Map<String, dynamic>>{};
  final messages = <Map<String, dynamic>>[];
  final access = <Map<String, dynamic>>[];
  int get latest => epochs.isEmpty ? 0 : epochs.keys.reduce((a, b) => a > b ? a : b);
}

class FakeGroupLink extends FakeLink {
  FakeGroupLink(this.server);
  final FakeDirectd server;

  @override
  void send(String text) {
    super.send(text);
    final f = sent.last;
    if (f['type'] == 'send') server._onSend(this, f);
  }
}

const meId = '2b4d6f81-3a5c-4e7a-9b1d-3f5a7c9e1b2d';
const anaId = '7d0c9b8a-1e2f-4a3b-9c4d-5e6f7a8b9c0d';
const marcosId = '5c6d7e8f-9a0b-4c1d-8e2f-3a4b5c6d7e8f';
const paulaId = 'd1e2f3a4-b5c6-4d7e-8f90-a1b2c3d4e5f6';

class FakeDirectd {
  FakeDirectd(this.c, {int Function()? clock}) : cc = ChatCrypto(c), clock = clock ?? _counter() {
    serverSeed = c.random(32);
    serverPub = c.signPubFromSeed(serverSeed);
    modSeed = c.random(32);
    modPub = c.signPubFromSeed(modSeed);
    escrow = c.generateDeviceKeys();
    me = addDevice(meId, 'João - Financeiro');
    ana = addDevice(anaId, 'Ana Souza - Diretoria');
    marcos = addDevice(marcosId, 'Marcos Lima - TI');
    paula = addDevice(paulaId, 'Paula Reis - RH');
  }

  static int Function() _counter() {
    var t = 1798100000000;
    return () => t += 1000;
  }

  final DirectCrypto c;
  final ChatCrypto cc;
  final int Function() clock;
  late final Uint8List serverSeed, serverPub, modSeed, modPub;
  late final DeviceKeys escrow;
  late final FakeDevice me, ana, marcos, paula;

  final devices = <String, FakeDevice>{};
  final groups = <String, FakeGroup>{};
  final inactive = <String>{};
  final blobs = <String, ({String conv, String uploader, Uint8List data})>{};
  final requests = <String>[];
  final selfRevoked = <Map<String, dynamic>>[];
  FakeGroupLink? link;
  bool down = false;

  /// Mentira do servidor na lista informativa de membros.
  List<String> extraMembers = const [];
  int _wrapId = 0;
  int _ids = 0;

  String newId() => '44444444-4444-4444-8444-${(++_ids).toString().padLeft(12, '0')}';

  FakeDevice addDevice(String userId, String label, {int enrolledAt = 1790000000000}) {
    final k = c.generateDeviceKeys();
    final id = '${userId.substring(0, 24)}${(devices.length + 1).toString().padLeft(12, '0')}';
    final unsigned = DeviceCert(
      deviceId: id,
      userId: userId,
      adminLabel: label,
      signPub: k.signPub,
      kexPub: k.kexPub,
      enrolledAt: enrolledAt,
      expiresAt: 1900000000000,
      sig: Uint8List(64),
    );
    final cert = DeviceCert.fromJson({...unsigned.toJson(), 'sig': b64uEncode(c.sign(serverSeed, c.certBytes(unsigned)))});
    return devices[id] = FakeDevice(cert, k);
  }

  Iterable<FakeDevice> activeOf(Iterable<String> users) =>
      devices.values.where((d) => d.active && users.contains(d.userId));

  ChainKeys get chainKeys => ChainKeys(
    serverSignPub: serverPub,
    modPub: modPub,
    certs: {for (final d in devices.values) d.id: d.cert},
  );

  // ---- o cliente em teste ----

  ChatService service({AppDatabase? db, bool pinned = true, bool Function(String)? isLocked, FakeDevice? as}) {
    final self = as ?? me;
    return ChatService(
      db: db ?? AppDatabase(NativeDatabase.memory()),
      api: DirectApi('h.example', client: client),
      crypto: cc,
      // cópia: `stop()` zera as chaves do serviço
      keys: DeviceKeys(
        signSeed: Uint8List.fromList(self.keys.signSeed),
        signPub: self.keys.signPub,
        kexSk: Uint8List.fromList(self.keys.kexSk),
        kexPub: self.keys.kexPub,
      ),
      cert: self.cert,
      serverSignPub: serverPub,
      escrowPub: escrow.kexPub,
      modPub: pinned ? modPub : null,
      isLocked: isLocked ?? (_) => false,
      login: () async => AccessToken('t', clock() + 3600000000),
      connector: (_) async {
        if (down) throw StateError('sem rede');
        return link = FakeGroupLink(this);
      },
      maxBackoff: const Duration(milliseconds: 20),
    );
  }

  void push(Map<String, dynamic> f) => link!.push(f);

  // ---- ações dos outros usuários ----

  SignedChange sign(FakeGroup g, int kind, FakeDevice? author, Uint8List body) {
    final bytes = GroupChange(
      conversationId: g.id,
      n: g.state.n + 1,
      prev: g.state.head,
      kind: kind,
      authorType: author == null ? authorModerator : authorDevice,
      authorDeviceId: author?.id ?? zeroUuid,
      authorUserId: author?.userId ?? zeroUuid,
      createdAt: clock(),
      body: body,
    ).encode();
    return SignedChange(bytes, c.sign(author?.keys.signSeed ?? modSeed, bytes), n: g.state.n + 1, receivedAt: clock());
  }

  void apply(FakeGroup g, SignedChange r) {
    g.state.apply(r, chainKeys);
    g.changes.add(r);
  }

  Uint8List metaBytes(String name) => GroupProfile(name: name).encode(c.random(32));

  /// Grupo criado por [creator] (null: pelo moderador, com rótulo).
  FakeGroup createGroup(
    FakeDevice? creator, {
    required Iterable<String> members,
    String name = 'Projeto Atlas',
    String label = 'Diretoria - oficial',
    String? admin,
  }) {
    final id = newId();
    final g = groups[id] = FakeGroup(id, GroupState(c, id));
    final meta = creator == null ? null : metaBytes(name);
    final roles = {for (final u in members) u: roleMember};
    roles[creator?.userId ?? admin ?? anaId] = roleAdmin;
    apply(
      g,
      sign(
        g,
        kindCreate,
        creator,
        createBody(creator == null ? label : '', meta == null ? Uint8List(32) : metaCommitOf(c, id, meta), roles),
      ),
    );
    if (creator != null) newEpoch(g, creator, meta: meta);
    return g;
  }

  /// Época nova de [creator] para os aparelhos dos membros (mais [extra], para
  /// simular fantasma). Devolve a chave.
  Uint8List newEpoch(FakeGroup g, FakeDevice creator, {Uint8List? meta, List<FakeDevice> extra = const []}) {
    final epoch = g.latest + 1;
    final ne = createGroupEpoch(
      cc,
      conversationId: g.id,
      epoch: epoch,
      self: creator.keys,
      selfDeviceId: creator.id,
      escrowPub: escrow.kexPub,
      chainN: g.state.n,
      chainHash: g.state.head,
      certs: [...activeOf(g.state.members.keys).map((d) => d.cert), ...extra.map((d) => d.cert)],
    );
    _storeEpoch(g, {
      ...DirectApi.epochJson(epoch, creator.id, ne),
      'chain_n': g.state.n,
      'chain_hash': b64uEncode(g.state.head),
    });
    final bytes = meta ?? (g.state.hasMeta ? openMeta(g) : null);
    if (bytes != null) {
      g.metas[epoch] = sealGroupMeta(cc, key: ne.key, conversationId: g.id, epoch: epoch, meta: bytes).toJson();
    }
    return ne.key;
  }

  void _storeEpoch(FakeGroup g, Map<String, dynamic> e) {
    final epoch = e['epoch'] as int;
    g.epochs[epoch] = FakeEpoch(
      e['creator_device_id'] as String,
      e['key_commitment'] as String,
      (e['recipients'] as List).cast<String>(),
      e['signature'] as String,
      e['chain_n'] as int,
      e['chain_hash'] as String,
    );
    for (final w in (e['wraps'] as List).cast<Map<String, dynamic>>()) {
      g.wraps.add((++_wrapId, epoch, w['device_id'] as String, w['wrapped_key'] as String));
    }
  }

  Map<String, dynamic> epochItem(FakeGroup g, (int, int, String, String) w) {
    final e = g.epochs[w.$2]!;
    return {
      'wrap_id': w.$1,
      'conversation_id': g.id,
      'epoch': w.$2,
      'creator_device_id': e.creator,
      'key_commitment': e.commitment,
      'recipients': e.recipients,
      'signature': e.signature,
      'wrapped_key': w.$4,
      'chain_n': e.chainN,
      'chain_hash': e.chainHash,
    };
  }

  /// O admin reembrulha [epochs] para o aparelho em teste.
  void release(FakeGroup g, List<int> epochs) {
    for (final epoch in epochs) {
      final wrapped = c.sodium.crypto.box.seal(message: _anyKey(g, epoch)!, publicKey: me.keys.kexPub);
      g.wraps.add((++_wrapId, epoch, me.id, b64uEncode(wrapped)));
    }
  }

  /// Chave da época como [d] a abre, ou null se não há embrulho para ele.
  Uint8List? keyFor(FakeGroup g, int epoch, FakeDevice d) {
    for (final w in g.wraps) {
      if (w.$2 == epoch && w.$3 == d.id) {
        final sk = c.sodium.secureCopy(d.keys.kexSk);
        try {
          return c.sodium.crypto.box.sealOpen(cipherText: b64uDecode(w.$4), publicKey: d.keys.kexPub, secretKey: sk);
        } finally {
          sk.dispose();
        }
      }
    }
    return null;
  }

  Uint8List? _anyKey(FakeGroup g, int epoch) {
    for (final d in devices.values) {
      final k = keyFor(g, epoch, d);
      if (k != null) return k;
    }
    return null;
  }

  Uint8List? openMeta(FakeGroup g) {
    for (final m in g.metas.values.toList().reversed) {
      final meta = GroupMeta.fromJson(m);
      final key = _anyKey(g, meta.epoch);
      if (key != null) return openGroupMeta(cc, key: key, conversationId: g.id, meta: meta, commit: meta.metaCommit);
    }
    return null;
  }

  /// Mensagem de [from] na época atual. Com [image], o texto claro é esse JSON.
  Map<String, dynamic> say(FakeGroup g, FakeDevice from, String text, {String? image, bool push = true}) {
    final epoch = g.latest;
    final header = MessageHeader(
      conversationId: g.id,
      epoch: epoch,
      senderDeviceId: from.id,
      messageId: newId(),
      sentAt: clock(),
    );
    final sealed = cc.seal(
      header: header,
      epochKey: _anyKey(g, epoch)!,
      plaintext: image == null ? cc.textPlain(text) : Uint8List.fromList(utf8.encode(image)),
      signSeed: from.keys.signSeed,
    );
    final m = {
      ...WireMessage(
        conversationId: g.id,
        epoch: epoch,
        senderDeviceId: from.id,
        messageId: header.messageId,
        sentAt: header.sentAt,
        nonce: sealed.nonce,
        ciphertext: sealed.ciphertext,
        signature: sealed.signature,
      ).toSendJson(),
      'seq': g.messages.length + 1,
      'created_at': clock(),
    };
    g.messages.add(m);
    if (push && link != null) this.push({'type': 'message', 'message': _wire(g, m)});
    return m;
  }

  /// Imagem de [from] com o blob no servidor.
  void sayImage(FakeGroup g, FakeDevice from, PreparedImage p) {
    final key = c.random(32);
    final blob = cc.sealBlob(conversationId: g.id, key: key, jpeg: p.jpeg);
    final id = newId();
    blobs[id] = (conv: g.id, uploader: from.userId, data: blob);
    final ref = ImageRef(blobId: id, key: key, sha256: sha256Of(blob), width: p.width, height: p.height, thumb: p.thumb);
    say(g, from, '', image: ref.toJson());
  }

  /// Registro novo com o evento, como o servidor faz.
  void change(FakeGroup g, int kind, FakeDevice? author, Uint8List body, {bool epoch = false}) {
    final r = sign(g, kind, author, body);
    apply(g, r);
    _announce(g, r);
    if (epoch) {
      newEpoch(g, author!);
      _pushEpoch(g);
    }
  }

  void _announce(FakeGroup g, SignedChange r) {
    if (link == null) return;
    push({
      'type': 'group_change',
      'conversation_id': g.id,
      'change': _changeJson(r),
      'meta': null,
    });
  }

  void _pushEpoch(FakeGroup g) {
    if (link == null) return;
    for (final w in g.wraps.where((w) => w.$2 == g.latest && w.$3 == me.id)) {
      push({'type': 'epoch', 'item': epochItem(g, w)});
    }
  }

  /// Transição de acesso (D11): revoga ou volta.
  void setActive(FakeGroup g, String userId, bool active) {
    active ? inactive.remove(userId) : inactive.add(userId);
    final at = clock();
    g.access.add({'id': g.access.length + 1, 'user_id': userId, 'active': active, 'at': at});
    push({'type': 'member_access', 'user_id': userId, 'active': active, 'at': at, 'conversations': [g.id]});
  }

  // ---- HTTP e WebSocket ----

  Map<String, dynamic> _changeJson(SignedChange r) => {...r.toJson(), 'n': r.n, 'received_at': r.receivedAt};

  Map<String, dynamic> _wire(FakeGroup g, Map<String, dynamic> m) {
    final dev = devices[m['sender_device_id']]!;
    if (!inactive.contains(dev.userId)) return m;
    final len = b64uDecode(m['ciphertext'] as String).length;
    return {
      'conversation_id': g.id,
      'seq': m['seq'],
      'message_id': m['message_id'],
      'sender_device_id': dev.id,
      'sender_user_id': dev.userId,
      'created_at': m['created_at'],
      'sealed': true,
      'scramble': scramble(c, g.id, m['seq'] as int, scrambleLength(len)),
    };
  }

  Map<String, dynamic> conv(FakeGroup g) => {
    'conversation_id': g.id,
    'kind': 'group',
    'members': [...g.state.members.keys, ...extraMembers],
    'latest_epoch': g.latest,
    'last_seq': g.messages.length,
    'chain_n': g.state.n,
    'admin_label': g.state.adminLabel.isEmpty ? null : g.state.adminLabel,
    'closed': g.state.closed,
  };

  void _onSend(FakeGroupLink l, Map<String, dynamic> f) {
    final m = f['message'] as Map<String, dynamic>;
    final g = groups[m['conversation_id']]!;
    void error(String code) => l.push({'type': 'error', 'req_id': f['req_id'], 'code': code, 'latest_epoch': g.latest});
    if (g.state.closed) return error('group_closed');
    final want = activeOf(g.state.members.keys).map((d) => d.id).toList()..sort();
    final e = g.epochs[m['epoch']];
    if (m['epoch'] != g.latest || e == null || e.recipients.join() != want.join()) return error('epoch_required');
    final stored = {...m, 'seq': g.messages.length + 1, 'created_at': clock()};
    g.messages.add(stored);
    l.push({'type': 'ack', 'req_id': f['req_id'], 'seq': stored['seq'], 'created_at': stored['created_at']});
  }

  /// Valida a época de um pedido do cliente como o servidor (§10.3).
  String? _checkEpoch(FakeGroup g, GroupState state, Map<String, dynamic> e, Map<String, dynamic>? meta) {
    if (e['epoch'] != g.latest + 1) return 'epoch_conflict';
    if (e['chain_n'] != state.n || e['chain_hash'] != b64uEncode(state.head)) return 'chain_conflict';
    final want = activeOf(state.members.keys).map((d) => d.id).toList()..sort();
    if ((e['recipients'] as List).join() != want.join()) return 'device_set_changed';
    final creator = devices[e['creator_device_id']]!;
    final bytes = groupEpochBytes(
      conversationId: g.id,
      epoch: e['epoch'] as int,
      creatorDeviceId: creator.id,
      commitment: b64uDecode(e['key_commitment'] as String),
      escrowPub: escrow.kexPub,
      chainN: state.n,
      chainHash: state.head,
      recipients: (e['recipients'] as List).cast<String>(),
    );
    if (!c.verify(creator.cert.signPub, bytes, b64uDecode(e['signature'] as String))) return 'bad_signature';
    if (state.hasMeta && (meta == null || meta['meta_commit'] != b64uEncode(state.metaCommit))) return 'bad_request';
    return null;
  }

  http.Response _ok(Object? j, [int status = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(j)),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  http.Response _err(int status, String code) => _ok({'error': {'code': code, 'message': ''}}, status);

  late final http.Client client = MockClient((req) async {
    if (down) throw http.ClientException('sem rede');
    final path = req.url.path;
    final q = req.url.queryParameters;
    requests.add('${req.method} $path');
    final seg = req.url.pathSegments;
    Map<String, dynamic> body() => jsonDecode(req.body) as Map<String, dynamic>;
    final g = seg.length > 2 ? groups[seg[2]] : null;
    final member = g != null && g.state.isMember(me.userId);

    switch ((req.method, path)) {
      case ('GET', '/v1/directory'):
        final users = {for (final d in devices.values) d.userId: d.cert.adminLabel};
        return _ok({
          'users': [
            for (final u in users.entries)
              {
                'user_id': u.key,
                'admin_label': u.value,
                'display_name': '',
                'status': '',
                'devices': [for (final d in activeOf([u.key])) d.cert.toJson()],
              },
          ],
        });
      case ('GET', '/v1/devices'):
        return _ok({
          'devices': [
            for (final id in q['ids']!.split(',')) if (devices[id] != null) {'cert': devices[id]!.cert.toJson()},
          ],
        });
      case ('GET', '/v1/epochs/mine'):
        final after = int.parse(q['after'] ?? '0');
        return _ok({
          'items': [
            for (final g in groups.values)
              for (final w in g.wraps) if (w.$3 == me.id && w.$1 > after) epochItem(g, w),
          ],
          'has_more': false,
        });
      case ('GET', '/v1/conversations'):
        return _ok({
          'conversations': [for (final g in groups.values) if (g.state.isMember(me.userId)) conv(g)],
        });
      case ('POST', '/v1/groups'):
        final b = body();
        final r = SignedChange.fromJson(b['change'] as Map<String, dynamic>);
        final change = GroupChange.decode(r.bytes)!;
        final id = change.conversationId;
        final fresh = FakeGroup(id, GroupState(c, id));
        final rec = SignedChange(r.bytes, r.signature, n: 1, receivedAt: clock());
        apply(fresh, rec);
        final e = b['epoch'] as Map<String, dynamic>;
        final code = _checkEpoch(fresh, fresh.state, e, b['meta'] as Map<String, dynamic>);
        if (code != null) return _err(409, code);
        groups[id] = fresh;
        _storeEpoch(fresh, e);
        fresh.metas[1] = b['meta'] as Map<String, dynamic>;
        return _ok(conv(fresh), 201);
      case ('POST', '/v1/devices/self-revoke'):
        selfRevoked.add(body());
        return _ok({'revoked_at': clock()});
      case ('POST', '/v1/blobs'):
        final id = newId();
        final data = Uint8List.fromList(req.bodyBytes);
        blobs[id] = (conv: q['conversation_id']!, uploader: me.userId, data: data);
        return _ok({'blob_id': id, 'size': data.length, 'sha256': b64uEncode(sha256Of(data))}, 201);
    }

    if (seg.length == 3 && seg[1] == 'blobs') {
      final blob = blobs[seg[2]];
      if (blob == null) return _err(404, 'not_found');
      if (inactive.contains(blob.uploader)) return _err(403, 'sender_inactive');
      return http.Response.bytes(blob.data, 200);
    }

    if (!member) return _err(403, 'forbidden');
    switch ((req.method, seg[1], seg.sublist(3).join('/'))) {
      case ('GET', 'groups', 'changes'):
        final after = int.parse(q['after'] ?? '0');
        return _ok({'changes': [for (final r in g.changes.skip(after)) _changeJson(r)], 'has_more': false});
      case ('POST', 'groups', 'changes'):
        final b = body();
        final r = SignedChange.fromJson(b['change'] as Map<String, dynamic>);
        final change = GroupChange.decode(r.bytes)!;
        if (change.n != g.state.n + 1) return _err(409, 'chain_conflict');
        final next = GroupState.verify(c, g.id, [...g.changes, r], chainKeys);
        final needsEpoch = change.kind == kindAdd || change.kind == kindRemove;
        final e = b['epoch'] as Map<String, dynamic>?;
        final meta = b['meta'] as Map<String, dynamic>?;
        if (needsEpoch != (e != null)) return _err(400, 'bad_request');
        if (e != null) {
          final code = _checkEpoch(g, next, e, meta);
          if (code != null) return _err(409, code);
        }
        if (change.kind == kindRename && meta?['meta_commit'] != b64uEncode(next.metaCommit)) {
          return _err(400, 'bad_request');
        }
        final rec = SignedChange(r.bytes, r.signature, n: change.n, receivedAt: clock());
        apply(g, rec);
        if (e != null) _storeEpoch(g, e);
        if (meta != null) g.metas[meta['epoch'] as int] = meta;
        _announce(g, rec); // eco do próprio registro
        return _ok({'n': change.n}, 201);
      case ('GET', 'groups', 'meta'):
        final commit = b64uEncode(g.state.metaCommit);
        final items = [for (final m in g.metas.values) if (m['meta_commit'] == commit) m]
          ..sort((a, b) => (b['epoch'] as int).compareTo(a['epoch'] as int));
        return _ok({'items': items});
      case ('POST', 'groups', 'history-wraps'):
        final b = body();
        final add = g.state.records[(b['add_n'] as int) - 1];
        for (final i in (b['items'] as List).cast<Map<String, dynamic>>()) {
          final to = devices[i['device_id']]!;
          if (!add.body.history || !add.body.users.contains(to.userId) || g.epochs[i['epoch']]!.chainN >= add.change.n) {
            return _err(400, 'bad_request');
          }
          g.wraps.add((++_wrapId, i['epoch'] as int, to.id, i['wrapped_key'] as String));
        }
        return _ok({}, 201);
      case ('GET', 'conversations', 'epochs/mine'):
        return _ok({'items': [for (final w in g.wraps) if (w.$3 == me.id) epochItem(g, w)], 'has_more': false});
      case ('POST', 'conversations', 'epochs'):
        final b = body();
        final code = _checkEpoch(g, g.state, b, b['meta'] as Map<String, dynamic>?);
        if (code != null) return _err(409, code);
        _storeEpoch(g, b);
        if (b['meta'] != null) g.metas[b['epoch'] as int] = b['meta'] as Map<String, dynamic>;
        return _ok({'epoch': b['epoch']}, 201);
      case ('GET', 'conversations', 'messages'):
        final after = int.parse(q['after'] ?? '0');
        final before = int.parse(q['before'] ?? '9007199254740991');
        final limit = int.parse(q['limit'] ?? '200');
        final all = [for (final m in g.messages) if ((m['seq'] as int) > after && (m['seq'] as int) < before) m];
        final page = q.containsKey('before') && all.length > limit ? all.sublist(all.length - limit) : all.take(limit);
        return _ok({'messages': [for (final m in page) _wire(g, m)], 'has_more': all.length > limit});
      case ('GET', 'conversations', 'access-events'):
        final after = int.parse(q['after'] ?? '0');
        return _ok({'events': [for (final e in g.access) if ((e['id'] as int) > after) e], 'has_more': false});
    }
    return _err(404, 'not_found');
  });
}

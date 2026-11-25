import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'b64.dart';
import 'chat_crypto.dart';
import 'crypto.dart';
import 'models.dart';

/// Protocolo de grupos (docs/protocolo-grupos.md). Espelha `server/internal/proto/group*.go`;
/// os vetores de `docs/vetores/grupos/` conferem os dois.

const groupMaxMembers = 100;
const groupMaxChangeBytes = 4096;

/// Tipos de registro (§2.2).
const kindCreate = 1,
    kindAdd = 2,
    kindRemove = 3,
    kindPromote = 4,
    kindLeave = 5,
    kindRename = 6,
    kindCloseGroup = 7;

const authorDevice = 1, authorModerator = 2;
const roleMember = 1, roleAdmin = 2;

/// 23 do rótulo + 108 fixos antes do corpo.
const _label = 'direct/v1/group-change';
const _changeFixed = 131;

/// Registro que falhou e o código de §2.6.
class ChainError implements Exception {
  ChainError(this.n, this.code);
  final int n;
  final String code;
  @override
  String toString() => 'registro $n do grupo: $code';
}

String bytesToUuid(List<int> b) {
  final h = toHex(b);
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

const zeroUuid = '00000000-0000-0000-0000-000000000000';

bool _allZero(List<int> b) => b.every((x) => x == 0);

bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a[i] ^ b[i];
  }
  return d == 0;
}

/// Sem caracteres de controle (categoria Cc), como no servidor.
bool noControl(String s) => !s.runes.any((r) => r < 0x20 || (r >= 0x7f && r < 0xa0));

/// Um registro decodificado.
class GroupChange {
  GroupChange({
    required this.conversationId,
    required this.n,
    required this.prev,
    required this.kind,
    required this.authorType,
    this.authorDeviceId = zeroUuid,
    this.authorUserId = zeroUuid,
    required this.createdAt,
    required this.body,
  });
  final String conversationId;
  final int n;
  final Uint8List prev;
  final int kind;
  final int authorType;
  final String authorDeviceId;
  final String authorUserId;
  final int createdAt;
  final Uint8List body;

  bool get byModerator => authorType == authorModerator;

  Uint8List encode() => concat([
    label(_label),
    uuidToBytes(conversationId),
    u64(n),
    prev,
    u32(kind),
    u32(authorType),
    fromHex(authorDeviceId.replaceAll('-', '')),
    fromHex(authorUserId.replaceAll('-', '')),
    u64(createdAt),
    u32(body.length),
    body,
  ]);

  /// Confere só o formato externo; o corpo é de [parseBody].
  static GroupChange? decode(Uint8List b) {
    final prefix = label(_label);
    if (b.length < _changeFixed || b.length > groupMaxChangeBytes) return null;
    if (!bytesEqual(Uint8List.sublistView(b, 0, prefix.length), prefix)) return null;
    final p = Uint8List.sublistView(b, prefix.length);
    final d = ByteData.sublistView(p);
    if (d.getUint32(104) != p.length - 108) return null;
    return GroupChange(
      conversationId: bytesToUuid(p.sublist(0, 16)),
      n: d.getUint64(16),
      prev: p.sublist(24, 56),
      kind: d.getUint32(56),
      authorType: d.getUint32(60),
      authorDeviceId: bytesToUuid(p.sublist(64, 80)),
      authorUserId: bytesToUuid(p.sublist(80, 96)),
      createdAt: d.getUint64(96),
      body: p.sublist(108),
    );
  }
}

/// Corpo já interpretado: só os campos do tipo do registro.
class ChangeBody {
  String adminLabel = '';
  Uint8List metaCommit = Uint8List(32);

  /// criar: user_id → papel.
  Map<String, int> members = {};

  /// adicionar, remover, promover.
  List<String> users = const [];
  bool history = false;
}

class _Reader {
  _Reader(this.b);
  final Uint8List b;
  int at = 0;
  bool bad = false;

  Uint8List take(int n) {
    if (bad || n < 0 || b.length - at < n) {
      bad = true;
      return Uint8List(0);
    }
    return b.sublist(at, at += n);
  }

  int u32be() {
    final p = take(4);
    return bad ? 0 : ByteData.sublistView(p).getUint32(0);
  }

  /// Lista de 1 a 101 ids em ordem crescente estrita (§2.2).
  List<String> users() {
    final k = u32be();
    if (bad || k < 1 || k > groupMaxMembers + 1) {
      bad = true;
      return const [];
    }
    final out = <String>[];
    for (var i = 0; i < k && !bad; i++) {
      final id = take(16);
      if (bad) break;
      final s = bytesToUuid(id);
      if (out.isNotEmpty && out.last.compareTo(s) >= 0) bad = true;
      out.add(s);
    }
    return out;
  }
}

/// Corpo canônico do tipo [kind], ou null.
ChangeBody? parseBody(int kind, Uint8List body) {
  final out = ChangeBody();
  final r = _Reader(body);
  switch (kind) {
    case kindCreate:
      final raw = r.take(r.u32be());
      try {
        out.adminLabel = utf8.decode(raw);
      } on FormatException {
        return null;
      }
      out.metaCommit = r.take(32);
      final m = r.u32be();
      if (r.bad || m < 1 || m > groupMaxMembers + 1) return null;
      String? last;
      for (var i = 0; i < m; i++) {
        final id = r.take(16);
        final role = r.u32be();
        if (r.bad || (role != roleMember && role != roleAdmin)) return null;
        final s = bytesToUuid(id);
        if (last != null && last.compareTo(s) >= 0) return null;
        out.members[last = s] = role;
      }
    case kindAdd:
      final h = r.u32be();
      if (h > 1) return null;
      out.history = h == 1;
      out.users = r.users();
    case kindRemove || kindPromote:
      out.users = r.users();
    case kindRename:
      out.metaCommit = r.take(32);
    case kindLeave || kindCloseGroup:
      break;
    default:
      return null;
  }
  return r.bad || r.at != body.length ? null : out;
}

List<int> _sortedUsers(Iterable<String> ids) {
  final l = ids.toSet().toList()..sort();
  return concat([u32(l.length), for (final u in l) uuidToBytes(u)]);
}

Uint8List createBody(String adminLabel, Uint8List metaCommit, Map<String, int> members) {
  final name = utf8.encode(adminLabel);
  final ids = members.keys.toList()..sort();
  return concat([
    u32(name.length),
    name,
    metaCommit,
    u32(ids.length),
    for (final id in ids) ...[uuidToBytes(id), u32(members[id]!)],
  ]);
}

Uint8List addBody({required bool history, required Iterable<String> users}) =>
    concat([u32(history ? 1 : 0), _sortedUsers(users)]);

/// remover e promover.
Uint8List usersBody(Iterable<String> users) => Uint8List.fromList(_sortedUsers(users));

/// Registro como trafega (§2.8). `receivedAt` é do servidor e não é assinado.
class SignedChange {
  SignedChange(this.bytes, this.signature, {this.n = 0, this.receivedAt = 0});
  final Uint8List bytes;
  final Uint8List signature;
  final int n;
  final int receivedAt;

  factory SignedChange.fromJson(Map<String, dynamic> j) {
    final b = b64uDecode(j['change_bytes'] as String);
    return SignedChange(
      b,
      b64uDecode(j['signature'] as String),
      n: j['n'] as int? ?? 0,
      receivedAt: j['received_at'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'change_bytes': b64uEncode(bytes),
    'signature': b64uEncode(signature),
  };
}

/// `record_hash` (§2.3): o `prev_hash` do registro seguinte.
Uint8List changeHash(DirectCrypto c, SignedChange r) => c.blake2b256(
  concat([label('direct/v1/group-link'), u32(r.bytes.length), r.bytes, r.signature]),
);

/// O que o verificador confia: as chaves fixadas e os certificados dos autores
/// (conferidos aqui contra [serverSignPub]).
class ChainKeys {
  ChainKeys({required this.serverSignPub, this.modPub, required this.certs});
  final Uint8List serverSignPub;

  /// null = não fixada: registro do moderador falha com `autor`.
  final Uint8List? modPub;
  final Map<String, DeviceCert> certs;
}

/// Período `[from, to)` em posições da cadeia (`to` = 0: ainda membro).
class Interval {
  Interval(this.from, {this.history = false});
  final int from;
  int to = 0;
  final bool history;
}

/// Um registro verificado e aplicado.
class AppliedRecord {
  AppliedRecord(this.record, this.change, this.body);
  final SignedChange record;
  final GroupChange change;
  final ChangeBody body;
}

/// Estado depois de verificar um prefixo da cadeia (§2.5, §2.6).
class GroupState {
  GroupState(this.crypto, this.conversationId);
  final DirectCrypto crypto;
  final String conversationId;

  int n = 0;
  Uint8List head = Uint8List(32);
  final Map<String, int> members = {};
  int closedAt = 0;
  String adminLabel = '';
  Uint8List metaCommit = Uint8List(32);
  final Map<String, List<Interval>> intervals = {};
  final List<Uint8List> _hashes = [];

  /// Registro i+1.
  final List<AppliedRecord> records = [];

  bool get closed => closedAt != 0;
  bool get hasMeta => !_allZero(metaCommit);
  bool get official => records.isNotEmpty && records.first.change.byModerator;

  static GroupState verify(DirectCrypto crypto, String conversationId, Iterable<SignedChange> recs, ChainKeys keys) {
    final s = GroupState(crypto, conversationId);
    for (final r in recs) {
      s.apply(r, keys);
    }
    return s;
  }

  /// Confere um registro, na ordem de §2.6, e aplica. Em erro nada muda.
  void apply(SignedChange rec, ChainKeys keys) {
    Never fail(String code) => throw ChainError(n + 1, code);

    final c = GroupChange.decode(rec.bytes);
    if (c == null || rec.signature.length != 64) fail('formato');
    final body = parseBody(c.kind, c.body);
    if (body == null || !_authorFormatOk(c, body)) fail('formato');
    if (c.conversationId != conversationId) fail('conversa');
    if (c.n != n + 1 || (c.kind == kindCreate) != (c.n == 1)) fail('sequencia');
    if (!bytesEqual(c.prev, head)) fail('prev_hash');

    final Uint8List pub;
    switch (c.authorType) {
      case authorModerator:
        final m = keys.modPub;
        if (c.authorDeviceId != zeroUuid || c.authorUserId != zeroUuid || m == null) fail('autor');
        pub = m;
      case authorDevice:
        final cert = keys.certs[c.authorDeviceId];
        if (cert == null ||
            cert.deviceId != c.authorDeviceId ||
            cert.userId != c.authorUserId ||
            !crypto.verifyCert(cert, keys.serverSignPub)) {
          fail('autor');
        }
        pub = cert.signPub;
      default:
        fail('autor');
    }
    if (!crypto.verify(pub, rec.bytes, rec.signature)) fail('assinatura');
    if (closed) fail('encerrado');

    final mod = c.byModerator;
    final role = members[c.authorUserId] ?? 0;
    switch (c.kind) {
      case kindCreate:
        if (!mod && body.members[c.authorUserId] != roleAdmin) fail('papel');
        if (!body.members.containsValue(roleAdmin)) fail('papel');
      case kindRemove || kindCloseGroup:
        if (!mod && role != roleAdmin) fail('papel');
      case kindAdd || kindPromote || kindRename:
        if (mod || role != roleAdmin) fail('papel');
      case kindLeave:
        if (mod || role == 0) fail('papel');
    }

    for (final u in body.users) {
      final cur = members[u] ?? 0;
      if ((c.kind == kindAdd && cur != 0) ||
          (c.kind == kindRemove && (cur == 0 || (!mod && u == c.authorUserId))) ||
          (c.kind == kindPromote && cur != roleMember)) {
        fail('alvo');
      }
    }

    if ((c.kind == kindCreate && body.members.length > groupMaxMembers) ||
        (c.kind == kindAdd && members.length + body.users.length > groupMaxMembers)) {
      fail('limite');
    }

    final at = c.n;
    void open(String u, int r, {bool history = false}) {
      members[u] = r;
      (intervals[u] ??= []).add(Interval(at, history: history));
    }

    void leave(String u) {
      members.remove(u);
      intervals[u]!.last.to = at;
    }

    switch (c.kind) {
      case kindCreate:
        adminLabel = body.adminLabel;
        metaCommit = body.metaCommit;
        body.members.forEach(open);
      case kindAdd:
        for (final u in body.users) {
          open(u, roleMember, history: body.history);
        }
      case kindRemove:
        body.users.forEach(leave);
      case kindLeave:
        leave(c.authorUserId);
      case kindPromote:
        for (final u in body.users) {
          members[u] = roleAdmin;
        }
      case kindRename:
        metaCommit = body.metaCommit;
      case kindCloseGroup:
        closedAt = at;
    }
    if (members.isEmpty && closedAt == 0) closedAt = at;
    n = at;
    head = changeHash(crypto, rec);
    _hashes.add(head);
    records.add(AppliedRecord(rec, c, body));
  }

  /// `admin_label` só em grupo do moderador, que não tem chave para cifrar nome.
  static bool _authorFormatOk(GroupChange c, ChangeBody b) {
    switch (c.kind) {
      case kindCreate:
        if (c.byModerator) {
          final len = utf8.encode(b.adminLabel).length;
          return len >= 1 && len <= 100 && noControl(b.adminLabel) && _allZero(b.metaCommit);
        }
        return b.adminLabel.isEmpty && !_allZero(b.metaCommit);
      case kindRename:
        return !_allZero(b.metaCommit);
    }
    return true;
  }

  Uint8List? hashAt(int at) => at < 1 || at > n ? null : _hashes[at - 1];

  bool isMember(String user) => members.containsKey(user);
  bool isAdmin(String user) => members[user] == roleAdmin;

  /// `membro_em(u, c)`: membro no estado logo depois do registro `c`.
  bool memberAt(String user, int at) =>
      (intervals[user] ?? const <Interval>[]).any((i) => i.from <= at && (i.to == 0 || at < i.to));

  /// `pode_reembrulhar(u, c)` (§2.5): histórico liberado ou escrow.
  bool mayRewrap(String user, int at) {
    if (!isMember(user) || at < 1 || at > n) return false;
    return memberAt(user, at) || intervals[user]!.any((i) => i.history && at < i.from);
  }

  /// §5.2, passos 1 a 3: devolve o código do erro ou null.
  String? checkEpoch({
    required int chainN,
    required Uint8List chainHash,
    required String creatorUserId,
    required Iterable<String> recipientOwners,
  }) {
    final h = hashAt(chainN);
    if (h == null || !bytesEqual(h, chainHash) || (closedAt != 0 && chainN >= closedAt)) return 'cadeia';
    if (!memberAt(creatorUserId, chainN)) return 'papel';
    if (recipientOwners.any((u) => !memberAt(u, chainN))) return 'alvo';
    return null;
  }
}

// ---- épocas (§5) ----

Uint8List groupEpochBytes({
  required String conversationId,
  required int epoch,
  required String creatorDeviceId,
  required Uint8List commitment,
  required Uint8List escrowPub,
  required int chainN,
  required Uint8List chainHash,
  required List<String> recipients,
}) => concat([
  label('direct/v1/group-epoch'),
  uuidToBytes(conversationId),
  u32(epoch),
  uuidToBytes(creatorDeviceId),
  commitment,
  escrowPub,
  u64(chainN),
  chainHash,
  u32(recipients.length),
  for (final r in recipients) uuidToBytes(r),
]);

/// Época de grupo nova: a da v1 com a posição da cadeia na declaração assinada.
NewEpoch createGroupEpoch(
  ChatCrypto cc, {
  required String conversationId,
  required int epoch,
  required DeviceKeys self,
  required String selfDeviceId,
  required Uint8List escrowPub,
  required int chainN,
  required Uint8List chainHash,
  required List<DeviceCert> certs,
}) {
  final key = cc.c.random(32);
  final commitment = cc.keyCommitment(conversationId, epoch, key);
  final byId = {for (final d in certs) d.deviceId: d};
  final recipients = ChatCrypto.sortedUnique(byId.keys);
  final seal = cc.sodium.crypto.box.seal;
  return NewEpoch(
    key: key,
    commitment: commitment,
    recipients: recipients,
    wraps: {for (final id in recipients) id: seal(message: key, publicKey: byId[id]!.kexPub)},
    escrowWrap: seal(message: key, publicKey: escrowPub),
    signature: cc.c.sign(
      self.signSeed,
      groupEpochBytes(
        conversationId: conversationId,
        epoch: epoch,
        creatorDeviceId: selfDeviceId,
        commitment: commitment,
        escrowPub: escrowPub,
        chainN: chainN,
        chainHash: chainHash,
        recipients: recipients,
      ),
    ),
  );
}

/// Assinatura, embrulho e compromisso (§9.8, passos 2 a 4). A cadeia é de
/// [GroupState.checkEpoch]. Devolve `K` ou lança [ChatCryptoException].
Uint8List openGroupEpoch(
  ChatCrypto cc, {
  required String conversationId,
  required int epoch,
  required DeviceCert creator,
  required Uint8List commitment,
  required List<String> recipients,
  required Uint8List signature,
  required Uint8List wrappedKey,
  required Uint8List escrowPub,
  required int chainN,
  required Uint8List chainHash,
  required DeviceKeys self,
}) {
  final sorted = ChatCrypto.sortedUnique(recipients);
  if (sorted.join(',') != recipients.join(',')) {
    throw ChatCryptoException('recipients fora de ordem');
  }
  final bytes = groupEpochBytes(
    conversationId: conversationId,
    epoch: epoch,
    creatorDeviceId: creator.deviceId,
    commitment: commitment,
    escrowPub: escrowPub,
    chainN: chainN,
    chainHash: chainHash,
    recipients: recipients,
  );
  if (!cc.c.verify(creator.signPub, bytes, signature)) throw ChatCryptoException('assinatura da época inválida');
  final Uint8List k;
  final sk = cc.sodium.secureCopy(self.kexSk);
  try {
    k = cc.sodium.crypto.box.sealOpen(cipherText: wrappedKey, publicKey: self.kexPub, secretKey: sk);
  } on Object {
    throw ChatCryptoException('embrulho de chave não abre');
  } finally {
    sk.dispose();
  }
  if (k.length != 32) throw ChatCryptoException('chave de época com tamanho errado');
  final expect = cc.keyCommitment(conversationId, epoch, k);
  if (!cc.sodium.memcmp(expect, commitment)) {
    throw ChatCryptoException('compromisso da chave não confere');
  }
  return k;
}

// ---- nome, descrição e foto (§6) ----

const groupPhotoMaxBytes = 8192;
const groupPhotoSide = 256;
const maxGroupMetaBytes = 16383;

class GroupProfile {
  GroupProfile({required this.name, this.description = '', this.photo});
  final String name;
  final String description;
  final Uint8List? photo;

  static bool _photoOk(Uint8List p) {
    if (p.length > groupPhotoMaxBytes) return false;
    final info = img.JpegDecoder().startDecode(p);
    return info != null && info.width <= groupPhotoSide && info.height <= groupPhotoSide;
  }

  static bool validName(String s) => s.runes.isNotEmpty && s.runes.length <= 64 && noControl(s);
  static bool validDescription(String s) => s.runes.length <= 500 && noControl(s);

  /// Os bytes exatos que serão comprometidos; [salt] novo a cada mudança.
  Uint8List encode(Uint8List salt) {
    final out = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'v': 1,
          'salt': b64uEncode(salt),
          'name': name,
          'description': description,
          if (photo != null) 'photo': b64uEncode(photo!),
        }),
      ),
    );
    if (!validName(name) || !validDescription(description) || (photo != null && !_photoOk(photo!)) || out.length > maxGroupMetaBytes) {
      throw const FormatException('nome, descrição ou foto fora das regras');
    }
    return out;
  }

  /// null = fora das regras de §6.1 (o app mostra o nome provisório).
  static GroupProfile? decode(Uint8List meta) {
    try {
      final j = jsonDecode(utf8.decode(meta)) as Map<String, dynamic>;
      if (j['v'] != 1) return null;
      b64uDecode(j['salt'] as String, length: 32);
      final name = j['name'] as String, description = j['description'] as String? ?? '';
      if (!validName(name) || !validDescription(description)) return null;
      final p = j['photo'] == null ? null : b64uDecode(j['photo'] as String);
      return GroupProfile(name: name, description: description, photo: p != null && _photoOk(p) ? p : null);
    } on Object {
      return null;
    }
  }
}

Uint8List metaCommitOf(DirectCrypto c, String conversationId, Uint8List meta) => c.blake2b256(
  concat([label('direct/v1/group-meta-commit'), uuidToBytes(conversationId), u32(meta.length), meta]),
);

Uint8List metaAad(String conversationId, int epoch, Uint8List commit) =>
    concat([label('direct/v1/group-meta'), uuidToBytes(conversationId), u32(epoch), commit]);

/// `GroupMeta` no fio (§6.3).
class GroupMeta {
  GroupMeta({required this.epoch, required this.metaCommit, required this.nonce, required this.ciphertext});
  final int epoch;
  final Uint8List metaCommit;
  final Uint8List nonce;
  final Uint8List ciphertext;

  factory GroupMeta.fromJson(Map<String, dynamic> j) => GroupMeta(
    epoch: j['epoch'] as int,
    metaCommit: b64uDecode(j['meta_commit'] as String, length: 32),
    nonce: b64uDecode(j['nonce'] as String, length: 24),
    ciphertext: b64uDecode(j['ciphertext'] as String),
  );

  Map<String, dynamic> toJson() => {
    'epoch': epoch,
    'meta_commit': b64uEncode(metaCommit),
    'nonce': b64uEncode(nonce),
    'ciphertext': b64uEncode(ciphertext),
  };
}

GroupMeta sealGroupMeta(
  ChatCrypto cc, {
  required Uint8List key,
  required String conversationId,
  required int epoch,
  required Uint8List meta,
  Uint8List? nonce,
}) {
  final commit = metaCommitOf(cc.c, conversationId, meta);
  final n = nonce ?? cc.c.random(24);
  final k = cc.sodium.secureCopy(key);
  try {
    return GroupMeta(
      epoch: epoch,
      metaCommit: commit,
      nonce: n,
      ciphertext: cc.sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
        message: cc.pad(meta),
        nonce: n,
        key: k,
        additionalData: metaAad(conversationId, epoch, commit),
      ),
    );
  } finally {
    k.dispose();
  }
}

/// Abre e confere contra o `meta_commit` **do estado atual da cadeia**.
Uint8List openGroupMeta(
  ChatCrypto cc, {
  required Uint8List key,
  required String conversationId,
  required GroupMeta meta,
  required Uint8List commit,
}) {
  final k = cc.sodium.secureCopy(key);
  try {
    final plain = cc.unpad(
      cc.sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
        cipherText: meta.ciphertext,
        nonce: meta.nonce,
        key: k,
        additionalData: metaAad(conversationId, meta.epoch, commit),
      ),
    );
    final got = metaCommitOf(cc.c, conversationId, plain);
    if (!cc.sodium.memcmp(got, commit)) {
      throw ChatCryptoException('metadados não conferem com a cadeia');
    }
    return plain;
  } on ChatCryptoException {
    rethrow;
  } on Object {
    throw ChatCryptoException('metadados não abrem');
  } finally {
    k.dispose();
  }
}

// ---- mensagem selada (§7.2) ----

const _scrambleAlphabet = r'0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRST#@%&$*!?';

/// 12, 16, ... 32 conforme o tamanho preenchido da mensagem.
int scrambleLength(int ciphertextLen) {
  final blocks = (ciphertextLen - 16) ~/ 256;
  return 12 + 4 * (blocks - 1).clamp(0, 5);
}

/// Embaralhado só para exibir: depende da conversa, do `seq` e da faixa de tamanho.
String scramble(DirectCrypto c, String conversationId, int seq, int length) {
  final h = c.blake2b256(concat([label('direct/v1/sealed'), uuidToBytes(conversationId), u64(seq)]));
  return String.fromCharCodes([for (final b in h.take(length)) _scrambleAlphabet.codeUnitAt(b & 63)]);
}

// ---- revogação pré-assinada (§8) e chave do moderador (§3) ----

Uint8List selfRevokeBytes(Uint8List serverSignPub, String deviceId, int createdAt) =>
    concat([label('direct/v1/self-revoke'), serverSignPub, uuidToBytes(deviceId), u64(createdAt)]);

/// Forma guardada e enviada (§8.1).
Map<String, dynamic> signSelfRevoke(
  DirectCrypto c, {
  required Uint8List signSeed,
  required Uint8List serverSignPub,
  required String deviceId,
  required int createdAt,
}) => {
  'device_id': deviceId,
  'created_at': createdAt,
  'sig': b64uEncode(c.sign(signSeed, selfRevokeBytes(serverSignPub, deviceId, createdAt))),
};

/// Código de 20 dígitos com a chave do moderador (§3.3).
String serverCodeMod(DirectCrypto c, Uint8List serverSignPub, Uint8List escrowPub, Uint8List modPub) =>
    c.code20(c.blake2b256(concat([label('direct/v1/server-code-m'), serverSignPub, escrowPub, modPub])));

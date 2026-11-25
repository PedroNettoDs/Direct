import 'dart:typed_data';

import 'b64.dart';
import 'models.dart';

/// Usuário do diretório com aparelhos ativos (protocolo §7.1).
class DirectoryUser {
  DirectoryUser({
    required this.userId,
    required this.adminLabel,
    required this.displayName,
    required this.status,
    required this.devices,
  });
  final String userId;
  final String adminLabel;
  final String displayName;
  final String status;
  final List<DeviceCert> devices;

  factory DirectoryUser.fromJson(Map<String, dynamic> j) {
    final userId = j['user_id'] as String;
    uuidToBytes(userId);
    return DirectoryUser(
      userId: userId,
      adminLabel: j['admin_label'] as String,
      displayName: j['display_name'] as String,
      status: j['status'] as String,
      devices: [
        for (final d in (j['devices'] as List)) DeviceCert.fromJson(d as Map<String, dynamic>),
      ],
    );
  }
}

class ConvInfo {
  ConvInfo(
    this.conversationId,
    this.members,
    this.latestEpoch,
    this.lastSeq, {
    this.kind = 'direct',
    this.chainN = 0,
    this.adminLabel,
    this.closed = false,
  });

  /// `direct` ou `group` (protocolo-grupos §10.5).
  final String kind;
  final int chainN;
  final String? adminLabel;
  final bool closed;
  bool get isGroup => kind == 'group';

  final String conversationId;
  final List<String> members;
  final int latestEpoch;
  final int lastSeq;

  factory ConvInfo.fromJson(Map<String, dynamic> j) {
    final id = j['conversation_id'] as String;
    uuidToBytes(id);
    return ConvInfo(
      id,
      (j['members'] as List).cast<String>(),
      j['latest_epoch'] as int,
      j['last_seq'] as int,
      kind: j['kind'] as String? ?? 'direct',
      chainN: j['chain_n'] as int? ?? 0,
      adminLabel: j['admin_label'] as String?,
      closed: j['closed'] == true,
    );
  }
}

/// Item de `GET /v1/epochs/mine` ou evento `epoch` (protocolo §9.7).
class EpochItem {
  EpochItem({
    required this.wrapId,
    required this.conversationId,
    required this.epoch,
    required this.creatorDeviceId,
    required this.commitment,
    required this.recipients,
    required this.signature,
    required this.wrappedKey,
    this.chainN,
    this.chainHash,
  });

  /// Só em época de grupo (protocolo-grupos §10.3).
  final int? chainN;
  final Uint8List? chainHash;
  bool get isGroup => chainN != null;

  final int wrapId;
  final String conversationId;
  final int epoch;
  final String creatorDeviceId;
  final Uint8List commitment;
  final List<String> recipients;
  final Uint8List signature;
  final Uint8List wrappedKey;

  factory EpochItem.fromJson(Map<String, dynamic> j) {
    final cid = j['conversation_id'] as String;
    final creator = j['creator_device_id'] as String;
    uuidToBytes(cid);
    uuidToBytes(creator);
    final rec = (j['recipients'] as List).cast<String>();
    for (final r in rec) {
      uuidToBytes(r);
    }
    return EpochItem(
      wrapId: j['wrap_id'] as int,
      conversationId: cid,
      epoch: j['epoch'] as int,
      creatorDeviceId: creator,
      commitment: b64uDecode(j['key_commitment'] as String, length: 32),
      recipients: rec,
      signature: b64uDecode(j['signature'] as String, length: 64),
      wrappedKey: b64uDecode(j['wrapped_key'] as String, length: 80),
      chainN: j['chain_n'] as int?,
      chainHash: j['chain_hash'] == null ? null : b64uDecode(j['chain_hash'] as String, length: 32),
    );
  }
}

/// Mensagem no fio (protocolo §10.5). `seq` e `createdAt` só vêm do servidor.
class WireMessage {
  WireMessage({
    required this.conversationId,
    required this.epoch,
    required this.senderDeviceId,
    required this.messageId,
    required this.sentAt,
    required this.nonce,
    required this.ciphertext,
    required this.signature,
    this.seq,
    this.createdAt,
  });
  final int? createdAt;
  final String conversationId;
  final int epoch;
  final String senderDeviceId;
  final String messageId;
  final int sentAt;
  final Uint8List nonce;
  final Uint8List ciphertext;
  final Uint8List signature;
  final int? seq;

  factory WireMessage.fromJson(Map<String, dynamic> j) {
    final cid = j['conversation_id'] as String;
    final dev = j['sender_device_id'] as String;
    final mid = j['message_id'] as String;
    uuidToBytes(cid);
    uuidToBytes(dev);
    uuidToBytes(mid);
    final ct = b64uDecode(j['ciphertext'] as String);
    if (ct.length < 272 || ct.length > 16400 || (ct.length - 16) % 256 != 0) {
      throw const FormatException('tamanho do ciphertext');
    }
    return WireMessage(
      conversationId: cid,
      epoch: j['epoch'] as int,
      senderDeviceId: dev,
      messageId: mid,
      sentAt: j['sent_at'] as int,
      nonce: b64uDecode(j['nonce'] as String, length: 24),
      ciphertext: ct,
      signature: b64uDecode(j['signature'] as String, length: 64),
      seq: j['seq'] as int?,
      createdAt: j['created_at'] as int?,
    );
  }

  Map<String, dynamic> toSendJson() => {
    'conversation_id': conversationId,
    'epoch': epoch,
    'sender_device_id': senderDeviceId,
    'message_id': messageId,
    'sent_at': sentAt,
    'nonce': b64uEncode(nonce),
    'ciphertext': b64uEncode(ciphertext),
    'signature': b64uEncode(signature),
  };
}

/// Mensagem selada (protocolo-grupos §7.2): autor sem acesso. Não traz conteúdo.
class SealedWire {
  SealedWire({
    required this.conversationId,
    required this.seq,
    required this.messageId,
    required this.senderDeviceId,
    required this.senderUserId,
    required this.createdAt,
    required this.scrambleLength,
  });
  final String conversationId;
  final int seq;
  final String messageId;
  final String senderDeviceId;
  final String senderUserId;
  final int createdAt;

  /// Só o tamanho do embaralhado do servidor é usado: o texto é recalculado,
  /// para o servidor não poder pôr uma frase legível no nome de alguém.
  final int scrambleLength;

  factory SealedWire.fromJson(Map<String, dynamic> j) {
    final cid = j['conversation_id'] as String;
    final mid = j['message_id'] as String;
    final dev = j['sender_device_id'] as String;
    final user = j['sender_user_id'] as String;
    for (final id in [cid, mid, dev, user]) {
      uuidToBytes(id);
    }
    return SealedWire(
      conversationId: cid,
      seq: j['seq'] as int,
      messageId: mid,
      senderDeviceId: dev,
      senderUserId: user,
      createdAt: j['created_at'] as int,
      scrambleLength: (j['scramble'] as String).length.clamp(12, 32),
    );
  }
}

/// Linha "perdeu o acesso" / "voltou ao grupo" (§7.4).
class AccessEvent {
  AccessEvent(this.id, this.userId, this.active, this.at);
  final int id;
  final String userId;
  final bool active;
  final int at;

  factory AccessEvent.fromJson(Map<String, dynamic> j) =>
      AccessEvent(j['id'] as int, j['user_id'] as String, j['active'] as bool, j['at'] as int);
}

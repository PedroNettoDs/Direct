import 'dart:typed_data';

import 'b64.dart';

final _uuidRe = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

/// UUID texto (minúsculo, 36 caracteres) → 16 bytes (protocolo §2.1/§2.2).
Uint8List uuidToBytes(String uuid) {
  if (!_uuidRe.hasMatch(uuid)) throw FormatException('UUID inválido: $uuid');
  return fromHex(uuid.replaceAll('-', ''));
}

/// Certificado de aparelho (protocolo §5.3).
class DeviceCert {
  DeviceCert({
    required this.deviceId,
    required this.userId,
    required this.adminLabel,
    required this.signPub,
    required this.kexPub,
    required this.enrolledAt,
    required this.expiresAt,
    required this.sig,
  });

  final String deviceId;
  final String userId;
  final String adminLabel;
  final Uint8List signPub;
  final Uint8List kexPub;
  final int enrolledAt;
  final int expiresAt;
  final Uint8List sig;

  factory DeviceCert.fromJson(Map<String, dynamic> j) {
    final deviceId = j['device_id'] as String;
    final userId = j['user_id'] as String;
    uuidToBytes(deviceId);
    uuidToBytes(userId);
    return DeviceCert(
      deviceId: deviceId,
      userId: userId,
      adminLabel: j['admin_label'] as String,
      signPub: b64uDecode(j['sign_pub'] as String, length: 32),
      kexPub: b64uDecode(j['kex_pub'] as String, length: 32),
      enrolledAt: j['enrolled_at'] as int,
      expiresAt: j['expires_at'] as int,
      sig: b64uDecode(j['sig'] as String, length: 64),
    );
  }

  Map<String, dynamic> toJson() => {
    'device_id': deviceId,
    'user_id': userId,
    'admin_label': adminLabel,
    'sign_pub': b64uEncode(signPub),
    'kex_pub': b64uEncode(kexPub),
    'enrolled_at': enrolledAt,
    'expires_at': expiresAt,
    'sig': b64uEncode(sig),
  };
}

/// Chaves do aparelho (privadas: semente Ed25519 e escalar X25519).
class DeviceKeys {
  DeviceKeys({
    required this.signSeed,
    required this.signPub,
    required this.kexSk,
    required this.kexPub,
  });

  final Uint8List signSeed;
  final Uint8List signPub;
  final Uint8List kexSk;
  final Uint8List kexPub;
}

/// Dados do QR de convite, já validados (protocolo §4.2).
class Invite {
  Invite({
    required this.host,
    required this.seed,
    required this.serverSignPub,
    required this.escrowPub,
    this.modPub,
  });

  final String host;
  final Uint8List seed;
  final Uint8List serverSignPub;
  final Uint8List escrowPub;

  /// Chave do moderador (convite v=2, protocolo-grupos §3.2).
  final Uint8List? modPub;
}

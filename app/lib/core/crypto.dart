import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart';

import 'models.dart';

Uint8List concat(List<List<int>> parts) {
  final b = BytesBuilder(copy: false);
  for (final p in parts) {
    b.add(p);
  }
  return b.toBytes();
}

Uint8List u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v);
Uint8List u64(int v) => Uint8List(8)..buffer.asByteData().setUint64(0, v);

/// Rótulo de domínio: ASCII + 0x00 (protocolo §2.1).
Uint8List label(String s) => concat([ascii.encode(s), [0]]);

/// Primitivas do protocolo sobre libsodium (protocolo §1, §4–§6).
class DirectCrypto {
  DirectCrypto(this.sodium);
  final SodiumSumo sodium;

  Uint8List random(int n) => sodium.randombytes.buf(n);

  T _withKey<T>(Uint8List bytes, T Function(SecureKey) f) {
    final k = sodium.secureCopy(bytes);
    try {
      return f(k);
    } finally {
      k.dispose();
    }
  }

  Uint8List signPubFromSeed(Uint8List seed) => _withKey(seed, (s) {
    final kp = sodium.crypto.sign.seedKeyPair(s);
    kp.secretKey.dispose();
    return kp.publicKey;
  });

  Uint8List x25519Pub(Uint8List sk) =>
      _withKey(sk, (k) => sodium.crypto.scalarmult.base(n: k));

  DeviceKeys generateDeviceKeys() {
    final seed = random(32);
    final kexSk = random(32);
    return DeviceKeys(
      signSeed: seed,
      signPub: signPubFromSeed(seed),
      kexSk: kexSk,
      kexPub: x25519Pub(kexSk),
    );
  }

  Uint8List sign(Uint8List seed, Uint8List msg) => _withKey(seed, (s) {
    final kp = sodium.crypto.sign.seedKeyPair(s);
    try {
      return sodium.crypto.sign.detached(message: msg, secretKey: kp.secretKey);
    } finally {
      kp.secretKey.dispose();
    }
  });

  bool verify(Uint8List pub, Uint8List msg, Uint8List sig) {
    try {
      return sodium.crypto.sign.verifyDetached(
        message: msg,
        signature: sig,
        publicKey: pub,
      );
    } on Object {
      return false;
    }
  }

  Uint8List blake2b256(Uint8List msg) =>
      sodium.crypto.genericHash(message: msg, outLen: 32);

  /// Código de verificação do servidor, 20 dígitos (protocolo §4.3).
  String serverCode(Uint8List serverSignPub, Uint8List escrowPub) =>
      code20(blake2b256(concat([label('direct/v1/server-code'), serverSignPub, escrowPub])));

  /// Impressão digital do aparelho (protocolo §13.4): o moderador confere com a
  /// da CLI antes do `escrow rewrap`.
  String deviceCode(Uint8List signPub, Uint8List kexPub) =>
      code20(blake2b256(concat([label('direct/v1/device-code'), signPub, kexPub])));

  /// 20 dígitos de um hash de 32 bytes (§4.3).
  String code20(Uint8List dg) {
    final groups = <String>[];
    for (var i = 0; i < 4; i++) {
      var v = 0;
      for (var j = 0; j < 5; j++) {
        v = (v << 8) | dg[5 * i + j];
      }
      groups.add((v % 100000).toString().padLeft(5, '0'));
    }
    return groups.join(' ');
  }

  Uint8List enrollBytes(Uint8List invitePub, Uint8List signPub, Uint8List kexPub) =>
      concat([label('direct/v1/enroll'), invitePub, signPub, kexPub]);

  Uint8List certBytes(DeviceCert c) {
    final name = utf8.encode(c.adminLabel);
    return concat([
      label('direct/v1/device-cert'),
      uuidToBytes(c.deviceId),
      uuidToBytes(c.userId),
      c.signPub,
      c.kexPub,
      u64(c.enrolledAt),
      u64(c.expiresAt),
      u32(name.length),
      name,
    ]);
  }

  bool verifyCert(DeviceCert c, Uint8List serverSignPub) =>
      verify(serverSignPub, certBytes(c), c.sig);

  Uint8List authBytes(
    Uint8List serverSignPub,
    String deviceId,
    Uint8List challenge,
  ) => concat([
    label('direct/v1/auth'),
    serverSignPub,
    uuidToBytes(deviceId),
    challenge,
  ]);

  Uint8List revokedBytes(String deviceId, Uint8List challenge) =>
      concat([label('direct/v1/revoked'), uuidToBytes(deviceId), challenge]);
}

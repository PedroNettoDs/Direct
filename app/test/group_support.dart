// Aparelhos e cadeia dos vetores de grupo, para os testes.
import 'dart:typed_data';

import 'package:direct/core/b64.dart';
import 'package:direct/core/crypto.dart';
import 'package:direct/core/group_proto.dart';
import 'package:direct/core/models.dart';

import 'support.dart';

class VecDevice {
  VecDevice(this.name, this.cert, this.signSeed, this.kexSk);
  final String name;
  final DeviceCert cert;
  final Uint8List signSeed;
  final Uint8List kexSk;

  DeviceKeys get keys => DeviceKeys(signSeed: signSeed, signPub: cert.signPub, kexSk: kexSk, kexPub: cert.kexPub);
}

Uint8List _hex(Object? s) => fromHex(s! as String);

/// A, B, C (../chaves + ../cadastro) e D, E (grupos/chaves).
Map<String, VecDevice> vecDevices() {
  final chaves = vetor('chaves');
  final certs = {
    for (final c in vetor('cadastro')['certificados'] as List) (c as Map)['aparelho'] as String: c,
  };
  final out = <String, VecDevice>{};
  for (final d in (chaves['aparelhos'] as List).cast<Map<String, dynamic>>()) {
    final c = certs[d['nome']]!;
    out[d['nome'] as String] = VecDevice(
      d['nome'] as String,
      DeviceCert(
        deviceId: d['device_id'] as String,
        userId: d['user_id'] as String,
        adminLabel: d['admin_label'] as String,
        signPub: _hex(d['sign_pub']),
        kexPub: _hex(d['kex_pub']),
        enrolledAt: c['enrolled_at'] as int,
        expiresAt: c['expires_at'] as int,
        sig: _hex(c['cert_sig']),
      ),
      _hex(d['sign_seed']),
      _hex(d['kex_sk']),
    );
  }
  for (final d in (vetor('grupos/chaves')['aparelhos_novos'] as List).cast<Map<String, dynamic>>()) {
    out[d['nome'] as String] = VecDevice(
      d['nome'] as String,
      DeviceCert.fromJson(d['cert'] as Map<String, dynamic>),
      _hex(d['sign_seed']),
      _hex(d['kex_sk']),
    );
  }
  return out;
}

Uint8List vecServerPub() => _hex((vetor('chaves')['servidor'] as Map)['sign_pub']);
Uint8List vecEscrowPub() => _hex((vetor('chaves')['escrow'] as Map)['kex_pub']);
Uint8List vecModSeed() => _hex((vetor('grupos/chaves')['moderador'] as Map)['sign_seed']);
Uint8List vecModPub() => _hex((vetor('grupos/chaves')['moderador'] as Map)['sign_pub']);

ChainKeys vecChainKeys({bool mod = true}) => ChainKeys(
  serverSignPub: vecServerPub(),
  modPub: mod ? vecModPub() : null,
  certs: {for (final d in vecDevices().values) d.cert.deviceId: d.cert},
);

/// Registro como no vetor (bytes em hexadecimal).
SignedChange vecRecord(Map<String, dynamic> r) =>
    SignedChange(_hex(r['change_bytes']), _hex(r['signature']), n: r['n'] as int? ?? 0);

/// Registro assinado por um aparelho de teste.
SignedChange signRecord(
  DirectCrypto c, {
  required String conversationId,
  required GroupState state,
  required int kind,
  VecDevice? author,
  Uint8List? modSeed,
  Uint8List? body,
  int createdAt = 1798100000000,
  int receivedAt = 0,
}) {
  final change = GroupChange(
    conversationId: conversationId,
    n: state.n + 1,
    prev: state.head,
    kind: kind,
    authorType: author == null ? authorModerator : authorDevice,
    authorDeviceId: author?.cert.deviceId ?? zeroUuid,
    authorUserId: author?.cert.userId ?? zeroUuid,
    createdAt: createdAt,
    body: body ?? Uint8List(0),
  );
  final bytes = change.encode();
  return SignedChange(bytes, c.sign(author?.signSeed ?? modSeed!, bytes), n: change.n, receivedAt: receivedAt);
}

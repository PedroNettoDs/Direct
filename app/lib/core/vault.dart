import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart';

import 'b64.dart';
import 'bio.dart';
import 'crypto.dart';
import 'kv_store.dart';
import 'models.dart';

class WrongPassword implements Exception {
  WrongPassword(this.retryAfter);

  /// Espera até a próxima tentativa (zero = pode tentar já).
  final Duration retryAfter;
}

class LockedOut implements Exception {
  LockedOut(this.retryAfter);
  final Duration retryAfter;
}

/// Atraso após [fails] senhas erradas seguidas: 0 até 2 erros; depois
/// 5 s, 10 s, 20 s ... até 15 min.
Duration lockoutDelay(int fails) {
  if (fails < 3) return Duration.zero;
  final secs = 5 * (1 << (fails - 3).clamp(0, 10));
  return Duration(seconds: secs > 900 ? 900 : secs);
}

/// Chave-mestra local (PLANO §7).
///
/// senha --Argon2id--> chave que embrulha a chave-mestra (32 bytes aleatórios).
/// A chave-mestra gera, por BLAKE2b com chave, a chave do SQLCipher e a chave
/// que cifra as chaves privadas guardadas no Keychain/Keystore.
class Vault {
  Vault(
    this.sodium,
    this.kv, {
    DateTime Function()? now,
    this.uptime,
    int? opsLimit,
    int? memLimit,
    BioStore? bio,
  }) : bio = bio ?? NoBio(),
       _now = now ?? DateTime.now,
       opsLimit = opsLimit ?? sodium.crypto.pwhash.opsLimitModerate,
       memLimit = memLimit ?? sodium.crypto.pwhash.memLimitInteractive;

  final SodiumSumo sodium;
  final KvStore kv;
  final BioStore bio;
  final DateTime Function() _now;

  /// Relógio monotônico (ms desde o boot). Sem ele o atraso fica só no de parede.
  final Future<int> Function()? uptime;
  final int opsLimit;
  final int memLimit;

  static const _kVault = 'vault';
  static const _kThrottle = 'throttle';
  static const _kBio = 'bio';
  static const _kSecrets = 'secrets';
  static const _aadVault = 'direct/v1/vault';
  static const _aadSecrets = 'direct/v1/secrets';

  Future<bool> get exists async => await kv.read(_kVault) != null;

  Uint8List _kdf(String password, Uint8List salt, int ops, int mem) {
    final k = sodium.crypto.pwhash.callRaw(
      outLen: 32,
      password: Int8List.view(Uint8List.fromList(utf8.encode(password)).buffer),
      salt: salt,
      opsLimit: ops,
      memLimit: mem,
      alg: CryptoPwhashAlgorithm.argon2id13,
    );
    try {
      return k.extractBytes();
    } finally {
      k.dispose();
    }
  }

  Uint8List _seal(Uint8List key, Uint8List plain, String aad) {
    final nonce = sodium.randombytes.buf(24);
    final k = sodium.secureCopy(key);
    try {
      final ct = sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
        message: plain,
        nonce: nonce,
        key: k,
        additionalData: utf8.encode(aad).toUint8List(),
      );
      return concat([nonce, ct]);
    } finally {
      k.dispose();
    }
  }

  /// Devolve null se a chave ou o texto estiverem errados.
  Uint8List? _open(Uint8List key, Uint8List blob, String aad) {
    if (blob.length < 24 + 16) return null;
    final k = sodium.secureCopy(key);
    try {
      return sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
        cipherText: blob.sublist(24),
        nonce: blob.sublist(0, 24),
        key: k,
        additionalData: utf8.encode(aad).toUint8List(),
      );
    } on SodiumException {
      return null;
    } finally {
      k.dispose();
    }
  }

  /// Cria a chave-mestra embrulhada pela senha e a devolve.
  Future<Uint8List> create(String password) async {
    final salt = sodium.randombytes.buf(16);
    final master = sodium.randombytes.buf(32);
    final wrapKey = _kdf(password, salt, opsLimit, memLimit);
    await kv.write(
      _kVault,
      jsonEncode({
        'v': 1,
        'salt': b64uEncode(salt),
        'ops': opsLimit,
        'mem': memLimit,
        'wrapped': b64uEncode(_seal(wrapKey, master, _aadVault)),
      }),
    );
    await kv.delete(_kThrottle);
    return master;
  }

  Future<({int fails, int until, int? up})> _throttle(String slot) async {
    final raw = await kv.read(slot);
    if (raw == null) return (fails: 0, until: 0, up: null);
    final j = jsonDecode(raw) as Map<String, dynamic>;
    return (fails: j['fails'] as int, until: j['until'] as int, up: j['up'] as int?);
  }

  Future<void> _writeThrottle(String slot, int fails) async => kv.write(
    slot,
    jsonEncode({
      'fails': fails,
      'until': _now().add(lockoutDelay(fails)).millisecondsSinceEpoch,
      'up': await uptime?.call(),
    }),
  );

  /// Tempo que falta para a próxima tentativa. Os dois relógios têm de ter
  /// andado; se o de parede voltou ou o aparelho reiniciou, a espera recomeça.
  Future<Duration> lockoutRemaining() => _remaining(_kThrottle);

  Future<Duration> _remaining(String slot) async {
    final t = await _throttle(slot);
    final delay = lockoutDelay(t.fails).inMilliseconds;
    if (delay == 0) return Duration.zero;
    final now = _now().millisecondsSinceEpoch;
    var left = t.until - now;
    final up = await uptime?.call();
    if (up != null && t.up != null) {
      final elapsed = up - t.up!;
      if (elapsed < 0 || now < t.until - delay) {
        await _writeThrottle(slot, t.fails);
        return Duration(milliseconds: delay);
      }
      left = max(left, delay - elapsed);
    }
    return left > 0 ? Duration(milliseconds: left) : Duration.zero;
  }

  /// Abre a chave-mestra. [LockedOut] se ainda no atraso (sem gastar Argon2);
  /// [WrongPassword] se errada (e aumenta o atraso).
  Future<Uint8List> unlock(String password) async =>
      _unwrap(password, (await kv.read(_kVault))!, _aadVault, _kThrottle);

  Future<Uint8List> _unwrap(String password, String json, String aad, String slot) async {
    final wait = await _remaining(slot);
    if (wait > Duration.zero) throw LockedOut(wait);
    final j = jsonDecode(json) as Map<String, dynamic>;
    final wrapKey = _kdf(
      password,
      b64uDecode(j['salt'] as String, length: 16),
      j['ops'] as int,
      j['mem'] as int,
    );
    final secret = _open(wrapKey, b64uDecode(j['wrapped'] as String), aad);
    if (secret == null) {
      final fails = (await _throttle(slot)).fails + 1;
      await _writeThrottle(slot, fails);
      throw WrongPassword(lockoutDelay(fails));
    }
    await kv.delete(slot);
    return secret;
  }

  // ---- senha própria de conversa oculta (D12) ----

  static String _hiddenSlot(String id) => 'hidden_throttle:$id';

  /// Embrulha a chave privada da conversa [id] com a senha dela, nos mesmos
  /// parâmetros de Argon2id da trava. Nada disto depende da chave-mestra.
  Future<String> wrapForConversation(String id, String password, Uint8List secret) async {
    final salt = sodium.randombytes.buf(16);
    final wrapKey = _kdf(password, salt, opsLimit, memLimit);
    await kv.delete(_hiddenSlot(id));
    return jsonEncode({
      'v': 1,
      'salt': b64uEncode(salt),
      'ops': opsLimit,
      'mem': memLimit,
      'wrapped': b64uEncode(_seal(wrapKey, secret, 'direct/v1/hidden:$id')),
    });
  }

  /// Mesmo atraso crescente da trava, contado por conversa. Lança [WrongPassword]
  /// / [LockedOut].
  Future<Uint8List> unwrapForConversation(String id, String password, String json) =>
      _unwrap(password, json, 'direct/v1/hidden:$id', _hiddenSlot(id));

  // ---- digital (D9) ----

  /// Digital ativada neste aparelho (marca em [kv]; o segredo fica no [bio]).
  Future<bool> get bioEnabled async => await kv.read(_kBio) == '1';

  /// Guarda a chave-mestra atrás da digital. Pede a digital.
  Future<void> enableBio(Uint8List master) async {
    await bio.write(b64uEncode(master));
    await kv.write(_kBio, '1');
  }

  Future<void> disableBio() async {
    await kv.delete(_kBio);
    await bio.delete();
  }

  /// Abre a chave-mestra com a digital. Digital nova no aparelho
  /// ([BioInvalidated]) desativa o recurso: só a senha abre.
  Future<Uint8List> unlockBio() async {
    if (!await bioEnabled) throw BioUnavailable();
    final String? raw;
    try {
      raw = await bio.read();
    } on BioInvalidated {
      await disableBio();
      rethrow;
    }
    if (raw == null) {
      await disableBio();
      throw BioInvalidated();
    }
    return b64uDecode(raw, length: 32);
  }

  Uint8List _subkey(Uint8List master, String context) {
    final k = sodium.secureCopy(master);
    try {
      return sodium.crypto.genericHash(
        message: ascii.encode(context).toUint8List(),
        key: k,
        outLen: 32,
      );
    } finally {
      k.dispose();
    }
  }

  /// Chave de 32 bytes do SQLCipher.
  Uint8List dbKey(Uint8List master) => _subkey(master, 'direct/v1/db');

  Future<void> saveSecrets(Uint8List master, DeviceKeys keys) async {
    final plain = utf8.encode(
      jsonEncode({
        'sign_seed': b64uEncode(keys.signSeed),
        'kex_sk': b64uEncode(keys.kexSk),
      }),
    );
    final blob = _seal(
      _subkey(master, 'direct/v1/secrets'),
      Uint8List.fromList(plain),
      _aadSecrets,
    );
    await kv.write(_kSecrets, b64uEncode(blob));
  }

  /// Chaves privadas do aparelho (precisa da chave-mestra aberta).
  Future<({Uint8List signSeed, Uint8List kexSk})?> loadSecrets(
    Uint8List master,
  ) async {
    final raw = await kv.read(_kSecrets);
    if (raw == null) return null;
    final plain = _open(
      _subkey(master, 'direct/v1/secrets'),
      b64uDecode(raw),
      _aadSecrets,
    );
    if (plain == null) return null;
    final j = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
    return (
      signSeed: b64uDecode(j['sign_seed'] as String, length: 32),
      kexSk: b64uDecode(j['kex_sk'] as String, length: 32),
    );
  }
}

extension on List<int> {
  Uint8List toUint8List() => Uint8List.fromList(this);
}

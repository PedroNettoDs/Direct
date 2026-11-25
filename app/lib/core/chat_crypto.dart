import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart';

import 'crypto.dart';
import 'models.dart';

/// Falha ao validar ou decifrar (assinatura, compromisso, AAD, formato).
class ChatCryptoException implements Exception {
  ChatCryptoException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Cabeçalho da mensagem (protocolo §10.3).
class MessageHeader {
  MessageHeader({
    required this.conversationId,
    required this.epoch,
    required this.senderDeviceId,
    required this.messageId,
    required this.sentAt,
  });
  final String conversationId;
  final int epoch;
  final String senderDeviceId;
  final String messageId;
  final int sentAt;
}

class SealedMessage {
  SealedMessage(this.nonce, this.ciphertext, this.signature);
  final Uint8List nonce;
  final Uint8List ciphertext;
  final Uint8List signature;
}

class NewEpoch {
  NewEpoch({
    required this.key,
    required this.commitment,
    required this.recipients,
    required this.wraps,
    required this.escrowWrap,
    required this.signature,
  });
  final Uint8List key;
  final Uint8List commitment;
  final List<String> recipients;

  /// device_id → sealed box.
  final Map<String, Uint8List> wraps;
  final Uint8List escrowWrap;
  final Uint8List signature;
}

/// Épocas e mensagens (protocolo §9 e §10).
class ChatCrypto {
  ChatCrypto(this.c);
  final DirectCrypto c;
  SodiumSumo get sodium => c.sodium;

  static const maxText = 12000;

  T _key<T>(Uint8List bytes, T Function(SecureKey) f) {
    final k = sodium.secureCopy(bytes);
    try {
      return f(k);
    } finally {
      k.dispose();
    }
  }

  // ---- preenchimento (ISO/IEC 7816-4, bloco 256; §10.2) ----

  Uint8List pad(Uint8List data) => sodium.pad(data, 256);
  Uint8List unpad(Uint8List data) => sodium.unpad(data, 256);

  // ---- época ----

  Uint8List keyCommitment(String conversationId, int epoch, Uint8List key) =>
      c.blake2b256(
        concat([label('direct/v1/epoch-key'), uuidToBytes(conversationId), u32(epoch), key]),
      );

  /// Bytes assinados da declaração de época (§9.3). [recipients] já ordenado.
  Uint8List epochBytes({
    required String conversationId,
    required int epoch,
    required String creatorDeviceId,
    required Uint8List commitment,
    required Uint8List escrowPub,
    required List<String> recipients,
  }) => concat([
    label('direct/v1/epoch'),
    uuidToBytes(conversationId),
    u32(epoch),
    uuidToBytes(creatorDeviceId),
    commitment,
    escrowPub,
    u32(recipients.length),
    for (final r in recipients) uuidToBytes(r),
  ]);

  /// UUIDs minúsculos ordenam como bytes; remove repetidos.
  static List<String> sortedUnique(Iterable<String> ids) => ids.toSet().toList()..sort();

  /// Cria a chave de época `epoch` para [certs] (todos os aparelhos ativos dos membros).
  NewEpoch createEpoch({
    required String conversationId,
    required int epoch,
    required DeviceKeys self,
    required String selfDeviceId,
    required Uint8List escrowPub,
    required List<DeviceCert> certs,
  }) {
    final key = c.random(32);
    final commitment = keyCommitment(conversationId, epoch, key);
    final byId = {for (final d in certs) d.deviceId: d};
    final recipients = sortedUnique(byId.keys);
    final wraps = {
      for (final id in recipients)
        id: sodium.crypto.box.seal(message: key, publicKey: byId[id]!.kexPub),
    };
    final sig = c.sign(
      self.signSeed,
      epochBytes(
        conversationId: conversationId,
        epoch: epoch,
        creatorDeviceId: selfDeviceId,
        commitment: commitment,
        escrowPub: escrowPub,
        recipients: recipients,
      ),
    );
    return NewEpoch(
      key: key,
      commitment: commitment,
      recipients: recipients,
      wraps: wraps,
      escrowWrap: sodium.crypto.box.seal(message: key, publicKey: escrowPub),
      signature: sig,
    );
  }

  /// Validação do item de época (§9.8, passos 2 a 4). O certificado do criador
  /// e a pertença à conversa já foram conferidos por quem chama.
  /// Devolve `K` ou lança [ChatCryptoException].
  Uint8List openEpoch({
    required String conversationId,
    required int epoch,
    required DeviceCert creator,
    required Uint8List commitment,
    required List<String> recipients,
    required Uint8List signature,
    required Uint8List wrappedKey,
    required Uint8List escrowPub,
    required DeviceKeys self,
  }) {
    final sorted = sortedUnique(recipients);
    if (sorted.length != recipients.length ||
        !_sameList(sorted, recipients)) {
      throw ChatCryptoException('recipients fora de ordem');
    }
    final eb = epochBytes(
      conversationId: conversationId,
      epoch: epoch,
      creatorDeviceId: creator.deviceId,
      commitment: commitment,
      escrowPub: escrowPub,
      recipients: recipients,
    );
    if (!c.verify(creator.signPub, eb, signature)) {
      throw ChatCryptoException('assinatura da época inválida');
    }
    final Uint8List k;
    try {
      k = _key(
        self.kexSk,
        (sk) => sodium.crypto.box.sealOpen(
          cipherText: wrappedKey,
          publicKey: self.kexPub,
          secretKey: sk,
        ),
      );
    } on Object {
      throw ChatCryptoException('embrulho de chave não abre');
    }
    if (k.length != 32) throw ChatCryptoException('chave de época com tamanho errado');
    final expect = keyCommitment(conversationId, epoch, k);
    if (!sodium.memcmp(expect, commitment)) {
      throw ChatCryptoException('compromisso da chave não confere');
    }
    return k;
  }

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // ---- mensagem ----

  Uint8List headerBytes(MessageHeader h) => concat([
    uuidToBytes(h.conversationId),
    u32(h.epoch),
    uuidToBytes(h.senderDeviceId),
    uuidToBytes(h.messageId),
    u64(h.sentAt),
  ]);

  Uint8List aad(MessageHeader h) => concat([label('direct/v1/msg'), headerBytes(h)]);

  Uint8List sigBytes(MessageHeader h, Uint8List nonce, Uint8List ciphertext) => concat([
    label('direct/v1/msg-sig'),
    headerBytes(h),
    nonce,
    u32(ciphertext.length),
    ciphertext,
  ]);

  Uint8List textPlain(String text) => Uint8List.fromList(utf8.encode(jsonEncode({'type': 'text', 'text': text})));

  /// Cifra e assina (§10.3, §10.4). Nonce novo a cada chamada.
  SealedMessage seal({
    required MessageHeader header,
    required Uint8List epochKey,
    required Uint8List plaintext,
    required Uint8List signSeed,
  }) {
    final padded = pad(plaintext);
    final nonce = c.random(24);
    final ct = _key(
      epochKey,
      (k) => sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
        message: padded,
        nonce: nonce,
        key: k,
        additionalData: aad(header),
      ),
    );
    return SealedMessage(nonce, ct, c.sign(signSeed, sigBytes(header, nonce, ct)));
  }

  /// Verifica a assinatura e decifra (§10.7, passos 4 e 5). Devolve o texto claro (JSON).
  Uint8List open({
    required MessageHeader header,
    required SealedMessage msg,
    required Uint8List epochKey,
    required Uint8List senderSignPub,
  }) {
    if (!c.verify(senderSignPub, sigBytes(header, msg.nonce, msg.ciphertext), msg.signature)) {
      throw ChatCryptoException('assinatura da mensagem inválida');
    }
    try {
      final padded = _key(
        epochKey,
        (k) => sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
          cipherText: msg.ciphertext,
          nonce: msg.nonce,
          key: k,
          additionalData: aad(header),
        ),
      );
      return unpad(padded);
    } on Object {
      throw ChatCryptoException('mensagem não decifra');
    }
  }

  // ---- blob de anexo (§18.2) ----

  Uint8List blobAad(String conversationId) => concat([label('direct/v1/blob'), uuidToBytes(conversationId)]);

  /// `nonce(24) || XChaCha20-Poly1305(key, nonce, jpeg, aad)`. [key] tem 32 bytes aleatórios por imagem.
  Uint8List sealBlob({required String conversationId, required Uint8List key, required Uint8List jpeg}) {
    final nonce = c.random(24);
    final ct = _key(
      key,
      (k) => sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
        message: jpeg,
        nonce: nonce,
        key: k,
        additionalData: blobAad(conversationId),
      ),
    );
    return concat([nonce, ct]);
  }

  /// Abre o blob. Lança [ChatCryptoException] se a tag não confere. O SHA-256 é conferido por quem chama.
  Uint8List openBlob({required String conversationId, required Uint8List key, required Uint8List blob}) {
    if (blob.length < 41) throw ChatCryptoException('blob curto demais');
    try {
      return _key(
        key,
        (k) => sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
          cipherText: Uint8List.sublistView(blob, 24),
          nonce: Uint8List.sublistView(blob, 0, 24),
          key: k,
          additionalData: blobAad(conversationId),
        ),
      );
    } on Object {
      throw ChatCryptoException('imagem não decifra');
    }
  }

  /// Extrai o texto de um claro `{"type":"text","text":...}`. Outro `type`: `null`.
  static String? parseText(Uint8List plain) {
    final Object? j;
    try {
      j = jsonDecode(utf8.decode(plain));
    } on FormatException {
      throw ChatCryptoException('claro não é JSON');
    }
    if (j is! Map<String, dynamic> || j['type'] is! String) {
      throw ChatCryptoException('claro sem type');
    }
    if (j['type'] != 'text') return null;
    final t = j['text'];
    if (t is! String) throw ChatCryptoException('texto inválido');
    return t;
  }
}

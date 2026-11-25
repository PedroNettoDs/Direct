import 'dart:typed_data';

import 'b64.dart';
import 'models.dart';

class InviteException implements Exception {
  InviteException(this.message);
  final String message;
  @override
  String toString() => message;
}

final _hostRe = RegExp(r'^[a-z0-9-]+(\.[a-z0-9-]+)*$');

bool isValidHost(String h) => h.length <= 253 && _hostRe.hasMatch(h);

Map<String, String> _params(String uri, String prefix) {
  if (uri.contains('%')) throw InviteException('Convite inválido');
  final params = <String, String>{};
  for (final part in uri.substring(prefix.length).split('&')) {
    final i = part.indexOf('=');
    if (i <= 0) throw InviteException('Convite inválido');
    final k = part.substring(0, i);
    if (params.containsKey(k)) throw InviteException('Convite inválido');
    params[k] = part.substring(i + 1);
  }
  return params;
}

bool _exactly(Map<String, String> p, Set<String> keys) =>
    p.length == keys.length && p.keys.every(keys.contains);

/// Lê `direct://enroll?v=1&h=...&t=...&s=...&e=...` (protocolo §4.2) ou `v=2`
/// com `m` (protocolo-grupos §3.2). Recusa qualquer desvio: o QR é a raiz de
/// confiança do app.
Invite parseInviteUri(String uri) {
  const prefix = 'direct://enroll?';
  if (!uri.startsWith(prefix)) {
    throw InviteException('QR não é um convite do Direct');
  }
  final params = _params(uri, prefix);
  final v = params['v'];
  if (v != '1' && v != '2') throw InviteException('Versão de convite não suportada');
  if (!_exactly(params, {'v', 'h', 't', 's', 'e', if (v == '2') 'm'})) {
    throw InviteException('Convite inválido');
  }
  final host = params['h']!;
  if (!isValidHost(host)) throw InviteException('Endereço do servidor inválido');
  try {
    return Invite(
      host: host,
      seed: b64uDecode(params['t']!, length: 32),
      serverSignPub: b64uDecode(params['s']!, length: 32),
      escrowPub: b64uDecode(params['e']!, length: 32),
      modPub: v == '2' ? b64uDecode(params['m']!, length: 32) : null,
    );
  } on FormatException {
    throw InviteException('Convite inválido');
  }
}

/// QR de fixação da chave do moderador (protocolo-grupos §3.4):
/// `direct://pin?v=1&h=...&s=...&e=...&m=...`. [host], [serverSignPub] e
/// [escrowPub] são os já fixados e têm de ser iguais. Devolve `mod_sign_pub`.
Uint8List parsePinUri(
  String uri, {
  required String host,
  required Uint8List serverSignPub,
  required Uint8List escrowPub,
}) {
  const prefix = 'direct://pin?';
  if (!uri.startsWith(prefix)) throw InviteException('QR não é de ativação de grupos');
  final p = _params(uri, prefix);
  if (!_exactly(p, {'v', 'h', 's', 'e', 'm'}) || p['v'] != '1') {
    throw InviteException('QR de ativação inválido');
  }
  if (p['h'] != host || p['s'] != b64uEncode(serverSignPub) || p['e'] != b64uEncode(escrowPub)) {
    throw InviteException('Este QR é de outro servidor.');
  }
  try {
    return b64uDecode(p['m']!, length: 32);
  } on FormatException {
    throw InviteException('QR de ativação inválido');
  }
}

import 'dart:convert';
import 'dart:typed_data';

/// base64url sem `=` (protocolo §2.2).
String b64uEncode(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

/// Decodificação estrita: recusa `=`, alfabeto errado, forma não canônica e
/// tamanho diferente de [length] (quando informado).
Uint8List b64uDecode(String s, {int? length}) {
  if (s.contains('=')) {
    throw const FormatException('base64url com padding');
  }
  final Uint8List out;
  try {
    out = Uint8List.fromList(base64Url.decode(base64Url.normalize(s)));
  } on FormatException {
    throw const FormatException('base64url inválido');
  }
  if (b64uEncode(out) != s) {
    throw const FormatException('base64url não canônico');
  }
  if (length != null && out.length != length) {
    throw FormatException('tamanho ${out.length}, esperado $length');
  }
  return out;
}

String toHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List fromHex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(2 * i, 2 * i + 2), radix: 16);
  }
  return out;
}

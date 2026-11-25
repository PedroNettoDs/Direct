import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:image/image.dart' as img;

import 'b64.dart';
import 'chat_crypto.dart';
import 'models.dart';

/// Imagens (protocolo §18): preparo no remetente, referência na mensagem, EXIF de salvamento.

const maxImageSide = 2048;
const thumbSide = 96;
const thumbMaxBytes = 6144;
const maxBlobBytes = 10 * 1024 * 1024;

Uint8List sha256Of(List<int> data) => Uint8List.fromList(hash.sha256.convert(data).bytes);

/// JPEG pronto para cifrar: sem EXIF nem qualquer outro metadado do original (§18.3).
class PreparedImage {
  PreparedImage(this.jpeg, this.thumb, this.width, this.height);
  final Uint8List jpeg;
  final Uint8List thumb;
  final int width;
  final int height;
}

/// Decodifica, aplica a orientação, reduz a no máximo 2048 px e recomprime em JPEG a partir dos
/// pixels. Roda num isolate: fotos de câmera são grandes. Lança [FormatException] se não for imagem.
Future<PreparedImage> prepareImage(Uint8List source) => Isolate.run(() => prepareImageSync(source));

PreparedImage prepareImageSync(Uint8List source) {
  final decoded = img.decodeImage(source);
  if (decoded == null) throw const FormatException('imagem ilegível');
  var im = img.bakeOrientation(decoded);
  final big = im.width > im.height ? im.width : im.height;
  if (big > maxImageSide) {
    im = img.copyResize(
      im,
      width: im.width >= im.height ? maxImageSide : null,
      height: im.height > im.width ? maxImageSide : null,
      interpolation: img.Interpolation.average,
    );
  }
  final jpeg = _encodeClean(im, 85);
  var side = thumbSide;
  Uint8List thumb;
  while (true) {
    final t = img.copyResize(
      im,
      width: im.width >= im.height ? side : null,
      height: im.height > im.width ? side : null,
      interpolation: img.Interpolation.average,
    );
    thumb = _encodeClean(t, 50);
    if (thumb.length <= thumbMaxBytes || side <= 16) break;
    side -= 16;
  }
  return PreparedImage(jpeg, thumb, im.width, im.height);
}

/// Foto de grupo (protocolo-grupos §6.1): só pixels, até 256 px e 8 KiB.
Future<Uint8List> prepareGroupPhoto(Uint8List source) => Isolate.run(() => prepareGroupPhotoSync(source));

Uint8List prepareGroupPhotoSync(Uint8List source) {
  final decoded = img.decodeImage(source);
  if (decoded == null) throw const FormatException('imagem ilegível');
  final im = img.bakeOrientation(decoded);
  var side = math.min(256, math.max(im.width, im.height));
  var quality = 80;
  while (true) {
    final out = _encodeClean(
      img.copyResize(
        im,
        width: im.width >= im.height ? side : null,
        height: im.height > im.width ? side : null,
        interpolation: img.Interpolation.average,
      ),
      quality,
    );
    if (out.length <= 8192) return out;
    if (quality > 40) {
      quality -= 20;
    } else if (side > 32) {
      side = side * 3 ~/ 4;
    } else {
      throw const FormatException('foto grande demais');
    }
  }
}

/// Zera EXIF, perfil ICC e texto do original: o JPEG sai só com pixels (o encoder só escreve
/// APP1/ICC se houver dado).
Uint8List _encodeClean(img.Image im, int quality) {
  im
    ..exif = img.ExifData()
    ..iccProfile = null
    ..textData = null;
  return Uint8List.fromList(img.encodeJpg(im, quality: quality));
}

/// Mensagem `image` (§18.1).
class ImageRef {
  ImageRef({
    required this.blobId,
    required this.key,
    required this.sha256,
    required this.width,
    required this.height,
    required this.thumb,
  });
  final String blobId; // vazio enquanto o blob não subiu
  final Uint8List key;
  final Uint8List sha256;
  final int width;
  final int height;
  final Uint8List thumb;

  ImageRef withBlobId(String id) =>
      ImageRef(blobId: id, key: key, sha256: sha256, width: width, height: height, thumb: thumb);

  /// JSON de §18.1: é o texto claro da mensagem.
  String toJson() => jsonEncode({
    'type': 'image',
    'blob_id': blobId,
    'key': b64uEncode(key),
    'sha256': b64uEncode(sha256),
    'mime': 'image/jpeg',
    'w': width,
    'h': height,
    'thumb': b64uEncode(thumb),
  });

  /// Lê o JSON de §18.1. Lança [ChatCryptoException] se faltar campo, tamanho errado ou `mime` ≠ JPEG.
  /// [allowPendingBlob] aceita `blob_id` vazio (só no armazenamento local, antes do envio).
  static ImageRef fromJson(String json, {bool allowPendingBlob = false}) {
    try {
      final j = jsonDecode(json);
      if (j is! Map<String, dynamic> || j['type'] != 'image' || j['mime'] != 'image/jpeg') {
        throw const FormatException('não é imagem JPEG');
      }
      final id = j['blob_id'] as String;
      if (!(allowPendingBlob && id.isEmpty)) uuidToBytes(id);
      final w = j['w'] as int, h = j['h'] as int;
      if (w < 1 || h < 1 || w > 4096 || h > 4096) throw const FormatException('dimensões');
      final thumb = b64uDecode(j['thumb'] as String);
      if (thumb.isEmpty || thumb.length > thumbMaxBytes) throw const FormatException('miniatura');
      return ImageRef(
        blobId: id,
        key: b64uDecode(j['key'] as String, length: 32),
        sha256: b64uDecode(j['sha256'] as String, length: 32),
        width: w,
        height: h,
        thumb: thumb,
      );
    } on FormatException catch (e) {
      throw ChatCryptoException('imagem inválida: ${e.message}');
    } on TypeError {
      throw ChatCryptoException('imagem inválida: campo ausente ou de tipo errado');
    }
  }

  /// Plano de §18.1 já em bytes, para cifrar como mensagem (§10).
  Uint8List toPlain() => Uint8List.fromList(utf8.encode(toJson()));

  /// Tenta ler [plain] como imagem. `null` se o `type` não for `image`; lança se for e estiver errado.
  static ImageRef? tryParse(Uint8List plain) {
    final Object? j;
    try {
      j = jsonDecode(utf8.decode(plain));
    } on FormatException {
      return null;
    }
    if (j is! Map<String, dynamic> || j['type'] != 'image') return null;
    return fromJson(utf8.decode(plain));
  }
}

/// Texto de `ImageDescription` e `UserComment` (§18.6). [at] em UTC, segundos, sufixo `Z`.
String saveDescription({
  required String saveId,
  required String userId,
  required String deviceId,
  required DateTime at,
}) => 'Direct save_id=$saveId user=$userId device=$deviceId at=${utcSeconds(at)}';

String utcSeconds(DateTime t) {
  final u = t.toUtc();
  String p(int v, [int n = 2]) => v.toString().padLeft(n, '0');
  return '${p(u.year, 4)}-${p(u.month)}-${p(u.day)}T${p(u.hour)}:${p(u.minute)}:${p(u.second)}Z';
}

/// Texto da marca d'água visível (D10, §18.6): `<rótulo> · <data UTC> · <save_id curto>`.
String watermarkText({required String label, required DateTime at, required String saveId}) =>
    '$label \u00b7 ${utcSeconds(at)} \u00b7 ${saveId.substring(0, 8)}';

/// A fonte bitmap só tem ASCII: tira acentos e troca o separador `·` por `|`.
String _drawable(String t) {
  const from = 'áàâãäéèêëíìîïóòôõöúùûüçñÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ';
  const to = 'aaaaaeeeeiiiiooooouuuucnAAAAAEEEEIIIIOOOOOUUUUCN';
  final b = StringBuffer();
  for (final r in t.runes) {
    final c = String.fromCharCode(r);
    final k = from.indexOf(c);
    b.write(r == 0xb7 ? '|' : k >= 0 ? to[k] : (r >= 32 && r < 127 ? c : '?'));
  }
  return b.toString();
}

/// Cópia de [jpeg] com [text] repetido em diagonal pela imagem toda, branco semitransparente com
/// sombra, corpo proporcional ao lado menor (cortar não remove). Recomprime em JPEG (qualidade 92)
/// e não carrega EXIF: quem chama grava o EXIF depois. Só para a cópia que vai à galeria.
Future<Uint8List> applyWatermark(Uint8List jpeg, String text) => Isolate.run(() => applyWatermarkSync(jpeg, text));

Uint8List applyWatermarkSync(Uint8List jpeg, String text) {
  final base = img.decodeJpg(jpeg);
  if (base == null) throw const FormatException('JPEG inválido');
  final photo = base.numChannels == 3 ? base : base.convert(numChannels: 3);
  final font = img.arial48;
  final short = photo.width < photo.height ? photo.width : photo.height;
  final scale = (short / 24) / 48; // corpo da letra ≈ 1/24 do lado menor
  final drawn = _drawable(text);
  // camada com o texto na escala nativa da fonte, depois ajustada
  final tw = drawn.length * 30 + 40, th = 80;
  var layer = img.Image(width: tw, height: th, numChannels: 4);
  img.drawString(layer, drawn, font: font, x: 22, y: 18, color: img.ColorRgba8(0, 0, 0, 200));
  img.drawString(layer, drawn, font: font, x: 20, y: 16, color: img.ColorRgba8(255, 255, 255, 255));
  layer = img.copyResize(layer, width: (tw * scale).round().clamp(8, 1 << 14), interpolation: img.Interpolation.cubic);
  const tilt = 30.0;
  layer = img.copyRotate(layer, angle: -tilt, interpolation: img.Interpolation.linear);
  for (final p in layer) {
    p.a = p.a * 0.5;
  }
  // grade: textos lado a lado ao longo da diagonal (sobe para a direita), linhas paralelas abaixo
  final stepX = (layer.width * 0.9).round();
  final stepUp = (stepX * math.tan(tilt * math.pi / 180)).round();
  final stepY = (th * scale * 3.5).round().clamp(8, 1 << 14);
  final cols = photo.width ~/ stepX + 3;
  final rowsMin = -(cols * stepUp ~/ stepY) - 2, rowsMax = photo.height ~/ stepY + 2;
  for (var j = rowsMin; j <= rowsMax; j++) {
    for (var i = -2; i < cols; i++) {
      img.compositeImage(photo, layer, dstX: i * stepX, dstY: j * stepY - i * stepUp + stepUp ~/ 2);
    }
  }
  photo
    ..exif = img.ExifData()
    ..iccProfile = null;
  return Uint8List.fromList(img.encodeJpg(photo, quality: 92));
}

/// Grava `Artist`, `ImageDescription` e `UserComment` (com o prefixo `ASCII\0\0\0` do padrão EXIF)
/// no JPEG [jpeg], sem recomprimir. Os textos vão em UTF-8.
Uint8List addSaveExif(Uint8List jpeg, {required String artist, required String description}) {
  final exif = img.ExifData();
  exif.imageIfd.data[0x013b] = img.IfdValueAscii.list(utf8.encode(artist));
  exif.imageIfd.data[0x010e] = img.IfdValueAscii.list(utf8.encode(description));
  exif.exifIfd.data[0x9286] = img.IfdValueUndefined.list([
    ...ascii.encode('ASCII'),
    0,
    0,
    0,
    ...utf8.encode(description),
  ]);
  final out = img.injectJpgExif(jpeg, exif);
  if (out == null) throw const FormatException('JPEG inválido');
  return out;
}

/// Lê de volta o que [addSaveExif] gravou (testes e conferência).
({String? artist, String? description, String? comment}) readSaveExif(Uint8List jpeg) {
  final e = img.decodeJpgExif(jpeg);
  if (e == null) return (artist: null, description: null, comment: null);
  String? text(img.IfdValue? v) => v == null ? null : utf8.decode(v.toData(), allowMalformed: true);
  final c = e.exifIfd.data[0x9286]?.toData();
  return (
    artist: text(e.imageIfd.data[0x013b]),
    description: text(e.imageIfd.data[0x010e]),
    comment: c == null || c.length < 8 ? null : utf8.decode(c.sublist(8), allowMalformed: true),
  );
}

/// Rótulo `Artist` do salvamento: o `admin_label` do certificado do aparelho (§18.6).
String artistLabel(DeviceCert cert) => cert.adminLabel;

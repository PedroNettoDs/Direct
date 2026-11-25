import 'dart:io';
import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

/// Câmera ou galeria. Lê os bytes e apaga o arquivo temporário do `image_picker` na hora
/// (PLANO 15: nada em claro no disco). Devolve `null` se o usuário cancelou.
Future<Uint8List?> pickImageBytes(ImageSource source, {ImagePicker? picker}) async {
  final file = await (picker ?? ImagePicker()).pickImage(source: source, requestFullMetadata: false);
  if (file == null) return null;
  final Uint8List bytes;
  try {
    bytes = await file.readAsBytes();
  } finally {
    await _deleteQuietly(File(file.path));
    await sweepPickerTemp();
  }
  return bytes;
}

Future<void> _deleteQuietly(File f) async {
  try {
    if (await f.exists()) await f.delete();
  } on FileSystemException {
    // melhor esforço
  }
}

/// Apaga o que o plugin deixou no cache (cópias e versões reduzidas, por nome `image_picker*`
/// ou `scaled_*`), na raiz do diretório temporário e um nível abaixo.
Future<void> sweepPickerTemp() async {
  try {
    final tmp = await getTemporaryDirectory();
    await for (final e in tmp.list()) {
      final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (name.startsWith('image_picker') || name.startsWith('scaled_')) {
        await e.delete(recursive: true);
      }
    }
  } on Object {
    // melhor esforço
  }
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:direct/core/b64.dart';
import 'package:direct/core/chat_crypto.dart';
import 'package:direct/core/crypto.dart';
import 'package:direct/core/media.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'support.dart';

/// JPEG de câmera sintético: 3000x2000, orientação 6 (girado), GPS, fabricante e miniatura.
Uint8List cameraJpeg() {
  final im = img.Image(width: 3000, height: 2000, numChannels: 3);
  for (final p in im) {
    p.setRgb(p.x * 255 ~/ 3000, p.y * 255 ~/ 2000, (p.x + p.y) % 256);
  }
  im.exif.imageIfd
    ..make = 'AparelhoSecreto'
    ..model = 'Modelo-123'
    ..orientation = 6;
  im.exif.gpsIfd.data[0x0002] = img.IfdValueRational(23, 1);
  im.exif.gpsIfd.data[0x0001] = img.IfdValueAscii('S');
  final raw = Uint8List.fromList(img.encodeJpg(im, quality: 90));
  final withExif = img.injectJpgExif(raw, im.exif)!;
  expect(utf8.decode(withExif, allowMalformed: true), contains('AparelhoSecreto'));
  return withExif;
}

void main() {
  group('preparo da imagem (§18.3)', () {
    test('reduz a 2048 px, aplica a orientação e remove todo o EXIF do original', () {
      final src = cameraJpeg();
      final out = prepareImageSync(src);
      final dec = img.decodeJpg(out.jpeg)!;
      // 3000x2000 girado 90°: 2000x3000 → lado maior 2048
      expect([dec.width, dec.height], [1365, 2048]);
      expect([out.width, out.height], [1365, 2048]);
      final text = latin1.decode(out.jpeg);
      for (final s in ['AparelhoSecreto', 'Modelo-123', 'Exif', 'GPS']) {
        expect(text.contains(s), isFalse, reason: s);
      }
      expect(img.decodeJpgExif(out.jpeg)?.isEmpty ?? true, isTrue);
      // nenhum segmento APP1 (EXIF/XMP): marcadores 0xFFE1
      expect(_hasMarker(out.jpeg, 0xe1), isFalse);
    });

    test('miniatura: JPEG de até 96 px e 6144 bytes, também sem EXIF', () {
      final out = prepareImageSync(cameraJpeg());
      expect(out.thumb.length, lessThanOrEqualTo(thumbMaxBytes));
      final t = img.decodeJpg(out.thumb)!;
      expect(t.height, 96);
      expect(_hasMarker(out.thumb, 0xe1), isFalse);
    });

    test('imagem pequena não é ampliada; lixo é recusado', () {
      final small = Uint8List.fromList(img.encodeJpg(img.Image(width: 40, height: 30, numChannels: 3), quality: 90));
      final out = prepareImageSync(small);
      expect([out.width, out.height], [40, 30]);
      expect(() => prepareImageSync(Uint8List.fromList([1, 2, 3, 4])), throwsFormatException);
    });
  });

  group('EXIF do salvamento (§18.6)', () {
    test('Artist, ImageDescription e UserComment, sem recomprimir', () {
      final jpeg = prepareImageSync(cameraJpeg()).jpeg;
      final desc = saveDescription(
        saveId: '5c4b3a29-1807-4f6e-8d5c-4b3a29180716',
        userId: '2b4d6f81-3a5c-4e7a-9b1d-3f5a7c9e1b2d',
        deviceId: '1f2e3d4c-5b6a-4978-8695-a4b3c2d1e0f9',
        at: DateTime.fromMillisecondsSinceEpoch(1795600123456, isUtc: true),
      );
      expect(desc, endsWith('at=2026-11-25T09:48:43Z'));
      final out = addSaveExif(jpeg, artist: 'João - Financeiro', description: desc);
      final back = readSaveExif(out);
      expect(back.artist, 'João - Financeiro');
      expect(back.description, desc);
      expect(back.comment, desc);
      // os pixels são os mesmos: o JPEG original aparece intacto depois do cabeçalho EXIF
      final a = img.decodeJpg(jpeg)!, b = img.decodeJpg(out)!;
      expect([a.width, a.height], [b.width, b.height]);
      expect(a.getPixel(7, 9).r, b.getPixel(7, 9).r);
    });

    test('hora em UTC com segundos e sufixo Z', () {
      expect(utcSeconds(DateTime.utc(2026, 1, 2, 3, 4, 5, 678)), '2026-01-02T03:04:05Z');
    });
  });

  group('marca d\'água (D10)', () {
    test('a cópia difere da original, cobre a imagem toda e o EXIF segue presente', () {
      final orig = prepareImageSync(cameraJpeg()).jpeg;
      final text = watermarkText(
        label: 'João - Financeiro',
        at: DateTime.utc(2026, 11, 24, 18, 30, 5),
        saveId: '5c4b3a29-1807-4f6e-8d5c-4b3a29180716',
      );
      expect(text, 'João - Financeiro \u00b7 2026-11-24T18:30:05Z \u00b7 5c4b3a29');
      final marked = applyWatermarkSync(orig, text);
      expect(marked, isNot(orig));
      final a = img.decodeJpg(orig)!, b = img.decodeJpg(marked)!;
      expect([b.width, b.height], [a.width, a.height]);
      // a marca aparece em todos os quadrantes (cortar um canto não a remove)
      for (final (x0, y0) in [(0, 0), (1, 0), (0, 1), (1, 1)]) {
        var changed = 0;
        for (var y = y0 * b.height ~/ 2; y < (y0 + 1) * b.height ~/ 2; y += 4) {
          for (var x = x0 * b.width ~/ 2; x < (x0 + 1) * b.width ~/ 2; x += 4) {
            final p = a.getPixel(x, y), q = b.getPixel(x, y);
            if ((p.r - q.r).abs() + (p.g - q.g).abs() + (p.b - q.b).abs() > 30) changed++;
          }
        }
        expect(changed, greaterThan(100), reason: 'quadrante $x0,$y0');
      }
      // EXIF gravado depois da marca
      final out = addSaveExif(marked, artist: 'João - Financeiro', description: 'Direct save_id=x');
      final ex = readSaveExif(out);
      expect(ex.artist, 'João - Financeiro');
      expect(ex.description, 'Direct save_id=x');
      expect(out, isNot(orig));
      expect(img.decodeJpg(out), isNotNull);
    });
  });

  group('anexo.json', () {
    late DirectCrypto c;
    late ChatCrypto cc;
    late Map<String, dynamic> an, chaves;
    setUpAll(() async {
      c = await loadCrypto();
      cc = ChatCrypto(c);
      an = vetor('anexo');
      chaves = vetor('chaves');
    });

    test('blob: AAD, SHA-256 e abertura', () {
      final conv = an['conversation_id'] as String;
      final blob = fromHex(an['blob'] as String);
      expect(toHex(cc.blobAad(conv)), an['aad_blob']);
      expect(toHex(sha256Of(blob)), an['blob_sha256']);
      final key = fromHex(an['chave_blob'] as String);
      expect(toHex(cc.openBlob(conversationId: conv, key: key, blob: blob)), an['imagem_bytes']);
      // selar com o nonce do vetor reproduz o blob; aqui o nonce é novo, então só conferimos o ciclo
      final again = cc.sealBlob(conversationId: conv, key: key, jpeg: fromHex(an['imagem_bytes'] as String));
      expect(again.length, blob.length);
      expect(toHex(cc.openBlob(conversationId: conv, key: key, blob: again)), an['imagem_bytes']);
    });

    test('casos que devem falhar', () {
      final conv = an['conversation_id'] as String;
      final key = fromHex(an['chave_blob'] as String);
      for (final f in (an['deve_falhar'] as List).cast<Map<String, dynamic>>()) {
        final blob = fromHex(f['blob'] as String);
        if (f.containsKey('aad')) {
          // outra conversa no AAD
          expect(
            () => cc.openBlob(conversationId: 'ffffffff-e4f5-4a6b-8c7d-9e0f1a2b3c4d', key: key, blob: blob),
            throwsA(isA<ChatCryptoException>()),
            reason: f['caso'] as String,
          );
        } else {
          expect(toHex(sha256Of(blob)), isNot(f['blob_sha256_esperado']), reason: f['caso'] as String);
          expect(() => cc.openBlob(conversationId: conv, key: key, blob: blob), throwsA(isA<ChatCryptoException>()));
        }
      }
      expect(() => cc.openBlob(conversationId: conv, key: key, blob: Uint8List(40)), throwsA(isA<ChatCryptoException>()));
      expect(
        () => cc.openBlob(conversationId: conv, key: Uint8List(32), blob: fromHex(an['blob'] as String)),
        throwsA(isA<ChatCryptoException>()),
      );
    });

    test('mensagem image: abre, confere a assinatura e aponta para o blob', () {
      final m = an['mensagem'] as Map<String, dynamic>;
      final a = (chaves['aparelhos'] as List).cast<Map<String, dynamic>>().firstWhere((x) => x['nome'] == 'A');
      final header = MessageHeader(
        conversationId: an['conversation_id'] as String,
        epoch: m['epoch'] as int,
        senderDeviceId: a['device_id'] as String,
        messageId: m['message_id'] as String,
        sentAt: m['sent_at'] as int,
      );
      expect(toHex(cc.aad(header)), m['aad']);
      final sealed = SealedMessage(fromHex(m['nonce'] as String), fromHex(m['ciphertext'] as String), fromHex(m['signature'] as String));
      expect(toHex(cc.sigBytes(header, sealed.nonce, sealed.ciphertext)), m['assinado_bytes']);
      final plain = cc.open(
        header: header,
        msg: sealed,
        epochKey: fromHex(m['chave_epoca'] as String),
        senderSignPub: fromHex(a['sign_pub'] as String),
      );
      expect(toHex(plain), m['texto_claro_bytes']);
      expect(ChatCrypto.parseText(plain), isNull);
      final ref = ImageRef.tryParse(plain)!;
      expect(ref.blobId, an['blob_id']);
      expect(toHex(ref.key), an['chave_blob']);
      expect(toHex(ref.sha256), an['blob_sha256']);
      expect([ref.width, ref.height], [1536, 2048]);
      expect(toHex(ref.thumb), an['miniatura_bytes']);
      // o JSON que o app produz é o do vetor (ordem de campos incluída)
      expect(ref.toJson(), m['texto_claro']);
    });

    test('EXIF de salvamento do vetor', () {
      final s = an['salvar'] as Map<String, dynamic>;
      expect(
        saveDescription(
          saveId: s['save_id'] as String,
          userId: s['user_id'] as String,
          deviceId: s['device_id'] as String,
          at: DateTime.utc(2026, 11, 24, 18, 30, 5),
        ),
        s['exif_descricao'],
      );
    });
  });

  group('ImageRef recusa mensagens malformadas (§18.1)', () {
    Map<String, dynamic> ok() => {
      'type': 'image',
      'blob_id': '0b9a8c7d-6e5f-4a3b-9c2d-1e0f9a8b7c6d',
      'key': b64uEncode(Uint8List(32)),
      'sha256': b64uEncode(Uint8List(32)),
      'mime': 'image/jpeg',
      'w': 10,
      'h': 10,
      'thumb': b64uEncode(Uint8List.fromList([1, 2, 3])),
    };
    Uint8List enc(Map<String, dynamic> j) => Uint8List.fromList(utf8.encode(jsonEncode(j)));

    test('válida passa; type diferente vira null', () {
      expect(ImageRef.tryParse(enc(ok())), isNotNull);
      expect(ImageRef.tryParse(enc({'type': 'text', 'text': 'x'})), isNull);
    });

    test('campos faltando, tamanhos e mime errados', () {
      final cases = <String, void Function(Map<String, dynamic>)>{
        'sem blob_id': (j) => j.remove('blob_id'),
        'blob_id ruim': (j) => j['blob_id'] = 'xyz',
        'chave curta': (j) => j['key'] = b64uEncode(Uint8List(31)),
        'hash curto': (j) => j['sha256'] = b64uEncode(Uint8List(33)),
        'mime': (j) => j['mime'] = 'image/png',
        'largura 0': (j) => j['w'] = 0,
        'altura enorme': (j) => j['h'] = 5000,
        'miniatura grande': (j) => j['thumb'] = b64uEncode(Uint8List(thumbMaxBytes + 1)),
        'miniatura vazia': (j) => j['thumb'] = '',
        'w como texto': (j) => j['w'] = '10',
      };
      cases.forEach((nome, mut) {
        final j = ok();
        mut(j);
        expect(() => ImageRef.tryParse(enc(j)), throwsA(isA<ChatCryptoException>()), reason: nome);
      });
    });
  });
}

bool _hasMarker(Uint8List b, int marker) {
  var i = 2; // depois do SOI
  while (i + 3 < b.length && b[i] == 0xff) {
    final m = b[i + 1];
    if (m == marker) return true;
    if (m == 0xda) return false; // início dos dados da imagem
    i += 2 + ((b[i + 2] << 8) | b[i + 3]);
  }
  return false;
}

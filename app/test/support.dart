import 'dart:convert';
import 'dart:io';

import 'package:direct/core/crypto.dart';
import 'package:sodium/sodium_sumo.dart';

Future<DirectCrypto>? _c;
Future<DirectCrypto> loadCrypto() => _c ??= Future(() async => DirectCrypto(await SodiumSumoInit.init()));

Map<String, dynamic> vetor(String nome) =>
    jsonDecode(File('../docs/vetores/$nome.json').readAsStringSync()) as Map<String, dynamic>;

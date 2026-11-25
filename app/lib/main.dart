import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sodium/sodium_sumo.dart';

import 'app_controller.dart';
import 'bubble/mini.dart';
import 'bubble/mini_view.dart';
import 'bubble/platform.dart';
import 'bubble/port.dart';
import 'core/api.dart';
import 'core/bio.dart';
import 'core/clock.dart';
import 'core/crypto.dart';
import 'core/kv_store.dart';
import 'core/vault.dart';
import 'data/db.dart';
import 'ui/app.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final sodium = await SodiumSumoInit.init();
  final dir = await getApplicationSupportDirectory();
  final dbFile = File('${dir.path}/direct.db');
  final kv = SecureKv(
    const FlutterSecureStorage(
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      ),
    ),
  );
  final controller = AppController(
    crypto: DirectCrypto(sodium),
    kv: kv,
    vault: Vault(sodium, kv, bio: PluginBioStore(), uptime: uptimeMs),
    uptime: uptimeMs,
    openDb: fileDbOpener(dbFile),
    wipeDbFiles: () => deleteDbFiles(dbFile),
    apiFor: (h) => DirectApi(
      h,
      debugBase: kDebugMode && h == '10.0.2.2'
          ? Uri.parse('http://10.0.2.2:${const String.fromEnvironment('DIRECT_DEBUG_PORT', defaultValue: '8080')}')
          : null,
    ),
    deviceInfo: _deviceInfo,
    firstRunMarker: () async => (await SharedPreferences.getInstance()).getBool('installed') != true,
    markInstalled: () async => (await SharedPreferences.getInstance()).setBool('installed', true),
  );
  // Conteúdo de grupo que saiu da memória não fica no cache de imagens (D11).
  controller.onPurge = () => PaintingBinding.instance.imageCache
    ..clear()
    ..clearLiveImages();
  await controller.init();
  // Isolate principal: dono das chaves, do banco e do WebSocket. A bolha fala
  // com ele por portas em memória.
  if (Platform.isAndroid) {
    serveMini(LocalMiniBackend(controller));
    await BubblePlatform().attach(controller);
  }
  runApp(DirectApp(controller: controller));
}

/// Entrada do segundo engine, o da bolha (`MiniChatActivity`). Só tela: não
/// abre cofre, banco nem rede.
@pragma('vm:entry-point')
void miniChatMain(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: directTheme(Brightness.light),
      darkTheme: directTheme(Brightness.dark),
      home: Scaffold(
        body: SafeArea(child: MiniChatView(backend: PortMiniBackend(), conversationId: args.single)),
      ),
    ),
  );
}

Future<DeviceInfoData> _deviceInfo() async {
  final p = DeviceInfoPlugin();
  if (Platform.isIOS) {
    final i = await p.iosInfo;
    return DeviceInfoData('ios', i.utsname.machine, i.systemVersion);
  }
  final a = await p.androidInfo;
  return DeviceInfoData('android', '${a.manufacturer} ${a.model}', a.version.release);
}

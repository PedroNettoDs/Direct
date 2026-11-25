import 'package:flutter/services.dart';

/// Eventos das proteções de tela nativas (PLANO §8). O bloqueio em si é
/// nativo; aqui só chega o aviso de print (iOS não consegue bloquear).
class ScreenGuard {
  ScreenGuard({void Function()? onScreenshot}) {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'screenshot') onScreenshot?.call();
    });
  }

  static const _ch = MethodChannel('direct/screen');

  void dispose() => _ch.setMethodCallHandler(null);
}

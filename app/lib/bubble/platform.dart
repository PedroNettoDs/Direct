import 'package:flutter/services.dart';

import '../app_controller.dart';

/// O que falta para a bolha aparecer.
class BubbleStatus {
  const BubbleStatus(this.notifications, this.bubbles);
  final bool notifications;
  final bool bubbles;
}

/// Lado Android das bolhas (`Bubbles.kt`).
class BubblePlatform {
  static const _ch = MethodChannel('direct/bubble');

  /// Liga o [AppController] ao Android: bolhas abertas e trancas pedidas.
  Future<void> attach(AppController c) async {
    c.dismissedSource = () async => await _ch.invokeListMethod<String>('dismissed') ?? const [];
    c.dismissedAck = (ids) => _ch.invokeMethod('ackDismissed', ids);
    c.onWipe = () => _ch.invokeMethod('closeAll');
    c.closeBubble = (id) => _ch.invokeMethod('close', id);
    // A tranca é gravada antes de o conjunto mudar: fechar a última bolha
    // com o app fora da tela fecha o banco.
    Future<void> sync() async {
      await c.applyDismissed();
      await c.setBubbles({...?await _ch.invokeListMethod<String>('active')});
    }

    _ch.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'changed':
          await sync();
        case 'screenOff':
          // o lado nativo já gravou as trancas; aqui aplica e esquece as chaves
          await c.applyDismissed();
          await c.lockBubbles();
      }
    });
    await sync();
  }

  Future<BubbleStatus> status() async {
    final m = (await _ch.invokeMapMethod<String, bool>('status'))!;
    return BubbleStatus(m['notifications']!, m['bubbles']!);
  }

  Future<void> requestNotifications() => _ch.invokeMethod('requestNotifications');

  Future<void> openSettings() => _ch.invokeMethod('openSettings');

  /// [title] é o nome do contato; nenhum conteúdo de mensagem sai do app.
  Future<void> show(AppController c, String conversationId, String title) async {
    // Conversa oculta não tem pop-up (D12).
    if (c.isHidden(conversationId)) throw StateError('conversa oculta');
    final before = c.bubbles;
    // Antes da bolha abrir: ela cobre o app, que então sai de primeiro plano.
    await c.setBubbles({...before, conversationId});
    try {
      await _ch.invokeMethod('show', {'id': conversationId, 'title': title});
    } on Object {
      await c.setBubbles(before);
      rethrow;
    }
  }
}

import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

/// WebSocket mínimo, só quadros de texto (protocolo §11.1). Troca-se nos testes.
abstract class WsLink {
  Stream<String> get incoming;
  void send(String text);

  /// Código de fechamento recebido do servidor (depois de `incoming` terminar).
  int? get closeCode;
  Future<void> close([int code = 1000]);
}

typedef WsConnector = Future<WsLink> Function(Uri uri);

class IoWsLink implements WsLink {
  IoWsLink(this._ch);
  final WebSocketChannel _ch;

  @override
  Stream<String> get incoming => _ch.stream.map((e) {
    if (e is String) return e;
    throw const FormatException('quadro binário');
  });

  @override
  void send(String text) => _ch.sink.add(text);

  @override
  int? get closeCode => _ch.closeCode;

  @override
  Future<void> close([int code = 1000]) => _ch.sink.close(code).timeout(
    const Duration(seconds: 2),
    onTimeout: () {},
  );
}

Future<WsLink> connectWs(Uri uri) async {
  final ch = WebSocketChannel.connect(uri);
  await ch.ready.timeout(const Duration(seconds: 10));
  return IoWsLink(ch);
}

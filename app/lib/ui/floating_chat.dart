import 'package:material_ui/material_ui.dart';

import '../app_controller.dart';
import '../bubble/mini.dart';
import '../bubble/mini_view.dart';

/// iOS: mini-chat flutuante dentro do app, por cima das outras telas. Tocar na
/// cabeça abre e recolhe; o X, ou arrastar a cabeça até o lixo, fecha e
/// tranca a conversa (PLANO §9, D7).
class FloatingChat extends StatefulWidget {
  const FloatingChat({super.key, required this.controller, required this.conversationId});
  final AppController controller;
  final String conversationId;

  @override
  State<FloatingChat> createState() => _FloatingChatState();
}

class _FloatingChatState extends State<FloatingChat> {
  late final _backend = LocalMiniBackend(widget.controller);
  Offset? _pos;
  bool _open = true;
  bool _dragging = false;
  bool _overTrash = false;

  static const _head = 56.0;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final pos = _pos ?? Offset(box.maxWidth - _head - 8, media.padding.top + 8);
        final trash = Offset(box.maxWidth / 2, box.maxHeight - media.padding.bottom - 56);
        final top = media.padding.top + _head + 16;
        return Stack(
          children: [
            if (_open)
              Positioned(
                left: 8,
                right: 8,
                top: top,
                bottom: 8 + media.viewInsets.bottom + media.padding.bottom,
                child: Material(
                  elevation: 12,
                  color: Theme.of(context).scaffoldBackgroundColor,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: MiniChatView(
                    backend: _backend,
                    conversationId: widget.conversationId,
                    onClose: widget.controller.closeFloating,
                  ),
                ),
              ),
            if (_dragging)
              Positioned(
                left: trash.dx - 32,
                top: trash.dy - 32,
                child: CircleAvatar(
                  radius: 32,
                  backgroundColor: _overTrash ? Colors.red : Colors.black54,
                  child: const Icon(Icons.delete_outline, color: Colors.white),
                ),
              ),
            Positioned(
              left: pos.dx,
              top: pos.dy,
              child: GestureDetector(
                key: const Key('floating-head'),
                onTap: () => setState(() => _open = !_open),
                onPanStart: (_) => setState(() {
                  _dragging = true;
                  _open = false;
                }),
                onPanUpdate: (d) => setState(() {
                  _pos = (_pos ?? pos) + d.delta;
                  _overTrash = (_pos! + const Offset(_head / 2, _head / 2) - trash).distance < 56;
                }),
                onPanEnd: (_) {
                  if (_overTrash) {
                    widget.controller.closeFloating();
                  } else {
                    setState(() => _dragging = _overTrash = false);
                  }
                },
                child: const Material(
                  type: MaterialType.transparency,
                  child: CircleAvatar(radius: _head / 2, child: Icon(Icons.chat_bubble)),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

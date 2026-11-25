import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../chat/chat_service.dart';
import 'chat_widgets.dart';
import 'theme.dart';

/// Linhas da lista de conversas.
class ConversationList extends StatelessWidget {
  const ConversationList({
    super.key,
    required this.items,
    required this.isLocked,
    required this.onTap,
    this.now,
    this.photoOf,
    this.footer,
    this.hidden = const [],
  });

  /// Ocultas reveladas pelos 7 toques (D12): em cima, só nome.
  final List<ConversationView> hidden;

  /// Foto cifrada do grupo, se houver.
  final Uint8List? Function(String conversationId)? photoOf;

  /// Linha depois das conversas (estado dos grupos).
  final Widget? footer;
  final List<ConversationView> items;
  final bool Function(String conversationId) isLocked;
  final void Function(ConversationView c) onTap;

  /// Relógio das horas (testes).
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final meta = TextStyle(color: ChatColors.of(context).meta, fontSize: 14);
    // cabeçalho + ocultas, quando reveladas
    final top = hidden.isEmpty ? 0 : hidden.length + 1;
    return ListView.builder(
      itemCount: top + items.length + (footer == null ? 0 : 1),
      itemBuilder: (context, index) {
        if (index < top) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text('OCULTAS', style: meta.copyWith(fontSize: 12, fontWeight: FontWeight.w600)),
            );
          }
          final h = hidden[index - 1];
          return ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            minVerticalPadding: 8,
            leading: Avatar(h.title, size: 52, group: h.isGroup),
            title: Text(h.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17)),
            subtitle: Text('Conversa oculta', style: meta),
            trailing: Icon(Icons.visibility_off_outlined, color: ChatColors.of(context).meta),
            onTap: () => onTap(h),
          );
        }
        final i = index - top;
        if (i == items.length) return footer!;
        final c = items[i];
        final locked = isLocked(c.conversationId);
        final preview = locked ? 'Conversa trancada' : (c.lastText.isEmpty ? c.subtitle : c.lastText);
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          minVerticalPadding: 8,
          leading: Avatar(c.title, size: 52, group: c.isGroup, photo: c.isGroup ? photoOf?.call(c.conversationId) : null),
          title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17)),
          subtitle: Row(
            children: [
              Flexible(child: Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis, style: meta)),
              if (!locked && c.lastAt != 0) Text(' · ${listTime(c.lastAt, now ?? DateTime.now())}', style: meta),
            ],
          ),
          trailing: locked ? Icon(Icons.lock_outline, color: ChatColors.of(context).meta) : null,
          onTap: () => onTap(c),
        );
      },
    );
  }
}

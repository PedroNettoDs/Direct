import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import 'chat_widgets.dart';
import 'common.dart';
import 'theme.dart';

/// Topo da conversa: voltar, avatar, nome com status, pop-up e informações.
class ChatHeader extends StatelessWidget implements PreferredSizeWidget {
  const ChatHeader({
    super.key,
    required this.title,
    this.status = '',
    this.onPopOut,
    this.onInfo,
    this.group = false,
    this.photo,
  });
  final bool group;
  final Uint8List? photo;
  final String title;
  final String status;
  final VoidCallback? onPopOut;
  final VoidCallback? onInfo;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) => AppBar(
    titleSpacing: 0,
    title: Row(
      children: [
        Avatar(title, size: 38, group: group, photo: photo),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
              if (status.isNotEmpty)
                Text(
                  status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: ChatColors.of(context).meta),
                ),
            ],
          ),
        ),
      ],
    ),
    actions: [
      if (onPopOut != null)
        IconButton(tooltip: 'Abrir em pop-up', icon: const Icon(Icons.picture_in_picture_alt), onPressed: onPopOut),
      if (onInfo != null)
        IconButton(
          tooltip: group ? 'Informações do grupo' : 'Informações do contato',
          icon: const Icon(Icons.info),
          onPressed: onInfo,
        ),
    ],
  );
}

List<Widget> _noTiles(BuildContext _) => const [];

/// Folha de informações do contato.
Future<void> showContactSheet(
  BuildContext context, {
  required String name,
  required String displayName,
  required String status,
  required List<String> deviceCodes,
  required VoidCallback onLock,
  List<Widget> Function(BuildContext sheet) extra = _noTiles,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (ctx) => SafeArea(
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Avatar(name, size: 72),
          const SizedBox(height: 8),
          Text(name, style: Theme.of(ctx).textTheme.titleLarge),
          if (displayName.isNotEmpty && displayName != name) Text(displayName),
          const SizedBox(height: 8),
          if (status.isNotEmpty)
            ListTile(leading: const Icon(Icons.chat_bubble_outline), title: const Text('Status'), subtitle: Text(status)),
          for (final code in deviceCodes)
            ListTile(
              leading: const Icon(Icons.smartphone),
              title: const Text('Código do aparelho'),
              subtitle: Text(code),
            ),
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: const Text('Trancar conversa'),
            onTap: () {
              Navigator.pop(ctx);
              onLock();
            },
          ),
          ...extra(ctx),
        ],
      ),
    ),
  ),
);

/// Conversa trancada: nenhum conteúdo, só o pedido para destravar.
class LockedChatView extends StatelessWidget {
  const LockedChatView({super.key, required this.title, required this.onUnlock, this.group = false});
  final bool group;
  final String title;
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: ChatHeader(title: title, group: group),
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_outline, size: 40, color: ChatColors.of(context).meta),
          const NoticeLine('Conversa trancada'),
          const SizedBox(height: 4),
          FilledButton(onPressed: onUnlock, child: const Text('Desbloquear conversa')),
        ],
      ),
    ),
  );
}

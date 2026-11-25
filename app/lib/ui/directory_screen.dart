import 'package:material_ui/material_ui.dart';

import '../app_controller.dart';
import '../chat/chat_service.dart';
import 'chat_screen.dart';
import 'chat_widgets.dart';
import 'common.dart';
import 'group_edit.dart';
import 'live.dart';

/// Diretório de usuários: toque para abrir (ou criar) a conversa 1:1.
class DirectoryScreen extends StatefulWidget {
  const DirectoryScreen({super.key, required this.controller, required this.svc});
  final AppController controller;
  final ChatService svc;

  @override
  State<DirectoryScreen> createState() => _DirectoryScreenState();
}

class _DirectoryScreenState extends State<DirectoryScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _open(DirectoryEntry u) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = await widget.svc.openConversationWith(u.userId);
      if (!mounted) return;
      await Navigator.pushReplacement(
        context,
        MaterialPageRoute<void>(
          builder: (_) => ChatScreen(
            controller: widget.controller,
            svc: widget.svc,
            conversationId: id,
            title: u.adminLabel,
          ),
        ),
      );
      return;
    } on Object catch (e) {
      _error = errorText(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nova conversa')),
      body: Column(
        children: [
          StatusBanner(svc: widget.svc),
          if (_busy) const LinearProgressIndicator(),
          ListenableBuilder(
            listenable: widget.svc,
            builder: (context, _) => !widget.svc.groupsAvailable
                ? const SizedBox.shrink()
                : ListTile(
                    leading: const Avatar('Grupo', group: true),
                    title: const Text('Novo grupo'),
                    onTap: () => Navigator.pushReplacement(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => NewGroupScreen(controller: widget.controller, svc: widget.svc),
                      ),
                    ),
                  ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          Expanded(
            child: Live<List<DirectoryEntry>>(
              svc: widget.svc,
              load: widget.svc.directory,
              builder: (context, list) => list.isEmpty
                  ? const Center(child: Text('Nenhum outro usuário no diretório.'))
                  : ListView.builder(
                      itemCount: list.length,
                      itemBuilder: (context, i) {
                        final u = list[i];
                        return ListTile(
                          enabled: !_busy,
                          leading: Avatar(u.adminLabel),
                          title: Text(u.adminLabel),
                          subtitle: Text(
                            [u.displayName, u.status].where((e) => e.isNotEmpty).join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => _open(u),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

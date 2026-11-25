import 'package:material_ui/material_ui.dart';

import '../app_controller.dart';
import '../chat/chat_service.dart';
import 'chat_screen.dart';
import 'conversation_list.dart';
import 'directory_screen.dart';
import 'live.dart';
import 'profile_screen.dart';

/// 7 toques no título, nesta janela (ms), revelam as ocultas (D12).
const _taps = 7;
const _tapWindow = 3000;

/// Lista de conversas.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  AppController get controller => widget.controller;

  /// Some ao sair desta tela; ao bloquear ou ir para segundo plano a própria
  /// tela é descartada.
  bool _revealed = false;
  final _tappedAt = <int>[];

  Future<void> _tapTitle() async {
    final now = await controller.uptime();
    _tappedAt
      ..removeWhere((t) => now - t > _tapWindow)
      ..add(now);
    if (_tappedAt.length < _taps || !mounted) return;
    _tappedAt.clear();
    setState(() => _revealed = true);
  }

  /// Toda saída desta tela passa por aqui.
  void _go(Widget screen) {
    _tappedAt.clear();
    setState(() => _revealed = false);
    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => screen));
  }

  /// Sem a chave do moderador: "Ative os grupos"; sem conexão, o aviso de D11.
  Widget? _groupsFooter(BuildContext context, ChatService svc) {
    if (svc.modPub == null) {
      if (svc.status != ChatStatus.online) return null;
      return ListTile(
        leading: const Icon(Icons.group_off_outlined),
        title: const Text('Ative os grupos'),
        subtitle: const Text('Confira a chave do moderador em Perfil.'),
        onTap: () => _go(ProfileScreen(controller: controller)),
      );
    }
    if (svc.groupsAvailable) return null;
    return const ListTile(
      leading: Icon(Icons.cloud_off_outlined),
      title: Text('Grupos indisponíveis sem conexão'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final svc = controller.chat;
    return Scaffold(
      appBar: AppBar(
        // Sem retorno visual antes do sétimo toque.
        title: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTap: _tapTitle,
          child: const Text('Conversas', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 24)),
        ),
        actions: [
          IconButton(
            tooltip: 'Perfil',
            icon: const Icon(Icons.person_outline),
            onPressed: () => _go(ProfileScreen(controller: controller)),
          ),
          IconButton(tooltip: 'Bloquear', icon: const Icon(Icons.lock_outline), onPressed: controller.lock),
        ],
      ),
      floatingActionButton: svc == null
          ? null
          : FloatingActionButton(
              tooltip: 'Nova conversa',
              onPressed: () => _go(DirectoryScreen(controller: controller, svc: svc)),
              child: const Icon(Icons.edit_outlined),
            ),
      body: svc == null
          ? const Center(child: Text('Chat indisponível.'))
          : Column(
              children: [
                StatusBanner(svc: svc),
                Expanded(
                  child: Live<(List<ConversationView>, List<ConversationView>)>(
                    svc: svc,
                    load: () async => (await svc.conversations(), await svc.hiddenConversations()),
                    builder: (context, data) {
                      final (list, hidden) = data;
                      final revealed = _revealed ? hidden : const <ConversationView>[];
                      if (list.isEmpty && revealed.isEmpty) {
                        return Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('Nenhuma conversa ainda.\nToque no lápis para começar.', textAlign: TextAlign.center),
                              const SizedBox(height: 16),
                              ?_groupsFooter(context, svc),
                            ],
                          ),
                        );
                      }
                      return ConversationList(
                        items: list,
                        hidden: revealed,
                        footer: _groupsFooter(context, svc),
                        photoOf: svc.groupPhoto,
                        now: svc.now(),
                        isLocked: controller.isConversationLocked,
                        onTap: (c) => _go(
                          ChatScreen(
                            controller: controller,
                            svc: svc,
                            conversationId: c.conversationId,
                            title: c.title,
                            group: c.isGroup,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

import 'package:material_ui/material_ui.dart';

import '../chat/chat_service.dart';

/// Recarrega [load] sempre que o [ChatService] avisa mudança no banco local.
class Live<T> extends StatefulWidget {
  const Live({super.key, required this.svc, required this.load, required this.builder});
  final ChatService svc;
  final Future<T> Function() load;
  final Widget Function(BuildContext context, T data) builder;

  @override
  State<Live<T>> createState() => _LiveState<T>();
}

class _LiveState<T> extends State<Live<T>> {
  T? _data;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    widget.svc.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    widget.svc.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final gen = ++_gen;
    final d = await widget.load();
    if (mounted && gen == _gen) setState(() => _data = d);
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    if (d == null) return const Center(child: CircularProgressIndicator());
    return widget.builder(context, d);
  }
}

String statusText(ChatStatus s) => switch (s) {
  ChatStatus.online => '',
  ChatStatus.connecting => 'Conectando…',
  ChatStatus.offline => 'Sem conexão. Tentando de novo…',
  ChatStatus.revoked => 'Aparelho revogado.',
  ChatStatus.expired => 'Acesso vencido. Peça um token novo ao moderador.',
};

/// Faixa de estado da conexão, vazia quando online.
class StatusBanner extends StatelessWidget {
  const StatusBanner({super.key, required this.svc});
  final ChatService svc;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: svc,
    builder: (context, _) {
      final t = statusText(svc.status);
      if (t.isEmpty) return const SizedBox.shrink();
      return Container(
        width: double.infinity,
        color: Theme.of(context).colorScheme.secondaryContainer,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Text(t, style: Theme.of(context).textTheme.bodySmall),
      );
    },
  );
}

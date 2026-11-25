import 'package:material_ui/material_ui.dart';

import '../ui/chat_widgets.dart';
import '../ui/theme.dart';
import 'mini.dart';

/// Mini-chat de uma conversa: o mesmo na bolha (Android) e no flutuante (iOS).
class MiniChatView extends StatefulWidget {
  const MiniChatView({super.key, required this.backend, required this.conversationId, this.onClose});
  final MiniBackend backend;
  final String conversationId;

  /// Só no flutuante do iOS: na bolha quem fecha é o sistema.
  final VoidCallback? onClose;

  @override
  State<MiniChatView> createState() => _MiniChatViewState();
}

class _MiniChatViewState extends State<MiniChatView> with WidgetsBindingObserver {
  final _text = TextEditingController();
  final _pw = TextEditingController();
  MiniState? _state;
  String? _error;
  bool _busy = false;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.backend.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.backend.removeListener(_reload);
    _text.dispose();
    _pw.dispose();
    super.dispose();
  }

  /// Abrir a bolha recolhida é um toque nela.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _touch();
  }

  Future<void> _touch() async {
    try {
      await widget.backend.touch();
    } on Object {
      // sem o app principal não há o que contar
    }
  }

  Future<void> _reload() async {
    final gen = ++_gen;
    try {
      final s = await widget.backend.load(widget.conversationId);
      if (!mounted || gen != _gen) return;
      if (s.phase != _state?.phase) {
        _error = null;
        _pw.clear();
      }
      setState(() => _state = s);
    } on Object {
      if (mounted && gen == _gen) setState(() => _error = 'Direct indisponível. Abra o app.');
    }
  }

  Future<void> _unlock(MiniPhase phase, String? password) async {
    if (_busy || (password != null && password.isEmpty)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? err;
    try {
      err = phase == MiniPhase.appLocked
          ? await widget.backend.unlockApp(password: password)
          : await widget.backend.unlockChat(widget.conversationId, password: password);
    } on Object {
      err = 'Não foi possível destravar.';
    }
    if (!mounted) return;
    _pw.clear();
    setState(() {
      _busy = false;
      _error = err == null || err.isEmpty ? null : err;
    });
    await _reload();
  }

  /// [like]: o coração envia direto, sem passar pelo campo.
  Future<void> _send([String? like]) async {
    final t = like ?? _text.text;
    if (t.trim().isEmpty) return;
    final String? err;
    try {
      err = await widget.backend.send(widget.conversationId, t);
    } on Object {
      if (mounted) setState(() => _error = 'Não foi possível enviar.');
      return;
    }
    if (!mounted) return;
    if (err == null && like == null) _text.clear();
    setState(() => _error = err);
  }

  @override
  Widget build(BuildContext context) {
    final s = _state;
    return Listener(
      onPointerDown: (_) => _touch(),
      child: _body(s),
    );
  }

  Widget _body(MiniState? s) {
    return Column(
      children: [
        Material(
          color: Theme.of(context).scaffoldBackgroundColor,
          child: Row(
            children: [
              const SizedBox(width: 12),
              if (s?.title.isNotEmpty == true) ...[Avatar(s!.title, size: 28, group: s.group), const SizedBox(width: 8)],
              Expanded(
                child: Text(
                  s?.title.isNotEmpty == true ? s!.title : 'Direct',
                  style: Theme.of(context).textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (widget.onClose != null)
                IconButton(
                  tooltip: 'Fechar e trancar',
                  icon: Icon(Icons.close, color: ChatColors.of(context).accentTop),
                  onPressed: widget.onClose,
                )
              else
                const SizedBox(height: 44),
            ],
          ),
        ),
        Expanded(
          child: switch (s?.phase) {
            null => Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!)),
            MiniPhase.ready => _chat(s!),
            MiniPhase.hidden => const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Conversa indisponível no pop-up.', textAlign: TextAlign.center),
              ),
            ),
            final p => _lock(p, s!.bio),
          },
        ),
      ],
    );
  }

  Widget _lock(MiniPhase phase, bool bio) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.lock_outline, size: 40),
          const SizedBox(height: 8),
          Text(
            phase == MiniPhase.appLocked ? 'Direct bloqueado' : 'Conversa trancada',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('mini-password'),
            controller: _pw,
            obscureText: true,
            enabled: !_busy,
            enableSuggestions: false,
            autocorrect: false,
            enableIMEPersonalizedLearning: false,
            onSubmitted: (v) => _unlock(phase, v),
            decoration: InputDecoration(labelText: 'Senha', border: const OutlineInputBorder(), errorText: _error),
          ),
          const SizedBox(height: 8),
          FilledButton(onPressed: _busy ? null : () => _unlock(phase, _pw.text), child: const Text('Desbloquear')),
          if (bio)
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _unlock(phase, null),
              icon: const Icon(Icons.fingerprint),
              label: const Text('Usar digital'),
            ),
        ],
      ),
    ),
  );

  Widget _chat(MiniState s) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        if (s.banner.isNotEmpty) Text(s.banner, style: Theme.of(context).textTheme.bodySmall),
        Expanded(
          child: MessageList(
            compact: true,
            showSenderNames: s.group,
            onRetry: widget.backend.retry,
            items: [
              for (final m in s.messages)
                ChatItem(
                  id: m.id,
                  mine: m.mine,
                  state: m.state,
                  sentAt: m.sentAt,
                  text: m.text,
                  thumb: m.thumb,
                  senderId: m.senderId,
                  senderName: m.mine ? '' : (s.group ? m.sender : s.title),
                  thumbLocked: m.thumbLocked,
                ),
            ],
          ),
        ),
        if (_error != null) Text(_error!, style: TextStyle(color: scheme.error)),
        Composer(
          compact: true,
          controller: _text,
          onChanged: (_) => _touch(),
          onSend: _send,
          onLike: () => _send(Composer.like),
        ),
      ],
    );
  }
}

import 'package:material_ui/material_ui.dart';

import '../app_controller.dart';

/// Pede senha ou digital sem mexer no estado do app. Devolve true se confere.
/// [run] troca a conferência (ex.: destrancar uma conversa, D7).
Future<bool> askReauth(
  BuildContext context,
  AppController c, {
  String title = 'Confirme que é você',
  Future<Reauth> Function(String? password)? run,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ReauthDialog(c, title, run ?? (p) => c.reauth(password: p)),
  );
  return ok ?? false;
}

class _ReauthDialog extends StatefulWidget {
  const _ReauthDialog(this.c, this.title, this.check);
  final AppController c;
  final Future<Reauth> Function(String? password) check;
  final String title;

  @override
  State<_ReauthDialog> createState() => _ReauthDialogState();
}

class _ReauthDialogState extends State<_ReauthDialog> {
  final _pw = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _pw.dispose();
    super.dispose();
  }

  Future<void> _run(String? password) async {
    if (_busy || (password != null && password.isEmpty)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final r = await widget.check(password);
    if (!mounted) return;
    if (r.ok) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      _busy = false;
      if (r.retryAfter != null) {
        _error = r.retryAfter! > Duration.zero
            ? 'Senha errada. Aguarde ${r.retryAfter!.inSeconds + 1} s.'
            : 'Senha errada.';
        _pw.clear();
      } else if (r.invalidated) {
        _error = 'A digital mudou. Use a senha.';
      } else if (!r.canceled) {
        _error = 'Não confere.';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _pw,
        obscureText: true,
        autofocus: true,
        enabled: !_busy,
        enableSuggestions: false,
        autocorrect: false,
        enableIMEPersonalizedLearning: false,
        onSubmitted: _run,
        decoration: InputDecoration(labelText: 'Senha', errorText: _error),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('Cancelar'),
        ),
        if (widget.c.bioEnabled)
          IconButton(
            tooltip: 'Usar digital',
            icon: const Icon(Icons.fingerprint),
            onPressed: _busy ? null : () => _run(null),
          ),
        FilledButton(
          onPressed: _busy ? null : () => _run(_pw.text),
          child: const Text('Confirmar'),
        ),
      ],
    );
  }
}

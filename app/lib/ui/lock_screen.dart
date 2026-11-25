import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../app_controller.dart';
import '../core/bio.dart';
import '../core/vault.dart';
import 'common.dart';

class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final _pw = TextEditingController();
  final _focus = FocusNode();
  Duration _wait = Duration.zero;
  String? _error;
  bool _busy = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    widget.controller.lockoutRemaining().then(_startWait);
    if (widget.controller.bioEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _bio());
    }
  }

  Future<void> _bio() async {
    if (_busy || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.controller.unlockWithBio();
      return; // a raiz troca de tela
    } on BioInvalidated {
      _error = 'A digital mudou no aparelho. Use a senha.';
    } on BioCanceled {
      // Fica a senha.
    } on BioUnavailable {
      _error = 'Digital indisponível agora. Use a senha.';
    } on Object {
      _error = 'Não foi possível abrir os dados locais.';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pw.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _startWait(Duration d) {
    _timer?.cancel();
    if (!mounted) return;
    setState(() => _wait = d);
    if (d <= Duration.zero) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      final left = _wait - const Duration(seconds: 1);
      if (left <= Duration.zero) t.cancel();
      setState(() => _wait = left > Duration.zero ? left : Duration.zero);
    });
  }

  Future<void> _submit() async {
    if (_busy || _wait > Duration.zero || _pw.text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    await Future<void>.delayed(const Duration(milliseconds: 50)); // pinta o spinner
    try {
      await widget.controller.unlock(_pw.text);
      return; // a raiz troca de tela
    } on WrongPassword catch (e) {
      _error = 'Senha errada.';
      _startWait(e.retryAfter);
    } on LockedOut catch (e) {
      _startWait(e.retryAfter);
    } on Object {
      _error = 'Não foi possível abrir os dados locais.';
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _pw.clear();
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final blocked = _wait > Duration.zero;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.lock_outline, size: 56),
                  const SizedBox(height: 16),
                  Text('Direct bloqueado',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _pw,
                    focusNode: _focus,
                    obscureText: true,
                    autofocus: true,
                    enabled: !_busy,
                    enableSuggestions: false,
                    autocorrect: false,
                    enableIMEPersonalizedLearning: false,
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      labelText: 'Senha',
                      border: const OutlineInputBorder(),
                      errorText: _error,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (blocked)
                    Text('Aguarde ${_wait.inSeconds + 1} s para tentar de novo.',
                        textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _busy || blocked ? null : _submit,
                    child: _busy
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Desbloquear'),
                  ),
                  if (widget.controller.bioEnabled)
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _bio,
                      icon: const Icon(Icons.fingerprint),
                      label: const Text('Usar digital'),
                    ),
                  TextButton(
                    onPressed: _busy ? null : _forgot,
                    child: const Text('Esqueci a senha'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _forgot() => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Esqueci a senha'),
      content: const Text(
        'A senha não pode ser recuperada: ela protege as chaves e o histórico '
        'guardados neste aparelho. A única saída é apagar tudo aqui e '
        'cadastrar o aparelho de novo com um convite. Com internet, este '
        'aparelho é revogado na hora; sem internet, peça ao moderador. Ele '
        'gera o convite e devolve o histórico.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Voltar'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(ctx);
            confirmWipe(context, widget.controller, forgot: true);
          },
          child: const Text('Apagar tudo neste aparelho'),
        ),
      ],
    ),
  );
}

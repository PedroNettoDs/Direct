// Telas das conversas ocultas (D12). Em nenhuma delas há digital.
import 'package:material_ui/material_ui.dart';

import '../app_controller.dart';
import 'chat_view.dart';
import 'common.dart';
import 'enroll_screen.dart' show minPasswordLength;
import 'theme.dart';

/// Itens da folha "i": esconder (só com [canHide], a chave do perfil) ou, na
/// conversa já oculta (e aberta), trocar a senha e mostrar de novo.
List<Widget> hiddenTiles({
  required bool hidden,
  required bool canHide,
  required VoidCallback onHide,
  required VoidCallback onChangePassword,
  required VoidCallback onShow,
}) => [
  if (!hidden && canHide)
    ListTile(
      leading: const Icon(Icons.visibility_off_outlined),
      title: const Text('Esconder conversa'),
      onTap: onHide,
    ),
  if (hidden) ...[
    ListTile(leading: const Icon(Icons.password), title: const Text('Trocar senha'), onTap: onChangePassword),
    ListTile(leading: const Icon(Icons.visibility_outlined), title: const Text('Mostrar conversa'), onTap: onShow),
  ],
];

/// Erros viram aviso no rodapé; a tela de origem pode já ter saído.
Future<void> _guard(ScaffoldMessengerState messenger, Future<void> Function() f) async {
  try {
    await f();
  } on Object catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(errorText(e))));
  }
}

/// Pede a senha, esconde e volta para a lista.
Future<void> hideFlow(BuildContext context, AppController c, String id) async {
  final nav = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final password = await _askNewPassword(
    context,
    title: 'Esconder conversa',
    action: 'Esconder',
    warning:
        'Ela some da lista. Para vê-la, toque 7 vezes em "Conversas".\n\n'
        'Se esquecer esta senha, não há como redefini-la: só com "Esqueci a senha" do app, '
        'que apaga tudo, e o moderador devolvendo o histórico.',
  );
  if (password == null) return;
  await _guard(messenger, () async {
    await c.hideConversation(id, password);
    nav.popUntil((r) => r.isFirst);
  });
}

Future<void> changeHiddenPasswordFlow(BuildContext context, AppController c, String id) async {
  final messenger = ScaffoldMessenger.of(context);
  final password = await _askNewPassword(context, title: 'Trocar senha', action: 'Trocar');
  if (password == null) return;
  await _guard(messenger, () async {
    await c.changeHiddenPassword(id, password);
    messenger.showSnackBar(const SnackBar(content: Text('Senha da conversa trocada.')));
  });
}

Future<void> showHiddenFlow(BuildContext context, AppController c, String id) async {
  final messenger = ScaffoldMessenger.of(context);
  await _guard(messenger, () async {
    await c.showHiddenConversation(id);
    messenger.showSnackBar(const SnackBar(content: Text('A conversa voltou para a lista.')));
  });
}

Future<String?> _askNewPassword(BuildContext context, {required String title, required String action, String? warning}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _NewPasswordDialog(title, action, warning),
    );

class _NewPasswordDialog extends StatefulWidget {
  const _NewPasswordDialog(this.title, this.action, this.warning);
  final String title;
  final String action;
  final String? warning;

  @override
  State<_NewPasswordDialog> createState() => _NewPasswordDialogState();
}

class _NewPasswordDialogState extends State<_NewPasswordDialog> {
  final _pw = TextEditingController();
  final _again = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pw.dispose();
    _again.dispose();
    super.dispose();
  }

  void _ok() {
    final error = _pw.text.length < minPasswordLength
        ? 'A senha precisa ter ao menos $minPasswordLength caracteres.'
        : _pw.text != _again.text
        ? 'As senhas não são iguais.'
        : null;
    if (error != null) return setState(() => _error = error);
    Navigator.pop(context, _pw.text);
  }

  Widget _field(Key key, TextEditingController c, String label, {String? error}) => TextField(
    key: key,
    controller: c,
    obscureText: true,
    enableSuggestions: false,
    autocorrect: false,
    enableIMEPersonalizedLearning: false,
    decoration: InputDecoration(labelText: label, errorText: error, errorMaxLines: 2),
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.warning != null) Text(widget.warning!),
          _field(const Key('hidden-new'), _pw, 'Senha desta conversa'),
          _field(const Key('hidden-again'), _again, 'Repita a senha', error: _error),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(onPressed: _ok, child: Text(widget.action)),
    ],
  );
}

/// Conversa oculta ainda fechada: só o pedido da senha dela.
class HiddenGate extends StatefulWidget {
  const HiddenGate({super.key, required this.title, required this.open, this.group = false});
  final String title;
  final bool group;
  final Future<Reauth> Function(String password) open;

  @override
  State<HiddenGate> createState() => _HiddenGateState();
}

class _HiddenGateState extends State<HiddenGate> {
  final _pw = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _pw.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final password = _pw.text;
    if (_busy || password.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    Reauth r;
    try {
      r = await widget.open(password);
    } on Object {
      r = Reauth.failed;
    }
    if (!mounted) return;
    _pw.clear();
    final wait = r.retryAfter;
    setState(() {
      _busy = false;
      _error = r.ok
          ? null
          : wait == null
          ? 'Não foi possível abrir.'
          : wait > Duration.zero
          ? 'Senha errada. Aguarde ${wait.inSeconds + 1} s.'
          : 'Senha errada.';
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: ChatHeader(title: widget.title, group: widget.group),
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(Icons.lock_outline, size: 40, color: ChatColors.of(context).meta),
            const NoticeLine('Conversa oculta. Digite a senha dela.'),
            const SizedBox(height: 4),
            TextField(
              key: const Key('hidden-password'),
              controller: _pw,
              obscureText: true,
              autofocus: true,
              enabled: !_busy,
              enableSuggestions: false,
              autocorrect: false,
              enableIMEPersonalizedLearning: false,
              onSubmitted: (_) => _run(),
              decoration: InputDecoration(labelText: 'Senha da conversa', errorText: _error),
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: _busy ? null : _run, child: const Text('Abrir')),
          ],
        ),
      ),
    ),
  );
}

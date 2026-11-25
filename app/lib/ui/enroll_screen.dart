import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../app_controller.dart';
import '../core/models.dart';
import 'common.dart';

const minPasswordLength = 8;

/// Cadastro: QR (ou domínio + token + código) → criar senha local.
class EnrollScreen extends StatefulWidget {
  const EnrollScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<EnrollScreen> createState() => _EnrollScreenState();
}

class _EnrollScreenState extends State<EnrollScreen> {
  Invite? _invite;
  bool _manual = false;
  bool _busy = false;
  String? _error;
  final _host = TextEditingController();
  final _token = TextEditingController();
  final _code = TextEditingController();
  final _pw = TextEditingController();
  final _pw2 = TextEditingController();

  @override
  void dispose() {
    for (final c in [_host, _token, _code, _pw, _pw2]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    try {
      await f();
    } on Object catch (e) {
      _error = errorText(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _scan() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const ScanPage(title: 'Ler QR do convite')),
    );
    if (raw == null) return;
    await _run(() async => _invite = widget.controller.inviteFromQr(raw));
  }

  Future<void> _manualNext() => _run(() async {
    _invite = await widget.controller.inviteFromManual(
      _host.text,
      _token.text,
      _code.text,
    );
  });

  Future<void> _create() => _run(() async {
    if (_pw.text.length < minPasswordLength) {
      throw UserFacingError('A senha precisa ter ao menos $minPasswordLength caracteres.');
    }
    if (_pw.text != _pw2.text) throw UserFacingError('As senhas não conferem.');
    await widget.controller.enroll(_invite!, _pw.text);
  });

  Widget _field(TextEditingController c, String label,
          {bool secret = false, bool enabled = true}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          obscureText: secret,
          enabled: enabled && !_busy,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      Text(_invite == null ? 'Entrar no Direct' : 'Criar senha do app',
          style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 16),
    ];
    if (_invite == null) {
      children.addAll([
        const Text('Leia o QR do convite que o moderador gerou.'),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _busy ? null : _scan,
          icon: const Icon(Icons.qr_code_scanner),
          label: const Text('Ler QR do convite'),
        ),
        TextButton(
          onPressed: _busy ? null : () => setState(() => _manual = !_manual),
          child: const Text('Digitar domínio e token'),
        ),
        if (_manual) ...[
          const SizedBox(height: 8),
          _field(_host, 'Domínio (ex.: direct.exemplo.com.br)'),
          _field(_token, 'Token (43 caracteres)'),
          _field(_code, 'Código de verificação (20 dígitos)'),
          FilledButton(
            onPressed: _busy ? null : _manualNext,
            child: const Text('Continuar'),
          ),
        ],
      ]);
    } else {
      children.addAll([
        Text('Servidor: ${_invite!.host}'),
        const SizedBox(height: 8),
        const Text(
          'Esta senha protege as chaves e as mensagens neste aparelho. '
          'Ela não pode ser recuperada: se esquecer, só resta apagar tudo e '
          'cadastrar de novo.',
        ),
        const SizedBox(height: 12),
        _field(_pw, 'Senha (mínimo $minPasswordLength caracteres)', secret: true),
        _field(_pw2, 'Repita a senha', secret: true),
        FilledButton(
          onPressed: _busy ? null : _create,
          child: const Text('Cadastrar este aparelho'),
        ),
        TextButton(
          onPressed: _busy ? null : () => setState(() => _invite = null),
          child: const Text('Voltar'),
        ),
      ]);
    }
    if (_busy) {
      children.addAll([
        const SizedBox(height: 16),
        const Center(child: CircularProgressIndicator()),
      ]);
    }
    if (_error != null) {
      children.addAll([
        const SizedBox(height: 16),
        Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ]);
    }
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Câmera lendo um QR; devolve o texto ao fechar.
class ScanPage extends StatefulWidget {
  const ScanPage({super.key, required this.title});
  final String title;

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final _scanner = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    body: MobileScanner(
      controller: _scanner,
      onDetect: (capture) {
        final raw = capture.barcodes.firstOrNull?.rawValue;
        if (raw == null || _done) return;
        _done = true;
        Navigator.of(context).pop(raw);
      },
    ),
  );
}

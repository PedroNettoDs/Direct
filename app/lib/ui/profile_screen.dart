import 'package:material_ui/material_ui.dart';

import '../app_controller.dart';
import '../core/bio.dart';
import '../core/vault.dart';
import 'common.dart';
import 'enroll_screen.dart';

/// Perfil (nome e status). Na primeira vez é o último passo do cadastro.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late final _name = TextEditingController(
    text: widget.controller.profile?.displayName ?? '',
  );
  late final _status = TextEditingController(
    text: widget.controller.profile?.status ?? '',
  );
  bool _busy = false;
  String? _error;
  bool _saved = false;
  String? _bioError;
  String? _groupError;

  /// Ativa os grupos pelo QR de fixação do moderador (protocolo-grupos §3.4).
  Future<void> _pinByQr() => _pin(() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const ScanPage(title: 'Ler QR do moderador')),
    );
    if (raw != null) await widget.controller.pinModeratorQr(raw);
  });

  /// Pelo código de 20 dígitos distribuído fora do servidor. O app não mostra o
  /// código que calculou: quem usa tem de digitar o que recebeu.
  Future<void> _pinByCode() => _pin(() async {
    final mod = await widget.controller.moderatorKeyFromServer();
    if (!mounted) return;
    final code = await _ask(
      title: 'Ativar grupos',
      label: 'Código do moderador (20 dígitos)',
      secret: false,
    );
    if (code != null) await widget.controller.pinModeratorCode(mod, code);
  });

  Future<void> _pin(Future<void> Function() f) async {
    setState(() => _groupError = null);
    try {
      await f();
    } on Object catch (e) {
      _groupError = errorText(e);
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _name.dispose();
    _status.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
      _saved = false;
    });
    try {
      await widget.controller.saveProfile(_name.text, _status.text);
      _saved = true;
    } on Object catch (e) {
      _error = errorText(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _toggleBio(bool on) async {
    final c = widget.controller;
    try {
      if (!on) {
        await c.disableBio();
        return;
      }
      if (!await c.bioAvailable()) {
        throw UserFacingError('Cadastre uma digital nas configurações do aparelho.');
      }
      if (!mounted) return;
      final pw = await _ask(title: 'Ativar digital', label: 'Digite sua senha', secret: true);
      if (pw == null) return;
      await c.enableBio(pw);
    } on WrongPassword {
      _bioError = 'Senha errada.';
    } on LockedOut catch (e) {
      _bioError = 'Aguarde ${e.retryAfter.inSeconds + 1} s.';
    } on BioCanceled {
      // Desistiu.
    } on BioUnavailable {
      _bioError = 'Digital indisponível agora.';
    } on Object catch (e) {
      _bioError = errorText(e);
    }
    if (mounted) setState(() {});
  }

  Future<String?> _ask({required String title, required String label, required bool secret}) {
    final ctl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctl,
          obscureText: secret,
          keyboardType: secret ? null : TextInputType.number,
          autofocus: true,
          enableSuggestions: false,
          autocorrect: false,
          enableIMEPersonalizedLearning: false,
          onSubmitted: (v) => Navigator.pop(ctx, v),
          decoration: InputDecoration(labelText: label),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctl.text),
            child: const Text('Continuar'),
          ),
        ],
      ),
    ).whenComplete(ctl.dispose);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final first = c.stage == Stage.profile;
    return Scaffold(
      appBar: AppBar(
        title: Text(first ? 'Seu perfil' : 'Perfil'),
        actions: [
          if (!first)
            IconButton(
              tooltip: 'Bloquear',
              icon: const Icon(Icons.lock_outline),
              onPressed: c.lock,
            ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (c.adminLabel != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text('Cadastrado como ${c.adminLabel}'),
                ),
              if (c.deviceCode != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    'Código deste aparelho: ${c.deviceCode}\n'
                    'Confira com o moderador antes de recuperar o histórico.',
                  ),
                ),
              TextField(
                controller: _name,
                enabled: !_busy,
                maxLength: 64,
                textCapitalization: TextCapitalization.words,
                enableIMEPersonalizedLearning: false,
                decoration: const InputDecoration(
                  labelText: 'Nome',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _status,
                enabled: !_busy,
                maxLength: 140,
                enableIMEPersonalizedLearning: false,
                decoration: const InputDecoration(
                  labelText: 'Status',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _busy ? null : _save,
                child: _busy
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Salvar'),
              ),
              if (_saved) const Padding(padding: EdgeInsets.only(top: 12), child: Text('Perfil salvo.')),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_error!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              if (!first) ...[
                const SizedBox(height: 24),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Desbloquear com digital'),
                  subtitle: Text(
                    _bioError ?? 'A senha continua valendo como reserva.',
                    style: _bioError == null
                        ? null
                        : TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                  value: c.bioEnabled,
                  onChanged: _toggleBio,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Adicionar secrets'),
                  subtitle: const Text('Mostra "Esconder conversa" nas informações da conversa.'),
                  value: c.secretsEnabled,
                  onChanged: (on) async {
                    await c.setSecrets(on);
                    if (mounted) setState(() {});
                  },
                ),
                const SizedBox(height: 16),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(c.groupsEnabled ? 'Grupos ativados' : 'Ativar grupos'),
                  subtitle: Text(
                    _groupError ??
                        (c.groupsEnabled
                            ? 'A chave do moderador está fixada neste aparelho.'
                            : 'Leia o QR do moderador ou digite o código que ele distribuiu.'),
                    style: _groupError == null ? null : TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
                if (!c.groupsEnabled)
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _pinByQr,
                        icon: const Icon(Icons.qr_code_scanner),
                        label: const Text('Ler QR'),
                      ),
                      OutlinedButton(onPressed: _pinByCode, child: const Text('Digitar código')),
                    ],
                  ),
              ],
              const SizedBox(height: 32),
              OutlinedButton(
                onPressed: _busy ? null : () => confirmWipe(context, c),
                child: const Text('Apagar tudo neste aparelho'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

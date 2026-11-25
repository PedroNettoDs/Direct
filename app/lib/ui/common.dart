import 'package:material_ui/material_ui.dart';

import '../app_controller.dart';
import 'theme.dart';

String errorText(Object e) =>
    e is UserFacingError ? e.message : 'Algo deu errado. Tente de novo.';

/// Confirmação de "Apagar tudo neste aparelho" (PLANO §6.5).
/// [forgot]: "Esqueci a senha" envia antes a revogação pré-assinada.
Future<void> confirmWipe(BuildContext context, AppController c, {bool forgot = false}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Apagar tudo neste aparelho?'),
      content: const Text(
        'Apaga o banco local, as chaves e o cadastro deste aparelho. '
        'Não dá para desfazer. Para voltar, o moderador precisa revogar este '
        'aparelho e gerar um convite novo; o histórico volta pelo moderador.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Apagar tudo neste aparelho'),
        ),
      ],
    ),
  );
  if (ok == true) await (forgot ? c.forgotPassword() : c.wipeAll());
}

/// Primeira letra do primeiro e do último nome.
String initials(String s) {
  final words = s.trim().split(RegExp(r'\s+'));
  String first(String w) => w.isEmpty ? '' : String.fromCharCode(w.runes.first).toUpperCase();
  final out = first(words.first) + (words.length > 1 ? first(words.last) : '');
  return out.isEmpty ? '?' : out;
}

/// HH:mm no fuso do aparelho.
String clock(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

/// Linha de sistema no meio do histórico: separador de horário, aviso local
/// (protocolo §7.3), conversa trancada e, nos grupos, "perdeu o acesso" e
/// "voltou ao grupo" (grupos.md §11).
class NoticeLine extends StatelessWidget {
  const NoticeLine(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(color: ChatColors.of(context).meta),
    ),
  );
}

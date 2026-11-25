import 'package:material_ui/material_ui.dart';

import '../app_controller.dart';
import '../chat/chat_service.dart';
import 'chat_widgets.dart';
import 'common.dart';
import 'group_edit.dart';
import 'hidden.dart';
import 'live.dart';
import 'theme.dart';

/// Informações do grupo: membros, ações de admin e a cadeia como histórico.
class GroupInfoScreen extends StatefulWidget {
  const GroupInfoScreen({super.key, required this.controller, required this.svc, required this.conversationId});
  final AppController controller;
  final ChatService svc;
  final String conversationId;

  @override
  State<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends State<GroupInfoScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<void> Function() f) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await f();
    } on Object catch (e) {
      _error = errorText(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<bool> _confirm(String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
          ],
        ),
      ) ==
      true;

  Future<void> _remove(GroupMemberView m) async {
    if (!await _confirm('Remover ${m.name}?', 'Quem sai não lê as próximas mensagens.', 'Remover')) return;
    await _run(() => widget.svc.removeMember(widget.conversationId, m.userId));
  }

  Future<void> _leave(GroupInfo g) async {
    final onlyAdmin = g.admin && g.members.where((m) => m.admin).length == 1 && g.members.length > 1;
    final ok = await _confirm(
      'Sair do grupo?',
      onlyAdmin
          ? 'Você é o único admin: o grupo ficará sem quem adicione ou remova pessoas.'
          : 'Você deixa de ver as mensagens deste grupo.',
      'Sair',
    );
    if (!ok) return;
    await _run(() async {
      await widget.svc.leaveGroup(widget.conversationId);
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    });
  }

  Future<void> _close() async {
    if (!await _confirm('Encerrar o grupo?', 'Ninguém mais envia mensagens. Não dá para desfazer.', 'Encerrar')) return;
    await _run(() => widget.svc.closeGroup(widget.conversationId));
  }

  void _push(Widget screen) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

  static String _when(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year} ${clock(ms)}';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Informações do grupo')),
    body: SafeArea(
      child: Live<(GroupInfo?,)>(
        svc: widget.svc,
        load: () async => (await widget.svc.groupInfo(widget.conversationId),),
        builder: (context, data) {
          final g = data.$1;
          if (g == null) return Center(child: Text(widget.svc.groupNotice(widget.conversationId) ?? ''));
          return _body(context, g);
        },
      ),
    ),
  );

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: ChatColors.of(context).meta)),
  );

  Widget _body(BuildContext context, GroupInfo g) {
    final canAdmin = g.admin && !g.closed && g.blocked == null;
    final description = g.profile?.description ?? '';
    return ListView(
      children: [
        const SizedBox(height: 12),
        Center(child: Avatar(g.title, size: 80, group: true, photo: g.profile?.photo)),
        const SizedBox(height: 8),
        Text(g.title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
        if (g.officialLabel.isNotEmpty) Text('oficial: ${g.officialLabel}', textAlign: TextAlign.center),
        if (description.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
            child: Text(description, textAlign: TextAlign.center),
          ),
        if (g.closed) const NoticeLine('Este grupo foi encerrado.'),
        if (g.blocked != null) NoticeLine(g.blocked!),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        if (canAdmin) ...[
          ListTile(
            leading: const Icon(Icons.person_add_alt),
            title: const Text('Adicionar pessoas'),
            onTap: _busy
                ? null
                : () => _push(
                    AddMembersScreen(
                      svc: widget.svc,
                      conversationId: g.id,
                      members: {for (final m in g.members) m.userId},
                    ),
                  ),
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Editar nome, descrição e foto'),
            onTap: _busy ? null : () => _push(EditGroupScreen(svc: widget.svc, conversationId: g.id, profile: g.profile)),
          ),
        ],
        if (g.members.isNotEmpty) _section(g.members.length == 1 ? '1 PESSOA' : '${g.members.length} PESSOAS'),
        for (final m in g.members)
          ListTile(
            leading: Avatar(m.name),
            title: Text(m.self ? '${m.name} (você)' : m.name),
            subtitle: m.admin ? const Text('Admin') : null,
            trailing: canAdmin && !m.self
                ? PopupMenuButton<String>(
                    tooltip: 'Opções de ${m.name}',
                    enabled: !_busy,
                    onSelected: (v) => v == 'remove'
                        ? _remove(m)
                        : _run(() => widget.svc.promoteMember(widget.conversationId, m.userId)),
                    itemBuilder: (_) => [
                      if (!m.admin) const PopupMenuItem(value: 'promote', child: Text('Tornar admin')),
                      const PopupMenuItem(value: 'remove', child: Text('Remover do grupo')),
                    ],
                  )
                : null,
          ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.lock_outline),
          title: const Text('Trancar grupo'),
          onTap: () {
            Navigator.pop(context);
            widget.controller.lockConversation(g.id);
          },
        ),
        ...hiddenTiles(
          hidden: widget.svc.isHidden(g.id),
          canHide: widget.controller.secretsEnabled,
          onHide: () => hideFlow(context, widget.controller, g.id),
          onChangePassword: () => changeHiddenPasswordFlow(context, widget.controller, g.id),
          onShow: () => showHiddenFlow(context, widget.controller, g.id),
        ),
        if (!g.closed && g.blocked == null)
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Sair do grupo'),
            onTap: _busy ? null : () => _leave(g),
          ),
        if (canAdmin)
          ListTile(
            leading: const Icon(Icons.block),
            title: const Text('Encerrar grupo'),
            onTap: _busy ? null : _close,
          ),
        if (g.history.isNotEmpty) _section('HISTÓRICO DO GRUPO'),
        for (final h in g.history) ListTile(dense: true, title: Text(h.text), subtitle: Text(_when(h.at))),
        const SizedBox(height: 16),
      ],
    );
  }
}

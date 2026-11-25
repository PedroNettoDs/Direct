import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../app_controller.dart';
import '../chat/chat_service.dart';
import '../core/group_proto.dart';
import '../core/media.dart';
import 'chat_screen.dart';
import 'chat_widgets.dart';
import 'common.dart';
import 'live.dart';
import 'pick_image.dart';

/// Nome, descrição e foto, como o usuário os está editando.
class _ProfileFields extends StatefulWidget {
  const _ProfileFields({required this.name, required this.description, required this.photo, required this.onPhoto});
  final TextEditingController name;
  final TextEditingController description;
  final Uint8List? photo;
  final ValueChanged<Uint8List?> onPhoto;

  @override
  State<_ProfileFields> createState() => _ProfileFieldsState();
}

class _ProfileFieldsState extends State<_ProfileFields> {
  String? _error;

  Future<void> _pick() async {
    try {
      final bytes = await pickImageBytes(ImageSource.gallery);
      if (bytes == null) return;
      widget.onPhoto(await prepareGroupPhoto(bytes));
      if (mounted) setState(() => _error = null);
    } on Object {
      if (mounted) setState(() => _error = 'Não consegui usar essa imagem.');
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Row(
        children: [
          IconButton(
            tooltip: 'Escolher foto',
            onPressed: _pick,
            icon: Avatar('Grupo', size: 56, group: true, photo: widget.photo),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              key: const Key('group-name'),
              controller: widget.name,
              maxLength: 64,
              textCapitalization: TextCapitalization.sentences,
              enableIMEPersonalizedLearning: false,
              decoration: const InputDecoration(labelText: 'Nome do grupo', border: OutlineInputBorder()),
            ),
          ),
        ],
      ),
      if (widget.photo != null)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(onPressed: () => widget.onPhoto(null), child: const Text('Tirar a foto')),
        ),
      TextField(
        controller: widget.description,
        maxLength: 500,
        minLines: 1,
        maxLines: 3,
        textCapitalization: TextCapitalization.sentences,
        enableIMEPersonalizedLearning: false,
        decoration: const InputDecoration(labelText: 'Descrição (opcional)', border: OutlineInputBorder()),
      ),
      if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
    ],
  );
}

/// Pessoas do diretório com caixa de seleção.
class _People extends StatelessWidget {
  const _People({required this.svc, required this.selected, required this.onChanged, this.exclude = const {}});
  final ChatService svc;
  final Set<String> selected;
  final Set<String> exclude;
  final void Function(String userId, bool on) onChanged;

  @override
  Widget build(BuildContext context) => Live<List<DirectoryEntry>>(
    svc: svc,
    load: svc.directory,
    builder: (context, all) {
      final list = [for (final u in all) if (!exclude.contains(u.userId)) u];
      if (list.isEmpty) return const Center(child: Text('Ninguém para adicionar.'));
      return ListView.builder(
        itemCount: list.length,
        itemBuilder: (context, i) {
          final u = list[i];
          return CheckboxListTile(
            secondary: Avatar(u.adminLabel),
            title: Text(u.adminLabel),
            value: selected.contains(u.userId),
            onChanged: (v) => onChanged(u.userId, v == true),
          );
        },
      );
    },
  );
}

Widget _errorText(BuildContext context, String text) => Padding(
  padding: const EdgeInsets.all(12),
  child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.error)),
);

/// Criar grupo: nome, foto, descrição e pessoas.
class NewGroupScreen extends StatefulWidget {
  const NewGroupScreen({super.key, required this.controller, required this.svc});
  final AppController controller;
  final ChatService svc;

  @override
  State<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends State<NewGroupScreen> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  Uint8List? _photo;
  final _selected = <String>{};
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final name = _name.text.trim();
      if (name.isEmpty) throw UserFacingError('Dê um nome ao grupo.');
      final id = await widget.svc.createGroup(
        GroupProfile(name: name, description: _description.text.trim(), photo: _photo),
        _selected,
      );
      if (!mounted) return;
      await Navigator.pushReplacement(
        context,
        MaterialPageRoute<void>(
          builder: (_) => ChatScreen(
            controller: widget.controller,
            svc: widget.svc,
            conversationId: id,
            title: name,
            group: true,
          ),
        ),
      );
      return;
    } on Object catch (e) {
      _error = errorText(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Novo grupo'),
      actions: [TextButton(onPressed: _busy ? null : _create, child: const Text('Criar'))],
    ),
    body: SafeArea(
      child: Column(
        children: [
          if (_busy) const LinearProgressIndicator(),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: _ProfileFields(
              name: _name,
              description: _description,
              photo: _photo,
              onPhoto: (p) => setState(() => _photo = p),
            ),
          ),
          if (_error != null) _errorText(context, _error!),
          Expanded(
            child: _People(
              svc: widget.svc,
              selected: _selected,
              onChanged: (u, on) => setState(() => on ? _selected.add(u) : _selected.remove(u)),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Adicionar pessoas (só admin), com a liberação de histórico desmarcada (G2).
class AddMembersScreen extends StatefulWidget {
  const AddMembersScreen({super.key, required this.svc, required this.conversationId, required this.members});
  final ChatService svc;
  final String conversationId;
  final Set<String> members;

  @override
  State<AddMembersScreen> createState() => _AddMembersScreenState();
}

class _AddMembersScreenState extends State<AddMembersScreen> {
  final _selected = <String>{};
  bool _history = false;
  bool _busy = false;
  String? _error;

  Future<void> _add() async {
    if (_selected.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.svc.addMembers(widget.conversationId, _selected.toList(), history: _history);
      if (mounted) Navigator.pop(context);
      return;
    } on Object catch (e) {
      _error = errorText(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Adicionar pessoas'),
      actions: [TextButton(onPressed: _busy ? null : _add, child: const Text('Adicionar'))],
    ),
    body: SafeArea(
      child: Column(
        children: [
          if (_busy) const LinearProgressIndicator(),
          SwitchListTile(
            title: const Text('Mostrar o histórico para quem entra'),
            subtitle: const Text('Fica registrado e aparece para todos.'),
            value: _history,
            onChanged: (v) => setState(() => _history = v),
          ),
          if (_error != null) _errorText(context, _error!),
          Expanded(
            child: _People(
              svc: widget.svc,
              exclude: widget.members,
              selected: _selected,
              onChanged: (u, on) => setState(() => on ? _selected.add(u) : _selected.remove(u)),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Renomear: nome, descrição e foto (só admin).
class EditGroupScreen extends StatefulWidget {
  const EditGroupScreen({super.key, required this.svc, required this.conversationId, this.profile});
  final ChatService svc;
  final String conversationId;
  final GroupProfile? profile;

  @override
  State<EditGroupScreen> createState() => _EditGroupScreenState();
}

class _EditGroupScreenState extends State<EditGroupScreen> {
  late final _name = TextEditingController(text: widget.profile?.name ?? '');
  late final _description = TextEditingController(text: widget.profile?.description ?? '');
  late Uint8List? _photo = widget.profile?.photo;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.svc.editGroup(
        widget.conversationId,
        GroupProfile(name: _name.text.trim(), description: _description.text.trim(), photo: _photo),
      );
      if (mounted) Navigator.pop(context);
      return;
    } on Object catch (e) {
      _error = errorText(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Editar grupo'),
      actions: [TextButton(onPressed: _busy ? null : _save, child: const Text('Salvar'))],
    ),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            if (_busy) const LinearProgressIndicator(),
            _ProfileFields(
              name: _name,
              description: _description,
              photo: _photo,
              onPhoto: (p) => setState(() => _photo = p),
            ),
            if (_error != null) _errorText(context, _error!),
          ],
        ),
      ),
    ),
  );
}

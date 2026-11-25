import 'dart:async';

import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../app_controller.dart';
import '../bubble/platform.dart';
import '../chat/chat_service.dart';
import '../core/media.dart';
import '../data/db.dart';
import 'chat_view.dart';
import 'chat_widgets.dart';
import 'common.dart';
import 'group_info.dart';
import 'hidden.dart';
import 'image_viewer.dart';
import 'live.dart';
import 'pick_image.dart';
import 'reauth.dart';

/// Conversa 1:1 ou de grupo.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.controller,
    required this.svc,
    required this.conversationId,
    required this.title,
    this.group = false,
    this.bubbles,
  });
  final bool group;
  final AppController controller;
  final ChatService svc;
  final BubblePlatform? bubbles;
  final String conversationId;
  final String title;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _text = TextEditingController();
  String? _error;
  PeerInfo? _peer;
  late bool _locked = widget.controller.isConversationLocked(widget.conversationId);

  /// Oculta e sem a senha dela (D12): só a tela que a pede.
  late bool _shut = widget.svc.isShut(widget.conversationId);
  bool get _hidden => widget.svc.isHidden(widget.conversationId);

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onController);
    widget.svc.addListener(_loadPeer);
    widget.svc.addListener(_onHidden);
    _loadPeer();
    if (widget.group && !_shut) unawaited(widget.svc.openGroup(widget.conversationId));
    if (_locked && !_hidden) WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  void _onHidden() {
    final shut = widget.svc.isShut(widget.conversationId);
    if (shut == _shut || !mounted) return;
    if (shut) _popAbove();
    setState(() => _shut = shut);
  }

  /// Some com o que estiver por cima (foto aberta, informações).
  void _popAbove() {
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) {
      Navigator.of(context).popUntil((r) => r == route || r.isFirst);
    }
  }

  /// Nome e quantidade de pessoas do grupo, atualizados com a cadeia.
  GroupInfo? _group;

  Future<void> _loadPeer() async {
    if (widget.group) {
      final g = await widget.svc.groupInfo(widget.conversationId);
      if (mounted) setState(() => _group = g);
      return;
    }
    final p = await widget.svc.peerInfo(widget.conversationId);
    if (mounted) setState(() => _peer = p);
  }

  /// A conversa pode ser trancada com esta tela aberta (bolha no lixo).
  void _onController() {
    final locked = widget.controller.isConversationLocked(widget.conversationId);
    if (locked == _locked || !mounted) return;
    // Na oculta quem manda é a senha dela (_onHidden).
    if (locked && !_hidden) _popAbove();
    setState(() => _locked = locked);
    if (!locked && widget.group) unawaited(widget.svc.openGroup(widget.conversationId));
  }

  /// D7: só a reautenticação feita nesta conversa a reabre.
  Future<void> _unlock() async {
    if (!mounted || !widget.controller.isConversationLocked(widget.conversationId)) return;
    await askReauth(
      context,
      widget.controller,
      title: 'Conversa trancada',
      run: (p) => widget.controller.unlockConversation(widget.conversationId, password: p),
    );
  }

  Future<void> _popOut() async {
    if (Theme.of(context).platform == TargetPlatform.iOS) {
      widget.controller.openFloating(widget.conversationId);
      Navigator.of(context).pop();
      return;
    }
    final bubbles = widget.bubbles ?? BubblePlatform();
    try {
      var s = await bubbles.status();
      if (!s.notifications) {
        await bubbles.requestNotifications();
        s = await bubbles.status();
      }
      if (!mounted) return;
      if (!s.notifications || !s.bubbles) {
        await _explainBubbles(bubbles, s);
        return;
      }
      // Nome de grupo é conteúdo cifrado: não vai para a notificação do sistema (D11).
      await bubbles.show(widget.controller, widget.conversationId, widget.group ? 'Grupo' : widget.title);
    } on Object {
      if (mounted) setState(() => _error = 'Não foi possível abrir o pop-up.');
    }
  }

  Future<void> _explainBubbles(BubblePlatform bubbles, BubbleStatus s) => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Ative as bolhas'),
      content: Text(
        !s.notifications
            ? 'O pop-up usa as notificações do Android. Nos ajustes, permita as notificações do Direct, '
                  'depois toque em "Bolhas" e escolha "Todas as conversas podem aparecer em balões".'
            : 'As bolhas estão desligadas. Nos ajustes, escolha "Todas as conversas podem aparecer em balões". '
                  'Se a opção não aparecer, ative "Balões" em Ajustes > Notificações.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Agora não')),
        FilledButton(
          onPressed: () {
            Navigator.pop(ctx);
            bubbles.openSettings();
          },
          child: const Text('Abrir ajustes'),
        ),
      ],
    ),
  );

  @override
  void dispose() {
    widget.controller.removeListener(_onController);
    widget.svc.removeListener(_loadPeer);
    widget.svc.removeListener(_onHidden);
    // Saiu da conversa: a senha dela será pedida de novo.
    widget.svc.closeHidden(widget.conversationId);
    _text.dispose();
    super.dispose();
  }

  /// [like]: o coração envia direto, sem passar pelo campo.
  Future<void> _send([String? like]) async {
    final t = like ?? _text.text;
    if (t.trim().isEmpty) return;
    try {
      await widget.svc.send(widget.conversationId, t);
      if (like == null) _text.clear();
      setState(() => _error = null);
    } on Object catch (e) {
      setState(() => _error = errorText(e));
    }
  }

  Future<void> _attach(ImageSource source) async {
    try {
      final bytes = await pickImageBytes(source);
      if (bytes == null) return;
      setState(() => _error = 'Preparando a imagem…');
      final prepared = await prepareImage(bytes);
      await widget.svc.sendImage(widget.conversationId, prepared);
      if (mounted) setState(() => _error = null);
    } on FormatException {
      if (mounted) setState(() => _error = 'Não consegui ler essa imagem.');
    } on Object catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  void _openImage(ChatMessage m) => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => ImageViewerScreen(svc: widget.svc, message: m)),
  );

  ChatItem _item(ChatMessage m, {String senderId = '', String? sender, bool thumbLocked = false}) {
    ImageRef? ref;
    if (m.kind == kindImage && m.state == msgOk && m.body != null) {
      try {
        ref = ImageRef.fromJson(m.body!, allowPendingBlob: true);
      } on Object {
        // sem miniatura
      }
    }
    return ChatItem(
      id: m.id,
      mine: m.mine,
      state: m.state,
      sentAt: m.sentAt,
      thumb: ref?.thumb,
      aspect: ref == null ? null : ref.width / ref.height,
      senderId: senderId,
      senderName: m.mine ? '' : sender ?? widget.title,
      thumbLocked: thumbLocked,
      // De imagem o `body` leva a chave: nunca vai para a tela.
      text: switch (m.state) {
        msgWaitingKey => 'Aguardando chave…',
        msgUnsupported => 'Mensagem não suportada nesta versão',
        msgNotice => m.body ?? '',
        _ => m.kind == kindImage ? (ref == null ? 'Foto' : '') : (m.body ?? ''),
      },
    );
  }

  Future<List<GroupLine>> _lines() async => widget.group
      ? widget.svc.groupLines(widget.conversationId)
      : [for (final m in await widget.svc.messages(widget.conversationId)) GroupLine(m)];

  void _info() {
    if (widget.group) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => GroupInfoScreen(
            controller: widget.controller,
            svc: widget.svc,
            conversationId: widget.conversationId,
          ),
        ),
      );
      return;
    }
    showContactSheet(
      context,
    name: widget.title,
    displayName: _peer?.displayName ?? '',
    status: _peer?.status ?? '',
    deviceCodes: _peer?.deviceCodes ?? const [],
      onLock: () => widget.controller.lockConversation(widget.conversationId),
      extra: (sheet) {
        void then(Future<void> Function(BuildContext, AppController, String) flow) {
          Navigator.pop(sheet);
          flow(context, widget.controller, widget.conversationId);
        }

        return hiddenTiles(
          hidden: _hidden,
          canHide: widget.controller.secretsEnabled,
          onHide: () => then(hideFlow),
          onChangePassword: () => then(changeHiddenPasswordFlow),
          onShow: () => then(showHiddenFlow),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_shut) {
      return HiddenGate(
        title: widget.title,
        group: widget.group,
        open: (password) => widget.controller.openHiddenConversation(widget.conversationId, password),
      );
    }
    if (_locked && !_hidden) {
      // De grupo trancado o nome já saiu da memória.
      return LockedChatView(title: widget.group ? 'Grupo' : widget.title, onUnlock: _unlock, group: widget.group);
    }
    final group = _group;
    final status = !widget.group
        ? _peer?.status ?? ''
        : group == null || group.blocked != null
        ? ''
        : [
            if (group.officialLabel.isNotEmpty) 'oficial: ${group.officialLabel}',
            group.members.length == 1 ? '1 pessoa' : '${group.members.length} pessoas',
          ].join(' · ');
    return Scaffold(
      appBar: ChatHeader(
        title: group?.title ?? widget.title,
        status: status,
        group: widget.group,
        photo: group?.profile?.photo,
        onPopOut: _hidden ? null : _popOut,
        onInfo: _info,
      ),
      body: SafeArea(
        child: Column(
          children: [
            StatusBanner(svc: widget.svc),
            Expanded(
              child: Live<List<GroupLine>>(
                svc: widget.svc,
                load: _lines,
                builder: (context, lines) => lines.isEmpty
                    ? Center(
                        child: Text(
                          widget.group
                              ? widget.svc.groupNotice(widget.conversationId) ?? 'Sem mensagens. Diga olá.'
                              : 'Sem mensagens. Diga olá.',
                          textAlign: TextAlign.center,
                        ),
                      )
                    : MessageList(
                        now: widget.svc.now(),
                        showSenderNames: widget.group,
                        items: [
                          for (final l in lines)
                            widget.group
                                ? _item(l.message, senderId: l.senderId, sender: l.senderName, thumbLocked: l.thumbLocked)
                                : _item(l.message),
                        ],
                        onRetry: (id) => widget.svc.retry(id),
                        onOpenImage: (id) => _openImage(lines.firstWhere((l) => l.message.id == id).message),
                        onReachTop: widget.group && widget.svc.hasOlder(widget.conversationId)
                            ? () => unawaited(widget.svc.loadOlder(widget.conversationId).catchError((Object _) {}))
                            : null,
                      ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            ListenableBuilder(
              listenable: widget.svc,
              builder: (context, _) {
                final notice = widget.group ? widget.svc.groupNotice(widget.conversationId) : null;
                if (notice != null) return NoticeLine(notice);
                return Composer(
                  controller: _text,
                  onSend: _send,
                  onLike: () => _send(Composer.like),
                  onCamera: () => _attach(ImageSource.camera),
                  onGallery: () => _attach(ImageSource.gallery),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

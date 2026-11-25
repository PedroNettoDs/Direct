
import 'package:flutter/foundation.dart';

import '../app_controller.dart';
import '../chat/chat_service.dart';
import '../core/bio.dart';
import '../core/media.dart';
import '../core/vault.dart';
import '../data/db.dart';
import '../ui/live.dart' show statusText;

/// O que o mini-chat mostra: trava do app, trava da conversa ou a conversa.
/// [hidden]: conversa oculta (D12) não abre no pop-up.
enum MiniPhase { appLocked, chatLocked, ready, hidden }

/// Mensagem já pronta para a tela. Sem chaves: de imagem vai só a miniatura.
class MiniMessage {
  const MiniMessage({
    required this.id,
    required this.mine,
    required this.state,
    required this.sentAt,
    required this.text,
    this.thumb,
    this.senderId = '',
    this.sender = '',
    this.thumbLocked = false,
  });

  /// Só em grupo.
  final String senderId;
  final String sender;
  final bool thumbLocked;
  final int id;
  final bool mine;
  final int state;
  final int sentAt;
  final String text;
  final Uint8List? thumb;

  Map<String, Object?> toMap() => {
    'id': id,
    'mine': mine,
    'state': state,
    'at': sentAt,
    'text': text,
    'thumb': thumb,
    'senderId': senderId,
    'sender': sender,
    'thumbLocked': thumbLocked,
  };

  static MiniMessage fromMap(Map<Object?, Object?> m) => MiniMessage(
    id: m['id'] as int,
    mine: m['mine'] as bool,
    state: m['state'] as int,
    sentAt: m['at'] as int,
    text: m['text'] as String,
    thumb: m['thumb'] as Uint8List?,
    senderId: m['senderId'] as String,
    sender: m['sender'] as String,
    thumbLocked: m['thumbLocked'] as bool,
  );
}

class MiniState {
  const MiniState(
    this.phase, {
    this.title = '',
    this.banner = '',
    this.bio = false,
    this.messages = const [],
    this.group = false,
  });
  final bool group;
  final MiniPhase phase;
  final String title;
  final String banner;

  /// Digital ativada.
  final bool bio;
  final List<MiniMessage> messages;

  Map<String, Object?> toMap() => {
    'phase': phase.index,
    'title': title,
    'banner': banner,
    'bio': bio,
    'group': group,
    'messages': [for (final m in messages) m.toMap()],
  };

  static MiniState fromMap(Map<Object?, Object?> m) => MiniState(
    MiniPhase.values[m['phase'] as int],
    title: m['title'] as String,
    banner: m['banner'] as String,
    bio: m['bio'] as bool,
    group: m['group'] as bool,
    messages: [for (final x in m['messages'] as List) MiniMessage.fromMap(x as Map<Object?, Object?>)],
  );
}

/// Dados do mini-chat. Os métodos de destravar devolvem null se deu certo,
/// texto vazio se o usuário desistiu, ou a mensagem de erro.
abstract class MiniBackend implements Listenable {
  Future<MiniState> load(String conversationId);

  /// Sem [password], usa a digital.
  Future<String?> unlockApp({String? password});
  Future<String?> unlockChat(String conversationId, {String? password});
  Future<String?> send(String conversationId, String text);
  Future<void> retry(int rowId);

  /// Toque na bolha: conta como interação (tranca por inatividade).
  Future<void> touch();
}

/// Direto no [AppController] (iOS, e o lado "core" da bolha Android).
class LocalMiniBackend implements MiniBackend {
  LocalMiniBackend(this.c);
  final AppController c;

  late final Listenable _changes = Listenable.merge([c, c.chatChanges]);

  @override
  void addListener(VoidCallback l) => _changes.addListener(l);
  @override
  void removeListener(VoidCallback l) => _changes.removeListener(l);

  static const maxMessages = 60;

  @override
  Future<MiniState> load(String conversationId) async {
    // Só confere o prazo: carregar não conta como interação (chega mensagem, recarrega).
    await c.expireIdleBubbles();
    final svc = c.chat;
    if (!c.sessionOpen || svc == null || !_served(conversationId)) {
      return MiniState(MiniPhase.appLocked, bio: c.bioEnabled);
    }
    // Nem nome, nem conteúdo, nem digital.
    if (c.isHidden(conversationId)) return const MiniState(MiniPhase.hidden);
    final group = svc.isGroup(conversationId);
    if (group && !c.isConversationLocked(conversationId)) await svc.openGroup(conversationId);
    final title = await svc.peerTitle(conversationId);
    // Conversa trancada: nenhum conteúdo sai daqui.
    if (c.isConversationLocked(conversationId)) {
      return MiniState(MiniPhase.chatLocked, title: title, bio: c.bioEnabled, group: group);
    }
    final all = group
        ? [
            for (final l in await svc.groupLines(conversationId))
              _mini(l.message, senderId: l.senderId, sender: l.senderName, thumbLocked: l.thumbLocked),
          ]
        : [for (final m in await svc.messages(conversationId)) _mini(m)];
    final status = statusText(svc.status);
    return MiniState(
      MiniPhase.ready,
      title: title,
      banner: group && status.isEmpty ? svc.groupNotice(conversationId) ?? '' : status,
      bio: c.bioEnabled,
      group: group,
      messages: all.sublist(all.length > maxMessages ? all.length - maxMessages : 0),
    );
  }

  /// Com a interface trancada, a ponte só serve conversa que tem bolha.
  bool _served(String conversationId) => c.stage != Stage.locked || c.bubbles.contains(conversationId);

  static MiniMessage _mini(ChatMessage m, {String senderId = '', String sender = '', bool thumbLocked = false}) {
    Uint8List? thumb;
    if (m.kind == kindImage && m.state == msgOk && m.body != null) {
      try {
        thumb = ImageRef.fromJson(m.body!, allowPendingBlob: true).thumb;
      } on Object {
        // sem miniatura
      }
    }
    return MiniMessage(
      id: m.id,
      mine: m.mine,
      state: m.state,
      sentAt: m.sentAt,
      thumb: thumb,
      senderId: senderId,
      sender: sender,
      thumbLocked: thumbLocked,
      text: switch (m.state) {
        msgWaitingKey => 'Aguardando chave…',
        msgUnsupported => 'Mensagem não suportada nesta versão',
        _ => m.kind == kindImage ? (thumb == null ? 'Foto' : '') : (m.body ?? ''),
      },
    );
  }

  static String _wrong(Duration wait) =>
      wait > Duration.zero ? 'Senha errada. Aguarde ${wait.inSeconds + 1} s.' : 'Senha errada.';

  @override
  Future<String?> unlockApp({String? password, Uint8List? master}) async {
    if (password == null && master == null) return '';
    try {
      await c.openSession(password: password, master: master);
      return null;
    } on WrongPassword catch (e) {
      return _wrong(e.retryAfter);
    } on LockedOut catch (e) {
      return _wrong(e.retryAfter);
    } on BioInvalidated {
      return 'A digital mudou. Use a senha.';
    } on Object {
      return 'Não foi possível abrir os dados locais.';
    }
  }

  @override
  Future<String?> unlockChat(String conversationId, {String? password, Uint8List? master}) async {
    if (master != null) {
      return await c.unlockConversationWithMaster(conversationId, master) ? null : 'Não confere.';
    }
    final r = await c.unlockConversation(conversationId, password: password);
    if (r.ok) return null;
    if (r.retryAfter != null) return _wrong(r.retryAfter!);
    if (r.invalidated) return 'A digital mudou. Use a senha.';
    return r.canceled ? '' : 'Não confere.';
  }

  @override
  Future<String?> send(String conversationId, String text) async {
    await c.touchBubble();
    final svc = c.chat;
    if (svc == null || c.isHidden(conversationId) || c.isConversationLocked(conversationId) || !_served(conversationId)) {
      return 'Conversa trancada.';
    }
    try {
      await svc.send(conversationId, text);
      return null;
    } on UserFacingError catch (e) {
      return e.message;
    }
  }

  @override
  Future<void> retry(int rowId) async {
    await c.touchBubble();
    await c.chat?.retry(rowId);
  }

  @override
  Future<void> touch() => c.touchBubble();
}

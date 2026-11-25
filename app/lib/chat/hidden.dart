part of 'chat_service.dart';

// Conversas ocultas (D12, docs/ocultas.md). Cada uma tem um par X25519: o que
// é conteúdo vai para o banco selado para a pública; a privada só existe aqui,
// em memória, entre a senha certa e a saída da conversa.

extension HiddenChats on ChatService {
  bool isHidden(String id) => db.hiddenIds.contains(id);

  /// Oculta e ainda sem a senha: nada dela pode ser aberto.
  bool isShut(String id) => _shut(id);

  bool _shut(String id) => db.hiddenIds.contains(id) && !_hiddenKeys.containsKey(id);

  void _requireOpen(String id) {
    if (_shut(id)) throw UserFacingError('Conversa oculta. Abra com a senha dela.');
  }

  Future<HiddenConversation?> hiddenRow(String id) =>
      (db.select(db.hiddenConversations)..where((t) => t.conversationId.equals(id))).getSingleOrNull();

  // ---- selar e abrir ----

  /// Chamar dentro da mesma transação da escrita: a marca é lida do banco.
  Future<Uint8List> _sealBytes(String id, Uint8List plain) async {
    final row = await hiddenRow(id);
    return row == null ? plain : _seal(row.pub, plain);
  }

  Future<String?> _sealText(String id, String? text) async {
    if (text == null) return null;
    final row = await hiddenRow(id);
    return row == null ? text : b64uEncode(_seal(row.pub, Uint8List.fromList(utf8.encode(text))));
  }

  Uint8List _seal(Uint8List pub, Uint8List plain) => crypto.c.sodium.crypto.box.seal(message: plain, publicKey: pub);

  Uint8List _unseal(Uint8List sk, Uint8List sealed) {
    final key = crypto.c.sodium.secureCopy(sk);
    try {
      return crypto.c.sodium.crypto.box.sealOpen(cipherText: sealed, publicKey: crypto.c.x25519Pub(sk), secretKey: key);
    } finally {
      key.dispose();
    }
  }

  /// Fora das ocultas devolve o próprio valor; oculta e fechada, null.
  Uint8List? _openBytes(String id, Uint8List stored) {
    if (!isHidden(id)) return stored;
    final sk = _hiddenKeys[id];
    return sk == null ? null : _unseal(sk, stored);
  }

  String? _openText(String id, String? stored) {
    if (stored == null || !isHidden(id)) return stored;
    final sk = _hiddenKeys[id];
    return sk == null ? null : utf8.decode(_unseal(sk, b64uDecode(stored)));
  }

  // ---- esconder, abrir, fechar, mostrar ----

  /// Regrava cada corpo, anexo e chave de época da conversa passando por [body]
  /// e [bytes]. Dentro de uma transação.
  Future<void> _rewrite(
    String id,
    String Function(String) body,
    Uint8List Function(Uint8List) bytes,
  ) async {
    for (final m in await (db.select(db.chatMessages)..where((t) => t.conversationId.equals(id))).get()) {
      if (m.body == null) continue;
      await (db.update(db.chatMessages)..where((t) => t.id.equals(m.id)))
          .write(ChatMessagesCompanion(body: Value(body(m.body!))));
    }
    for (final a in await (db.select(db.attachments)..where((t) => t.conversationId.equals(id))).get()) {
      if (a.data == null) continue;
      await (db.update(db.attachments)
            ..where((t) => t.conversationId.equals(id) & t.messageId.equals(a.messageId)))
          .write(AttachmentsCompanion(data: Value(bytes(a.data!))));
    }
    for (final e in await (db.select(db.epochKeys)..where((t) => t.conversationId.equals(id))).get()) {
      await (db.update(db.epochKeys)..where((t) => t.conversationId.equals(id) & t.epoch.equals(e.epoch)))
          .write(EpochKeysCompanion(key: Value(bytes(e.key))));
    }
  }

  /// Marca a conversa e sela o que já está no banco, tudo numa transação. Ela
  /// fica fechada. De grupo não há conteúdo no banco (D11): é marca e senha.
  Future<void> hide(String id, Uint8List pub, String wrapped) => _locked(() async {
    if (isHidden(id)) return;
    if (!_groupIds.contains(id) && await _conv(id) == null) throw UserFacingError('Conversa não encontrada.');
    await db.transaction(() async {
      await db.into(db.hiddenConversations).insert(
        HiddenConversationsCompanion.insert(conversationId: id, pub: pub, wrapped: wrapped),
      );
      await _rewrite(
        id,
        (text) => b64uEncode(_seal(pub, Uint8List.fromList(utf8.encode(text)))),
        (plain) => _seal(pub, plain),
      );
    });
    db.hiddenIds.add(id);
    forgetGroup(id);
    // Reescreve o arquivo: nada do texto aberto sobra em página livre.
    try {
      await db.customStatement('VACUUM');
    } on Object catch (e) {
      debugPrint('[direct] vacuum: ${e.runtimeType}'); // secure_delete já zerou
    }
    onPurge?.call();
    _changed();
  });

  /// [sk] é a privada que a senha certa abriu; o serviço fica com ela até
  /// [closeHidden].
  Future<void> openHidden(String id, Uint8List sk) async {
    _hiddenKeys[id] = Uint8List.fromList(sk);
    _changed();
    // O que chegou fechado é decifrado agora, e o que estava por enviar sai.
    await _locked(() async {
      try {
        await _retryWaiting();
        if (_synced) await _flushPending();
      } on Object catch (e) {
        debugPrint('[direct] oculta: ${e.runtimeType}');
      }
    });
    if (_groupIds.contains(id)) await openGroup(id);
    _changed();
  }

  /// Esquece a chave: a senha será pedida de novo.
  void closeHidden(String id) {
    final sk = _hiddenKeys.remove(id);
    if (sk == null) return;
    sk.fillRange(0, sk.length, 0);
    forgetGroup(id);
    onPurge?.call();
    // Quem chama pode estar desmontando a tela: avisa depois.
    scheduleMicrotask(_changed);
  }

  void closeAllHidden() {
    for (final id in _hiddenKeys.keys.toList()) {
      closeHidden(id);
    }
  }

  /// Nova senha: só a embrulhada muda.
  Future<void> rewrapHidden(String id, Future<String> Function(Uint8List sk) wrap) async {
    final sk = _hiddenKeys[id];
    if (sk == null) throw UserFacingError('Abra a conversa com a senha dela.');
    final wrapped = await wrap(Uint8List.fromList(sk));
    await (db.update(db.hiddenConversations)..where((t) => t.conversationId.equals(id)))
        .write(HiddenConversationsCompanion(wrapped: Value(wrapped)));
  }

  /// "Mostrar conversa": desfaz o esconder. Só com ela aberta.
  Future<void> unhide(String id) => _locked(() async {
    if (!isHidden(id)) return;
    final sk = _hiddenKeys[id];
    if (sk == null) throw UserFacingError('Abra a conversa com a senha dela.');
    await db.transaction(() async {
      await _rewrite(
        id,
        (stored) => utf8.decode(_unseal(sk, b64uDecode(stored))),
        (sealed) => _unseal(sk, sealed),
      );
      await (db.delete(db.hiddenConversations)..where((t) => t.conversationId.equals(id))).go();
    });
    db.hiddenIds.remove(id);
    _hiddenKeys.remove(id)?.fillRange(0, 32, 0);
    await _retryWaiting();
    _changed();
  });

  /// As ocultas, para a lista revelada pelos 7 toques: nome, sem prévia. Grupo
  /// não foi aberto, então leva o nome provisório (o cifrado exige buscar chave).
  Future<List<ConversationView>> hiddenConversations() async {
    final out = <ConversationView>[
      for (final g in await _groupViews())
        if (isHidden(g.conversationId))
          ConversationView(
            conversationId: g.conversationId,
            peerUserId: '',
            title: g.title,
            subtitle: 'Grupo',
            lastText: '',
            lastAt: 0,
            isGroup: true,
          ),
    ];
    for (final c in await db.select(db.conversations).get()) {
      if (!isHidden(c.conversationId)) continue;
      out.add(
        ConversationView(
          conversationId: c.conversationId,
          peerUserId: c.peerUserId,
          title: await peerTitle(c.conversationId),
          subtitle: '',
          lastText: '',
          lastAt: 0,
        ),
      );
    }
    out.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return out;
  }
}

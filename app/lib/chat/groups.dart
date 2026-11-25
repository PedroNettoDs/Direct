part of 'chat_service.dart';

// Grupos (docs/protocolo-grupos.md). Nada daqui vai para o disco, salvo a
// âncora da cadeia (§2.7, §7.6): chaves, cadeia, nome, mensagens e imagens vivem
// só em memória, somem ao trancar o app, ao cair a conexão e, por grupo, ao
// trancar o grupo.

/// Recorte de "o mais novo": o servidor devolve as mensagens antes deste `seq`.
const _newest = 9007199254740991;

/// Um registro feito por aparelho cadastrado há menos disto é destacado (§12).
const _freshDevice = Duration(days: 7);

/// Linha do histórico de um grupo, pronta para a tela. Aviso de sistema tem
/// `message.state == msgNotice`.
class GroupLine {
  GroupLine(this.message, {this.senderId = '', this.senderName = '', this.thumbLocked = false});
  final ChatMessage message;
  final String senderId;
  final String senderName;

  /// Imagem de remetente sem acesso: cadeado no lugar da miniatura (§7.5).
  final bool thumbLocked;
}

class GroupMemberView {
  GroupMemberView(this.userId, this.name, {required this.admin, required this.self});
  final String userId;
  final String name;
  final bool admin;
  final bool self;
}

/// Tela de informações do grupo.
class GroupInfo {
  GroupInfo({
    required this.id,
    required this.title,
    required this.officialLabel,
    required this.profile,
    required this.members,
    required this.history,
    required this.admin,
    required this.closed,
    required this.blocked,
  });
  final String id;
  final String title;

  /// `admin_label` de grupo criado pelo moderador, vazio nos demais.
  final String officialLabel;
  final GroupProfile? profile;
  final List<GroupMemberView> members;

  /// A cadeia verificada como histórico legível, do mais novo ao mais antigo.
  final List<({String text, int at})> history;
  final bool admin;
  final bool closed;
  final String? blocked;
}

class _Epoch {
  _Epoch(this.key, this.recipients, this.chainN);
  final Uint8List key;
  final List<String> recipients;
  final int chainN;
}

class _GroupMsg {
  _GroupMsg({
    required this.rowId,
    required this.messageId,
    required this.senderDeviceId,
    required this.senderUserId,
    required this.sentAt,
    required this.createdAt,
    required this.state,
    this.seq,
    this.epoch = 0,
    this.body,
    this.kind = kindText,
    this.mine = false,
    this.ciphertextLen = 272,
  });
  final int rowId; // negativo, para não colidir com o banco
  final String messageId;
  final String senderDeviceId;
  String senderUserId;
  final int sentAt;
  int createdAt;
  int state;
  int? seq;
  int epoch;
  String? body;
  int kind;
  bool mine;
  int ciphertextLen;

  /// À espera da chave.
  WireMessage? raw;

  /// Imagem cifrada de uma mensagem ainda por enviar: sobrevive à reconexão.
  Uint8List? blob;
  bool thumbLocked = false;
}

class _Group {
  _Group(this.info, this.state) : latestEpoch = info.latestEpoch;
  ConvInfo info;
  GroupState state;
  int latestEpoch;
  final epochs = <int, _Epoch>{};

  /// Bytes exatos dos metadados, para recifrar sem trocar o nome (§6.2).
  Uint8List? metaBytes;
  GroupProfile? profile;
  final messages = <String, _GroupMsg>{};
  final access = <int, AccessEvent>{};

  /// Imagens cifradas, por mensagem.
  final blobs = <String, Uint8List>{};
  bool loaded = false;
  bool hasOlder = false;
  bool resyncedEpochs = false;

  /// Alerta que bloqueia o grupo: nada de conteúdo (§11.10).
  String? blocked;

  String get id => info.conversationId;

  /// Apaga chaves e conteúdo; a cadeia verificada fica.
  void wipe() {
    for (final e in epochs.values) {
      e.key.fillRange(0, e.key.length, 0);
    }
    epochs.clear();
    metaBytes = null;
    profile = null;
    messages.clear();
    access.clear();
    blobs.clear();
    loaded = false;
    resyncedEpochs = false;
  }
}

const _badChain = 'A lista de membros deste grupo não confere.';
const _hiddenChain = 'O servidor escondeu ou trocou registros deste grupo.';

extension ChatGroups on ChatService {
  /// Há chave fixada e conexão: sem internet, só 1:1.
  bool get groupsAvailable => modPub != null && (status == ChatStatus.online || status == ChatStatus.connecting && _groups.isNotEmpty);

  /// A chave do moderador acabou de ser fixada.
  void enableGroups(Uint8List mod) {
    modPub = mod;
    final l = _link;
    if (l != null) {
      _planned = true;
      unawaited(l.close(1000)); // sincroniza de novo, agora com grupos
    }
    _changed();
  }

  bool isGroup(String conversationId) => _groupIds.contains(conversationId);

  /// Trancada (D7) ou oculta e fechada (D12): nada do grupo é buscado nem mostrado.
  bool _barred(String id) => isLocked(id) || _shut(id);

  Future<bool> _isKnownGroup(String id) async =>
      _groupIds.contains(id) ||
      await (db.select(db.groupAnchors)..where((t) => t.conversationId.equals(id))).getSingleOrNull() != null;

  void _wipeGroups() {
    if (_groups.isEmpty) return;
    for (final g in _groups.values) {
      g.wipe();
    }
    _groups.clear();
    onPurge?.call();
    _changed();
  }

  void _dropOutOfScope() {
    for (final id in _groups.keys.toList()) {
      if (!_inScope(id)) {
        _groups.remove(id)!.wipe();
        _outbox.remove(id);
        onPurge?.call();
      }
    }
  }

  /// D7 em grupo: trancar ou fechar a bolha apaga da memória.
  void forgetGroup(String id) {
    _opened.remove(id);
    _outbox.remove(id);
    final g = _groups[id];
    if (g == null) return;
    g.wipe();
    onPurge?.call();
    _changed();
  }

  void _drop(String id) {
    _groups.remove(id)?.wipe();
    _outbox.remove(id);
    _opened.remove(id);
    onPurge?.call();
  }

  void _block(_Group g, String why) {
    _alert('grupo bloqueado: $why');
    g.wipe();
    g.blocked = why;
    _outbox.remove(g.id);
    onPurge?.call();
  }

  /// Nada de conteúdo entra num grupo bloqueado, trancado ou depois de parar.
  bool _closedTo(_Group g) => !_running || g.blocked != null || _barred(g.id);

  // ---- cadeia (§2) ----

  /// Certificados dos autores: um registro antigo pode ser de aparelho que saiu.
  Future<ChainKeys> _chainKeys(Iterable<SignedChange> records) async {
    final certs = <String, DeviceCert>{};
    for (final r in records) {
      final c = GroupChange.decode(r.bytes);
      if (c == null || c.byModerator || certs.containsKey(c.authorDeviceId)) continue;
      final cert = await _cert(c.authorDeviceId);
      if (cert != null) certs[cert.deviceId] = cert;
    }
    return ChainKeys(serverSignPub: serverSignPub, modPub: modPub, certs: certs);
  }

  /// Aplica registros novos e confere a âncora (§2.7, passos 1 e 2). Devolve
  /// false e bloqueia o grupo se não conferir.
  Future<bool> _applyChain(_Group g, List<SignedChange> records) async {
    try {
      final keys = await _chainKeys(records);
      for (final r in records) {
        g.state.apply(r, keys);
      }
    } on ChainError catch (e) {
      _alert('$e');
      _block(g, _badChain);
      return false;
    }
    final anchor = await (db.select(db.groupAnchors)..where((t) => t.conversationId.equals(g.id))).getSingleOrNull();
    if (anchor != null) {
      final h = g.state.hashAt(anchor.n);
      if (h == null || !bytesEqual(h, anchor.hash)) {
        _block(g, _hiddenChain);
        return false;
      }
    }
    if (g.state.n > (anchor?.n ?? 0)) {
      await db.into(db.groupAnchors).insertOnConflictUpdate(
        GroupAnchorsCompanion.insert(conversationId: g.id, n: g.state.n, hash: g.state.head),
      );
    }
    return true;
  }

  /// Busca do último registro conhecido em diante: o hash encadeado faz dele
  /// prova de que o prefixo todo é o mesmo.
  Future<bool> _refreshChain(_Group g) async {
    if (g.blocked != null) return false;
    final known = g.state.n;
    var records = await _authed((t) => api.groupChanges(t, g.id, known == 0 ? 0 : known - 1));
    if (known > 0) {
      if (records.isEmpty || !bytesEqual(changeHash(crypto.c, records.first), g.state.head)) {
        _block(g, _hiddenChain);
        return false;
      }
      records = records.sublist(1);
    }
    return _applyChain(g, records);
  }

  // ---- épocas (§5) ----

  /// §9.8 com a validação de §5.2.
  Future<void> _addEpoch(_Group g, EpochItem it) async {
    if (_closedTo(g) || g.epochs.containsKey(it.epoch)) return;
    if (it.epoch > g.latestEpoch) g.latestEpoch = it.epoch;
    final chainN = it.chainN, chainHash = it.chainHash;
    if (chainN == null || chainHash == null) return _alert('época de grupo sem posição na cadeia');
    if (chainN > g.state.n && !await _refreshChain(g)) return;
    final creator = await _cert(it.creatorDeviceId);
    if (creator == null) return _alert('época com criador desconhecido');

    final mine = it.recipients.contains(selfDeviceId);
    final owners = <String>[];
    if (mine) {
      for (final r in it.recipients) {
        final cert = await _cert(r);
        if (cert == null) return _alert('época com destinatário desconhecido');
        owners.add(cert.userId);
      }
    }
    final code = g.state.checkEpoch(
      chainN: chainN,
      chainHash: chainHash,
      creatorUserId: creator.userId,
      recipientOwners: owners,
    );
    if (code == 'alvo') return _block(g, 'Uma chave deste grupo foi dada a quem não é membro.');
    if (code != null) return _alert('época ${it.epoch} descartada: $code');
    if (!mine && !g.state.mayRewrap(selfUserId, chainN)) {
      return _alert('época ${it.epoch} reembrulhada sem permissão da cadeia');
    }
    // `chain_n` não diminui de uma época para a seguinte.
    for (final e in g.epochs.entries) {
      if (e.key < it.epoch ? e.value.chainN > chainN : e.value.chainN < chainN) {
        return _alert('época ${it.epoch} descartada: posição fora de ordem');
      }
    }
    try {
      final k = openGroupEpoch(
        crypto,
        conversationId: g.id,
        epoch: it.epoch,
        creator: creator,
        commitment: it.commitment,
        recipients: it.recipients,
        signature: it.signature,
        wrappedKey: it.wrappedKey,
        escrowPub: escrowPub,
        chainN: chainN,
        chainHash: chainHash,
        self: keys,
      );
      if (_closedTo(g)) return; // trancado enquanto buscava certificados
      g.epochs[it.epoch] = _Epoch(k, it.recipients, chainN);
    } on ChatCryptoException catch (e) {
      _alert('época ${it.epoch} descartada: ${e.message}');
    }
  }

  Future<void> _loadEpochs(_Group g) async {
    final items = await _authed((t) => api.conversationEpochs(t, g.id));
    items.sort((a, b) => a.wrapId.compareTo(b.wrapId));
    for (final it in items) {
      if (it.conversationId == g.id) await _addEpoch(g, it);
    }
  }

  // ---- metadados (§6) ----

  bool _metaCurrent(_Group g) =>
      g.metaBytes != null && bytesEqual(metaCommitOf(crypto.c, g.id, g.metaBytes!), g.state.metaCommit);

  /// Abre o primeiro item do compromisso atual que tiver chave aqui.
  void _openMeta(_Group g, Iterable<GroupMeta> items) {
    if (_closedTo(g) || _metaCurrent(g)) return;
    if (!g.state.hasMeta) return;
    for (final m in items) {
      final epoch = g.epochs[m.epoch];
      if (epoch == null || !bytesEqual(m.metaCommit, g.state.metaCommit)) continue;
      try {
        g.metaBytes = openGroupMeta(crypto, key: epoch.key, conversationId: g.id, meta: m, commit: g.state.metaCommit);
        g.profile = GroupProfile.decode(g.metaBytes!);
      } on ChatCryptoException catch (e) {
        _alert(e.message);
        _block(g, 'Os dados deste grupo não conferem.');
      }
      return;
    }
  }

  Future<void> _loadMeta(_Group g) async {
    if (g.blocked != null) return;
    if (!_metaCurrent(g)) {
      g.metaBytes = null;
      g.profile = null;
    }
    if (g.state.hasMeta && g.metaBytes == null) _openMeta(g, await _authed((t) => api.groupMeta(t, g.id)));
  }

  // ---- carregar ----

  Future<void> _syncGroups(List<ConvInfo> list) async {
    if (modPub == null) return _wipeGroups();
    final fresh = <String, _Group>{};
    for (final ci in list) {
      if (!ci.isGroup || !_inScope(ci.conversationId)) continue;
      try {
        final g = await _loadGroup(ci);
        if (g != null) fresh[g.id] = g;
      } on ApiException catch (e) {
        _alert('grupo não carregado: ${e.code}');
      } on FormatException {
        _alert('grupo não carregado: resposta inválida');
      } on TypeError {
        _alert('grupo não carregado: resposta inválida');
      }
    }
    if (!_running) {
      for (final g in fresh.values) {
        g.wipe();
      }
      return;
    }
    for (final old in _groups.values) {
      old.wipe();
    }
    _groups
      ..clear()
      ..addAll(fresh);
    onPurge?.call();
    _changed();
  }

  /// Verifica a cadeia e, se o grupo não está trancado, busca chaves, nome e
  /// mensagens. null = não somos membros.
  Future<_Group?> _loadGroup(ConvInfo ci) async {
    final g = _Group(ci, GroupState(crypto.c, ci.conversationId));
    if (!await _applyChain(g, await _authed((t) => api.groupChanges(t, g.id, 0)))) return g;
    if (!g.state.isMember(selfUserId)) return null;
    await _fillGroup(g, full: _opened.contains(g.id));
    return g;
  }

  /// [full]: histórico recente; senão só a última mensagem, para a lista.
  Future<void> _fillGroup(_Group g, {required bool full}) async {
    if (g.blocked != null || _barred(g.id)) return;
    if (g.epochs.isEmpty) await _loadEpochs(g);
    await _loadMeta(g);
    if (g.blocked != null) return;
    if (!full) {
      await _loadHistory(g, before: _newest, limit: 1);
      return;
    }
    await _loadAccess(g);
    await _loadHistory(g, before: _newest);
    g.loaded = g.blocked == null;
  }

  Future<void> _loadHistory(_Group g, {required int before, int limit = 200}) async {
    final page = await _authed((t) => api.groupMessages(t, g.id, before: before, limit: limit));
    for (final w in page.items) {
      if (g.blocked != null) return;
      switch (w) {
        case final WireMessage m when m.conversationId == g.id:
          await _putMessage(g, m);
        case final SealedWire s when s.conversationId == g.id:
          await _putSealed(g, s);
      }
    }
    g.hasOlder = page.hasMore;
  }

  Future<void> _loadAccess(_Group g) async {
    var after = g.access.keys.fold(0, max);
    var more = true;
    while (more) {
      final page = await _authed((t) => api.accessEvents(t, g.id, after));
      for (final e in page.events) {
        g.access[e.id] = e;
        after = max(after, e.id);
      }
      more = page.hasMore && page.events.isNotEmpty;
    }
  }

  /// A tela (ou a bolha) do grupo abriu.
  Future<void> openGroup(String id) async {
    _opened.add(id);
    bool done() {
      final g = _groups[id];
      return g == null || g.loaded || g.blocked != null || _barred(id) || !_synced;
    }

    if (done()) return;
    await _locked(() async {
      if (done()) return;
      final g = _groups[id]!;
      try {
        if (!await _refreshChain(g)) return _changed();
        await _fillGroup(g, full: true);
        await _retryGroupWaiting(g);
        _changed();
      } on Object catch (e) {
        // sem _changed: quem recarrega ao ser avisado chamaria isto sem parar
        _alert('grupo não carregado: ${e.runtimeType}');
      }
    });
  }

  /// Uma imagem aberta na tela ainda pode ser mostrada?
  bool imageAvailable(ChatMessage row) {
    if (_shut(row.conversationId)) return false;
    if (!_groupIds.contains(row.conversationId)) return true;
    final m = _groups[row.conversationId]?.messages[row.messageId] ?? _pendingMsg(row.conversationId, row.id);
    return m != null && m.state != msgSealed && !m.thumbLocked;
  }

  /// Mensagens mais antigas, ao rolar até o topo.
  Future<void> loadOlder(String id) => _locked(() async {
    final g = _groups[id];
    if (g == null || !g.loaded || !g.hasOlder) return;
    final seqs = [for (final m in g.messages.values) ?m.seq];
    if (seqs.isEmpty) return;
    await _loadHistory(g, before: seqs.reduce(min));
    _changed();
  });

  // ---- receber (§7, §10.7) ----

  Future<void> _addGroup(ConvInfo ci) async {
    _groupIds.add(ci.conversationId);
    if (modPub == null || !_inScope(ci.conversationId)) return;
    final old = _groups[ci.conversationId];
    if (old != null) {
      old.info = ci;
      old.latestEpoch = max(old.latestEpoch, ci.latestEpoch);
      return;
    }
    final g = await _loadGroup(ci);
    if (g != null) _groups[g.id] = g;
  }

  Future<void> _decryptInto(_Group g, _GroupMsg out, WireMessage m) async {
    final sender = await _cert(m.senderDeviceId);
    // Mesmo sem chave: `member_access` precisa achar a mensagem para selar.
    out.senderUserId = sender?.userId ?? '';
    var epoch = g.epochs[m.epoch];
    if (epoch == null && !g.resyncedEpochs) {
      g.resyncedEpochs = true;
      await _loadEpochs(g);
      epoch = g.epochs[m.epoch];
    }
    if (epoch == null) {
      out.state = msgWaitingKey;
      out.raw = m;
      return;
    }
    out.raw = null;
    // O remetente tinha de ser membro na posição da cadeia da época.
    if (sender == null || !g.state.memberAt(sender.userId, epoch.chainN)) {
      _alert('mensagem de remetente inválido');
      out.state = msgDiscarded;
      return;
    }
    final (state, body, mine, kind) = _decryptFrom(sender, m, epoch.key);
    out
      ..state = state
      ..body = body
      ..mine = mine
      ..kind = kind;
  }

  Future<void> _putMessage(_Group g, WireMessage m) async {
    final old = g.messages[m.messageId];
    if (old != null && old.state != msgSealed) return;
    final out = _GroupMsg(
      rowId: old?.rowId ?? --_groupRowId,
      messageId: m.messageId,
      senderDeviceId: m.senderDeviceId,
      senderUserId: old?.senderUserId ?? '',
      sentAt: m.sentAt,
      createdAt: m.createdAt ?? m.sentAt,
      state: msgWaitingKey,
      seq: m.seq,
      epoch: m.epoch,
      ciphertextLen: m.ciphertext.length,
    );
    await _decryptInto(g, out, m);
    if (_closedTo(g)) return;
    g.messages[m.messageId] = out;
    // Só o meu próprio envio tira a pendente (ack perdido).
    if (m.senderDeviceId == selfDeviceId) _outbox[g.id]?.removeWhere((p) => p.messageId == m.messageId);
  }

  Future<void> _putSealed(_Group g, SealedWire s) async {
    final sender = await _cert(s.senderDeviceId);
    if (_closedTo(g)) return;
    final old = g.messages[s.messageId];
    g.blobs.remove(s.messageId);
    g.messages[s.messageId] = _GroupMsg(
      rowId: old?.rowId ?? --_groupRowId,
      messageId: s.messageId,
      senderDeviceId: s.senderDeviceId,
      senderUserId: sender?.userId ?? s.senderUserId,
      sentAt: s.createdAt,
      createdAt: s.createdAt,
      state: msgSealed,
      seq: s.seq,
      // Recalculado: o texto do servidor nunca vai para a tela.
      body: scramble(crypto.c, g.id, s.seq, s.scrambleLength),
      mine: (sender?.userId ?? s.senderUserId) == selfUserId,
    );
  }

  Future<void> _receiveGroup(WireMessage m) async {
    final g = _groups[m.conversationId];
    if (g == null || g.blocked != null || _barred(g.id)) return;
    await _putMessage(g, m);
    _changed();
  }

  Future<void> _receiveSealed(SealedWire s) async {
    final g = _groups[s.conversationId];
    if (g == null || g.blocked != null || _barred(g.id)) return;
    await _putSealed(g, s);
    onPurge?.call();
    _changed();
  }

  Future<void> _retryGroupWaiting(_Group g) async {
    for (final m in g.messages.values.where((m) => m.state == msgWaitingKey && m.raw != null).toList()) {
      if (g.epochs.containsKey(m.epoch)) await _decryptInto(g, m, m.raw!);
    }
  }

  Future<void> _onGroupEpoch(EpochItem it) async {
    _groupIds.add(it.conversationId);
    final g = _groups[it.conversationId];
    if (g == null || _barred(g.id)) return;
    // Liberação de histórico: o servidor avisa só parte das épocas antigas.
    final old = it.chainN! <= g.state.n && !g.state.memberAt(selfUserId, it.chainN!);
    if (old && !g.epochs.containsKey(it.epoch)) {
      await _loadEpochs(g);
    } else {
      await _addEpoch(g, it);
    }
    await _loadMeta(g);
    await _retryGroupWaiting(g);
  }

  Future<void> _onGroupChange(Map<String, dynamic> f) async {
    final id = f['conversation_id'] as String;
    final rec = SignedChange.fromJson(f['change'] as Map<String, dynamic>);
    final g = _groups[id];
    if (g == null || g.blocked != null) return;
    final n = GroupChange.decode(rec.bytes)?.n ?? 0;
    if (n == g.state.n + 1) {
      if (!await _applyChain(g, [rec])) return;
    } else if (n > g.state.n) {
      if (!await _refreshChain(g)) return;
    }
    if (!g.state.isMember(selfUserId)) return _drop(id);
    if (_barred(id)) return;
    final meta = f['meta'];
    if (meta is Map<String, dynamic>) _openMeta(g, [GroupMeta.fromJson(meta)]);
    await _loadMeta(g);
  }

  /// §7.3: sela na hora o que já está em memória; ao voltar, busca de novo.
  Future<void> _onMemberAccess(Map<String, dynamic> f) async {
    final user = f['user_id'] as String;
    final active = f['active'] as bool;
    for (final id in (f['conversations'] as List).cast<String>()) {
      final g = _groups[id];
      if (g == null || g.blocked != null || _barred(id)) continue;
      if (!active) {
        for (final m in g.messages.values) {
          if (m.senderUserId != user || m.state == msgSealed || m.seq == null) continue;
          m
            ..state = msgSealed
            ..body = scramble(crypto.c, id, m.seq!, scrambleLength(m.ciphertextLen))
            ..kind = kindText
            ..raw = null;
          g.blobs.remove(m.messageId);
        }
        onPurge?.call();
      }
      try {
        await _loadAccess(g);
        if (active) {
          g.messages.clear();
          await _loadHistory(g, before: _newest, limit: g.loaded ? 200 : 1);
        }
      } on ApiException catch (e) {
        _alert('acesso: ${e.code}');
      }
    }
  }

  void _lockThumb(String conversationId, String messageId) {
    final g = _groups[conversationId];
    final m = g?.messages[messageId];
    if (m == null) return;
    m.thumbLocked = true;
    g!.blobs.remove(messageId);
    onPurge?.call();
    _changed();
  }

  Future<Uint8List> _loadGroupImage(ChatMessage row) async {
    final g = _groups[row.conversationId];
    final m = g?.messages[row.messageId] ?? _pendingMsg(row.conversationId, row.id);
    if (g == null || m == null || m.state == msgSealed) throw UserFacingError('Imagem indisponível.');
    final ref = ImageRef.fromJson(row.body!, allowPendingBlob: true);
    final data =
        m.blob ?? g.blobs[row.messageId] ?? (g.blobs[row.messageId] = await _fetchGroupBlob(g, row.messageId, ref));
    try {
      return crypto.openBlob(conversationId: g.id, key: ref.key, blob: data);
    } on ChatCryptoException catch (e) {
      _alert('imagem descartada: ${e.message}');
      throw UserFacingError('Imagem indisponível.');
    }
  }

  Future<Uint8List> _fetchGroupBlob(_Group g, String messageId, ImageRef ref) async {
    final Uint8List data;
    try {
      data = await _authed((t) => api.downloadBlob(t, ref.blobId));
    } on ApiException catch (e) {
      if (e.code != 'sender_inactive') throw UserFacingError('Imagem indisponível.');
      _lockThumb(g.id, messageId);
      throw UserFacingError('Quem enviou está sem acesso ao grupo.');
    } on Object {
      throw UserFacingError('Sem conexão para baixar a imagem.');
    }
    if (!ChatService._sameBytes(sha256Of(data), ref.sha256)) {
      _alert('imagem descartada: hash não confere');
      throw UserFacingError('Imagem indisponível (arquivo adulterado).');
    }
    return data;
  }

  // ---- enviar ----

  _GroupMsg? _pendingMsg(String id, int rowId) {
    for (final m in _outbox[id] ?? const <_GroupMsg>[]) {
      if (m.rowId == rowId) return m;
    }
    return null;
  }

  _Group _usable(String id) {
    final g = _groups[id];
    if (g == null || !groupsAvailable) throw UserFacingError('Sem conexão. Grupos só funcionam conectados.');
    if (g.blocked != null) throw UserFacingError(g.blocked!);
    if (g.state.closed) throw UserFacingError('Este grupo foi encerrado.');
    if (_barred(id)) throw UserFacingError('Conversa trancada.');
    return g;
  }

  Future<void> _sendGroup(String id, int kind, String body, {Uint8List? blob}) async {
    _usable(id);
    final m = _GroupMsg(
      rowId: --_groupRowId,
      messageId: _uuid4(),
      senderDeviceId: selfDeviceId,
      senderUserId: selfUserId,
      sentAt: _ms(),
      createdAt: _ms(),
      state: msgSending,
      body: body,
      kind: kind,
      mine: true,
    );
    m.blob = blob;
    (_outbox[id] ??= []).add(m);
    _changed();
    if (_synced) unawaited(_locked(() => _transmitGroup(id, m)).catchError((Object _) {}));
  }

  Future<void> _retryGroup(int rowId) async {
    for (final e in _outbox.entries) {
      for (final m in e.value) {
        if (m.rowId != rowId) continue;
        m.state = msgSending;
        _changed();
        if (_synced) unawaited(_locked(() => _transmitGroup(e.key, m)).catchError((Object _) {}));
        return;
      }
    }
  }

  Future<void> _flushGroups() async {
    for (final e in _outbox.entries.toList()) {
      for (final m in e.value.toList()) {
        if (!_synced) return;
        if (m.state == msgSending) await _transmitGroup(e.key, m);
      }
    }
  }

  /// Antes de enviar ou embrulhar chave (§2.7): cadeia, âncora e diretório.
  Future<void> _prepare(_Group g, {required bool force}) async {
    if (!await _refreshChain(g)) throw UserFacingError(g.blocked!);
    if (!g.state.isMember(selfUserId)) {
      _drop(g.id);
      throw UserFacingError('Você não faz mais parte deste grupo.');
    }
    if (g.state.closed) throw UserFacingError('Este grupo foi encerrado.');
    if (force || _ms() - _dirAt > 30000) await _refreshDirectory();
  }

  /// Aparelhos ativos, com certificado verificado, **só** dos membros da cadeia.
  Future<List<DeviceCert>> _memberCerts(GroupState s) async {
    final certs = await _activeCerts(s.members.keys);
    if (!certs.any((c) => c.deviceId == selfDeviceId)) {
      throw UserFacingError('Este aparelho não está ativo no diretório.');
    }
    return certs;
  }

  /// Metadados atuais recifrados com a chave nova (§6.4).
  GroupMeta? _reseal(_Group g, GroupState s, Uint8List key, int epoch) {
    if (!s.hasMeta) return null;
    if (!_metaCurrent(g)) {
      throw UserFacingError(
        'Este aparelho ainda não tem o nome cifrado do grupo. Peça a outro membro para enviar uma mensagem.',
      );
    }
    return sealGroupMeta(crypto, key: key, conversationId: g.id, epoch: epoch, meta: g.metaBytes!);
  }

  NewEpoch _newEpoch(String id, int epoch, GroupState s, List<DeviceCert> certs) => createGroupEpoch(
    crypto,
    conversationId: id,
    epoch: epoch,
    self: keys,
    selfDeviceId: selfDeviceId,
    escrowPub: escrowPub,
    chainN: s.n,
    chainHash: s.head,
    certs: certs,
  );

  Map<String, dynamic> _epochBody(int epoch, NewEpoch ne, GroupState s) => {
    ...DirectApi.epochJson(epoch, selfDeviceId, ne),
    'chain_n': s.n,
    'chain_hash': b64uEncode(s.head),
  };

  static const _conflicts = {'epoch_conflict', 'device_set_changed', 'chain_conflict'};

  /// §5.3: a época a usar, criando a seguinte se o conjunto de aparelhos mudou.
  Future<int> _ensureGroupEpoch(_Group g) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      await _prepare(g, force: attempt > 0);
      final certs = await _memberCerts(g.state);
      final s = ChatCrypto.sortedUnique(certs.map((c) => c.deviceId));
      final latest = g.latestEpoch;
      final current = g.epochs[latest];
      if (current != null && listEquals(current.recipients, s)) return latest;
      final ne = _newEpoch(g.id, latest + 1, g.state, certs);
      final meta = _reseal(g, g.state, ne.key, latest + 1);
      try {
        await _authed(
          (t) => api.createGroupEpoch(t, g.id, {..._epochBody(latest + 1, ne, g.state), 'meta': ?meta?.toJson()}),
        );
      } on ApiException catch (e) {
        if (e.code == 'group_closed') throw UserFacingError('Este grupo foi encerrado.');
        if (!_conflicts.contains(e.code)) rethrow;
        g.latestEpoch = max(g.latestEpoch, e.latestEpoch ?? 0);
        await _loadEpochs(g);
        continue;
      }
      g.epochs[latest + 1] = _Epoch(ne.key, ne.recipients, g.state.n);
      g.latestEpoch = latest + 1;
      return latest + 1;
    }
    throw UserFacingError('Não foi possível criar a chave do grupo. Tente de novo.');
  }

  Future<void> _transmitGroup(String id, _GroupMsg m) async {
    if (!(_outbox[id]?.contains(m) ?? false) || m.state != msgSending) return;
    final g = _groups[id];
    if (g == null) return; // sem conexão: sai na próxima sincronização
    try {
      if (g.blocked != null || _barred(id)) throw UserFacingError('Grupo indisponível.');
      var body = m.body!;
      if (m.kind == kindImage) {
        final ref = ImageRef.fromJson(body, allowPendingBlob: true);
        if (ref.blobId.isEmpty) {
          final data = m.blob;
          if (data == null) throw UserFacingError('Imagem local perdida.');
          final up = await _authed((t) => api.uploadBlob(t, id, data));
          if (!ChatService._sameBytes(up.sha256, ref.sha256) || up.size != data.length) {
            throw UserFacingError('O servidor guardou um blob diferente.');
          }
          body = m.body = ref.withBlobId(up.blobId).toJson();
        }
      }
      for (var attempt = 0; attempt < 3; attempt++) {
        final epoch = await _ensureGroupEpoch(g);
        final sealed = crypto.seal(
          header: MessageHeader(
            conversationId: id,
            epoch: epoch,
            senderDeviceId: selfDeviceId,
            messageId: m.messageId,
            sentAt: m.sentAt,
          ),
          epochKey: g.epochs[epoch]!.key,
          plaintext: m.kind == kindImage ? Uint8List.fromList(utf8.encode(body)) : crypto.textPlain(body),
          signSeed: keys.signSeed,
        );
        final res = await _request({
          'type': 'send',
          'message': WireMessage(
            conversationId: id,
            epoch: epoch,
            senderDeviceId: selfDeviceId,
            messageId: m.messageId,
            sentAt: m.sentAt,
            nonce: sealed.nonce,
            ciphertext: sealed.ciphertext,
            signature: sealed.signature,
          ).toSendJson(),
        });
        if (res['type'] == 'ack') {
          m
            ..seq = res['seq'] as int
            ..createdAt = res['created_at'] as int? ?? _ms()
            ..state = msgOk
            ..epoch = epoch
            ..ciphertextLen = sealed.ciphertext.length;
          g.messages[m.messageId] = m;
          _outbox[id]?.remove(m);
          _changed();
          return;
        }
        if (res['code'] == 'epoch_required') {
          final latest = res['latest_epoch'];
          if (latest is int) g.latestEpoch = max(g.latestEpoch, latest);
          await _refreshDirectory();
          await _loadEpochs(g);
          continue;
        }
        break; // inclui group_closed
      }
      m.state = msgFailed;
    } on _Offline {
      return;
    } on ApiException catch (e) {
      debugPrint('[direct] envio em grupo: ${e.code}');
      if (e.status < 400 || e.status >= 500) return;
      m.state = msgFailed;
    } on UserFacingError catch (e) {
      _alert('envio em grupo: ${e.message}');
      m.state = msgFailed;
    }
    _changed();
  }

  // ---- criar e administrar ----

  SignedChange _sign(String id, GroupState s, int kind, Uint8List body) {
    final bytes = GroupChange(
      conversationId: id,
      n: s.n + 1,
      prev: s.head,
      kind: kind,
      authorType: authorDevice,
      authorDeviceId: selfDeviceId,
      authorUserId: selfUserId,
      createdAt: _ms(),
      body: body,
    ).encode();
    return SignedChange(bytes, crypto.c.sign(keys.signSeed, bytes), n: s.n + 1, receivedAt: _ms());
  }

  Future<T> _groupAction<T>(Future<T> Function() f) async {
    try {
      return await _locked(f);
    } on UserFacingError {
      rethrow;
    } on ApiException catch (e) {
      throw UserFacingError(switch (e.code) {
        'group_closed' => 'Este grupo foi encerrado.',
        'forbidden' => 'Você não tem permissão para isso neste grupo.',
        _ => 'O servidor recusou (${e.code}).',
      });
    } on Object catch (e) {
      debugPrint('[direct] grupo: ${e.runtimeType}');
      throw UserFacingError('Sem conexão. Tente de novo.');
    } finally {
      _changed();
    }
  }

  /// Cria o grupo com este usuário como admin e a época 1. Devolve o id.
  Future<String> createGroup(GroupProfile profile, Iterable<String> userIds) => _groupAction(() async {
    if (!groupsAvailable) throw UserFacingError('Sem conexão. Grupos só funcionam conectados.');
    final members = {for (final u in userIds) u: roleMember, selfUserId: roleAdmin};
    if (members.length > groupMaxMembers) throw UserFacingError('Máximo de $groupMaxMembers pessoas.');
    final id = _uuid4();
    final Uint8List meta;
    try {
      meta = profile.encode(crypto.c.random(32));
    } on FormatException {
      throw UserFacingError('Nome de 1 a 64 caracteres; descrição de até 500.');
    }
    for (var attempt = 0; attempt < 3; attempt++) {
      await _refreshDirectory();
      final state = GroupState(crypto.c, id);
      final rec = _sign(id, state, kindCreate, createBody('', metaCommitOf(crypto.c, id, meta), members));
      state.apply(rec, await _chainKeys([rec]));
      final ne = _newEpoch(id, 1, state, await _memberCerts(state));
      final sealed = sealGroupMeta(crypto, key: ne.key, conversationId: id, epoch: 1, meta: meta);
      // Antes do pedido: o evento de volta não pode cair no caminho 1:1.
      _groupIds.add(id);
      final ConvInfo info;
      try {
        info = await _authed(
          (t) => api.createGroup(t, {
            'change': rec.toJson(),
            'epoch': _epochBody(1, ne, state),
            'meta': sealed.toJson(),
          }),
        );
      } on ApiException catch (e) {
        if (e.code != 'device_set_changed' || attempt == 2) rethrow;
        continue;
      }
      if (info.conversationId != id) throw UserFacingError('O servidor devolveu outro grupo.');
      final g = _Group(info, state)
        ..latestEpoch = 1
        ..metaBytes = meta
        ..profile = profile
        ..loaded = true
        ..epochs[1] = _Epoch(ne.key, ne.recipients, 1);
      await _applyChain(g, const []); // grava a âncora
      _groups[id] = g;
      return id;
    }
    throw UserFacingError('Não foi possível criar o grupo. Tente de novo.');
  });

  /// Monta o registro, confere-o como os outros conferirão e envia com a época
  /// e os metadados que o tipo pede (§5.3, §6.4).
  Future<int> _change(String id, int kind, {Uint8List? body, Uint8List? newMeta}) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final g = _usable(id);
      await _prepare(g, force: true);
      if (kind == kindRename && g.epochs[g.latestEpoch] == null) await _ensureGroupEpoch(g);
      final rec = _sign(id, g.state, kind, newMeta != null ? metaCommitOf(crypto.c, id, newMeta) : body ?? Uint8List(0));
      final records = [for (final r in g.state.records) r.record, rec];
      final GroupState next;
      try {
        next = GroupState.verify(crypto.c, id, records, await _chainKeys(records));
      } on ChainError catch (e) {
        throw UserFacingError(switch (e.code) {
          'limite' => 'Máximo de $groupMaxMembers pessoas.',
          'papel' => 'Só um admin do grupo pode fazer isso.',
          _ => 'A lista de membros mudou. Tente de novo.',
        });
      }
      NewEpoch? ne;
      GroupMeta? meta;
      final epoch = g.latestEpoch + 1;
      if (kind == kindAdd || kind == kindRemove) {
        ne = _newEpoch(id, epoch, next, await _memberCerts(next));
        meta = _reseal(g, next, ne.key, epoch);
      } else if (newMeta != null) {
        final current = g.epochs[g.latestEpoch];
        if (current == null) throw UserFacingError('Sem a chave atual do grupo.');
        meta = sealGroupMeta(crypto, key: current.key, conversationId: id, epoch: g.latestEpoch, meta: newMeta);
      }
      try {
        await _authed(
          (t) => api.groupChange(t, id, {
            'change': rec.toJson(),
            'epoch': ne == null ? null : _epochBody(epoch, ne, next),
            'meta': meta?.toJson(),
          }),
        );
      } on ApiException catch (e) {
        if (!_conflicts.contains(e.code) || attempt == 2) rethrow;
        await _loadEpochs(g);
        continue;
      }
      if (!await _applyChain(g, [rec])) throw UserFacingError(g.blocked!);
      if (ne != null) {
        g.epochs[epoch] = _Epoch(ne.key, ne.recipients, next.n);
        g.latestEpoch = epoch;
      }
      if (newMeta != null) {
        g.metaBytes = newMeta;
        g.profile = GroupProfile.decode(newMeta);
      }
      return next.n;
    }
    throw UserFacingError('A lista de membros mudou. Tente de novo.');
  }

  /// [history]: libera para quem entra as mensagens anteriores (G2).
  Future<void> addMembers(String id, List<String> userIds, {required bool history}) => _groupAction(() async {
    final addN = await _change(id, kindAdd, body: addBody(history: history, users: userIds));
    if (!history) return;
    try {
      await _releaseHistory(_usable(id), addN, userIds);
    } on Object catch (e) {
      debugPrint('[direct] histórico: ${e.runtimeType}');
      throw UserFacingError('A pessoa entrou, mas o histórico não foi liberado. O moderador pode restaurá-lo.');
    }
  });

  /// §5.4: só reembrulha o que a cadeia assinada permite.
  Future<void> _releaseHistory(_Group g, int addN, List<String> users) async {
    await _loadEpochs(g);
    await _refreshDirectory();
    final certs = await _activeCerts(users);
    final items = <Map<String, dynamic>>[
      for (final e in g.epochs.entries)
        if (e.value.chainN < addN)
          for (final c in certs)
            if (g.state.mayRewrap(c.userId, e.value.chainN))
              {
                'epoch': e.key,
                'device_id': c.deviceId,
                'wrapped_key': b64uEncode(crypto.sodium.crypto.box.seal(message: e.value.key, publicKey: c.kexPub)),
              },
    ];
    for (var i = 0; i < items.length; i += 500) {
      await _authed((t) => api.historyWraps(t, g.id, addN, items.sublist(i, min(i + 500, items.length))));
    }
  }

  Future<void> removeMember(String id, String userId) =>
      _groupAction(() async => _change(id, kindRemove, body: usersBody([userId])));

  Future<void> promoteMember(String id, String userId) =>
      _groupAction(() async => _change(id, kindPromote, body: usersBody([userId])));

  Future<void> leaveGroup(String id) => _groupAction(() async {
    await _change(id, kindLeave);
    _drop(id);
  });

  Future<void> closeGroup(String id) => _groupAction(() async => _change(id, kindCloseGroup));

  Future<void> editGroup(String id, GroupProfile profile) => _groupAction(() async {
    final Uint8List meta;
    try {
      meta = profile.encode(crypto.c.random(32));
    } on FormatException {
      throw UserFacingError('Nome de 1 a 64 caracteres; descrição de até 500.');
    }
    await _change(id, kindRename, newMeta: meta);
  });

  // ---- consultas para a interface ----

  /// `user_id → admin_label`, do diretório e dos certificados verificados.
  Future<Map<String, String>> _names() async {
    final out = <String, String>{};
    for (final d in await db.select(db.knownDevices).get()) {
      out[d.userId] = (jsonDecode(d.certJson) as Map<String, dynamic>)['admin_label'] as String;
    }
    for (final u in await db.select(db.dirUsers).get()) {
      out[u.userId] = u.adminLabel;
    }
    return out;
  }

  static String _name(Map<String, String> names, String userId) => names[userId] ?? 'Usuário removido';

  /// §6.5: nome cifrado; senão o rótulo do moderador; senão o provisório.
  String _title(_Group g, Map<String, String> names) {
    final p = g.profile;
    if (p != null) return p.name;
    if (!g.state.hasMeta && g.state.adminLabel.isNotEmpty) return g.state.adminLabel;
    final labels = [for (final u in g.state.members.keys) _name(names, u)]..sort();
    return labels.isEmpty ? 'Grupo' : 'Grupo ${labels.take(3).join(', ')}';
  }

  Future<String> groupTitle(String id) async {
    final g = _shut(id) ? null : _groups[id];
    return g == null ? 'Grupo' : _title(g, await _names());
  }

  Uint8List? groupPhoto(String id) => _groups[id]?.profile?.photo;

  /// Motivo para não dar para escrever; null = pode.
  String? groupNotice(String id) {
    final g = _groups[id];
    if (g == null) return groupsAvailable ? 'Você não faz parte deste grupo.' : 'Grupos indisponíveis sem conexão.';
    return g.blocked ?? (g.state.closed ? 'Este grupo foi encerrado.' : null);
  }

  bool hasOlder(String id) => _groups[id]?.hasOlder ?? false;

  /// A partir de quando mostrar o que não dá para ler: a entrada sem histórico.
  int _joinedAt(_Group g) {
    final open = g.state.intervals[selfUserId]?.last;
    if (open == null || open.history || open.from < 1) return 0;
    return g.state.records[open.from - 1].record.receivedAt;
  }

  Future<String> _recordText(_Group g, AppliedRecord r, Map<String, String> names) async {
    final c = r.change;
    final who = c.byModerator ? 'O moderador' : _name(names, c.authorUserId);
    final targets = r.body.users.map((u) => _name(names, u)).join(', ');
    var text = switch (c.kind) {
      kindCreate => c.byModerator ? 'O moderador criou o grupo oficial' : '$who criou o grupo',
      kindAdd => '$who adicionou $targets ${r.body.history ? 'com' : 'sem'} acesso ao histórico',
      kindRemove => '$who removeu $targets',
      kindPromote => '$who tornou $targets admin',
      kindLeave => '$who saiu do grupo',
      kindRename => '$who mudou o nome, a descrição ou a foto',
      _ => '$who encerrou o grupo',
    };
    if (!c.byModerator) {
      final cert = await _cert(c.authorDeviceId);
      if (cert != null && r.record.receivedAt - cert.enrolledAt < _freshDevice.inMilliseconds) {
        text += ' (por um aparelho novo)';
      }
    }
    return text;
  }

  ChatMessage _row(_Group g, _GroupMsg m) => ChatMessage(
    id: m.rowId,
    conversationId: g.id,
    messageId: m.messageId,
    seq: m.seq,
    epoch: m.epoch,
    senderDeviceId: m.senderDeviceId,
    sentAt: m.sentAt,
    body: m.body,
    kind: m.kind,
    state: m.state,
    mine: m.mine,
  );

  /// Mensagens com as linhas de sistema intercaladas pelo horário do servidor.
  Future<List<GroupLine>> groupLines(String id) async {
    final g = _groups[id];
    if (g == null || g.blocked != null || _barred(id)) return const [];
    final names = await _names();
    final joined = _joinedAt(g);

    final notices = <({int at, String key, String text})>[];
    for (final r in g.state.records) {
      if (r.record.receivedAt >= joined) {
        notices.add((at: r.record.receivedAt, key: 'r${r.change.n}', text: await _recordText(g, r, names)));
      }
    }
    for (final e in g.access.values) {
      if (e.at >= joined) {
        notices.add((
          at: e.at,
          key: 'a${e.id}',
          text: '${_name(names, e.userId)} ${e.active ? 'voltou ao grupo' : 'perdeu o acesso'}',
        ));
      }
    }
    // Aviso de aparelho novo (A1), com destaque para admin. Sem filtro pela
    // entrada: `noticedAt` é do relógio do aparelho, e um aviso não pode sumir.
    final seen = await (db.select(db.seenKeys)
          ..where((t) => t.userId.isIn(g.state.members.keys) & t.noticedAt.isNotNull()))
        .get();
    for (final s in seen) {
      if (s.userId != selfUserId) {
        final admin = g.state.isAdmin(s.userId) ? ' (admin do grupo)' : '';
        notices.add((
          at: s.noticedAt!,
          key: 'd${s.userId}${s.signPub}',
          text: '${_name(names, s.userId)}$admin conectou um aparelho novo',
        ));
      }
    }
    notices.sort((a, b) => a.at != b.at ? a.at.compareTo(b.at) : a.key.compareTo(b.key));

    final msgs = [
      for (final m in g.messages.values)
        // De antes da entrada sem histórico não há o que mostrar.
        if (m.state != msgDiscarded && !(m.createdAt < joined && (m.state == msgSealed || m.state == msgWaitingKey))) m,
    ]..sort((a, b) => (a.seq ?? 0).compareTo(b.seq ?? 0));

    final out = <GroupLine>[];
    var next = 0;
    var noticeId = -(1 << 40);
    void noticesUntil(int at) {
      while (next < notices.length && notices[next].at <= at) {
        final n = notices[next++];
        // Antes da primeira mensagem carregada há páginas mais antigas.
        out.add(
          GroupLine(
            ChatMessage(
              id: noticeId--,
              conversationId: id,
              messageId: n.key,
              epoch: 0,
              senderDeviceId: '',
              sentAt: n.at,
              body: n.text,
              kind: kindText,
              state: msgNotice,
              mine: false,
            ),
          ),
        );
      }
    }

    GroupLine line(_GroupMsg m) => GroupLine(
      _row(g, m),
      senderId: m.senderUserId,
      senderName: m.mine ? '' : _name(names, m.senderUserId),
      thumbLocked: m.thumbLocked,
    );

    for (final m in msgs) {
      noticesUntil(m.createdAt);
      out.add(line(m));
    }
    noticesUntil(_newest);
    out.addAll([for (final m in _outbox[id] ?? const <_GroupMsg>[]) line(m)]);
    return out;
  }

  Future<GroupInfo?> groupInfo(String id) async {
    final g = _groups[id];
    if (g == null || _shut(id)) return null;
    final names = await _names();
    final members = [
      for (final e in g.state.members.entries)
        GroupMemberView(e.key, _name(names, e.key), admin: e.value == roleAdmin, self: e.key == selfUserId),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return GroupInfo(
      id: id,
      title: _title(g, names),
      officialLabel: g.state.adminLabel,
      profile: g.profile,
      members: g.blocked == null ? members : const [],
      history: g.blocked != null
          ? const []
          : [
              for (final r in g.state.records.reversed)
                (text: await _recordText(g, r, names), at: r.record.receivedAt),
            ],
      admin: g.state.isAdmin(selfUserId),
      closed: g.state.closed,
      blocked: g.blocked,
    );
  }

  Future<List<ConversationView>> _groupViews() async {
    if (!groupsAvailable) return const [];
    final names = await _names();
    final out = <ConversationView>[];
    for (final g in _groups.values) {
      final msgs = [for (final m in g.messages.values) if (m.state != msgDiscarded) m]
        ..sort((a, b) => (a.seq ?? 0).compareTo(b.seq ?? 0));
      final pending = _outbox[g.id] ?? const <_GroupMsg>[];
      final last = pending.isNotEmpty ? pending.last : msgs.lastOrNull;
      var preview = '';
      if (g.blocked != null) {
        preview = g.blocked!;
      } else if (last != null) {
        final text = switch (last.state) {
          msgWaitingKey => 'Aguardando chave…',
          msgUnsupported => 'Mensagem não suportada nesta versão',
          _ => last.kind == kindImage ? 'Foto' : (last.body ?? ''),
        };
        preview = last.mine ? text : '${_name(names, last.senderUserId)}: $text';
      }
      out.add(
        ConversationView(
          conversationId: g.id,
          peerUserId: '',
          title: _title(g, names),
          subtitle: g.state.adminLabel.isEmpty ? 'Grupo' : 'oficial: ${g.state.adminLabel}',
          lastText: preview,
          lastAt: last?.createdAt ?? g.state.records.lastOrNull?.record.receivedAt ?? 0,
          isGroup: true,
        ),
      );
    }
    return out;
  }
}

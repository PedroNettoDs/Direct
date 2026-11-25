import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'chat/chat_service.dart';
import 'core/api.dart';
import 'core/b64.dart';
import 'core/bio.dart';
import 'core/chat_crypto.dart';
import 'core/crypto.dart';
import 'core/errors.dart';
import 'core/group_proto.dart';
import 'core/invite.dart';
import 'core/kv_store.dart';
import 'core/models.dart';
import 'core/vault.dart';
import 'core/ws.dart';
import 'data/db.dart';

export 'core/errors.dart';

const appVersion = '1.0.0';

/// Bolha sem interação por este tempo, com a interface principal trancada,
/// tranca sozinha (revisão de segurança, B1). Único lugar a mudar.
const bubbleIdleTimeout = Duration(minutes: 5);

enum Stage { booting, enroll, locked, profile, ready }

/// Resultado de [AppController.reauth].
class Reauth {
  const Reauth({
    this.ok = false,
    this.retryAfter,
    this.canceled = false,
    this.invalidated = false,
  });
  final bool ok;

  /// Senha errada ou travada: espera até a próxima tentativa.
  final Duration? retryAfter;

  /// Usuário desistiu da digital.
  final bool canceled;

  /// Digital nova no aparelho: só a senha serve.
  final bool invalidated;

  static const success = Reauth(ok: true);
  static const failed = Reauth();
}

class DeviceInfoData {
  const DeviceInfoData(this.platform, this.model, this.osVersion);
  final String platform; // android | ios
  final String model;
  final String osVersion;
}

class _Identity {
  _Identity(this.host, this.serverSignPub, this.escrowPub, this.cert, [this.modPub]);

  /// Chave do moderador fixada; null = grupos desligados.
  final Uint8List? modPub;
  final String host;
  final Uint8List serverSignPub;
  final Uint8List escrowPub;
  final DeviceCert cert;

  String encode() => jsonEncode({
    'host': host,
    'server_sign_pub': b64uEncode(serverSignPub),
    'escrow_pub': b64uEncode(escrowPub),
    'cert': cert.toJson(),
    if (modPub != null) 'mod_pub': b64uEncode(modPub!),
  });

  static _Identity decode(String s) {
    final j = jsonDecode(s) as Map<String, dynamic>;
    return _Identity(
      j['host'] as String,
      b64uDecode(j['server_sign_pub'] as String, length: 32),
      b64uDecode(j['escrow_pub'] as String, length: 32),
      DeviceCert.fromJson(j['cert'] as Map<String, dynamic>),
      j['mod_pub'] == null ? null : b64uDecode(j['mod_pub'] as String, length: 32),
    );
  }
}

class ChangeSignal extends ChangeNotifier {
  void ping() => notifyListeners();
}

/// Estado do app: cadastro, trava, perfil e chat.
class AppController extends ChangeNotifier {
  AppController({
    required this.crypto,
    required this.kv,
    required this.vault,
    required this.openDb,
    required this.wipeDbFiles,
    required this.apiFor,
    required this.deviceInfo,
    required this.firstRunMarker,
    this.markInstalled,
    this.wsConnector,
    Future<int> Function()? uptime,
    this.bubbleIdle = bubbleIdleTimeout,
  }) : uptime = uptime ?? _stopwatch();

  static Future<int> Function() _stopwatch() {
    final sw = Stopwatch()..start();
    return () async => sw.elapsedMilliseconds;
  }

  /// Relógio monotônico em ms.
  final Future<int> Function() uptime;
  final Duration bubbleIdle;

  final DirectCrypto crypto;
  final KvStore kv;
  final Vault vault;
  final DbOpener openDb;
  final Future<void> Function() wipeDbFiles;
  final DirectApi Function(String host) apiFor;
  final Future<DeviceInfoData> Function() deviceInfo;

  /// Marca em armazenamento que some com a desinstalação (UserDefaults no iOS).
  /// `check` devolve true na primeira execução desta instalação.
  final Future<bool> Function() firstRunMarker;

  /// Grava a marca, só depois de a limpeza da primeira execução terminar.
  final Future<void> Function()? markInstalled;

  /// Só testes: troca o WebSocket real.
  final WsConnector? wsConnector;

  Stage stage = Stage.booting;

  /// Digital ativada (mostrada na trava e em Ajustes).
  bool bioEnabled = false;

  /// "Adicionar secrets" no perfil: libera "Esconder conversa" na folha "i".
  bool secretsEnabled = false;
  LocalProfile? profile;
  String? adminLabel;

  Uint8List? _master;
  AppDatabase? _db;

  /// Chat ativo enquanto o app está destravado e com perfil (stage ready).
  ChatService? chat;
  _Identity? _id;
  DeviceKeys? _pendingKeys; // reaproveitado em nova tentativa do mesmo convite
  String? _pendingSeedB64;

  static const _kIdentity = 'identity';

  /// Revogação pré-assinada (protocolo-grupos §8): fora do cofre, para quem
  /// esqueceu a senha conseguir enviá-la.
  static const _kSelfRevoke = 'self_revoke';

  /// Grupos ligados: há chave do moderador fixada (app destravado).
  bool get groupsEnabled => _id?.modPub != null;

  /// Apaga imagens decodificadas quando conteúdo de grupo sai da memória.
  void Function() onPurge = () {};

  /// Código mostrado em Ajustes (protocolo §13.4); null com o app trancado.
  String? get deviceCode {
    final id = _id;
    return id == null ? null : crypto.deviceCode(id.cert.signPub, id.cert.kexPub);
  }

  Future<void> init() async {
    // Keychain do iOS sobrevive à desinstalação (PLANO §7): primeiro início
    // desta instalação apaga tudo que veio de uma anterior.
    if (await firstRunMarker()) {
      await kv.deleteAll();
      await vault.bio.delete();
      await wipeDbFiles();
      await markInstalled?.call();
    }
    bioEnabled = await vault.bioEnabled;
    stage = await vault.exists && await kv.read(_kIdentity) != null
        ? Stage.locked
        : Stage.enroll;
    notifyListeners();
  }

  // ---- cadastro ----

  /// Entrada manual: host + token + código de verificação (protocolo §4.3).
  Future<Invite> inviteFromManual(String host, String token, String code) async {
    host = host.trim();
    if (!isValidHost(host)) throw UserFacingError('Endereço do servidor inválido.');
    final Uint8List seed;
    try {
      seed = b64uDecode(token.trim(), length: 32);
    } on FormatException {
      throw UserFacingError('Token inválido.');
    }
    final api = apiFor(host);
    final ServerInfo info;
    try {
      info = await api.serverInfo();
    } on Object {
      throw UserFacingError('Não foi possível falar com o servidor.');
    } finally {
      api.close();
    }
    final typed = code.replaceAll(RegExp(r'\s'), '');
    String digits(String s) => s.replaceAll(' ', '');
    // Convite v=2: o código inclui a chave do moderador (protocolo-grupos §3.3).
    final mod = info.modPub;
    final withMod =
        mod != null && typed == digits(serverCodeMod(crypto, info.serverSignPub, info.escrowPub, mod));
    if (!withMod && typed != digits(crypto.serverCode(info.serverSignPub, info.escrowPub))) {
      throw UserFacingError(
        'O código de verificação não confere. Servidor não confiável: não continue.',
      );
    }
    return Invite(
      host: host,
      seed: seed,
      serverSignPub: info.serverSignPub,
      escrowPub: info.escrowPub,
      modPub: withMod ? mod : null,
    );
  }

  Invite inviteFromQr(String raw) {
    try {
      return parseInviteUri(raw.trim());
    } on InviteException catch (e) {
      throw UserFacingError(e.message);
    }
  }

  /// Gera chaves, cadastra o aparelho e cria a trava local.
  Future<void> enroll(Invite invite, String password) async {
    final seedB64 = b64uEncode(invite.seed);
    if (_pendingSeedB64 != seedB64) {
      _pendingKeys = crypto.generateDeviceKeys();
      _pendingSeedB64 = seedB64;
    }
    final keys = _pendingKeys!;
    final invitePub = crypto.signPubFromSeed(invite.seed);
    final eb = crypto.enrollBytes(invitePub, keys.signPub, keys.kexPub);
    final info = await deviceInfo();
    String cap(String s) => s.length > 64 ? s.substring(0, 64) : s;

    final api = apiFor(invite.host);
    final EnrollResult res;
    try {
      res = await api.enroll({
        'invite_pub': b64uEncode(invitePub),
        'sign_pub': b64uEncode(keys.signPub),
        'kex_pub': b64uEncode(keys.kexPub),
        'platform': info.platform,
        'model': cap(info.model),
        'os_version': cap(info.osVersion),
        'app_version': appVersion,
        'invite_sig': b64uEncode(crypto.sign(invite.seed, eb)),
        'proof': b64uEncode(crypto.sign(keys.signSeed, eb)),
      });
    } on ApiException catch (e) {
      throw UserFacingError(switch (e.code) {
        'invite_invalid' => 'Convite inválido, vencido ou já usado. Peça outro ao moderador.',
        'key_in_use' => 'Este aparelho já foi cadastrado.',
        'device_limit' => 'Você já tem 4 aparelhos ativos. Peça ao moderador para revogar um.',
        'rate_limited' => 'Muitas tentativas. Aguarde um minuto.',
        _ => 'O servidor recusou o cadastro (${e.code}).',
      });
    } on Object {
      throw UserFacingError('Sem conexão com o servidor. Tente de novo.');
    } finally {
      api.close();
    }

    final cert = res.cert;
    final ok =
        listEquals(cert.signPub, keys.signPub) &&
        listEquals(cert.kexPub, keys.kexPub) &&
        crypto.verifyCert(cert, invite.serverSignPub);
    if (!ok) {
      _pendingKeys = null;
      _pendingSeedB64 = null;
      throw UserFacingError('Resposta do servidor adulterada. Cadastro cancelado.');
    }

    // Convite descartado: só as chaves e o certificado ficam (protocolo §5.5).
    final master = await vault.create(password);
    await vault.saveSecrets(master, keys);
    _id = _Identity(invite.host, invite.serverSignPub, invite.escrowPub, cert, invite.modPub);
    await kv.write(_kIdentity, _id!.encode());
    _pendingKeys = null;
    _pendingSeedB64 = null;
    await _open(master);
    adminLabel = cert.adminLabel;
    stage = profile == null || res.newUser ? Stage.profile : Stage.ready;
    await _startChatIfReady();
    notifyListeners();
  }

  // ---- trava ----

  Future<Duration> lockoutRemaining() => vault.lockoutRemaining();

  /// Lança [WrongPassword] / [LockedOut].
  Future<void> unlock(String password) async =>
      _finishUnlock(await vault.unlock(password));

  /// Chaves e banco abertos. Pode ser true com [stage] em `locked`: o app foi
  /// para segundo plano com uma bolha aberta, que continua conversando.
  bool get sessionOpen => _master != null;

  /// Abre com a digital. Lança [BioCanceled], [BioUnavailable] ou
  /// [BioInvalidated] (digital nova: a digital some e só a senha abre).
  Future<void> unlockWithBio() async => _finishUnlock(await _bioMaster());

  Future<Uint8List> _bioMaster() async {
    try {
      return await vault.unlockBio();
    } on BioInvalidated {
      bioEnabled = false;
      notifyListeners();
      rethrow;
    }
  }

  /// Com a sessão já aberta (bolha), só libera a interface.
  Future<void> _finishUnlock(Uint8List master, {bool showUi = true, bool fromBridge = false}) async {
    final open = _master;
    if (open != null) {
      final same = vault.sodium.memcmp(open, master);
      master.fillRange(0, master.length, 0);
      if (!same) throw BioInvalidated();
      if (showUi) await _showUi();
      return;
    }
    _id = _Identity.decode((await kv.read(_kIdentity))!);
    if (await vault.loadSecrets(master) == null) {
      master.fillRange(0, master.length, 0);
      // Chave errada vinda pela ponte da bolha não desliga a digital.
      if (!fromBridge) {
        await vault.disableBio();
        bioEnabled = false;
      }
      throw BioInvalidated();
    }
    await _open(master);
    adminLabel = _id!.cert.adminLabel;
    if (showUi) {
      await _showUi();
    } else {
      await _startChatIfReady();
      notifyListeners();
    }
  }

  Future<void> _showUi() async {
    _idleTimer?.cancel();
    stage = profile == null ? Stage.profile : Stage.ready;
    chat?.setScope(null);
    await _startChatIfReady();
    notifyListeners();
  }

  Future<bool> bioAvailable() => vault.bio.available();

  /// Ativa a digital depois de conferir a senha. Lança [WrongPassword],
  /// [LockedOut], [BioCanceled], [BioUnavailable].
  Future<void> enableBio(String password) async {
    final master = await vault.unlock(password);
    try {
      await vault.enableBio(master);
    } finally {
      master.fillRange(0, master.length, 0);
    }
    bioEnabled = true;
    notifyListeners();
  }

  Future<void> disableBio() async {
    await vault.disableBio();
    bioEnabled = false;
    notifyListeners();
  }

  /// Reautenticação reutilizável (PLANO §7, usada para reabrir conversa
  /// trancada): confere senha ou digital sem refazer o desbloqueio, sem abrir
  /// banco nem mexer na tela. Com [password] confere a senha (mesmo atraso
  /// crescente da trava); sem ela, pede a digital.
  Future<Reauth> reauth({String? password}) async {
    try {
      if (password != null) {
        (await vault.unlock(password)).fillRange(0, 32, 0);
      } else if (!await _matchesAndWipe(await vault.unlockBio())) {
        return Reauth.failed;
      }
      return Reauth.success;
    } on WrongPassword catch (e) {
      return Reauth(retryAfter: e.retryAfter);
    } on LockedOut catch (e) {
      return Reauth(retryAfter: e.retryAfter);
    } on BioCanceled {
      return const Reauth(canceled: true);
    } on BioInvalidated {
      bioEnabled = false;
      notifyListeners();
      return const Reauth(invalidated: true);
    } on BioUnavailable {
      return const Reauth(canceled: true);
    }
  }

  Future<bool> _matchesAndWipe(Uint8List m) async {
    final cur = _master;
    var same = true;
    if (cur != null) same = vault.sodium.memcmp(m, cur);
    m.fillRange(0, m.length, 0);
    return same;
  }

  Future<void> _startChatIfReady() async {
    // Com a interface trancada, o chat só existe para as bolhas.
    final forBubble = stage == Stage.locked && bubbles.isNotEmpty && profile != null;
    if ((stage != Stage.ready && !forBubble) || chat != null) return;
    final id = _id!;
    final secrets = await vault.loadSecrets(_master!);
    if (secrets == null) return;
    chat = ChatService(
      db: _db!,
      api: apiFor(id.host),
      crypto: ChatCrypto(crypto),
      keys: DeviceKeys(
        signSeed: secrets.signSeed,
        signPub: id.cert.signPub,
        kexSk: secrets.kexSk,
        kexPub: id.cert.kexPub,
      ),
      cert: id.cert,
      serverSignPub: id.serverSignPub,
      escrowPub: id.escrowPub,
      modPub: id.modPub,
      isLocked: isConversationLocked,
      onPurge: () => onPurge(),
      login: _login,
      connector: wsConnector,
    );
    if (forBubble) chat!.setScope(bubbles);
    chat!.addListener(chatChanges.ping);
    chat!.start();
  }

  Future<void> _stopChat(ChatService? c) async {
    if (c != null) {
      c.removeListener(chatChanges.ping);
      await c.stop();
      c.api.close();
      c.dispose();
    }
  }

  Future<void> _open(Uint8List master) async {
    _master = master;
    _db = await openDb(vault.dbKey(master));
    profile = await _db!.getProfile();
    _lockedConvs = await _db!.lockedConversations();
    secretsEnabled = await _db!.secretsEnabled();
    await applyDismissed();
    await _ensureSelfRevoke(master);
  }

  /// Gera no cadastro e, em aparelho antigo, no primeiro desbloqueio (§8.2).
  Future<void> _ensureSelfRevoke(Uint8List master) async {
    final id = _id;
    if (id == null || await kv.read(_kSelfRevoke) != null) return;
    final secrets = await vault.loadSecrets(master);
    if (secrets == null) return;
    await kv.write(
      _kSelfRevoke,
      jsonEncode(
        signSelfRevoke(
          crypto,
          signSeed: secrets.signSeed,
          serverSignPub: id.serverSignPub,
          deviceId: id.cert.deviceId,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ),
    );
    secrets.signSeed.fillRange(0, 32, 0);
    secrets.kexSk.fillRange(0, 32, 0);
  }

  /// "Esqueci a senha": avisa o servidor, se der, e apaga tudo de qualquer jeito.
  Future<void> forgotPassword() async {
    try {
      final identity = await kv.read(_kIdentity);
      final revoke = await kv.read(_kSelfRevoke);
      if (identity != null && revoke != null) {
        final api = apiFor(_Identity.decode(identity).host);
        try {
          await api.selfRevoke(jsonDecode(revoke) as Map<String, dynamic>).timeout(const Duration(seconds: 10));
        } finally {
          api.close();
        }
      }
    } on Object catch (e) {
      // Sem rede ou recusado: o moderador revoga pela CLI.
      debugPrint('[direct] revogação não enviada: ${e.runtimeType}');
    }
    await wipeAll();
  }

  // ---- chave do moderador (protocolo-grupos §3.4) ----

  /// QR `direct://pin` mostrado pelo moderador.
  Future<void> pinModeratorQr(String raw) async {
    final id = _id;
    if (id == null) throw UserFacingError('App bloqueado.');
    final Uint8List mod;
    try {
      mod = parsePinUri(raw.trim(), host: id.host, serverSignPub: id.serverSignPub, escrowPub: id.escrowPub);
    } on InviteException catch (e) {
      throw UserFacingError(e.message);
    }
    await _pin(mod);
  }

  /// Chave que o servidor anuncia. Só é fixada por [pinModeratorCode].
  Future<Uint8List> moderatorKeyFromServer() async {
    final id = _id;
    if (id == null) throw UserFacingError('App bloqueado.');
    final api = apiFor(id.host);
    try {
      final mod = (await api.serverInfo()).modPub;
      if (mod == null) throw UserFacingError('O moderador ainda não ativou os grupos neste servidor.');
      return mod;
    } on UserFacingError {
      rethrow;
    } on Object {
      throw UserFacingError('Sem conexão com o servidor. Tente de novo.');
    } finally {
      api.close();
    }
  }

  /// [typed] é o código que o moderador distribuiu fora do servidor. As chaves do
  /// servidor e do escrow são as já fixadas.
  Future<void> pinModeratorCode(Uint8List mod, String typed) async {
    final id = _id;
    if (id == null) throw UserFacingError('App bloqueado.');
    final expected = serverCodeMod(crypto, id.serverSignPub, id.escrowPub, mod);
    if (typed.replaceAll(RegExp(r'\s'), '') != expected.replaceAll(' ', '')) {
      throw UserFacingError('O código não confere. Servidor não confiável: fale com o moderador.');
    }
    await _pin(mod);
  }

  Future<void> _pin(Uint8List mod) async {
    final id = _id!;
    final old = id.modPub;
    if (old != null) {
      if (!listEquals(old, mod)) throw UserFacingError('Este aparelho já fixou outra chave do moderador.');
      return;
    }
    _id = _Identity(id.host, id.serverSignPub, id.escrowPub, id.cert, mod);
    await kv.write(_kIdentity, _id!.encode());
    chat?.enableGroups(mod);
    notifyListeners();
  }

  // ---- chat flutuante (PLANO §9) ----

  /// Avisa mudança nas mensagens a quem espelha o chat (bolha).
  final chatChanges = ChangeSignal();

  /// iOS: conversa no mini-chat flutuante dentro do app.
  String? floating;

  void openFloating(String conversationId) {
    floating = conversationId;
    notifyListeners();
  }

  /// Fechar o mini-chat tranca a conversa, como a bolha (D7).
  Future<void> closeFloating() async {
    final id = floating;
    if (id == null) return;
    floating = null;
    await lockConversation(id);
  }

  /// Conversas com bolha aberta (só Android).
  Set<String> bubbles = {};

  Set<String> _lockedConvs = {};
  final Set<String> _pendingLocks = {};

  /// Persiste trancas pedidas pelo lado nativo (bolha jogada no lixo). Com o
  /// app trancado o banco está fechado: ficam pendentes até abrir.
  Future<List<String>> Function() dismissedSource = () async => const [];
  Future<void> Function(List<String>) dismissedAck = (_) async {};

  bool isConversationLocked(String id) =>
      _lockedConvs.contains(id) || _pendingLocks.contains(id);

  /// D7: tranca só aquela conversa.
  Future<void> lockConversation(String id) async {
    _pendingLocks.add(id);
    chat?.closeHidden(id); // oculta: volta a pedir a senha dela (D12)
    chat?.forgetGroup(id); // grupo: fechar apaga da memória (D11)
    notifyListeners();
    await _flushLocks();
  }

  Future<void> applyDismissed() async {
    final ids = await dismissedSource();
    _pendingLocks.addAll(ids);
    await _flushLocks();
    if (_db != null && ids.isNotEmpty) await dismissedAck(ids);
  }

  Future<void> _flushLocks() async {
    final db = _db;
    if (db == null) return;
    for (final id in _pendingLocks.toList()) {
      await db.lockConversationRow(id);
      _lockedConvs.add(id);
      _pendingLocks.remove(id);
      chat?.forgetGroup(id);
    }
    notifyListeners();
  }

  /// Única saída da tranca: reautenticação feita para aquela conversa.
  Future<Reauth> unlockConversation(String id, {String? password}) async {
    // Oculta só abre com a senha dela (D12): nem senha do app, nem digital.
    if (_db == null || isHidden(id)) return Reauth.failed;
    final r = await reauth(password: password);
    if (r.ok) await _clearLock(id);
    return r;
  }

  /// Digital lida pela tela da bolha (outro engine): confere e destranca.
  Future<bool> unlockConversationWithMaster(String id, Uint8List master) async {
    if (_master == null || !await _matchesAndWipe(master) || isHidden(id)) return false;
    await _clearLock(id);
    return true;
  }

  Future<void> _clearLock(String id) async {
    _pendingLocks.remove(id);
    await _db?.unlockConversationRow(id);
    _lockedConvs.remove(id);
    notifyListeners();
  }

  // ---- conversas ocultas (D12, docs/ocultas.md) ----

  /// Fecha a bolha dela e apaga notificação e atalho (lado nativo).
  Future<void> Function(String conversationId) closeBubble = (_) async {};

  bool isHidden(String id) => chat?.isHidden(id) ?? _db?.hiddenIds.contains(id) ?? false;

  ChatService get _openChat => chat ?? (throw UserFacingError('App bloqueado.'));

  /// Esconde com senha própria: sela o que há no banco e fecha a bolha.
  Future<void> hideConversation(String id, String password) async {
    final svc = _openChat;
    final sk = crypto.random(32);
    final pub = crypto.x25519Pub(sk);
    final wrapped = await vault.wrapForConversation(id, password, sk);
    sk.fillRange(0, 32, 0);
    await svc.hide(id, pub, wrapped);
    if (floating == id) floating = null;
    // Como fechar a bolha (D7); a tranca sai quando a senha dela abrir.
    await lockConversation(id);
    await closeBubble(id);
    if (bubbles.contains(id)) await setBubbles({...bubbles}..remove(id));
    chatChanges.ping();
  }

  /// A única entrada numa conversa oculta. Nunca usa a digital.
  Future<Reauth> openHiddenConversation(String id, String password) async {
    final svc = chat;
    final row = await svc?.hiddenRow(id);
    if (svc == null || row == null) return Reauth.failed;
    final Uint8List sk;
    try {
      sk = await vault.unwrapForConversation(id, password, row.wrapped);
    } on WrongPassword catch (e) {
      return Reauth(retryAfter: e.retryAfter);
    } on LockedOut catch (e) {
      return Reauth(retryAfter: e.retryAfter);
    }
    await _clearLock(id);
    // O app pode ter trancado ou saído da tela durante o Argon2.
    if (!identical(svc, chat) || (_master != null && stage == Stage.locked)) {
      sk.fillRange(0, sk.length, 0);
      return Reauth.failed;
    }
    final opened = svc.openHidden(id, sk);
    sk.fillRange(0, sk.length, 0);
    // Decifrar o pendente e buscar o grupo segue sem segurar a tela.
    unawaited(opened.catchError((Object e) => debugPrint('[direct] oculta: ${e.runtimeType}')));
    return Reauth.success;
  }

  /// Só com a conversa aberta.
  Future<void> changeHiddenPassword(String id, String password) =>
      _openChat.rewrapHidden(id, (sk) async {
        try {
          return await vault.wrapForConversation(id, password, sk);
        } finally {
          sk.fillRange(0, sk.length, 0);
        }
      });

  /// "Mostrar conversa". Só com ela aberta.
  Future<void> showHiddenConversation(String id) async {
    await _openChat.unhide(id);
    notifyListeners();
  }

  /// Abre a sessão a partir da bolha com o app trancado: a interface principal
  /// continua pedindo senha.
  Future<void> openSession({String? password, Uint8List? master}) async {
    await _finishUnlock(master ?? await vault.unlock(password!), showUi: false, fromBridge: master != null);
    await _startIdle();
  }

  // ---- tranca automática da bolha (B1) ----

  Timer? _idleTimer;
  int _touchedAt = 0;

  /// A bolha é a única tela com a sessão aberta.
  bool get _idleApplies => stage == Stage.locked && _master != null && bubbles.isNotEmpty;

  Future<void> _startIdle() async {
    _idleTimer?.cancel();
    if (!_idleApplies) return;
    _touchedAt = await uptime();
    _armIdle(bubbleIdle);
  }

  void _armIdle(Duration wait) {
    _idleTimer?.cancel();
    _idleTimer = Timer(wait, () async {
      if (await expireIdleBubbles() || !_idleApplies) return;
      _armIdle(bubbleIdle - Duration(milliseconds: await uptime() - _touchedAt));
    });
  }

  /// Confere o prazo no relógio monotônico (o `Timer` para com o aparelho em
  /// repouso). Tranca e devolve true se venceu.
  Future<bool> expireIdleBubbles() async {
    if (!_idleApplies || await uptime() - _touchedAt < bubbleIdle.inMilliseconds) return false;
    await lockBubbles();
    return true;
  }

  /// Toque, envio ou abertura na bolha: recomeça a contagem.
  Future<void> touchBubble() async {
    if (!await expireIdleBubbles()) await _startIdle();
  }

  /// Tela desligada ou inatividade: tranca a conversa de toda bolha (D7) e, com
  /// a interface principal trancada, esquece a chave-mestra.
  Future<void> lockBubbles() async {
    for (final id in bubbles.toList()) {
      await lockConversation(id);
    }
    if (stage == Stage.locked && bubbles.isNotEmpty && bubbles.every(isConversationLocked)) {
      await lock();
    }
  }

  Future<void> setBubbles(Set<String> ids) async {
    if (setEquals(ids, bubbles)) return;
    bubbles = Set.of(ids);
    notifyListeners();
    if (stage != Stage.locked || _master == null) return;
    if (bubbles.isEmpty) {
      await lock(); // última bolha fechada com o app fora da tela
    } else {
      chat?.setScope(bubbles);
      await _startChatIfReady();
      await _startIdle();
    }
  }

  /// App saiu da tela. Sem bolha, tranca tudo; com bolha, a interface tranca e
  /// só as conversas das bolhas seguem ligadas.
  Future<void> background() async {
    chat?.closeAllHidden();
    if (bubbles.isEmpty || (stage != Stage.ready && stage != Stage.locked)) {
      return lock();
    }
    if (stage == Stage.locked) return;
    stage = Stage.locked;
    chat?.setScope(bubbles);
    notifyListeners();
    if (bubbles.every(isConversationLocked)) return lock();
    await _startIdle();
  }

  /// Fecha banco e esquece a chave-mestra (ao abrir e ao ir para segundo plano).
  Future<void> lock() async {
    if (_master == null || stage == Stage.enroll) return;
    _idleTimer?.cancel();
    final running = chat;
    chat = null;
    _master?.fillRange(0, _master!.length, 0);
    _master = null;
    final db = _db;
    _db = null;
    profile = null;
    _id = null;
    _lockedConvs = {};
    stage = Stage.locked;
    notifyListeners();
    await _stopChat(running);
    await db?.close();
  }

  // ---- perfil ----

  /// Login por desafio (protocolo §6). Apaga tudo se o servidor provar revogação.
  Future<AccessToken> _login() async {
    final id = _id;
    final master = _master;
    if (id == null || master == null) throw UserFacingError('App bloqueado.');
    final keys = await vault.loadSecrets(master);
    if (keys == null) throw UserFacingError('Chaves locais indisponíveis.');
    final api = apiFor(id.host);
    Uint8List? challenge;
    try {
      challenge = await api.challenge(id.cert.deviceId);
      final sig = crypto.sign(
        keys.signSeed,
        crypto.authBytes(id.serverSignPub, id.cert.deviceId, challenge),
      );
      return await api.verify(id.cert.deviceId, challenge, sig);
    } on ApiException catch (e) {
      if (e.code == 'device_revoked' &&
          e.revokedSig != null &&
          challenge != null &&
          crypto.verify(
            id.serverSignPub,
            crypto.revokedBytes(id.cert.deviceId, challenge),
            e.revokedSig!,
          )) {
        await wipeAll();
        throw UserFacingError('Este aparelho foi revogado. Dados apagados.');
      }
      throw UserFacingError(switch (e.code) {
        'device_expired' => 'O cadastro deste aparelho venceu. Peça novo convite.',
        'device_revoked' => 'Não foi possível confirmar a revogação. Tente de novo.',
        _ => 'Falha no login (${e.code}).',
      });
    } on UserFacingError {
      rethrow;
    } on Object {
      throw UserFacingError('Sem conexão com o servidor. Tente de novo.');
    } finally {
      api.close();
    }
  }

  Future<void> saveProfile(String name, String status) async {
    name = name.trim();
    status = status.trim();
    if (name.isEmpty || name.runes.length > 64) {
      throw UserFacingError('Nome de 1 a 64 caracteres.');
    }
    if (status.runes.length > 140) {
      throw UserFacingError('Status de até 140 caracteres.');
    }
    if (_hasControl(name) || _hasControl(status)) {
      throw UserFacingError('Texto com caracteres inválidos.');
    }
    final token = (await _login()).token;
    final api = apiFor(_id!.host);
    try {
      await api.putProfile(token, name, status);
    } on ApiException catch (e) {
      throw UserFacingError('O servidor recusou o perfil (${e.code}).');
    } on Object {
      throw UserFacingError('Sem conexão com o servidor. Tente de novo.');
    } finally {
      api.close();
    }
    await _db!.saveProfile(name, status);
    profile = await _db!.getProfile();
    stage = Stage.ready;
    await _startChatIfReady();
    notifyListeners();
  }

  /// Desligar não mexe nas conversas que já estão ocultas.
  Future<void> setSecrets(bool on) async {
    await _db!.setSecretsEnabled(on);
    secretsEnabled = on;
    notifyListeners();
  }

  static bool _hasControl(String s) =>
      s.runes.any((r) => r < 0x20 || (r >= 0x7f && r < 0xa0));

  // ---- apagar tudo (PLANO §6.5) ----

  /// Fecha as bolhas e o serviço (lado nativo).
  Future<void> Function() onWipe = () async {};

  Future<void> wipeAll() async {
    _idleTimer?.cancel();
    final running = chat;
    chat = null;
    await _stopChat(running);
    _master?.fillRange(0, _master!.length, 0);
    _master = null;
    final db = _db;
    _db = null;
    await db?.close();
    await wipeDbFiles();
    await kv.deleteAll();
    await vault.bio.delete();
    await onWipe();
    bioEnabled = false;
    secretsEnabled = false;
    bubbles = {};
    floating = null;
    _lockedConvs = {};
    _pendingLocks.clear();
    _id = null;
    profile = null;
    adminLabel = null;
    _pendingKeys = null;
    _pendingSeedB64 = null;
    stage = Stage.enroll;
    notifyListeners();
  }
}

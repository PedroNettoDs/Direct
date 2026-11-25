import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import '../core/b64.dart';

part 'db.g.dart';

/// Perfil do próprio usuário (linha única, id = 1).
class LocalProfiles extends Table {
  IntColumn get id => integer()();
  TextColumn get displayName => text()();
  TextColumn get status => text()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Usuário do diretório (cache; `adminLabel` vem assinado nos certificados).
class DirUsers extends Table {
  TextColumn get userId => text()();
  TextColumn get adminLabel => text()();
  TextColumn get displayName => text()();
  TextColumn get status => text()();

  @override
  Set<Column> get primaryKey => {userId};
}

/// Certificados de aparelho já verificados (ativos e antigos).
class KnownDevices extends Table {
  TextColumn get deviceId => text()();
  TextColumn get userId => text()();
  TextColumn get certJson => text()();
  BoolColumn get active => boolean()();

  @override
  Set<Column> get primaryKey => {deviceId};
}

/// `sign_pub` já vistos por usuário (protocolo §7.3). `present` = estava no último diretório.
class SeenKeys extends Table {
  TextColumn get userId => text()();
  TextColumn get signPub => text()();
  BoolColumn get present => boolean()();

  /// Quando o app avisou que este era um aparelho novo (§7.3); os grupos
  /// montam a linha a partir daqui.
  IntColumn get noticedAt => integer().nullable()();

  @override
  Set<Column> get primaryKey => {userId, signPub};
}

/// Maior topo de cadeia já verificado por grupo (protocolo-grupos §2.7). É o
/// único registro de grupo que vai para o disco (D11).
class GroupAnchors extends Table {
  TextColumn get conversationId => text()();
  IntColumn get n => integer()();
  BlobColumn get hash => blob()();

  @override
  Set<Column> get primaryKey => {conversationId};
}

class Conversations extends Table {
  TextColumn get conversationId => text()();
  TextColumn get peerUserId => text()();
  TextColumn get membersJson => text()();
  IntColumn get latestEpoch => integer()();

  /// Maior `seq` já processado (inclui descartadas e à espera de chave).
  IntColumn get syncedSeq => integer()();

  @override
  Set<Column> get primaryKey => {conversationId};
}

class EpochKeys extends Table {
  TextColumn get conversationId => text()();
  IntColumn get epoch => integer()();
  BlobColumn get key => blob()();
  TextColumn get recipientsJson => text()();

  @override
  Set<Column> get primaryKey => {conversationId, epoch};
}

/// Estado das mensagens.
const msgSending = 0; // minha, ainda sem ack
const msgOk = 1;
const msgWaitingKey = 2; // recebida, sem chave de época: guarda o envelope
const msgDiscarded = 3; // falhou verificação/decifração: sem conteúdo
const msgUnsupported = 4; // `type` desconhecido
const msgFailed = 5; // minha, recusada pelo servidor
const msgNotice = 6; // aviso local (§7.3), nunca enviado: `body` é o texto
const msgSealed = 7; // só em memória (grupo, D11): `body` é o embaralhado

const kindText = 0;
const kindImage = 1;

class ChatMessages extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get conversationId => text()();
  TextColumn get messageId => text()();
  IntColumn get seq => integer().nullable()();
  IntColumn get epoch => integer()();
  TextColumn get senderDeviceId => text()();
  IntColumn get sentAt => integer()();
  TextColumn get body => text().nullable()();

  /// `kindText` ou `kindImage`; em imagem, `body` guarda o JSON de §18.1 (com a chave da imagem).
  IntColumn get kind => integer().withDefault(const Constant(0))();
  IntColumn get state => integer()();
  BoolColumn get mine => boolean()();
  BlobColumn get nonce => blob().nullable()();
  BlobColumn get ciphertext => blob().nullable()();
  BlobColumn get signature => blob().nullable()();

  @override
  List<Set<Column>> get uniqueKeys => [
    {conversationId, messageId},
  ];
}

/// Blob cifrado de uma imagem (protocolo §18.2), do envio ou do download. `data` é o blob como
/// o servidor o guarda (`nonce || ciphertext`); a imagem em claro nunca vai para o disco.
class Attachments extends Table {
  TextColumn get conversationId => text()();
  TextColumn get messageId => text()();
  BlobColumn get data => blob().nullable()();

  @override
  Set<Column> get primaryKey => {conversationId, messageId};
}

/// Conversa oculta (D12, docs/ocultas.md). Com a linha, corpo, anexo e chave de
/// época da conversa ficam selados (`crypto_box_seal`) para [pub].
class HiddenConversations extends Table {
  TextColumn get conversationId => text()();
  BlobColumn get pub => blob()();

  /// Chave privada embrulhada pela senha da conversa (`Vault.wrapWithPassword`).
  TextColumn get wrapped => text()();

  @override
  Set<Column> get primaryKey => {conversationId};
}

class ChatMeta extends Table {
  TextColumn get k => text()();
  TextColumn get v => text()();

  @override
  Set<Column> get primaryKey => {k};
}

@DriftDatabase(
  tables: [
    LocalProfiles,
    DirUsers,
    KnownDevices,
    SeenKeys,
    Conversations,
    EpochKeys,
    ChatMessages,
    ChatMeta,
    Attachments,
    GroupAnchors,
    HiddenConversations,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 6;

  /// Cache de `hidden_conversations`, carregado antes da primeira consulta.
  final hiddenIds = <String>{};

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.createTable(dirUsers);
        await m.createTable(knownDevices);
        await m.createTable(conversations);
        await m.createTable(epochKeys);
        await m.createTable(chatMessages);
        await m.createTable(chatMeta);
        await m.createTable(attachments);
      } else if (from == 2) {
        await m.addColumn(chatMessages, chatMessages.kind);
        await m.createTable(attachments);
      }
      if (from < 4) {
        await m.createTable(seenKeys);
      } else if (from < 5) {
        await m.addColumn(seenKeys, seenKeys.noticedAt);
      }
      if (from < 5) await m.createTable(groupAnchors);
      if (from < 6) await m.createTable(hiddenConversations);
    },
    beforeOpen: (_) async {
      // O que for apagado ou sobrescrito não fica nas páginas livres (D12).
      await customStatement('PRAGMA secure_delete = ON');
      hiddenIds
        ..clear()
        ..addAll([for (final r in await select(hiddenConversations).get()) r.conversationId]);
    },
  );

  Future<LocalProfile?> getProfile() =>
      (select(localProfiles)..where((t) => t.id.equals(1))).getSingleOrNull();

  Future<void> saveProfile(String name, String status) =>
      into(localProfiles).insertOnConflictUpdate(
        LocalProfilesCompanion.insert(
          id: const Value(1),
          displayName: name,
          status: status,
        ),
      );
}

/// Conversas trancadas (D7) ficam em `ChatMeta` (`locked:<id>`), no banco cifrado.
extension ConversationLocks on AppDatabase {
  static const _prefix = 'locked:';

  Future<void> lockConversationRow(String conversationId) => into(chatMeta)
      .insertOnConflictUpdate(ChatMetaCompanion.insert(k: '$_prefix$conversationId', v: '1'));

  Future<void> unlockConversationRow(String conversationId) =>
      (delete(chatMeta)..where((t) => t.k.equals('$_prefix$conversationId'))).go();

  Future<Set<String>> lockedConversations() async {
    final rows = await (select(chatMeta)..where((t) => t.k.like('$_prefix%'))).get();
    return {for (final r in rows) r.k.substring(_prefix.length)};
  }
}

/// Chave "Adicionar secrets" do perfil (D12), em `ChatMeta`. Sem a linha, desligada.
extension SecretsSetting on AppDatabase {
  static const _key = 'secrets';

  Future<void> setSecretsEnabled(bool on) => on
      ? into(chatMeta).insertOnConflictUpdate(ChatMetaCompanion.insert(k: _key, v: '1'))
      : (delete(chatMeta)..where((t) => t.k.equals(_key))).go();

  Future<bool> secretsEnabled() async =>
      await (select(chatMeta)..where((t) => t.k.equals(_key))).getSingleOrNull() != null;
}

typedef DbOpener = Future<AppDatabase> Function(Uint8List key);

/// Abre (ou cria) o banco SQLCipher com a chave de 32 bytes.
/// Falha se o SQLCipher não estiver presente: nunca cai num banco sem cifra.
DbOpener fileDbOpener(File file) => (key) async {
  return AppDatabase(
    NativeDatabase(
      file,
      setup: (raw) {
        raw.execute("PRAGMA key = \"x'${toHex(key)}'\";");
        final v = raw.select('PRAGMA cipher_version;');
        if (v.isEmpty || (v.first.values.first as String?)?.isEmpty != false) {
          throw StateError('SQLCipher indisponível: recusando banco sem cifra');
        }
        raw.select('SELECT count(*) FROM sqlite_master;'); // chave errada falha aqui
      },
    ),
  );
};

Future<void> deleteDbFiles(File file) async {
  for (final suffix in ['', '-wal', '-shm', '-journal']) {
    final f = File('${file.path}$suffix');
    if (await f.exists()) await f.delete();
  }
}

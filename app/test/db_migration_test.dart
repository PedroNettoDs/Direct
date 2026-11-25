// Banco de quem já tinha o app (schema 4) abre no 5 sem perder nada.
import 'dart:io';

import 'package:direct/data/db.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('schema 4 → atual: aviso de aparelho novo, âncoras de grupo e conversas ocultas', () async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final dir = await Directory.systemTemp.createTemp('direct-db');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/v4.db');
    var db = AppDatabase(NativeDatabase(file));
    await db.customStatement('ALTER TABLE seen_keys DROP COLUMN noticed_at');
    await db.customStatement('DROP TABLE group_anchors');
    await db.customStatement('DROP TABLE hidden_conversations');
    await db.customStatement("INSERT INTO seen_keys (user_id, sign_pub, present) VALUES ('u', 'k', 1)");
    await db.customStatement('PRAGMA user_version = 4');
    await db.close();

    db = AppDatabase(NativeDatabase(file));
    final seen = (await db.select(db.seenKeys).get()).single;
    expect((seen.signPub, seen.noticedAt), ('k', null));
    expect(await db.select(db.groupAnchors).get(), isEmpty);
    expect(await db.select(db.hiddenConversations).get(), isEmpty);
    expect(db.hiddenIds, isEmpty);
    await db.close();
  });
}

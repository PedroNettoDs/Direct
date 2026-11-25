import 'package:direct/core/kv_store.dart';
import 'package:direct/core/models.dart';
import 'package:direct/core/vault.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

import 'support.dart';

void main() {
  late SodiumSumo sodium;
  late MemoryKv kv;
  late DateTime t;
  late Vault vault;

  Vault make() => Vault(
    sodium,
    kv,
    now: () => t,
    opsLimit: sodium.crypto.pwhash.opsLimitMin,
    memLimit: sodium.crypto.pwhash.memLimitMin,
  );

  setUpAll(() async {
    sodium = (await loadCrypto()).sodium;
  });

  setUp(() {
    kv = MemoryKv();
    t = DateTime(2026, 11, 24, 12);
    vault = make();
  });

  test('atraso crescente definido', () {
    expect(lockoutDelay(1), Duration.zero);
    expect(lockoutDelay(2), Duration.zero);
    expect(lockoutDelay(3), const Duration(seconds: 5));
    expect(lockoutDelay(4), const Duration(seconds: 10));
    expect(lockoutDelay(5), const Duration(seconds: 20));
    expect(lockoutDelay(50), const Duration(minutes: 15));
  });

  test('senha certa devolve a mesma chave-mestra; segredos viajam', () async {
    final master = await vault.create('senha-boa-123');
    final keys = await loadCryptoKeys();
    await vault.saveSecrets(master, keys);
    final again = await make().unlock('senha-boa-123');
    expect(again, master);
    final s = await vault.loadSecrets(again);
    expect(s!.signSeed, keys.signSeed);
    expect(s.kexSk, keys.kexSk);
    expect(vault.dbKey(master), vault.dbKey(again));
    expect(vault.dbKey(master).length, 32);
  });

  test('segredo em repouso não contém a chave privada em claro', () async {
    final master = await vault.create('senha-boa-123');
    final keys = await loadCryptoKeys();
    await vault.saveSecrets(master, keys);
    for (final v in kv.data.values) {
      expect(v.contains(String.fromCharCodes(keys.signSeed)), isFalse);
    }
    // outra chave-mestra não abre
    expect(await vault.loadSecrets(sodium.randombytes.buf(32)), isNull);
  });

  test('senha errada: 2 erros sem atraso, 3º erro bloqueia 5 s', () async {
    await vault.create('certa-certa');
    await expectLater(vault.unlock('x'), throwsA(isA<WrongPassword>()));
    await expectLater(vault.unlock('y'), throwsA(isA<WrongPassword>()));
    expect(await vault.lockoutRemaining(), Duration.zero);
    await expectLater(
      vault.unlock('z'),
      throwsA(isA<WrongPassword>().having((e) => e.retryAfter, 'retryAfter', const Duration(seconds: 5))),
    );
    expect(await vault.lockoutRemaining(), const Duration(seconds: 5));
  });

  test('durante o atraso nem a senha certa entra; depois entra e zera', () async {
    await vault.create('certa-certa');
    for (var i = 0; i < 3; i++) {
      await expectLater(vault.unlock('errada'), throwsA(isA<WrongPassword>()));
    }
    await expectLater(vault.unlock('certa-certa'), throwsA(isA<LockedOut>()));
    t = t.add(const Duration(seconds: 6));
    await vault.unlock('certa-certa');
    expect(await vault.lockoutRemaining(), Duration.zero);
    // contador zerou: novo erro não bloqueia
    await expectLater(vault.unlock('errada'), throwsA(isA<WrongPassword>()));
    expect(await vault.lockoutRemaining(), Duration.zero);
  });

  test('atraso cresce a cada erro e sobrevive a reinício do app', () async {
    await vault.create('certa-certa');
    var last = Duration.zero;
    for (var i = 1; i <= 6; i++) {
      t = t.add(const Duration(hours: 1));
      try {
        await make().unlock('errada');
      } on WrongPassword catch (e) {
        if (i >= 4) expect(e.retryAfter > last, isTrue);
        last = e.retryAfter;
      }
    }
    expect(last, const Duration(seconds: 40));
    expect(await make().lockoutRemaining(), const Duration(seconds: 40));
  });

  test('mexer no relógio não encurta o atraso; reinício recomeça a espera (A3)', () async {
    var up = 1000000;
    Vault clocked() => Vault(
      sodium,
      kv,
      now: () => t,
      uptime: () async => up,
      opsLimit: sodium.crypto.pwhash.opsLimitMin,
      memLimit: sodium.crypto.pwhash.memLimitMin,
    );
    final v = clocked();
    await v.create('certa-certa');
    for (var i = 0; i < 3; i++) {
      await expectLater(v.unlock('errada'), throwsA(isA<WrongPassword>()));
    }
    // relógio adiantado, aparelho não: continua trancado
    t = t.add(const Duration(minutes: 15));
    await expectLater(v.unlock('certa-certa'), throwsA(isA<LockedOut>()));
    // relógio de volta para antes do erro: espera inteira
    t = t.subtract(const Duration(hours: 1));
    up += 4000;
    expect(await v.lockoutRemaining(), const Duration(seconds: 5));
    // reinício (uptime menor que o gravado): espera inteira outra vez
    up = 10;
    t = t.add(const Duration(hours: 2));
    expect(await v.lockoutRemaining(), const Duration(seconds: 5));
    // os dois andaram: abre
    up += 5000;
    t = t.add(const Duration(seconds: 5));
    await v.unlock('certa-certa');
  });

  test('adulterar o cofre impede abrir', () async {
    await vault.create('certa-certa');
    final raw = kv.data['vault']!;
    kv.data['vault'] = raw.replaceFirst('"wrapped":"', '"wrapped":"AAAA');
    await expectLater(vault.unlock('certa-certa'), throwsA(isA<WrongPassword>()));
  });
}

Future<DeviceKeys> loadCryptoKeys() async =>
    (await loadCrypto()).generateDeviceKeys();

import 'package:biometric_storage/biometric_storage.dart';

/// O usuário cancelou ou errou a digital.
class BioCanceled implements Exception {}

/// A digital não está disponível (sem sensor, sem digital cadastrada).
class BioUnavailable implements Exception {}

/// Digital nova cadastrada no aparelho: o Keystore/Keychain destruiu a chave.
class BioInvalidated implements Exception {}

/// Cofre preso à biometria (PLANO §7, D9). O segredo só sai com a digital:
/// no Android, chave do Keystore com `setUserAuthenticationRequired`, que o
/// sistema invalida ao cadastrar digital nova; no iOS, item do Keychain com
/// `biometryCurrentSet`. Não basta o "sim" do sensor.
abstract class BioStore {
  /// Aparelho tem sensor e ao menos uma digital cadastrada.
  Future<bool> available();

  /// Guarda [secret] atrás da digital. Pede a digital.
  Future<void> write(String secret);

  /// Lê o segredo. Pede a digital. [BioCanceled], [BioInvalidated],
  /// [BioUnavailable]. Null se não há nada guardado.
  Future<String?> read();

  /// Apaga o segredo e a chave. Não pede a digital.
  Future<void> delete();
}

class PluginBioStore implements BioStore {
  PluginBioStore([this._name = 'direct_master']);
  final String _name;
  BiometricStorageFile? _file;

  static const _prompt = PromptInfo(
    androidPromptInfo: AndroidPromptInfo(
      title: 'Desbloquear o Direct',
      negativeButton: 'Usar senha',
      confirmationRequired: false,
    ),
    iosPromptInfo: IosPromptInfo(
      saveTitle: 'Ativar digital',
      accessTitle: 'Desbloquear o Direct',
    ),
  );

  Future<BiometricStorageFile> _store() async =>
      _file ??= await BiometricStorage().getStorage(
        _name,
        options: StorageFileInitOptions(
          authenticationRequired: true,
          androidBiometricOnly: true,
          darwinBiometricOnly: true,
        ),
        promptInfo: _prompt,
      );

  @override
  Future<bool> available() async {
    try {
      return await BiometricStorage().canAuthenticate() ==
          CanAuthenticateResponse.success;
    } on Object {
      return false;
    }
  }

  Never _map(AuthException e) => switch (e.code) {
    AuthExceptionCode.keyInvalidated => throw BioInvalidated(),
    AuthExceptionCode.lockout ||
    AuthExceptionCode.lockoutPermanent => throw BioUnavailable(),
    _ => throw BioCanceled(),
  };

  @override
  Future<void> write(String secret) async {
    try {
      await (await _store()).write(secret);
    } on AuthException catch (e) {
      _map(e);
    }
  }

  @override
  Future<String?> read() async {
    try {
      return await (await _store()).read();
    } on AuthException catch (e) {
      _map(e);
    }
  }

  @override
  Future<void> delete() async {
    try {
      await (await _store()).delete();
    } on Object {
      // Chave já destruída ou nada guardado.
    }
  }
}

/// Sem biometria (testes e plataformas sem suporte).
class NoBio implements BioStore {
  @override
  Future<bool> available() async => false;
  @override
  Future<void> write(String secret) async => throw BioUnavailable();
  @override
  Future<String?> read() async => throw BioUnavailable();
  @override
  Future<void> delete() async {}
}

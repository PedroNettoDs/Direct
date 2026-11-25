import 'package:direct/core/bio.dart';

/// Cofre biométrico de mentira. [touch] diz se a digital passa;
/// [enroll] simula digital nova no aparelho (destrói a chave).
class FakeBio implements BioStore {
  bool hasSensor = true;
  bool touch = true;
  bool _invalid = false;
  String? _secret;
  int prompts = 0;

  void enroll() => _invalid = true;

  @override
  Future<bool> available() async => hasSensor;

  @override
  Future<void> write(String secret) async {
    prompts++;
    if (!hasSensor) throw BioUnavailable();
    if (!touch) throw BioCanceled();
    _secret = secret;
    _invalid = false;
  }

  @override
  Future<String?> read() async {
    prompts++;
    if (_secret == null) return null;
    if (_invalid) {
      _secret = null; // o Keystore apaga a chave
      throw BioInvalidated();
    }
    if (!touch) throw BioCanceled();
    return _secret;
  }

  @override
  Future<void> delete() async => _secret = null;
}

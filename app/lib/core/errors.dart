/// Falha com texto pronto para mostrar ao usuário.
class UserFacingError implements Exception {
  UserFacingError(this.message);
  final String message;
  @override
  String toString() => message;
}

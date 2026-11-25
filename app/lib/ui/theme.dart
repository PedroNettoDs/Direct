import 'package:material_ui/material_ui.dart';

/// Cores da conversa que o `ColorScheme` não cobre.
class ChatColors extends ThemeExtension<ChatColors> {
  const ChatColors({
    required this.sentGradient,
    required this.sentText,
    required this.received,
    required this.receivedText,
    required this.meta,
    required this.field,
    required this.accentTop,
    required this.accentBottom,
  });

  /// Balões enviados: do alto para baixo da área de mensagens.
  final List<Color> sentGradient;
  final Color sentText;
  final Color received;
  final Color receivedText;

  /// Separadores, linhas de sistema e horários.
  final Color meta;

  /// Fundo do campo de texto.
  final Color field;

  /// Destaque no topo da tela e na barra de baixo.
  final Color accentTop;
  final Color accentBottom;

  static const _gradient = [Color(0xFFE5589B), Color(0xFF9A68E8), Color(0xFF1C93DD)];

  static const dark = ChatColors(
    sentGradient: _gradient,
    sentText: Colors.white,
    received: Color(0xFF2E2E30),
    receivedText: Colors.white,
    meta: Color(0xFF9A9A9F),
    field: Color(0xFF2E2E30),
    accentTop: Color(0xFFFF86B4),
    accentBottom: Color(0xFF4B7BFF),
  );

  static const light = ChatColors(
    sentGradient: _gradient,
    sentText: Colors.white,
    received: Color(0xFFECECF0),
    receivedText: Color(0xFF101012),
    meta: Color(0xFF6B6B72),
    field: Color(0xFFECECF0),
    accentTop: Color(0xFFC92C72),
    accentBottom: Color(0xFF2456D6),
  );

  static ChatColors of(BuildContext context) {
    final t = Theme.of(context);
    return t.extension<ChatColors>() ?? (t.brightness == Brightness.dark ? dark : light);
  }

  @override
  ChatColors copyWith() => this;

  @override
  ChatColors lerp(covariant ChatColors? other, double t) => t < 0.5 || other == null ? this : other;
}

ThemeData directTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final chat = dark ? ChatColors.dark : ChatColors.light;
  final background = dark ? Colors.black : Colors.white;
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFFE5589B), brightness: brightness).copyWith(
    primary: chat.accentTop,
    onPrimary: dark ? Colors.black : Colors.white,
    surface: background,
    onSurface: dark ? Colors.white : const Color(0xFF101012),
    surfaceContainerLow: dark ? const Color(0xFF151517) : const Color(0xFFF6F6F8),
    surfaceContainer: dark ? const Color(0xFF151517) : const Color(0xFFF6F6F8),
    surfaceContainerHigh: dark ? const Color(0xFF1F1F21) : const Color(0xFFF1F1F4),
    surfaceContainerHighest: chat.received,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      iconTheme: IconThemeData(color: chat.accentTop),
      actionsIconTheme: IconThemeData(color: chat.accentTop),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: chat.accentTop,
      foregroundColor: scheme.onPrimary,
      shape: const CircleBorder(),
    ),
    extensions: [chat],
  );
}

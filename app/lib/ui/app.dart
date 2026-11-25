import 'package:material_ui/material_ui.dart';

import '../app_controller.dart';
import '../core/screen_guard.dart';
import 'enroll_screen.dart';
import 'floating_chat.dart';
import 'lock_screen.dart';
import 'home_screen.dart';
import 'profile_screen.dart';
import 'theme.dart';

/// Raiz: troca de tela pelo [Stage] e tranca ao ir para segundo plano.
class DirectApp extends StatefulWidget {
  const DirectApp({super.key, required this.controller});
  final AppController controller;

  @override
  State<DirectApp> createState() => _DirectAppState();
}

class _DirectAppState extends State<DirectApp> with WidgetsBindingObserver {
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  late final _guard = ScreenGuard(
    onScreenshot: () => _messenger.currentState?.showSnackBar(
      const SnackBar(
        content: Text('Print detectado. Conversas são confidenciais: não compartilhe.'),
      ),
    ),
  );

  @override
  void initState() {
    super.initState();
    _guard;
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_onController);
  }

  final _nav = GlobalKey<NavigatorState>();

  /// Ao trancar, some qualquer tela empilhada (chat, perfil) para a trava ficar na frente.
  void _onController() {
    if (widget.controller.stage == Stage.locked) {
      _nav.currentState?.popUntil((r) => r.isFirst);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onController);
    _guard.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `hidden` e `paused`: app fora da tela. `inactive` sozinho (diálogo do
    // sistema, permissão de câmera) não tranca.
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) {
      widget.controller.background();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _nav,
      scaffoldMessengerKey: _messenger,
      title: 'Direct',
      theme: directTheme(Brightness.light),
      darkTheme: directTheme(Brightness.dark),
      // iOS: o mini-chat flutuante fica por cima de todas as telas.
      builder: (context, child) => ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final c = widget.controller;
          final id = c.floating;
          return Stack(
            children: [
              child!,
              if (id != null && c.stage == Stage.ready)
                Overlay.wrap(child: FloatingChat(key: ValueKey(id), controller: c, conversationId: id)),
            ],
          );
        },
      ),
      home: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) => switch (widget.controller.stage) {
          Stage.booting => const Scaffold(body: SizedBox.shrink()),
          Stage.enroll => EnrollScreen(controller: widget.controller),
          Stage.locked => LockScreen(controller: widget.controller),
          Stage.profile => ProfileScreen(controller: widget.controller),
          Stage.ready => HomeScreen(controller: widget.controller),
        },
      ),
    );
  }
}

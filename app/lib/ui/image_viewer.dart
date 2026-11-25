import 'dart:typed_data';

import 'package:gal/gal.dart';
import 'package:material_ui/material_ui.dart';

import '../chat/chat_service.dart';
import '../data/db.dart';
import 'common.dart';

/// Imagem em tela cheia, sempre a partir da memória. "Salvar" registra no servidor antes de
/// gravar na galeria (PLANO 15).
class ImageViewerScreen extends StatefulWidget {
  const ImageViewerScreen({super.key, required this.svc, required this.message});
  final ChatService svc;
  final ChatMessage message;

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<ImageViewerScreen> {
  late final Future<Uint8List> _image = widget.svc.loadImage(widget.message);
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    widget.svc.addListener(_check);
  }

  @override
  void dispose() {
    widget.svc.removeListener(_check);
    super.dispose();
  }

  /// Grupo: se o autor perdeu o acesso ou o grupo saiu da memória, a foto fecha.
  void _check() {
    if (!mounted || widget.svc.imageAvailable(widget.message)) return;
    widget.svc.removeListener(_check);
    final route = ModalRoute.of(context);
    if (route != null) Navigator.of(context).removeRoute(route);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    String msg;
    try {
      final bytes = await widget.svc.prepareSave(widget.message);
      await Gal.putImageBytes(bytes, name: 'Direct_${DateTime.now().millisecondsSinceEpoch}');
      msg = 'Foto salva na galeria. O salvamento foi registrado.';
    } on GalException catch (e) {
      msg = e.type == GalExceptionType.permissionDenied
          ? 'Sem permissão para salvar na galeria.'
          : 'Não foi possível gravar na galeria.';
    } on Object catch (e) {
      msg = errorText(e);
    }
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final canSave = widget.message.seq != null;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          if (canSave)
            TextButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.download),
              label: const Text('Salvar'),
              style: TextButton.styleFrom(foregroundColor: Colors.white),
            ),
        ],
      ),
      body: FutureBuilder<Uint8List>(
        future: _image,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(errorText(snap.error!), style: const TextStyle(color: Colors.white), textAlign: TextAlign.center),
              ),
            );
          }
          return InteractiveViewer(
            maxScale: 5,
            child: Center(child: Image.memory(snap.data!, fit: BoxFit.contain, gaplessPlayback: true)),
          );
        },
      ),
    );
  }
}

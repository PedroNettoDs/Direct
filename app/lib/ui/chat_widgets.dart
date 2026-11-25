import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../data/db.dart';
import 'common.dart';
import 'theme.dart';

/// Peças visuais da conversa: usadas na tela cheia, na bolha e no flutuante, e
/// feitas para os grupos ([ChatItem.senderId], [MessageList.showSenderNames]).

/// Uma linha da conversa, pronta para a tela. `state == msgNotice` é linha de
/// sistema (o texto vai em [text]).
class ChatItem {
  const ChatItem({
    required this.id,
    required this.mine,
    required this.state,
    required this.sentAt,
    required this.text,
    this.thumb,
    this.aspect,
    this.senderId = '',
    this.senderName = '',
    this.thumbLocked = false,
  });

  /// Imagem de quem perdeu o acesso: cadeado no lugar da miniatura (D11).
  final bool thumbLocked;
  final int id;
  final bool mine;
  final int state;
  final int sentAt;
  final String text;
  final Uint8List? thumb;

  /// Largura / altura da imagem; null usa a proporção da própria miniatura.
  final double? aspect;

  /// Só para mensagens recebidas. No 1:1, [senderId] pode ficar vazio.
  final String senderId;
  final String senderName;
}

/// Intervalo a partir do qual aparece um separador de horário.
const separatorGap = Duration(minutes: 15);

/// Posição de uma linha no agrupamento.
typedef Grouping = ({bool separator, bool first, bool last});

/// [items] do mais antigo ao mais novo.
List<Grouping> groupItems(List<ChatItem> items) {
  final gap = separatorGap.inMilliseconds;
  // Linhas de sistema têm o horário em que foram detectadas, não o do histórico:
  // não contam para separar.
  int? previous;
  final separator = [
    for (final m in items)
      if (m.state == msgNotice)
        false
      else
        () {
          final s = previous == null || m.sentAt - previous! >= gap;
          previous = m.sentAt;
          return s;
        }(),
  ];
  bool joins(int a, int b) =>
      items[a].state != msgNotice &&
      items[b].state != msgNotice &&
      !separator[b] &&
      items[a].mine == items[b].mine &&
      items[a].senderId == items[b].senderId;
  return [
    for (var i = 0; i < items.length; i++)
      (
        separator: separator[i],
        first: i == 0 || !joins(i - 1, i),
        last: i == items.length - 1 || !joins(i, i + 1),
      ),
  ];
}

const _weekdays = ['SEG.', 'TER.', 'QUA.', 'QUI.', 'SEX.', 'SÁB.', 'DOM.'];
const _months = ['JAN.', 'FEV.', 'MAR.', 'ABR.', 'MAI.', 'JUN.', 'JUL.', 'AGO.', 'SET.', 'OUT.', 'NOV.', 'DEZ.'];

/// Dias de calendário entre [ms] e [now].
int _daysAgo(DateTime t, DateTime now) =>
    DateTime.utc(now.year, now.month, now.day).difference(DateTime.utc(t.year, t.month, t.day)).inDays;

/// "HOJE ÀS 20:03", "ONTEM ÀS …", "TER. ÀS …" ou "12 DE NOV. ÀS …".
String separatorLabel(int ms, DateTime now) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final days = _daysAgo(t, now);
  final day = switch (days) {
    0 => 'HOJE',
    1 => 'ONTEM',
    > 1 && < 7 => _weekdays[t.weekday - 1],
    _ => '${t.day} DE ${_months[t.month - 1]}${t.year == now.year ? '' : ' DE ${t.year}'}',
  };
  return '$day ÀS ${clock(ms)}';
}

/// Hora na lista de conversas: hora de hoje, dia da semana ou data.
String listTime(int ms, DateTime now) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final days = _daysAgo(t, now);
  if (days <= 0) return clock(ms);
  if (days < 7) return _weekdays[t.weekday - 1].toLowerCase();
  final month = _months[t.month - 1].toLowerCase();
  return '${t.day} de $month${t.year == now.year ? '' : ' de ${t.year}'}';
}

/// Avatar redondo com iniciais (não há foto de perfil). Grupo: a foto cifrada
/// dele, ou o ícone de pessoas.
class Avatar extends StatelessWidget {
  const Avatar(this.name, {super.key, this.size = 40, this.group = false, this.photo});
  final String name;
  final double size;
  final bool group;
  final Uint8List? photo;

  static const _colors = [
    Color(0xFFB4477A),
    Color(0xFF7A55C0),
    Color(0xFF2F6FB8),
    Color(0xFF1F8A80),
    Color(0xFF4F8A3C),
    Color(0xFFB0662A),
  ];

  @override
  Widget build(BuildContext context) {
    final color = _colors[name.runes.fold(0, (a, r) => (a * 31 + r) & 0x7fffffff) % _colors.length];
    if (photo != null) {
      return ClipOval(
        child: Image.memory(photo!, width: size, height: size, fit: BoxFit.cover, gaplessPlayback: true),
      );
    }
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: group ? Icon(Icons.group, color: Colors.white, size: size * 0.58) : Text(
        initials(name),
        textScaler: TextScaler.noScaling,
        style: TextStyle(color: Colors.white, fontSize: size * 0.38, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Mensagens, a mais nova embaixo.
class MessageList extends StatefulWidget {
  const MessageList({
    super.key,
    required this.items,
    this.onRetry,
    this.onOpenImage,
    this.showSenderNames = false,
    this.compact = false,
    this.now,
    this.onReachTop,
  });

  /// Rolou até o começo do que está carregado.
  final VoidCallback? onReachTop;

  /// Do mais antigo ao mais novo.
  final List<ChatItem> items;
  final void Function(int id)? onRetry;
  final void Function(int id)? onOpenImage;

  /// Grupos: nome acima do primeiro balão recebido de cada remetente.
  final bool showSenderNames;

  /// Bolha e mini-chat.
  final bool compact;

  /// Relógio dos separadores (testes).
  final DateTime? now;

  @override
  State<MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<MessageList> {
  /// Toque num balão mostra o horário dele.
  int? _timeOf;

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    final groups = groupItems(items);
    final now = widget.now ?? DateTime.now();
    final side = widget.compact ? 8.0 : 12.0;
    final list = ListView.builder(
      reverse: true,
      // O degradê depende da posição na tela: repinta junto com a rolagem.
      addRepaintBoundaries: false,
      padding: EdgeInsets.fromLTRB(side, 8, side, 8),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final i = items.length - 1 - index;
        final m = items[i];
        final g = groups[i];
        return Column(
          key: ValueKey(m.id),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (g.separator) NoticeLine(separatorLabel(m.sentAt, now)),
            if (m.state == msgNotice) NoticeLine(m.text) else _row(context, m, g),
          ],
        );
      },
    );
    if (widget.onReachTop == null) return list;
    return NotificationListener<ScrollEndNotification>(
      onNotification: (n) {
        if (n.metrics.extentAfter < 200) widget.onReachTop!();
        return false;
      },
      child: list,
    );
  }

  Widget _row(BuildContext context, ChatItem m, Grouping g) {
    final colors = ChatColors.of(context);
    final small = Theme.of(context).textTheme.labelSmall?.copyWith(color: colors.meta);
    final avatar = widget.compact ? 24.0 : 28.0;
    final note = switch (m.state) {
      msgSending => 'enviando…',
      msgFailed => 'falhou · toque para reenviar',
      _ => '',
    };
    final under = [if (_timeOf == m.id) clock(m.sentAt), if (note.isNotEmpty) note].join(' · ');
    final VoidCallback? onTap = m.state == msgFailed
        ? (widget.onRetry == null ? null : () => widget.onRetry!(m.id))
        : m.thumb != null && !m.thumbLocked
        ? (widget.onOpenImage == null ? null : () => widget.onOpenImage!(m.id))
        : () => setState(() => _timeOf = _timeOf == m.id ? null : m.id);

    return Padding(
      padding: EdgeInsets.only(top: g.first ? 8 : 2),
      child: Column(
        crossAxisAlignment: m.mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (!m.mine && widget.showSenderNames && g.first && m.senderName.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(left: avatar + 20, bottom: 2),
              child: Text(m.senderName, style: small),
            ),
          Row(
            mainAxisAlignment: m.mine ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!m.mine) ...[
                SizedBox(width: avatar, child: g.last ? Avatar(m.senderName, size: avatar) : null),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: LayoutBuilder(
                  builder: (context, box) => ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: box.maxWidth * (m.mine ? 0.8 : 0.9)),
                    child: GestureDetector(
                      onTap: onTap,
                      child: MessageBubble(item: m, first: g.first, last: g.last, compact: widget.compact),
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (under.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 36, right: 4),
              child: Text(under, style: small),
            ),
        ],
      ),
    );
  }
}

/// Balão de texto (degradê se enviado, cinza se recebido) ou imagem sem fundo.
class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.item, this.first = true, this.last = true, this.compact = false});
  final ChatItem item;

  /// Primeiro e último do grupo: decidem os cantos.
  final bool first;
  final bool last;
  final bool compact;

  /// Cantos grandes por fora, pequenos onde os balões do grupo se encostam.
  static BorderRadius radius({required bool mine, required bool first, required bool last}) {
    const big = Radius.circular(20);
    const small = Radius.circular(5);
    final top = first ? big : small;
    final bottom = last ? big : small;
    return BorderRadius.only(
      topLeft: mine ? big : top,
      bottomLeft: mine ? big : bottom,
      topRight: mine ? top : big,
      bottomRight: mine ? bottom : big,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = ChatColors.of(context);
    final corners = radius(mine: item.mine, first: first, last: last);
    final thumb = item.thumb;
    if (item.thumbLocked) {
      return Container(
        width: compact ? 160 : 220,
        height: compact ? 110 : 150,
        decoration: BoxDecoration(color: colors.received, borderRadius: corners),
        child: Icon(Icons.lock_outline, size: 36, color: colors.meta, semanticLabel: 'Imagem sem acesso'),
      );
    }
    if (thumb != null) {
      final width = compact ? 160.0 : 220.0;
      final image = Image.memory(
        thumb,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        filterQuality: FilterQuality.low,
      );
      return ClipRRect(
        borderRadius: corners,
        child: item.aspect == null
            ? ConstrainedBox(constraints: BoxConstraints(maxWidth: width, maxHeight: width), child: image)
            : SizedBox(width: width, child: AspectRatio(aspectRatio: item.aspect!, child: image)),
      );
    }
    final padded = Padding(
      padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 14, vertical: compact ? 7 : 9),
      child: Text(
        item.text,
        style: TextStyle(
          color: item.state == msgSealed
              ? colors.meta
              : item.mine
              ? colors.sentText
              : colors.receivedText,
          fontSize: compact ? 14 : 16,
          height: 1.3,
          fontStyle: item.state == msgWaitingKey || item.state == msgUnsupported ? FontStyle.italic : null,
        ),
      ),
    );
    if (item.mine && item.state != msgSealed) return ScreenGradient(colors: colors.sentGradient, radius: corners, child: padded);
    return DecoratedBox(
      decoration: BoxDecoration(color: colors.received, borderRadius: corners),
      child: padded,
    );
  }
}

/// Fundo com o trecho de um degradê que cobre a área de rolagem inteira: a cor
/// depende de onde o balão está na tela.
class ScreenGradient extends StatelessWidget {
  const ScreenGradient({super.key, required this.colors, required this.radius, required this.child});
  final List<Color> colors;
  final BorderRadius radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scrollable = Scrollable.maybeOf(context);
    return Builder(
      builder: (own) => CustomPaint(
        painter: _GradientPainter(scrollable, own, colors, radius),
        child: child,
      ),
    );
  }
}

class _GradientPainter extends CustomPainter {
  _GradientPainter(this.scrollable, this.own, this.colors, this.radius) : super(repaint: scrollable?.position);
  final ScrollableState? scrollable;
  final BuildContext own;
  final List<Color> colors;
  final BorderRadius radius;

  @override
  void paint(Canvas canvas, Size size) {
    var top = 0.0;
    var height = size.height;
    final viewport = scrollable?.context.findRenderObject();
    final box = own.findRenderObject();
    if (viewport is RenderBox && box is RenderBox) {
      top = -box.localToGlobal(Offset.zero, ancestor: viewport).dy;
      height = viewport.size.height;
    }
    final paint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, top),
        Offset(0, top + height),
        colors,
        [for (var i = 0; i < colors.length; i++) i / (colors.length - 1)],
      );
    canvas.drawRRect(radius.toRRect(Offset.zero & size), paint);
  }

  @override
  bool shouldRepaint(_GradientPainter old) => true;
}

/// Barra de digitação. Câmera e galeria só aparecem se houver quem as atenda
/// (a bolha não envia imagem). Campo vazio mostra o coração.
class Composer extends StatelessWidget {
  const Composer({
    super.key,
    required this.controller,
    required this.onSend,
    required this.onLike,
    this.onCamera,
    this.onGallery,
    this.onChanged,
    this.compact = false,
  });
  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onLike;
  final VoidCallback? onCamera;
  final VoidCallback? onGallery;
  final ValueChanged<String>? onChanged;
  final bool compact;

  /// O que o coração envia, como mensagem de texto comum.
  static const like = '💙';

  @override
  Widget build(BuildContext context) {
    final colors = ChatColors.of(context);
    Widget button(String tooltip, IconData icon, VoidCallback onPressed) => IconButton(
      tooltip: tooltip,
      icon: Icon(icon),
      color: colors.accentBottom,
      visualDensity: compact ? VisualDensity.compact : null,
      onPressed: onPressed,
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(onCamera == null && onGallery == null ? 10 : 2, 4, 2, compact ? 4 : 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (onCamera != null) button('Câmera', Icons.photo_camera, onCamera!),
          if (onGallery != null) button('Galeria', Icons.image, onGallery!),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              minLines: 1,
              maxLines: compact ? 3 : 5,
              textCapitalization: TextCapitalization.sentences,
              enableIMEPersonalizedLearning: false,
              decoration: InputDecoration(
                hintText: 'Mensagem',
                hintStyle: TextStyle(color: colors.meta),
                filled: true,
                fillColor: colors.field,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: compact ? 8 : 11),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) => value.text.trim().isEmpty
                ? button('Curtir', Icons.favorite, onLike)
                : button('Enviar', Icons.send, onSend),
          ),
        ],
      ),
    );
  }
}

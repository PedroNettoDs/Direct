import 'package:direct/data/db.dart';
import 'package:direct/ui/chat_widgets.dart';
import 'package:direct/ui/common.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

int at(int day, int hour, int minute) => DateTime(2026, 11, day, hour, minute).millisecondsSinceEpoch;

ChatItem item(int id, bool mine, int sentAt, {int state = msgOk, String sender = ''}) =>
    ChatItem(id: id, mine: mine, state: state, sentAt: sentAt, text: 'm$id', senderId: sender, senderName: sender);

void main() {
  test('agrupa por remetente; intervalo e linha de sistema quebram o grupo', () {
    final g = groupItems([
      item(0, false, at(25, 10, 0), sender: 'ana'),
      item(1, false, at(25, 10, 1), sender: 'ana'),
      item(2, false, at(25, 10, 2), sender: 'bia'), // grupos: outro remetente
      item(3, true, at(25, 10, 3)),
      item(4, false, at(25, 12, 0), state: msgNotice),
      item(5, true, at(25, 10, 4)), // o horário do aviso não separa
      item(6, true, at(25, 11, 0)),
    ]);
    expect([for (final x in g) x.separator], [true, false, false, false, false, false, true]);
    expect([for (final x in g) x.first], [true, false, true, true, true, true, true]);
    expect([for (final x in g) x.last], [false, true, true, true, true, true, true]);
  });

  test('separador em pt_BR', () {
    final now = DateTime(2026, 11, 26, 8, 0); // quinta
    expect(separatorLabel(at(26, 7, 5), now), 'HOJE ÀS 07:05');
    expect(separatorLabel(at(25, 23, 59), now), 'ONTEM ÀS 23:59');
    expect(separatorLabel(at(24, 20, 3), now), 'TER. ÀS 20:03');
    expect(separatorLabel(at(12, 20, 3), now), '12 DE NOV. ÀS 20:03');
    expect(separatorLabel(DateTime(2025, 3, 2, 9, 0).millisecondsSinceEpoch, now), '2 DE MAR. DE 2025 ÀS 09:00');
    expect(listTime(at(26, 7, 5), now), '07:05');
    expect(listTime(at(24, 20, 3), now), 'ter.');
    expect(listTime(at(12, 20, 3), now), '12 de nov.');
  });

  test('iniciais', () {
    expect(initials('Bia Souza'), 'BS');
    expect(initials('  marcos '), 'M');
    expect(initials('Ana de Souza Lima'), 'AL');
    expect(initials(''), '?');
  });

  testWidgets('campo vazio curte; com texto envia', (tester) async {
    final text = TextEditingController();
    addTearDown(text.dispose);
    final calls = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Composer(controller: text, onSend: () => calls.add('enviar'), onLike: () => calls.add('curtir')),
        ),
      ),
    );
    expect(find.byTooltip('Câmera'), findsNothing);
    await tester.tap(find.byTooltip('Curtir'));
    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    expect(find.byTooltip('Enviar'), findsNothing);
    await tester.enterText(find.byType(TextField), 'oi');
    await tester.pump();
    await tester.tap(find.byTooltip('Enviar'));
    expect(calls, ['curtir', 'enviar']);
  });
}

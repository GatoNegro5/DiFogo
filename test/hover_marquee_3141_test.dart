import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/ui/widgets/hover_marquee_text.dart';

// 3.1.41: HoverMarqueeText. Fuente de test: cada caracter mide fontSize px.
Widget _host(String text, {double width = 100}) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
        child: HoverMarqueeText(text, style: const TextStyle(fontSize: 10)),
      ),
    ),
  ),
);

Future<TestGesture> _mouse(WidgetTester tester) async {
  final TestGesture g = await tester.createGesture(
    kind: PointerDeviceKind.mouse,
  );
  await g.addPointer(location: const Offset(700, 500));
  addTearDown(g.removePointer);
  return g;
}

void main() {
  test('marqueeOverflow: 0 si cabe, sobrante si no cabe', () {
    const TextStyle s = TextStyle(fontSize: 10);
    expect(marqueeOverflow('abc', s, 100), 0);
    expect(marqueeOverflow('a' * 30, s, 100), closeTo(200, 1));
    expect(marqueeOverflow('a' * 30, s, double.infinity), 0);
    expect(marqueeOverflow('', s, 100), 0);
  });

  testWidgets('titulo corto: Text normal, el mouse no lo anima', (
    tester,
  ) async {
    await tester.pumpWidget(_host('Corto'));
    final TestGesture g = await _mouse(tester);
    await g.moveTo(tester.getCenter(find.byType(HoverMarqueeText)));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(SingleChildScrollView), findsNothing);
    final Text t = tester.widget<Text>(find.text('Corto'));
    expect(t.overflow, TextOverflow.ellipsis);
  });

  testWidgets('titulo largo: llega al final, pausa, vuelve y resetea', (
    tester,
  ) async {
    final String long = 'Cantante (110) - ${'x' * 30}';
    await tester.pumpWidget(_host(long));
    expect(
      tester.widget<Text>(find.text(long)).overflow,
      TextOverflow.ellipsis,
    );
    final TestGesture g = await _mouse(tester);
    await g.moveTo(tester.getCenter(find.byType(HoverMarqueeText)));
    await tester.pump();
    await tester.pump();
    final ScrollController c = tester
        .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .controller!;
    final double end = c.position.maxScrollExtent;
    // Material suma letterSpacing al estilo: el tope supera 47*10-100.
    expect(end, greaterThan(360));
    // ~40 px/s: a mitad de camino ya se movio, al final llega al tope.
    final int ms = (end / 40 * 1000).round();
    await tester.pump(Duration(milliseconds: ms ~/ 2));
    expect(c.offset, greaterThan(0));
    await tester.pump(Duration(milliseconds: ms ~/ 2 + 50));
    expect(c.offset, closeTo(end, 0.5));
    // Pausa ~600 ms en el final.
    await tester.pump(const Duration(milliseconds: 300));
    expect(c.offset, closeTo(end, 0.5));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(Duration(milliseconds: ms + 50));
    expect(c.offset, closeTo(0, 0.5));
    // Sale el mouse: vuelve el Text con ellipsis.
    await g.moveTo(const Offset(700, 500));
    await tester.pump();
    expect(find.byType(SingleChildScrollView), findsNothing);
    expect(
      tester.widget<Text>(find.text(long)).overflow,
      TextOverflow.ellipsis,
    );
  });

  testWidgets('salir a mitad del desplazamiento resetea al inicio', (
    tester,
  ) async {
    final String long = 'y' * 40;
    await tester.pumpWidget(_host(long));
    final TestGesture g = await _mouse(tester);
    await g.moveTo(tester.getCenter(find.byType(HoverMarqueeText)));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    await g.moveTo(const Offset(700, 500));
    await tester.pump();
    expect(find.byType(SingleChildScrollView), findsNothing);
    await tester.pump(const Duration(seconds: 20));
    expect(tester.takeException(), isNull);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/ui/widgets/theater_lyrics_view.dart';

Widget _host(int idx, List<String> lines, {double h = 400}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: 360,
        height: h,
        child: TheaterLyricsView(lines: lines, activeIndex: idx),
      ),
    ),
  ),
);

void main() {
  final lines = List<String>.generate(40, (i) => 'Linea $i');

  test('3151 cilindro movil: 3 lineas caben en la caja', () {
    expect(lyricWheelExtent(57) * 3, lessThanOrEqualTo(57));
    expect(lyricWheelExtent(55), closeTo(18.33, 0.01));
    expect(lyricWheelExtent(120), 20.0);
    expect(lyricWheelExtent(double.infinity), 20.0);
  });

  test('3151 teatro: objetivo centrado y acotado', () {
    expect(theaterScrollTarget(0, 64, 1000), 0);
    expect(theaterScrollTarget(5, 64, 1000), 320);
    expect(theaterScrollTarget(39, 64, 1000), 1000);
    expect(theaterScrollTarget(-1, 64, 1000), 0);
  });

  testWidgets('3151 teatro: la linea activa queda centrada', (tester) async {
    await tester.pumpWidget(_host(0, lines));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_host(1, lines));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_host(20, lines));
    await tester.pumpAndSettle();
    final double viewMid = tester.getCenter(find.byType(TheaterLyricsView)).dy;
    final double lineMid = tester.getCenter(find.text('Linea 20')).dy;
    expect((lineMid - viewMid).abs(), lessThan(1.0));
    await tester.pumpWidget(_host(21, lines));
    await tester.pump(const Duration(milliseconds: 200));
    final double mid = tester.getCenter(find.text('Linea 21')).dy;
    expect(mid, greaterThan(viewMid));
    await tester.pumpAndSettle();
    expect(
      (tester.getCenter(find.text('Linea 21')).dy - viewMid).abs(),
      lessThan(1.0),
    );
  });

  testWidgets('3151 teatro: arrastre del usuario pausa el seguimiento', (
    tester,
  ) async {
    await tester.pumpWidget(_host(10, lines));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pumpAndSettle();
    final st = tester.state<TheaterLyricsViewState>(
      find.byType(TheaterLyricsView),
    );
    final double before = st.controller.offset;
    await tester.pumpWidget(_host(11, lines));
    await tester.pumpAndSettle();
    expect(st.controller.offset, before);
  });
}

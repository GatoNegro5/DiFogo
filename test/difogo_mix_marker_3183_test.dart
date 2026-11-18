import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/ui/workspaces/livedj_mix_marker.dart';
import 'package:difogo/ui/workspaces/livedj_spotify_panel.dart';

// 3.1.83: la linea roja del punto de mezcla (customMixOutMs) sale en toda
// barra de progreso de AutomixDj con un solo widget compartido, y
// AutomixDj sigue abriendo en Modo Spotify. Solo lectura del repo.

Widget _bar(double width, int mixMs, int durMs) => MaterialApp(
  home: Center(
    child: SizedBox(
      width: width,
      height: 20,
      child: Stack(
        key: const Key('bar'),
        children: <Widget>[
          const SizedBox.expand(),
          liveDjMixMarker(6, mixMs, durMs),
        ],
      ),
    ),
  ),
);

void main() {
  testWidgets('3183 marcador: posicion = inset + ancho * mix/dur', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_bar(212, 150000, 200000));
    final Finder f = find.byKey(const Key('livedj-mix-marker'));
    expect(f, findsOneWidget);
    final double left =
        tester.getTopLeft(f).dx -
        tester.getTopLeft(find.byKey(const Key('bar'))).dx;
    // 6 + 200 * 0.75 - 1 = 155
    expect(left, closeTo(155, 0.01));
    expect(tester.getSize(f).width, 2);
  });

  testWidgets('3183 marcador: sin punto valido no se dibuja', (
    WidgetTester tester,
  ) async {
    for (final List<int> c in <List<int>>[
      <int>[0, 200000],
      <int>[150000, 0],
      <int>[200000, 200000],
    ]) {
      await tester.pumpWidget(_bar(212, c[0], c[1]));
      expect(find.byKey(const Key('livedj-mix-marker')), findsNothing);
    }
  });

  test('3183 todas las barras de AutomixDj usan el mismo marcador', () {
    final Map<String, int> uses = <String, int>{
      'lib/ui/workspaces/livedj_spotify_panel.dart': 1,
      'lib/ui/workspaces/livedj_workspace.dart': 2,
      'lib/ui/workspaces/livedj_folder_playlist.dart': 1,
    };
    for (final MapEntry<String, int> e in uses.entries) {
      final String src = File(e.key).readAsStringSync();
      expect(
        'liveDjMixMarker('.allMatches(src).length,
        e.value,
        reason: e.key,
      );
      expect(src.contains('_mixMarker('), isFalse, reason: e.key);
      expect(
        'Slider('.allMatches(src).length,
        e.value,
        reason: '${e.key}: cada Slider con su marcador',
      );
    }
    final String spotify = File(
      'lib/ui/workspaces/livedj_spotify_panel.dart',
    ).readAsStringSync();
    expect(
      spotify.contains('liveDjMixMarker(6, s.customMixOutMs, '),
      isTrue,
    );
  });

  test('3183 AutomixDj abre en Modo Spotify', () {
    final ProviderContainer c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(liveDjSpotifyModeProvider), isTrue);
    expect(
      File('lib/main.dart').readAsStringSync().contains('kStartRoute = 5'),
      isTrue,
    );
    expect(
      File('lib/djiphone/main.dart').readAsStringSync().contains(
        'int build() => 5;',
      ),
      isTrue,
    );
  });
}

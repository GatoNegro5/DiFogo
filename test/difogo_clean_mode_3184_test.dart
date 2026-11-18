import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/track_name_clean.dart';
import 'package:difogo/providers/livedj_provider.dart';
import 'package:difogo/providers/theme_provider.dart';
import 'package:difogo/ui/curator_inbox_dialog.dart';
import 'package:difogo/ui/vibe_hub_view.dart';
import 'package:difogo/ui/workspaces/livedj_spotify_panel.dart';
import 'package:difogo/ui/workspaces/livedj_workspace.dart';

// 3.1.84 Consumer Clean Mode: la pantalla principal sin jerga de DJ; todo
// lo tecnico en la hoja Modo DJ.

class _Live extends LiveDjNotifier {
  _Live(this.seed);
  final LiveDjState seed;
  @override
  LiveDjState build() => seed;
}

Future<void> _font(String family, String path) async {
  final File f = File(path);
  if (!f.existsSync()) return;
  final FontLoader l = FontLoader(family)
    ..addFont(Future<ByteData>.value(
      ByteData.sublistView(f.readAsBytesSync()),
    ));
  await l.load();
}

LiveDjState _seed() => LiveDjState(
  isPlaying: true,
  currentTrackPath: '/m/Teddy - Fuego (125 BPM).mp3',
  queue: <File>[
    File('/m/Daddy Yankee - Ghosting (91 BPM).mp3'),
    File('/m/Shakira - Loca (122 BPM).mp3'),
  ],
  position: const Duration(seconds: 30),
  duration: const Duration(seconds: 200),
  customMixOutMs: 150000,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final String win = Platform.environment['WINDIR'] ?? r'C:\Windows';
    await _font('Consolas', '$win\\Fonts\\consola.ttf');
    await _font('Roboto', '$win\\Fonts\\segoeui.ttf');
  });

  test('titulos limpios: sin .mp3 ni BPM', () {
    expect(
      cleanTrackTitle(r'C:\M\Daddy Yankee - Ghosting (91 BPM).mp3'),
      'Daddy Yankee - Ghosting',
    );
    expect(cleanTrackTitle('/m/Uno - Besame.mp3'), 'Uno - Besame');
    expect(stripBpmTag('Ghosting (91 BPM)'), 'Ghosting');
    final LiveDjState s = _seed();
    expect(spotifyCleanNextLabel(s), 'Siguiente: Daddy Yankee · Ghosting');
    expect(spotifyTrackLabels(s.currentTrackPath).title, 'Fuego');
    // 3.1.85: iconos vectoriales en lugar de emoji.
    expect(kRadioDiscoveryLabel, 'Radio');
    expect(acceptNewMusicLabel(1), 'Nuevas (1)');
  });

  test('3.1.85 chips Radio y Nuevas con Icon vectorial, sin emoji', () {
    final String hub = File('lib/ui/vibe_hub_view.dart').readAsStringSync();
    final String cur = File(
      'lib/ui/curator_inbox_dialog.dart',
    ).readAsStringSync();
    expect(hub.contains('Icons.local_fire_department_rounded'), isTrue);
    expect(cur.contains('Icons.auto_awesome_rounded'), isTrue);
    expect(hub.contains("'🔥 Radio'"), isFalse);
    expect(cur.contains('✨ Nuevas'), isFalse);
  });

  for (final bool spotify in <bool>[true, false]) {
    for (final Size size in <Size>[
      const Size(1366, 768),
      const Size(393, 852),
    ]) {
      final bool phone = size.width < 600;
      testWidgets(
        'cabecera limpia ${spotify ? 'Spotify Pro' : 'Lista'} '
        '${phone ? 'telefono' : 'escritorio'}',
        (WidgetTester t) async {
          t.view.physicalSize = size;
          t.view.devicePixelRatio = 1;
          addTearDown(t.view.reset);
          final ProviderContainer c = ProviderContainer(
            overrides: [liveDjProvider.overrideWith(() => _Live(_seed()))],
          );
          addTearDown(c.dispose);
          c.read(liveDjSpotifyModeProvider.notifier).state = spotify;
          await t.pumpWidget(
            UncontrolledProviderScope(
              container: c,
              child: MaterialApp(
                theme: GatoMixTheme.darkTheme,
                home: Scaffold(
                  body: LiveDjPlayerPanel(compactOverride: phone),
                ),
              ),
            ),
          );
          await t.pump();
          expect(t.takeException(), isNull);
          expect(find.byKey(const Key('livedj-mode-dj-button')), findsOneWidget);
          expect(find.text('TIPO DE MEZCLA:'), findsNothing);
          expect(find.byKey(const Key('spotify-mix-chip')), findsNothing);
          expect(find.byKey(const Key('spotify-fx-badge')), findsNothing);
          expect(find.byKey(const Key('classic-fx-badge')), findsNothing);
          expect(find.byKey(const Key('live-dj-next-strip')), findsNothing);
          expect(find.byKey(const Key('spotify-next-mix')), findsNothing);
          expect(find.textContaining('.mp3'), findsNothing);
          expect(find.textContaining('BPM)'), findsNothing);
          expect(find.textContaining('RADIO DESCUBRIMIENTO'), findsNothing);
          if (!spotify && phone) {
            // 3.1.85: tarjeta compacta: sin hueco bajo barra y controles.
            expect(
              t.getSize(find.byType(LiveDjPlayerPanel)).height,
              lessThan(300),
            );
          }
          await t.tap(find.byKey(const Key('livedj-mode-dj-button')));
          await t.pump();
          await t.pump(const Duration(milliseconds: 400));
          expect(find.byKey(const Key('livedj-mode-dj-panel')), findsOneWidget);
          expect(find.byKey(const Key('dj-mix-type')), findsOneWidget);
          expect(find.byKey(const Key('dj-fx-badge')), findsOneWidget);
          expect(find.byKey(const Key('dj-next-mix')), findsOneWidget);
          expect(t.takeException(), isNull);
          await t.pumpWidget(const SizedBox.shrink());
          await t.pump();
        },
      );
    }
  }
}

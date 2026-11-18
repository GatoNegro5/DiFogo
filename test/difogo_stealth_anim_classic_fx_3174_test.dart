import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/genre_mix_fx.dart';
import 'package:difogo/providers/livedj_provider.dart';
import 'package:difogo/providers/mix_formula.dart';
import 'package:difogo/providers/session_provider.dart';
import 'package:difogo/providers/vibe_hub_provider.dart';
import 'package:difogo/ui/workspaces/livedj_deck_relevo.dart';
import 'package:difogo/ui/workspaces/livedj_dj_sheet.dart';
import 'package:difogo/ui/workspaces/livedj_spotify_panel.dart';
import 'package:difogo/ui/workspaces/livedj_workspace.dart';

// 3.1.74: el relevo en pantalla de Stealth dura la ventana real de 10-12 s
// y el badge FX (AUTO/FIJO) esta en Spotify Pro y en la consola clasica con
// el mismo estado. Todo en %TEMP%, sin red ni audio.

class _Live extends LiveDjNotifier {
  _Live(this.seed);
  final LiveDjState seed;
  @override
  LiveDjState build() => seed;
}

final String _sep = Platform.pathSeparator;

String _read(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');

void main() {
  late Directory tmp;
  late String root;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('gmx_3174_');
    root = '${tmp.path}${_sep}Musica';
    Directory(root).createSync(recursive: true);
    debugVibeRootOverride = root;
    debugVibeStatePath = '${tmp.path}${_sep}state.json';
    debugVibeHubStatePath = debugVibeStatePath;
    debugVibeHubScan = (String r) async => const <VibeGenre>[];
    debugStationSessionsPath = '${tmp.path}${_sep}sessions.json';
    debugTrackGenreIndexPath = '${tmp.path}${_sep}genre_index.json';
  });

  tearDown(() {
    debugVibeRootOverride = null;
    debugVibeStatePath = null;
    debugVibeHubStatePath = null;
    debugVibeHubScan = null;
    debugStationSessionsPath = null;
    debugTrackGenreIndexPath = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  LiveDjState seed() => LiveDjState(
    currentTrackPath: '$root${_sep}Electronica${_sep}Uno - Pulso.mp3',
    queue: <File>[File('$root${_sep}Electronica${_sep}Dos - Laser.mp3')],
    position: const Duration(seconds: 30),
    duration: const Duration(seconds: 200),
    customMixOutMs: 90000,
  );

  test('3174 relevo de Stealth = ventana real de 10-12 s', () {
    for (double bpm = 60; bpm <= 200; bpm += 1) {
      final int ms = relevoDurationMs(
        derive: true,
        mode: LiveDjMixMode.activeSync,
        formula: MixFormula.stealthGap,
        bpm: bpm,
        durationMs: 200000,
      );
      expect(ms, stealthWindowMs(bpm), reason: '$bpm');
      expect(ms, inInclusiveRange(10000, 12000), reason: '$bpm');
    }
    expect(
      relevoDurationMs(
        derive: true,
        mode: LiveDjMixMode.activeSync,
        formula: MixFormula.stealthGap,
      ),
      11000,
    );
    // El temporizador viejo (phraseFadeMs, 8-18 s) ya no existe en el relevo.
    final String relevo = _read('lib/ui/workspaces/livedj_deck_relevo.dart');
    expect(relevo.contains('phraseFadeMs('), isFalse);
    expect(
      relevo.contains(
        'if (formula == MixFormula.stealthGap) return stealthWindowMs(bpm);',
      ),
      isTrue,
    );
    // El motor publica la misma ventana que usa el fundido de Stealth y la
    // vista la toma.
    final String ld = _read('lib/providers/livedj_provider.dart');
    expect(ld.contains('? stealthWindowMs(_extractBpm(nextTrack))'), isTrue);
    final String fp = _read('lib/ui/workspaces/livedj_folder_playlist.dart');
    expect(fp.contains('formula == MixFormula.stealthGap) {'), isTrue);
    expect(fp.contains('if (published > 0) ms = published;'), isTrue);
  });

  testWidgets('3174 badge FX en la hoja Modo DJ (3.1.84)', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final ProviderContainer c = ProviderContainer(
      overrides: [liveDjProvider.overrideWith(() => _Live(seed()))],
    );
    addTearDown(c.dispose);
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(
          home: Scaffold(body: LiveDjModeDjPanel()),
        ),
      ),
    );
    await t.pump();
    final Finder badge = find.byKey(const Key('dj-fx-badge'));
    expect(badge, findsOneWidget);
    expect(find.text('FX · PHRASE 8 + HIGHPASS SWEEP · AUTO'), findsOneWidget);
    await t.tap(badge);
    await t.pump();
    expect(c.read(mixFormulaLockedProvider), isTrue);
    expect(
      find.text('FX · ACTIVE BEATMATCHING + HIGHPASS SWEEP · FIJO'),
      findsOneWidget,
    );
    await t.tap(badge);
    await t.pump();
    expect(c.read(mixFormulaLockedProvider), isFalse);
    expect(t.takeException(), isNull);
  });

  testWidgets('3174 badge FX en la consola clasica (estado compartido)', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final ProviderContainer c = ProviderContainer(
      overrides: [liveDjProvider.overrideWith(() => _Live(seed()))],
    );
    addTearDown(c.dispose);
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(
          home: Scaffold(body: LiveDjPlayerPanel(compactOverride: false)),
        ),
      ),
    );
    await t.pump();
    // 3.1.84: la consola clasica abre la misma hoja Modo DJ.
    expect(find.byKey(const Key('classic-fx-badge')), findsNothing);
    // La consola clasica no muestra el panel Spotify.
    expect(find.byType(LiveDjSpotifyPanel), findsNothing);
    await t.tap(find.byKey(const Key('livedj-mode-dj-button')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    final Finder badge = find.byKey(const Key('dj-fx-badge'));
    expect(badge, findsOneWidget);
    expect(find.text('FX · PHRASE 8 + HIGHPASS SWEEP · AUTO'), findsOneWidget);
    await t.tap(badge);
    await t.pump();
    expect(c.read(mixFormulaLockedProvider), isTrue);
    expect(
      find.text('FX · ACTIVE BEATMATCHING + HIGHPASS SWEEP · FIJO'),
      findsOneWidget,
    );
    // Mismo estado que Spotify Pro: cambiarlo desde fuera se ve aqui.
    c.read(mixFormulaLockedProvider.notifier).state = false;
    await t.pump();
    expect(find.text('FX · PHRASE 8 + HIGHPASS SWEEP · AUTO'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}

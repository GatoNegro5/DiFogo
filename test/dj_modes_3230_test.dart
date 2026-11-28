import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/dj_lyrics.dart';
import 'package:difogo/core/genre_stations.dart';
import 'package:difogo/providers/dj_ui_provider.dart';
import 'package:difogo/providers/livedj_provider.dart';
import 'package:difogo/providers/session_provider.dart';
import 'package:difogo/providers/theme_provider.dart';
import 'package:difogo/providers/vibe_hub_provider.dart';
import 'package:difogo/ui/workspaces/dj_mode_bar.dart';
import 'package:difogo/ui/workspaces/livedj_workspace.dart';

// 3.2.30 Dj: segmentado [Automix | Radio | Fiesta] excluyente, boton
// Letras y `_dj_ui.json`. Restaurar solo pinta (no suena); cambiar de modo
// nunca corta. Todo en %TEMP%, sin red ni audio.

final String _sep = Platform.pathSeparator;

String _src(String rel) =>
    File(rel).readAsStringSync().replaceAll('\r\n', '\n');

class _Hub extends VibeHubNotifier {
  _Hub(this.calls, {this.fiesta = false, this.discoveryDelay});
  final List<String> calls;
  final bool fiesta;
  final Duration? discoveryDelay;
  @override
  VibeHubState build() => VibeHubState(fiestaMode: fiesta);
  @override
  Future<void> setFiestaMode(bool on) async {
    calls.add('fiesta:$on');
    state = state.copyWith(fiestaMode: on);
  }

  @override
  Future<int> setDiscovery(bool on) async {
    calls.add('discovery:$on');
    state = state.copyWith(discoveryOn: on);
    final Duration? d = discoveryDelay;
    if (on && d != null) await Future<void>.delayed(d);
    return 0;
  }
}

class _Live extends LiveDjNotifier {
  _Live(this.seed, this.calls);
  final LiveDjState seed;
  final List<String> calls;
  @override
  LiveDjState build() => seed;
  @override
  Future<void> togglePlayPause() async => calls.add('togglePlayPause');
  @override
  Future<void> forceNext({int? queueIndex}) async => calls.add('forceNext');
  @override
  Future<void> playTrackFromQueue(int index) async => calls.add('play');
  @override
  Future<void> toggleRadio() async {
    calls.add('radio:${!state.radioOn}');
    state = state.copyWith(radioOn: !state.radioOn);
  }
}

void main() {
  late Directory tmp;
  late String uiPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('gmx_dj_3230_');
    uiPath = '${tmp.path}${_sep}DjPlaylists$_sep$kDjUiFileName';
    debugDjUiPath = uiPath;
    DjUiNotifier.debugResetColdStart();
  });

  tearDown(() {
    debugDjUiPath = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  ProviderContainer make(
    List<String> hubCalls,
    List<String> liveCalls, {
    LiveDjState? live,
    bool fiesta = false,
    Duration? discoveryDelay,
  }) {
    final ProviderContainer c = ProviderContainer(
      overrides: [
        vibeHubProvider.overrideWith(
          () => _Hub(
            hubCalls,
            fiesta: fiesta,
            discoveryDelay: discoveryDelay,
          ),
        ),
        liveDjProvider.overrideWith(
          () => _Live(live ?? LiveDjState(), liveCalls),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Map<String, dynamic> saved() =>
      jsonDecode(File(uiPath).readAsStringSync()) as Map<String, dynamic>;

  test('modo, Letras y fuente se guardan en _dj_ui.json y se restauran '
      'sin sonar', () async {
    final List<String> hub = <String>[];
    final List<String> live = <String>[];
    final ProviderContainer c1 = make(hub, live);
    await c1.read(djUiProvider.notifier).setMode(DjMode.radio);
    c1.read(djUiProvider.notifier).setLyrics(true);
    c1.read(djUiProvider.notifier).noteFolder('C:/m/Merengue');
    final Map<String, dynamic> j = saved();
    expect(j['schema'], 1);
    expect(j['mode'], 'radio');
    expect(j['lyrics'], isTrue);
    expect(j['source'], 'carpeta');
    expect(j['lastFolder'], 'C:/m/Merengue');
    expect(
      j.keys.toSet(),
      containsAll(<String>[
        'schema',
        'mode',
        'lyrics',
        'source',
        'lastGenre',
        'lastFolder',
        'lastFiesta',
      ]),
    );

    // Reabrir (proceso nuevo): pinta Radio y Letras; no bombea ni suena.
    DjUiNotifier.debugResetColdStart();
    final List<String> hub2 = <String>[];
    final List<String> live2 = <String>[];
    final ProviderContainer c2 = make(hub2, live2);
    final DjUiState s = c2.read(djUiProvider);
    expect(s.mode, DjMode.radio);
    expect(s.lyrics, isTrue);
    expect(s.lastFolder, 'C:/m/Merengue');
    await Future<void>.delayed(Duration.zero);
    expect(c2.read(vibeHubProvider).discoveryOn, isTrue);
    expect(hub2, isEmpty, reason: 'restaurar no llama setDiscovery');
    expect(live2, isEmpty, reason: 'restaurar no suena');
  });

  test(
    'si el archivo y el motor discrepan manda el motor y se corrige',
    () async {
      Directory(File(uiPath).parent.path).createSync(recursive: true);
      File(uiPath).writeAsStringSync(
        jsonEncode(<String, Object?>{'schema': 1, 'mode': 'fiesta'}),
      );
      final ProviderContainer c = make(<String>[], <String>[]);
      expect(c.read(djUiProvider).mode, DjMode.automix);
      await Future<void>.delayed(Duration.zero);
      expect(saved()['mode'], 'automix');

      DjUiNotifier.debugResetColdStart();
      final ProviderContainer c2 = make(<String>[], <String>[], fiesta: true);
      expect(c2.read(djUiProvider).mode, DjMode.fiesta);
    },
  );

  test('cambiar de modo con musica sonando no corta ni llama play', () async {
    final List<String> hub = <String>[];
    final List<String> live = <String>[];
    final ProviderContainer c = make(
      hub,
      live,
      live: LiveDjState(
        isPlaying: true,
        currentTrackPath: 'C:/m/Salsa/a.mp3',
        position: const Duration(seconds: 42),
        radioOn: true,
      ),
    );
    final DjUiNotifier n = c.read(djUiProvider.notifier);
    for (final DjMode m in <DjMode>[
      DjMode.automix,
      DjMode.radio,
      DjMode.fiesta,
      DjMode.automix,
    ]) {
      await n.setMode(m);
      final LiveDjState s = c.read(liveDjProvider);
      expect(s.isPlaying, isTrue, reason: m.name);
      expect(s.currentTrackPath, 'C:/m/Salsa/a.mp3', reason: m.name);
      expect(s.position, const Duration(seconds: 42));
    }
    expect(live.where((String x) => x != 'radio:false'), isEmpty);
    expect(live, <String>['radio:false']);
  });

  test('modos excluyentes', () async {
    final List<String> hub = <String>[];
    final ProviderContainer c = make(hub, <String>[]);
    final DjUiNotifier n = c.read(djUiProvider.notifier);
    VibeHubState h() => c.read(vibeHubProvider);

    await n.setMode(DjMode.fiesta);
    expect(h().fiestaMode, isTrue);
    expect(h().discoveryOn, isFalse);
    await n.setMode(DjMode.radio);
    expect(h().fiestaMode, isFalse);
    expect(h().discoveryOn, isTrue);
    await n.setMode(DjMode.fiesta);
    expect(h().discoveryOn, isFalse);
    expect(h().fiestaMode, isTrue);
    await n.setMode(DjMode.automix);
    expect(h().fiestaMode, isFalse);
    expect(h().discoveryOn, isFalse);
    expect(c.read(liveDjProvider).radioOn, isFalse);
    expect(c.read(djUiProvider).mode, DjMode.automix);
  });

  test('3236 Fiesta-Radio-Fiesta y Automix: un Radio lento no deshace '
      'el toque siguiente', () async {
    Future<void> round(DjMode back) async {
      final List<String> hub = <String>[];
      final ProviderContainer c = make(
        hub,
        <String>[],
        discoveryDelay: const Duration(milliseconds: 80),
      );
      final DjUiNotifier n = c.read(djUiProvider.notifier);
      VibeHubState h() => c.read(vibeHubProvider);

      await n.setMode(DjMode.fiesta);
      expect(h().fiestaMode, isTrue);
      expect(c.read(djUiProvider).mode, DjMode.fiesta);

      final Future<void> radio = n.setMode(DjMode.radio);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(djUiProvider).mode, DjMode.radio);

      await n.setMode(back);
      await radio;
      expect(c.read(djUiProvider).mode, back, reason: back.name);
      expect(h().fiestaMode, back == DjMode.fiesta, reason: back.name);
      expect(h().discoveryOn, isFalse, reason: back.name);
    }

    await round(DjMode.fiesta);
    await round(DjMode.automix);
  });

  test(
    'Fiesta encendida desde el Hub pasa a ser el modo y apaga la Radio',
    () async {
      final ProviderContainer c = make(<String>[], <String>[]);
      await c.read(djUiProvider.notifier).setMode(DjMode.radio);
      await c.read(vibeHubProvider.notifier).setFiestaMode(true);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(djUiProvider).mode, DjMode.fiesta);
      expect(c.read(vibeHubProvider).discoveryOn, isFalse);
      expect(saved()['mode'], 'fiesta');
    },
  );

  test('letras: parseo LRC, linea activa y archivo faltante', () async {
    final List<DjLyricLine> l = parseDjLrc(
      '[ar:x]\n[00:01.50]Uno\n[00:03.000]Dos\n\n[00:05.10]  \n[01:00.00]Tres',
    );
    expect(l.map((DjLyricLine x) => x.text), <String>['Uno', 'Dos', 'Tres']);
    expect(l.map((DjLyricLine x) => x.ms), <int>[1500, 3000, 60000]);
    expect(djLyricIndexAt(l, 0), -1);
    expect(djLyricIndexAt(l, 1500), 0);
    expect(djLyricIndexAt(l, 59999), 1);
    expect(djLyricIndexAt(l, 999999), 2);
    expect(djLyricIndexAt(const <DjLyricLine>[], 10), -1);
    final String mp3 = '${tmp.path}${_sep}Tema.mp3';
    expect(djLrcPathOf(mp3), '${tmp.path}${_sep}Tema.lrc');
    expect(await loadDjLyrics(mp3), isEmpty);
    File('${tmp.path}${_sep}Tema.lrc').writeAsStringSync('[00:00.10]Hola');
    expect((await loadDjLyrics(mp3)).single.text, 'Hola');
  });

  test('fuente: Dj no detiene ni arranca y Mix con Letra intacto', () {
    final String p = _src('lib/providers/dj_ui_provider.dart');
    for (final String bad in <String>[
      'togglePlayPause',
      '.stop(',
      'forceNext',
      'playStation(',
      'loadStation(',
      'parkIdleDecks',
    ]) {
      expect(p.contains(bad), isFalse, reason: bad);
    }
    expect(p, contains('SessionStore.writeJsonSync('));
    final String bar = _src('lib/ui/workspaces/dj_mode_bar.dart');
    expect(bar, contains('TheaterLyricsView('));
    for (final String f in <String>[
      'lib/main.dart',
      'lib/djiphone/main.dart',
    ]) {
      final String src = _src(f).replaceAll("'", '"');
      expect(src, contains('label: "Mix con Letra"'), reason: f);
      expect(src, contains('label: "Dj"'), reason: f);
      expect(src.contains('"AutomixDj"'), isFalse, reason: f);
      expect(src, contains('djUiProvider.notifier).persist()'), reason: f);
    }
  });

  group('pantalla', () {
    late String root;
    bool realFont = false;

    setUpAll(() async {
      final String win = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final Map<String, String> fonts = <String, String>{
        'Consolas': '$win\\Fonts\\consola.ttf',
        'Roboto': '$win\\Fonts\\segoeui.ttf',
      };
      bool all = true;
      for (final MapEntry<String, String> e in fonts.entries) {
        final File f = File(e.value);
        if (!f.existsSync()) {
          all = false;
          continue;
        }
        await (FontLoader(e.key)..addFont(
              Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())),
            ))
            .load();
      }
      realFont = all;
    });

    setUp(() {
      root = '${tmp.path}${_sep}R';
      Directory(root).createSync(recursive: true);
      final String state = '${tmp.path}${_sep}state.json';
      debugVibeRootOverride = root;
      debugVibeStatePath = state;
      debugVibeHubStatePath = state;
      debugStationSessionsPath = '${tmp.path}${_sep}sessions.json';
      debugTrackGenreIndexPath = '${tmp.path}$_sep$kTrackGenreIndexName';
      debugStationFeed = (String k, StationFeed f, int n) async =>
          const <String>[];
    });

    tearDown(() {
      debugVibeRootOverride = null;
      debugVibeStatePath = null;
      debugVibeHubStatePath = null;
      debugStationSessionsPath = null;
      debugTrackGenreIndexPath = null;
      debugStationFeed = null;
      debugLiveDjForceMobile = null;
    });

    Future<List<String>> pumpAt(
      WidgetTester t,
      Size size,
      bool mobile, {
      required String current,
    }) async {
      final List<String> calls = <String>[];
      debugLiveDjForceMobile = mobile;
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        ProviderScope(
          overrides: [
            liveDjProvider.overrideWith(
              () => _Live(
                LiveDjState(
                  queue: <File>[File('$root${_sep}Karol G - Provenza.mp3')],
                  currentTrackPath: current,
                  isPlaying: true,
                  position: const Duration(seconds: 2),
                  mixStrategy: LiveDjMixStrategy.random,
                ),
                calls,
              ),
            ),
          ],
          child: MaterialApp(
            theme: GatoMixTheme.darkTheme,
            home: const LiveDjWorkspace(),
          ),
        ),
      );
      await t.pump();
      await t.pump();
      return calls;
    }

    for (final (String name, Size size, bool mobile) v
        in <(String, Size, bool)>[
          ('telefono 360x640', const Size(360, 640), true),
          ('telefono 393x852', const Size(393, 852), true),
          ('escritorio 1024x600', const Size(1024, 600), false),
          ('escritorio 1400x900', const Size(1400, 900), false),
        ]) {
      testWidgets('3230 ${v.$1}: segmentado, Letras y "Sin letra" sin '
          'desbordar', (WidgetTester t) async {
        final String cur = '$root${_sep}Manuel Turizo - Besame.mp3';
        final List<String> calls = await pumpAt(t, v.$2, v.$3, current: cur);
        expect(t.takeException(), isNull, reason: 'overflow ${v.$1}');
        expect(find.byKey(const Key('dj-mode-bar')), findsOneWidget);
        expect(find.text('Automix'), findsOneWidget);
        expect(find.text('Radio'), findsOneWidget);
        expect(find.text('Fiesta'), findsOneWidget);
        expect(find.byKey(const Key('dj-lyrics-panel')), findsNothing);
        await t.tap(find.byKey(const Key('dj-lyrics-toggle')));
        await t.pump();
        await t.pump(const Duration(milliseconds: 50));
        expect(find.byKey(const Key('dj-lyrics-panel')), findsOneWidget);
        expect(find.text(kDjNoLyrics), findsOneWidget);
        expect(t.takeException(), isNull, reason: 'overflow letras ${v.$1}');
        expect(saved()['lyrics'], isTrue);
        expect(calls, isEmpty, reason: 'Letras no toca el audio');
        if (realFont && v.$3) {
          final Rect b = t.getRect(find.byKey(const Key('dj-mode-bar')));
          expect(b.right, lessThanOrEqualTo(v.$2.width));
        }
      });
    }

    testWidgets('3230 Letras muestra la letra de la pista que suena', (
      WidgetTester t,
    ) async {
      final String cur = '$root${_sep}Con Letra.mp3';
      File('$root${_sep}Con Letra.lrc').writeAsStringSync(
        '[00:00.50]Primera linea\n[00:01.50]Segunda linea\n[00:09.00]Tercera',
      );
      File(uiPath)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(jsonEncode(<String, Object?>{'lyrics': true}));
      await t.runAsync(() async {
        await pumpAt(t, const Size(393, 852), true, current: cur);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await t.pump();
      await t.pump();
      expect(find.byKey(const Key('dj-lyrics-panel')), findsOneWidget);
      expect(find.text('Segunda linea'), findsOneWidget);
      expect(find.text(kDjNoLyrics), findsNothing);
      expect(t.takeException(), isNull);
    });
  });
}

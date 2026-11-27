import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/genre_stations.dart';
import 'package:difogo/providers/livedj_provider.dart';
import 'package:difogo/providers/session_provider.dart';
import 'package:difogo/providers/theme_provider.dart';
import 'package:difogo/providers/vibe_hub_provider.dart';
import 'package:difogo/ui/workspaces/livedj_spotify_panel.dart';
import 'package:difogo/ui/workspaces/livedj_workspace.dart';

// 3.2.9: AutomixDj con Spotify Pro como vista unica (sin conmutador) y la
// Radio en la barra superior junto a Modo DJ, sin overflow en telefono,
// telefono acostado y escritorio. Todo en %TEMP%, sin red.

final String _sep = Platform.pathSeparator;

class _Live extends LiveDjNotifier {
  _Live(this.seed);
  final LiveDjState seed;
  @override
  LiveDjState build() => seed;
}

String _src(String rel) =>
    File(rel).readAsStringSync().replaceAll('\r\n', '\n');

String _body(String src, String from, String to) {
  final int a = src.indexOf(from);
  expect(a, greaterThanOrEqualTo(0), reason: from);
  final int b = src.indexOf(to, a + from.length);
  expect(b, greaterThan(a), reason: to);
  return src.substring(a, b);
}

void main() {
  late Directory tmp;
  late String root;
  bool realFont = false;

  setUpAll(() async {
    // Medidas reales en Windows (Consolas y Segoe UI como Roboto); en CI
    // (Linux) no existen y solo se revisa el overflow.
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
    tmp = Directory.systemTemp.createTempSync('gmx_3209_');
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
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpAt(WidgetTester t, Size size, bool mobile) async {
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
                queue: <File>[
                  File('$root${_sep}Karol G - Provenza.mp3'),
                  File('$root${_sep}Bad Bunny - Moscow Mule.mp3'),
                ],
                currentTrackPath: '$root${_sep}Manuel Turizo - Besame.mp3',
                mixStrategy: LiveDjMixStrategy.random,
              ),
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
  }

  for (final (String name, Size size, bool mobile) v in <(String, Size, bool)>[
    ('escritorio 1400x900', const Size(1400, 900), false),
    ('escritorio 1024x600', const Size(1024, 600), false),
    ('telefono 360x640', const Size(360, 640), true),
    ('telefono 393x852', const Size(393, 852), true),
    ('telefono acostado 780x360', const Size(780, 360), true),
    ('telefono acostado 844x390', const Size(844, 390), true),
  ]) {
    testWidgets('3209 barra Dj ${v.$1}: modos y Letras junto a Modo DJ', (
      WidgetTester t,
    ) async {
      await pumpAt(t, v.$2, v.$3);
      expect(t.takeException(), isNull, reason: 'overflow ${v.$1}');
      // Vista unica Spotify Pro: sin conmutador.
      expect(find.byKey(const Key('livedj-spotify-toggle')), findsNothing);
      expect(find.byKey(const Key('livedj-spotify-panel')), findsOneWidget);
      // Disco / pantalla completa intacto.
      // El disco de la barra movil sigue intacto.
      if (v.$3) expect(find.byIcon(Icons.album), findsWidgets);
      // 3.2.30: el chip Radio paso al segmentado [Automix | Radio |
      // Fiesta]; Letras queda junto a Modo DJ. Todo sobre la cola.
      expect(find.byKey(const Key('radio-discovery-toggle')), findsNothing);
      final Finder bar = find.byKey(const Key('dj-mode-bar'));
      final Finder letras = find.byKey(const Key('dj-lyrics-toggle'));
      final Finder dj = find.byKey(const Key('livedj-mode-dj-button'));
      expect(bar, findsOneWidget);
      expect(letras, findsOneWidget);
      expect(dj, findsOneWidget);
      final Rect r = t.getRect(letras);
      final Rect d = t.getRect(dj);
      final Rect b = t.getRect(bar);
      expect((r.center.dy - d.center.dy).abs(), lessThan(16));
      expect((r.center.dx - d.center.dx).abs(), lessThan(140));
      if (v.$3) {
        // Telefono: segmentado en su propia fila bajo Modo DJ.
        expect(b.top, greaterThanOrEqualTo(d.bottom - 1));
      } else {
        expect((b.center.dy - d.center.dy).abs(), lessThan(16));
        expect(b.right, lessThanOrEqualTo(r.left));
      }
      final Finder cola = find.textContaining(
        v.$3 ? 'COLA (2)' : 'COLA DE REPRODUCCIÓN (2)',
      );
      expect(cola, findsOneWidget);
      expect(r.bottom, lessThanOrEqualTo(t.getRect(cola).top));
      expect(b.bottom, lessThanOrEqualTo(t.getRect(cola).top));
      // Dentro de la pantalla.
      for (final Rect x in <Rect>[r, b]) {
        expect(x.left, greaterThanOrEqualTo(0));
        expect(x.right, lessThanOrEqualTo(v.$2.width));
      }
      if (realFont && !v.$3) {
        final RenderParagraph p = t.renderObject<RenderParagraph>(
          find.text('Modo DJ').first,
        );
        expect(p.didExceedMaxLines, isFalse);
      }
    });
  }

  test('3209 fuente: sin conmutador en la barra y Radio fuera de la cola', () {
    final String ws = _src('lib/ui/workspaces/livedj_workspace.dart');
    final String panel = _body(
      ws,
      'class LiveDjCartridgePanel',
      'COLA DE REPRODUCCIÓN',
    );
    expect(panel.contains('RadioDiscoveryButton('), isFalse);
    expect(panel.contains('CuratorInboxButton()'), isTrue);
    expect(ws.contains('LiveDjSpotifyToggle()'), isFalse);
    // 3.2.30: Letras junto a Modo DJ; sin chips Radio ni Fiesta sueltos.
    expect(
      RegExp(
        r'DjLyricsButton\(\),\s*const SizedBox\(width: 6\),'
        r'\s*const LiveDjModeDjButton\(\),',
      ).hasMatch(ws),
      isTrue,
    );
    expect(
      RegExp(
        r'LiveDjModeDjButton\(compact: true\),[\s\S]{0,900}?'
        r'DjLyricsButton\(compact: true\),',
      ).hasMatch(ws),
      isTrue,
    );
    expect(ws.contains('RadioDiscoveryButton(compact: true)'), isFalse);
    expect(ws.contains('FiestaModeButton(compact: true)'), isFalse);
    expect(ws.contains('DjModeBar('), isTrue);
    // La clase y el modo siguen (codigo clasico intacto).
    final String sp = _src('lib/ui/workspaces/livedj_spotify_panel.dart');
    expect(sp.contains('class LiveDjSpotifyToggle'), isTrue);
    final ProviderContainer c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(liveDjSpotifyModeProvider), isTrue);
  });
}

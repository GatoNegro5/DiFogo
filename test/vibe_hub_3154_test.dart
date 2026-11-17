import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/genre_stations.dart';
import 'package:gatomix/providers/livedj_provider.dart';
import 'package:gatomix/providers/session_provider.dart';
import 'package:gatomix/providers/vibe_hub_provider.dart';
import 'package:gatomix/ui/vibe_hub_view.dart';
import 'package:gatomix/ui/workspaces/automix_workspace.dart';
import 'package:gatomix/ui/workspaces/livedj_workspace.dart';

class _FakeLiveDj extends LiveDjNotifier {
  @override
  LiveDjState build() => LiveDjState();
}

late Directory _tmp;
late String _root;
late String _state;
final List<List<File>> _played = <List<File>>[];

void _touch(String rel) {
  final File f = File('$_root${Platform.pathSeparator}$rel');
  f.parent.createSync(recursive: true);
  f.writeAsBytesSync(<int>[0]);
}

void main() {
  setUp(() {
    _tmp = Directory.systemTemp.createTempSync('gmx_hub_3154_');
    _root = '${_tmp.path}${Platform.pathSeparator}ReGenial';
    _state = '${_tmp.path}${Platform.pathSeparator}state.json';
    _touch('Salsa${Platform.pathSeparator}a.mp3');
    _touch('Salsa${Platform.pathSeparator}sub${Platform.pathSeparator}b.mp3');
    _touch('Merengue${Platform.pathSeparator}c.mp3');
    debugVibeRootOverride = _root;
    debugVibeStatePath = _state;
    debugVibeHubStatePath = _state;
    debugVibeHubScan = (String r) async => const <VibeGenre>[
      VibeGenre('Merengue', 1),
      VibeGenre('Salsa', 2),
    ];
    _played.clear();
    debugVibeHubPlay = (List<File> files) async => _played.add(files);
  });

  tearDown(() {
    debugVibeRootOverride = null;
    debugVibeStatePath = null;
    debugVibeHubStatePath = null;
    debugVibeHubScan = null;
    debugVibeHubPlay = null;
    debugLiveDjForceMobile = null;
    try {
      _tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpWs(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [liveDjProvider.overrideWith(_FakeLiveDj.new)],
        child: const MaterialApp(home: LiveDjWorkspace()),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('escritorio: Smart Vibe por defecto y conmutador a clasico', (
    WidgetTester tester,
  ) async {
    debugLiveDjForceMobile = false;
    await pumpWs(tester, const Size(1400, 900));
    expect(find.byType(VibeHubView), findsOneWidget);
    expect(find.byType(LibraryTreePanel), findsNothing);
    // 3.1.62: Salsa y Merengue van dentro de la estacion Tropical.
    expect(find.text('Tropical'), findsOneWidget);
    expect(find.text('Cargar Carpeta'), findsNothing);
    expect(find.byType(LiveDjCartridgePanel), findsNothing);
    await tester.tap(find.byKey(const Key('livedj-view-toggle')));
    await tester.pump();
    expect(find.byType(VibeHubView), findsNothing);
    expect(find.text('Cargar Carpeta'), findsOneWidget);
    expect(find.byType(LibraryTreePanel), findsOneWidget);
    await tester.tap(find.byKey(const Key('livedj-view-toggle')));
    await tester.pump();
    await tester.pump();
    expect(find.byType(VibeHubView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('3162 estacion: sub-generos en visto y Shuffle de lo marcado', (
    WidgetTester tester,
  ) async {
    debugLiveDjForceMobile = false;
    debugStationSessionsPath =
        '${_tmp.path}${Platform.pathSeparator}sessions.json';
    final List<StationPlan> plans = <StationPlan>[];
    debugStationPlay = (StationPlan p) async => plans.add(p);
    addTearDown(() {
      debugStationSessionsPath = null;
      debugStationPlay = null;
    });
    await pumpWs(tester, const Size(1400, 900));
    expect(find.byIcon(Icons.folder), findsNothing);
    await tester.tap(find.byKey(const Key('vibe-hub-st-tropical')));
    await tester.pump();
    // 3.1.69: Tropical abre con su visto maestro apagado; al ponerlo se
    // encienden sus 6 sub-generos (Momento sigue con su maestro).
    await tester.tap(find.byKey(const Key('vibe-hub-master-tropical')));
    await tester.pump();
    expect(find.byIcon(Icons.check_box), findsNWidgets(8));
    await tester.tap(find.byKey(const Key('vibe-hub-cat-Merengue')));
    await tester.pump();
    await tester.tap(find.text('Reproducir Estación en Shuffle'));
    // E/S real del plan y del JSON: se deja correr fuera del reloj falso.
    for (int i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
      if (plans.isNotEmpty &&
          File(debugStationSessionsPath!).existsSync() &&
          File(
            debugStationSessionsPath!,
          ).readAsStringSync().contains('"active":"tropical"')) {
        break;
      }
    }
    expect(plans.length, 1);
    final List<String> all = <String>[
      plans.single.currentTrackPath!,
      ...plans.single.queue,
    ];
    expect(all.length, 2);
    expect(all.every((String p) => p.contains('Salsa')), isTrue);
    final Map<String, dynamic> doc =
        jsonDecode(File(debugStationSessionsPath!).readAsStringSync())
            as Map<String, dynamic>;
    expect(doc['active'], 'tropical');
    expect(
      ((doc['stations'] as Map)['tropical'] as Map)['subGenresChecked'],
      <String>['Salsa', 'Cumbia', 'Bachatas', 'Vallenatos', 'Todas'],
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('movil: el conmutador abre el Hub en hoja sin overflow', (
    WidgetTester tester,
  ) async {
    debugLiveDjForceMobile = true;
    await pumpWs(tester, const Size(360, 800));
    expect(find.byType(VibeHubView), findsNothing);
    expect(find.text('+ Agregar canciones'), findsOneWidget);
    await tester.tap(find.byKey(const Key('livedj-view-toggle')));
    await tester.pumpAndSettle();
    expect(find.byType(VibeHubView), findsOneWidget);
    expect(find.text('ESTACIONES & GÉNEROS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

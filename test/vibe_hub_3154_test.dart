import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
    expect(find.text('Salsa'), findsOneWidget);
    await tester.tap(find.byKey(const Key('livedj-view-toggle')));
    await tester.pump();
    expect(find.byType(VibeHubView), findsNothing);
    expect(find.byType(LibraryTreePanel), findsOneWidget);
    await tester.tap(find.byKey(const Key('livedj-view-toggle')));
    await tester.pump();
    await tester.pump();
    expect(find.byType(VibeHubView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('casillas: se guardan y Mezclar carga solo lo marcado', (
    WidgetTester tester,
  ) async {
    debugLiveDjForceMobile = false;
    await pumpWs(tester, const Size(1400, 900));
    await tester.tap(find.byKey(const Key('vibe-hub-cat-Salsa')));
    await tester.runAsync(
      () => Future<void>.delayed(Duration(milliseconds: 50)),
    );
    await tester.pump();
    final Map<String, dynamic> doc =
        jsonDecode(File(_state).readAsStringSync()) as Map<String, dynamic>;
    expect((doc['vibeHub'] as Map)['checked'], <String>['Salsa']);
    await tester.runAsync(() async {
      final ProviderContainer c = ProviderScope.containerOf(
        tester.element(find.byType(VibeHubView)),
      );
      final int n = await c.read(vibeHubProvider.notifier).play();
      expect(n, 2);
    });
    expect(_played.length, 1);
    expect(_played.single.every((File f) => f.path.contains('Salsa')), isTrue);
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
    expect(find.text('SMART VIBE'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

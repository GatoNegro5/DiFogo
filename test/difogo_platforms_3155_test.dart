import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/providers/automix_provider.dart';
import 'package:gatomix/providers/curator_provider.dart';
import 'package:gatomix/providers/livedj_provider.dart';
import 'package:gatomix/providers/session_provider.dart';
import 'package:gatomix/providers/theme_provider.dart';
import 'package:gatomix/providers/vibe_hub_provider.dart';
import 'package:gatomix/services/smart_discovery_service.dart';
import 'package:gatomix/ui/curator_inbox_dialog.dart';
import 'package:gatomix/ui/vibe_hub_view.dart';
import 'package:gatomix/ui/workspaces/livedj_workspace.dart';

// Verificacion multiplataforma 3.1.55 (DiFogo): tamanos de Android, iPhone,
// tablet y escritorio, con el tema real y todo en %TEMP%.

class _FakeQueue extends AutomixQueueNotifier {
  @override
  List<File> build() => <File>[];

  @override
  void addTrack(File file) => state = <File>[...state, file];
}

class _FakeLiveDj extends LiveDjNotifier {
  @override
  LiveDjState build() => LiveDjState();
}

const Map<String, Size> _phones = <String, Size>{
  'Android 360x640': Size(360, 640),
  'iPhone SE 375x667': Size(375, 667),
  'iPhone 14 390x844': Size(390, 844),
  'Android horizontal 800x360': Size(800, 360),
};

const Map<String, Size> _desktops = <String, Size>{
  'Windows/Mac 1280x720': Size(1280, 720),
  'Windows/Mac 1920x1080': Size(1920, 1080),
  'Tablet 1024x768': Size(1024, 768),
};

bool realFont = false;

void main() {
  final String sep = Platform.pathSeparator;
  late Directory tmp;
  late String root;

  setUpAll(() async {
    // Medidas reales: en Windows se cargan Consolas (fuente del tema, ancho
    // fijo y la mas ancha) y Segoe UI como Roboto. En CI (Linux) no existen
    // y solo se revisa el overflow.
    const Map<String, String> fonts = <String, String>{
      'Consolas': r'C:\Windows\Fonts\consola.ttf',
      'Roboto': r'C:\Windows\Fonts\segoeui.ttf',
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
    tmp = Directory.systemTemp.createTempSync('gmx_difogo_3155_');
    root = '${tmp.path}${sep}ReGenial';
    for (final String rel in <String>[
      'Salsa${sep}a.mp3',
      'Merengue${sep}c.mp3',
    ]) {
      File('$root$sep$rel')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(<int>[0]);
    }
    final String state = '${tmp.path}${sep}state.json';
    debugVibeRootOverride = root;
    debugVibeStatePath = state;
    debugVibeHubStatePath = state;
    debugVibeHubScan = (String r) async => const <VibeGenre>[
      VibeGenre('Merengue', 1),
      VibeGenre('Salsa Romantica y Clasicos', 2),
    ];
    debugVibeHubPlay = (List<File> files) async {};
    debugDisableCuratorWorker = true;
    debugCuratorRegister = (String p, String g) async {};
    debugCuratorService = SmartDiscoveryService(
      search: (String q) async => const <DiscoveryCandidate>[
        DiscoveryCandidate(
          id: 'v1',
          title:
              'Un titulo muy largo de prueba para ver si la tarjeta se desborda',
          duration: Duration(minutes: 4),
        ),
        DiscoveryCandidate(
          id: 'v2',
          title: 'Tema Dos',
          duration: Duration(minutes: 5),
        ),
      ],
      download: (DiscoveryCandidate c, String mp3) async =>
          File(mp3).writeAsStringSync('mp3:${c.id}'),
      inboxDir: '${tmp.path}${sep}Inbox',
      now: () => DateTime(2026, 11, 16, 10),
    );
  });

  tearDown(() {
    debugVibeRootOverride = null;
    debugVibeStatePath = null;
    debugVibeHubStatePath = null;
    debugVibeHubScan = null;
    debugVibeHubPlay = null;
    debugCuratorService = null;
    debugCuratorRegister = null;
    debugLiveDjForceMobile = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  void setSize(WidgetTester t, Size size) {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
  }

  void expectNotClipped(WidgetTester t, String text) {
    // La fuente de prueba de flutter_test mide 1 em por letra (casi el
    // doble que Roboto/Segoe UI); sin fuente real solo vale el overflow.
    if (!realFont) return;
    for (final Element e in find.text(text).evaluate()) {
      final RenderParagraph p = e.renderObject! as RenderParagraph;
      expect(p.didExceedMaxLines, isFalse, reason: '$text recortado');
      final double full = (TextPainter(
        text: p.text,
        textDirection: TextDirection.ltr,
        textScaler: p.textScaler,
      )..layout()).width;
      expect(
        p.size.width + 0.5,
        greaterThanOrEqualTo(full),
        reason: '$text recortado: ${p.size.width} < $full',
      );
    }
  }

  Future<void> curatorAt(WidgetTester t, Size size, double scale) async {
    // 3.1.63: sin Consolas/Segoe UI (CI Linux) la fuente de prueba mide
    // 1 em por letra y marca overflows falsos en los botones del curador.
    if (!realFont) {
      markTestSkipped('curador: requiere fuentes reales (Consolas y Segoe UI)');
      return;
    }
    setSize(t, size);
    final ProviderContainer c = ProviderContainer(
      overrides: [automixQueueProvider.overrideWith(_FakeQueue.new)],
    );
    addTearDown(c.dispose);
    await t.runAsync(() async {
      await c.read(vibeProvider.notifier).choose('Salsa');
      await c.read(curatorProvider.notifier).discover(count: 2);
    });
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: GatoMixTheme.darkTheme,
          builder: (BuildContext ctx, Widget? w) => MediaQuery(
            data: MediaQuery.of(
              ctx,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: w!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (BuildContext ctx) => TextButton(
                onPressed: () => showCuratorInbox(ctx),
                child: const Text('abrir'),
              ),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('abrir'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull, reason: 'overflow en $size x$scale');
    expect(find.text('✓ Aceptar'), findsNWidgets(2));
    expect(find.text('✕ Descartar'), findsNWidgets(2));
    expectNotClipped(t, '✓ Aceptar');
    expectNotClipped(t, '✕ Descartar');
    // Con letra grande estos dos usan su elipsis prevista desde la 3.1.53.
    if (scale == 1.0) {
      expectNotClipped(t, 'Buscar más');
      expectNotClipped(t, 'Ver después');
    }
    final Color fg = t
        .widget<OutlinedButton>(
          find.ancestor(
            of: find.text('✓ Aceptar').first,
            matching: find.byType(OutlinedButton),
          ),
        )
        .style!
        .foregroundColor!
        .resolve(<WidgetState>{})!;
    expect(fg, GatoMixTheme.fire);
  }

  for (final MapEntry<String, Size> e in <String, Size>{
    ..._phones,
    ..._desktops,
  }.entries) {
    testWidgets('curador ${e.key}: botones de texto completos', (t) async {
      await curatorAt(t, e.value, 1.0);
    });
  }

  testWidgets('curador movil con letra grande (x1.3) sin recortes', (t) async {
    await curatorAt(t, const Size(360, 640), 1.3);
  });

  Future<void> liveDjAt(WidgetTester t, Size size, bool mobile) async {
    setSize(t, size);
    debugLiveDjForceMobile = mobile;
    await t.pumpWidget(
      ProviderScope(
        overrides: [liveDjProvider.overrideWith(_FakeLiveDj.new)],
        child: MaterialApp(
          theme: GatoMixTheme.darkTheme,
          home: const LiveDjWorkspace(),
        ),
      ),
    );
    await t.pump();
    await t.pump();
    expect(t.takeException(), isNull, reason: 'overflow Live DJ $size');
    final BuildContext ctx = t.element(find.byType(LiveDjWorkspace));
    expect(Theme.of(ctx).scaffoldBackgroundColor, GatoMixTheme.bgDark);
    expect(Theme.of(ctx).colorScheme.primary, GatoMixTheme.fire);
  }

  for (final MapEntry<String, Size> e in _desktops.entries) {
    testWidgets('Live DJ + Hub ${e.key}: tema fuego sin overflow', (t) async {
      await liveDjAt(t, e.value, false);
      expect(find.byType(VibeHubView), findsOneWidget);
      expectNotClipped(t, 'ESTACIONES & GÉNEROS');
      // 3.1.62: los sub-generos (casillas) salen al abrir una estacion.
      await t.tap(
        find
            .byWidgetPredicate(
              (Widget w) =>
                  w.key is ValueKey<String> &&
                  (w.key! as ValueKey<String>).value.startsWith('vibe-hub-st-'),
            )
            .first,
      );
      await t.pump();
      expect(t.takeException(), isNull, reason: 'overflow estacion ${e.key}');
      expectNotClipped(t, 'Reproducir Estación en Shuffle');
      final Icon cb = t.widget<Icon>(find.byIcon(Icons.check_box).first);
      expect(cb.color, GatoMixTheme.fire);
    });
  }

  for (final MapEntry<String, Size> e in _phones.entries) {
    testWidgets('Live DJ movil ${e.key}: Hub en hoja sin overflow', (t) async {
      await liveDjAt(t, e.value, true);
      await t.tap(find.byKey(const Key('livedj-view-toggle')));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.byType(VibeHubView), findsOneWidget);
      expectNotClipped(t, 'ESTACIONES & GÉNEROS');
    });
  }
}

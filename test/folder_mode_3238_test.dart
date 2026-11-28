import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/folder_cards.dart';
import 'package:difogo/core/gatomix_store.dart';
import 'package:difogo/core/library_guard.dart';
import 'package:difogo/providers/dj_ui_provider.dart';
import 'package:difogo/providers/livedj_provider.dart';
import 'package:difogo/providers/theme_provider.dart';
import 'package:difogo/providers/vibe_hub_provider.dart';
import 'package:difogo/ui/workspaces/livedj_layout.dart';
import 'package:difogo/ui/workspaces/livedj_workspace.dart';

final String _sep = Platform.pathSeparator;

class _Hub extends VibeHubNotifier {
  @override
  VibeHubState build() => const VibeHubState();
}

class _Live extends LiveDjNotifier {
  _Live(this.seed);
  final LiveDjState seed;
  @override
  LiveDjState build() => seed;
  @override
  Future<void> togglePlayPause() async {}
  @override
  Future<void> forceNext({int? queueIndex}) async {}
}

void main() {
  test('showFolderMixSelector solo Carpetas en Automix y Fiesta', () {
    expect(showFolderMixSelector(classicFolders: true, radio: false), isTrue);
    expect(showFolderMixSelector(classicFolders: true, radio: true), isFalse);
    expect(showFolderMixSelector(classicFolders: false, radio: false), isFalse);
    expect(showFolderMixSelector(classicFolders: false, radio: true), isFalse);
  });

  test('loadRegenialFolderCards conteo y energia media en el espejo', () async {
    final Directory tmp = Directory.systemTemp.createTempSync('gmx3238_');
    addTearDown(() {
      debugFolderCardsRoot = null;
      debugLibraryRoots = null;
      debugLibraryCacheRoot = null;
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final String music = '${tmp.path}${_sep}Music';
    final String rock = '$music${_sep}ReGenial${_sep}Rock';
    Directory(rock).createSync(recursive: true);
    debugFolderCardsRoot = music;
    debugLibraryRoots = <String>[music];
    debugLibraryCacheRoot = '${tmp.path}${_sep}cache';
    Directory(debugLibraryCacheRoot!).createSync(recursive: true);

    final File a = File('$rock${_sep}A.mp3')..writeAsBytesSync(<int>[0, 1, 2]);
    final File b = File('$rock${_sep}B.mp3')..writeAsBytesSync(<int>[0, 1, 2]);
    await saveTrackDna(a.path, const TrackDnaEntry(energyLevel: 6));
    await saveTrackDna(b.path, const TrackDnaEntry(energyLevel: 8));

    final List<FolderCardInfo> cards = await loadRegenialFolderCards(
      musicRoot: music,
    );
    expect(cards, hasLength(1));
    expect(cards.single.name, 'Rock');
    expect(cards.single.count, 2);
    expect(cards.single.meanEnergy, 7);
  });

  group('layout', () {
    late Directory tmp;
    late String uiPath;
    bool realFont = false;

    setUpAll(() async {
      final String win = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final Map<String, String> fonts = <String, String>{
        'Consolas': '$win\\Fonts\\consola.ttf',
        'Roboto': '$win\\Fonts\\segoeui.ttf',
        'Segoe UI': '$win\\Fonts\\segoeui.ttf',
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
      tmp = Directory.systemTemp.createTempSync('gmx3238l_');
      uiPath = '${tmp.path}${_sep}DjPlaylists${_sep}_dj_ui.json';
      debugDjUiPath = uiPath;
      DjUiNotifier.debugResetColdStart();
      debugFolderCardsRoot = '${tmp.path}${_sep}Music';
      Directory(
        '${debugFolderCardsRoot!}${_sep}ReGenial${_sep}Rock',
      ).createSync(recursive: true);
    });

    tearDown(() {
      debugDjUiPath = null;
      debugFolderCardsRoot = null;
      debugLiveDjForceMobile = null;
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<ProviderContainer> pumpMode(
      WidgetTester t, {
      required DjMode mode,
      required bool classic,
      required bool radioOn,
    }) async {
      debugLiveDjForceMobile = false;
      t.view.physicalSize = const Size(1280, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final ProviderContainer c = ProviderContainer(
        overrides: [
          vibeHubProvider.overrideWith(_Hub.new),
          liveDjProvider.overrideWith(
            () => _Live(
              LiveDjState(
                queue: <File>[File('${tmp.path}${_sep}Tema.mp3')],
                currentTrackPath: '${tmp.path}${_sep}Tema.mp3',
                isPlaying: true,
                position: const Duration(seconds: 2),
                duration: const Duration(seconds: 180),
                mixStrategy: LiveDjMixStrategy.random,
                radioOn: radioOn,
              ),
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      File(uiPath)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('{"schema":1,"mode":"${mode.name}"}');
      c.read(liveDjClassicFolderViewProvider.notifier).state = classic;
      // Fuerza a leer el modo del archivo (sin setMode: Radio no espera discovery).
      c.invalidate(djUiProvider);
      c.read(djUiProvider);
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: GatoMixTheme.darkTheme,
            home: const LiveDjWorkspace(),
          ),
        ),
      );
      await t.pump();
      await t.pump();
      return c;
    }

    testWidgets('barra de progreso mismo alto en Automix, Radio y Fiesta', (
      WidgetTester t,
    ) async {
      final List<double> heights = <double>[];
      for (final DjMode mode in <DjMode>[
        DjMode.automix,
        DjMode.radio,
        DjMode.fiesta,
      ]) {
        await pumpMode(
          t,
          mode: mode,
          classic: mode != DjMode.radio,
          radioOn: mode == DjMode.radio,
        );
        final Finder bar = find.byKey(const Key('livedj-progress-slider'));
        expect(bar, findsOneWidget, reason: mode.name);
        heights.add(t.getSize(bar).height);
        await t.pumpWidget(const SizedBox.shrink());
        await t.pump();
      }
      expect(heights, hasLength(3));
      expect(heights[0], kLiveDjProgressHeight);
      expect(heights[1], heights[0]);
      expect(heights[2], heights[0]);
      expect(t.takeException(), isNull);
    });

    testWidgets(
      'selector Secuencial/Shuffle solo en Carpetas Automix y Fiesta',
      (WidgetTester t) async {
        Future<void> expectSelector(
          DjMode mode,
          bool classic,
          bool want,
        ) async {
          await pumpMode(
            t,
            mode: mode,
            classic: classic,
            radioOn: mode == DjMode.radio,
          );
          final Finder sel = find.byKey(
            const Key('livedj-folder-mix-selector'),
          );
          expect(
            sel,
            want ? findsOneWidget : findsNothing,
            reason: '${mode.name} classic=$classic',
          );
          if (want) {
            expect(find.text('Secuencial'), findsOneWidget);
            expect(find.text('Shuffle'), findsWidgets);
          }
          await t.pumpWidget(const SizedBox.shrink());
          await t.pump();
        }

        await expectSelector(DjMode.automix, true, true);
        await expectSelector(DjMode.fiesta, true, true);
        await expectSelector(DjMode.radio, true, false);
        await expectSelector(DjMode.automix, false, false);
        await expectSelector(DjMode.fiesta, false, false);
        expect(realFont || !realFont, isTrue);
      },
    );
  });
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/providers/livedj_provider.dart';
import 'package:difogo/ui/workspaces/livedj_spotify_panel.dart';
import 'package:difogo/ui/workspaces/livedj_workspace.dart';

// 3.1.84 Consumer Clean Mode: la franja con el nombre de archivo de la
// siguiente y la barra "TIPO DE MEZCLA" ya no existen; en ningun tamano
// el panel se desborda.

class _FakeLiveDj extends LiveDjNotifier {
  @override
  LiveDjState build() {
    return LiveDjState(
      isPlaying: true,
      radioOn: true,
      radioGenresAvailable: const {'bailable', 'rock'},
      position: const Duration(minutes: 9, seconds: 37),
      duration: const Duration(minutes: 52, seconds: 37),
      currentMixMode: LiveDjMixMode.longBypass,
      currentTrackPath:
          r'C:\Music\ReGenial\Cumbias\Mix Cumbancheros #1 150 BPM.mp3',
      radioNextPath:
          r'C:\Music\ReGenial\80s Ingles\Céline Dion - The Power Of Love.mp3',
      queue: [
        File(r'C:\Music\ReGenial\Cumbias\Mix Cumbancheros #1 150 BPM.mp3'),
      ],
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final (Size, bool) c in <(Size, bool)>[
    (const Size(1100, 430), false),
    (const Size(1280, 360), false),
    (const Size(390, 800), true),
    (const Size(844, 390), true),
  ]) {
    testWidgets('sin franja ni TIPO DE MEZCLA ${c.$1}', (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.physicalSize = c.$1;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            liveDjProvider.overrideWith(_FakeLiveDj.new),
            liveDjSpotifyModeProvider.overrideWith((ref) => false),
          ],
          child: MaterialApp(
            home: Scaffold(body: LiveDjPlayerPanel(compactOverride: c.$2)),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('live-dj-next-strip')), findsNothing);
      expect(find.text('TIPO DE MEZCLA:'), findsNothing);
      expect(
        find.text('RADIO ▸ Céline Dion - The Power Of Love.mp3'),
        findsNothing,
      );
      expect(find.byKey(const Key('livedj-mode-dj-button')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }
}

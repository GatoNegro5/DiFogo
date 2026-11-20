// 3.2.5: ADN en vivo. Automix, Live DJ y Radio pasan dnaOf (fuente),
// enqueueDna no trabaja durante un cruce, ventana con tope y ADN enviado al
// isolate del Shuffle/Radio. Sin Rust ni red.
import 'dart:io';

import 'package:difogo/core/bpm_backfill_worker.dart';
import 'package:difogo/core/gatomix_radio.dart';
import 'package:difogo/core/gatomix_store.dart';
import 'package:difogo/core/library_guard.dart';
import 'package:difogo/core/livedj_order.dart';
import 'package:difogo/providers/automix_provider.dart';
import 'package:difogo/providers/livedj_provider.dart';
import 'package:flutter_test/flutter_test.dart';

String _src(String p) => File(p).readAsStringSync();

void main() {
  group('fuente: dnaOf en los 3 llamadores', () {
    test('Automix: los 2 buildHarmonicShuffle con harmonicDnaOf', () {
      final String s = _src('lib/providers/automix_provider.dart');
      expect('buildHarmonicShuffle('.allMatches(s).length, 2);
      expect('dnaOf: harmonicDnaOf,'.allMatches(s).length, 2);
      expect(s, contains('worker.enqueueDna(dnaWin);'));
      expect(s, contains('await warmHarmonicDna(paths).timeout(kDnaWarmWait'));
    });

    test('Live DJ: reorden con harmonicDnaOf y Shuffle con el ADN enviado', () {
      final String s = _src('lib/providers/livedj_provider.dart');
      expect('buildHarmonicShuffle('.allMatches(s).length, 2);
      expect('dnaOf: harmonicDnaOf,'.allMatches(s).length, 1);
      expect('dnaOf: liveHarmonicDnaOf,'.allMatches(s).length, 1);
      expect(s, contains("'dna': harmonicDnaPayload(paths),"));
      expect(s, contains("'dna': harmonicDnaPayload(pool),"));
      expect(s, contains("tagged['dna'] = harmonicDnaPayload(pool);"));
      expect(s, contains("primeHarmonicDna(msg['dna']);"));
      expect(s, contains('worker.enqueueDna(dnaWin);'));
    });

    test('Radio: buildDifferentRound con dnaOf (cae en harmonicDnaOf)', () {
      final String s = _src('lib/core/gatomix_radio.dart');
      expect('buildHarmonicShuffle('.allMatches(s).length, 1);
      expect(s, contains('dnaOf: liveHarmonicDnaOf,'));
      expect(s, contains("primeHarmonicDna(raw['dna']);"));
      expect(s, contains('return harmonicDnaOf(path);'));
    });
  });

  group('worker y ventana', () {
    test('enqueueDna no trabaja durante un cruce; dedup', () async {
      final List<String> filled = <String>[];
      bool crossfading = true;
      final BpmBackfillWorker w = BpmBackfillWorker(
        measure: (String _) async => 0,
        isPaused: () => crossfading,
        onBatch: (_) {},
        gap: const Duration(milliseconds: 1),
        fillDna: (String p) async {
          filled.add(p);
          return true;
        },
      );
      final List<String> win = <String>['/m/a.mp3', '/m/b.mp3', '/m/c_K.mp3'];
      w.enqueueDna(win);
      w.enqueueDna(win);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(filled, isEmpty, reason: 'nada durante el cruce');
      expect(w.isRunning, isTrue);
      crossfading = false;
      for (int i = 0; i < 60 && filled.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(filled, <String>['/m/a.mp3', '/m/b.mp3']);
      // Ya intentadas: otra ventana igual no vuelve a trabajar.
      w.enqueueDna(win);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(filled.length, 2);
      w.cancel();
    });

    test('ventanas con tope de 48 y sin _K', () {
      final List<String> big = <String>[
        for (int i = 0; i < 5000; i++)
          i % 10 == 3 ? '/m/t${i}_K.mp3' : '/m/t$i.mp3',
      ];
      final List<String> a = automixDnaWindow(big, 2);
      expect(a.length, lessThanOrEqualTo(48));
      expect(a.first, '/m/t2.mp3');
      expect(a.any((String p) => p.contains('_K')), isFalse);
      final List<String> l = liveDjDnaWindow(<File>[
        for (final String p in big) File(p),
      ], 1);
      expect(l.length, lessThanOrEqualTo(48));
      expect(l.first, '/m/t1.mp3');
      expect(l.any((String p) => p.contains('_K')), isFalse);
      expect(automixDnaWindow(big, 6000), isEmpty);
    });
  });

  group('cache y envio al isolate', () {
    late Directory root;
    final String sep = Platform.pathSeparator;

    setUp(() {
      root = Directory.systemTemp.createTempSync('difogo_dna3205_');
      debugLibraryRoots = <String>['${root.path}${sep}Biblioteca'];
      debugLibraryCacheRoot = '${root.path}${sep}cache';
      debugForgetTrackDnaMemory();
      debugForgetHarmonicDnaWarm();
    });

    tearDown(() {
      GatomixStore.forget(<String>[
        for (int i = 0; i < 3; i++) '${root.path}${sep}d$i',
      ]);
      debugForgetTrackDnaMemory();
      debugForgetHarmonicDnaWarm();
      debugLibraryRoots = null;
      debugLibraryCacheRoot = null;
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });

    test(
      'warmHarmonicDna: tope de carpetas por llamada, sin repetir',
      () async {
        final List<String> paths = <String>[];
        for (int i = 0; i < 3; i++) {
          final File f = File('${root.path}${sep}d$i${sep}t$i.mp3')
            ..parent.createSync(recursive: true)
            ..writeAsBytesSync(<int>[1]);
          paths.add(f.path);
          await saveTrackDna(f.path, TrackDnaEntry(energy: 0.1 * (i + 1)));
        }
        debugForgetTrackDnaMemory();
        GatomixStore.forget(<String>[
          for (int i = 0; i < 3; i++) '${root.path}${sep}d$i',
        ]);
        await warmHarmonicDna(paths, maxDirs: 2);
        expect(harmonicDnaOf(paths[0])?.energy, closeTo(0.1, 1e-9));
        expect(harmonicDnaOf(paths[1])?.energy, closeTo(0.2, 1e-9));
        expect(harmonicDnaOf(paths[2]), isNull);
        await warmHarmonicDna(paths, maxDirs: 2);
        expect(harmonicDnaOf(paths[2])?.energy, closeTo(0.3, 1e-9));
      },
    );

    test('payload -> primeHarmonicDna -> liveHarmonicDnaOf', () async {
      final File f = File('${root.path}${sep}d0${sep}x.mp3')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(<int>[1]);
      await saveTrackDna(
        f.path,
        const TrackDnaEntry(
          energy: 0.8,
          brightness: 0.6,
          beatDensity: 0.4,
          lang: 'es',
        ),
      );
      final Map<String, List<Object?>> payload = harmonicDnaPayload(<String>[
        f.path,
        '/no/hay.mp3',
      ]);
      expect(payload.keys, <String>[f.path]);
      // Otro isolate: sin cache en memoria, solo lo enviado.
      debugForgetTrackDnaMemory();
      expect(liveHarmonicDnaOf(f.path), isNull);
      primeHarmonicDna(payload);
      final HarmonicDna d = liveHarmonicDnaOf(f.path)!;
      expect(
        (d.energy, d.brightness, d.beatDensity, d.lang),
        (0.8, 0.6, 0.4, 'es'),
      );
      primeHarmonicDna(null);
      expect(liveHarmonicDnaOf(f.path), isNull);
    });
  });
}

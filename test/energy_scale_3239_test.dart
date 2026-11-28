import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/gatomix_store.dart';
import 'package:difogo/core/library_guard.dart';
import 'package:difogo/core/track_energy.dart';

void main() {
  tearDown(EnergyScale.debugReset);

  test('deciles reparte 100 valores uniformes en E1..E10', () {
    final List<double> raws = <double>[
      for (int i = 0; i < 100; i++) (i + 0.5) / 100.0,
    ];
    final EnergyScale scale = EnergyScale.fitDeciles(raws);
    expect(scale.isValid, isTrue);
    final List<int> hist = List<int>.filled(10, 0);
    for (final double r in raws) {
      hist[scale.levelOf(r) - 1]++;
    }
    for (int i = 0; i < 10; i++) {
      expect(
        hist[i],
        inInclusiveRange(8, 12),
        reason: 'E${i + 1}=${hist[i]} hist=$hist cuts=${scale.cuts}',
      );
    }
  });

  test('mapeo lineal de respaldo sin escala', () {
    expect(linearEnergyLevel(0), 1);
    expect(linearEnergyLevel(1), 10);
    expect(linearEnergyLevel(0.5), 6);
  });

  test('energyRaw se guarda y no exige decode para rellenar nivel', () async {
    final Directory tmp = Directory.systemTemp.createTempSync('gmx3239_');
    addTearDown(() {
      EnergyScale.debugReset();
      debugLibraryRoots = null;
      debugLibraryCacheRoot = null;
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final String sep = Platform.pathSeparator;
    final String music = '${tmp.path}${sep}Music';
    final String regen = '$music${sep}ReGenial${sep}Disco';
    Directory(regen).createSync(recursive: true);
    debugLibraryRoots = <String>[music];
    debugLibraryCacheRoot = '${tmp.path}${sep}cache';
    Directory(debugLibraryCacheRoot!).createSync(recursive: true);

    final File audio = File('$regen${sep}Tema.mp3')
      ..writeAsBytesSync(List<int>.filled(64, 0));
    final int mtime = audio.lastModifiedSync().millisecondsSinceEpoch;
    await saveTrackDna(
      audio.path,
      TrackDnaEntry(
        energy: 0.4,
        brightness: 0.4,
        beatDensity: 0.4,
        energyRaw: 0.42,
        energyLevel: 5,
        mtimeMs: mtime,
      ),
    );
    expect(trackEnergyNeedsFill(peekTrackDna(audio.path), mtime), isFalse);
    final TrackDnaEntry? got = await fillTrackEnergyIfStale(audio.path);
    expect(got?.energyRaw, closeTo(0.42, 1e-9));
    expect(got?.energyLevel, 5);

    // Sin energyRaw, se recalcula barato desde metricas (sin decode).
    final File audio2 = File('$regen${sep}Otro.mp3')
      ..writeAsBytesSync(List<int>.filled(64, 0));
    final int m2 = audio2.lastModifiedSync().millisecondsSinceEpoch;
    await saveTrackDna(
      audio2.path,
      TrackDnaEntry(
        energy: 0.5,
        brightness: 0.5,
        beatDensity: 0.5,
        mtimeMs: m2,
      ),
    );
    expect(trackEnergyNeedsFill(peekTrackDna(audio2.path), m2), isTrue);
    final TrackDnaEntry? cheap = await fillTrackEnergyIfStale(audio2.path);
    expect(cheap?.energyRaw, closeTo(0.5, 1e-9));
    expect(cheap?.energyLevel, 6);
    expect(trackEnergyNeedsFill(peekTrackDna(audio2.path), m2), isFalse);
  });

  test('relevelLibraryEnergy ajusta deciles sin decode', () async {
    final Directory tmp = Directory.systemTemp.createTempSync('gmx3239r_');
    addTearDown(() {
      EnergyScale.debugReset();
      debugLibraryRoots = null;
      debugLibraryCacheRoot = null;
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final String sep = Platform.pathSeparator;
    final String music = '${tmp.path}${sep}Music';
    final String regen = '$music${sep}ReGenial${sep}Pop';
    Directory(regen).createSync(recursive: true);
    debugLibraryRoots = <String>[music];
    debugLibraryCacheRoot = '${tmp.path}${sep}cache';
    Directory(debugLibraryCacheRoot!).createSync(recursive: true);

    for (int i = 0; i < 20; i++) {
      final File audio = File('$regen${sep}T$i.mp3')
        ..writeAsBytesSync(List<int>.filled(32, 0));
      final int mtime = audio.lastModifiedSync().millisecondsSinceEpoch;
      final double v = (i + 0.5) / 20.0;
      await saveTrackDna(
        audio.path,
        TrackDnaEntry(
          energy: v,
          brightness: v,
          beatDensity: v,
          energyLevel: 5,
          mtimeMs: mtime,
        ),
      );
    }

    final EnergyRelevelReport r = await relevelLibraryEnergy(
      root: regen,
      log: (_) {},
    );
    expect(r.withRaw, 20);
    expect(r.updated, 20);
    expect(r.missing, 0);
    expect(r.cuts.length, 9);
    int occupied = 0;
    for (final int n in r.histogram) {
      if (n > 0) occupied++;
    }
    expect(occupied, greaterThanOrEqualTo(8), reason: 'hist=${r.histogram}');
    // Ningun cubo se come toda la biblioteca (el problema lineal E5).
    for (int i = 0; i < 10; i++) {
      expect(r.histogram[i], lessThanOrEqualTo(4), reason: 'E${i + 1}');
    }
  });
}

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/gatomix_store.dart';
import 'package:difogo/core/library_guard.dart';
import 'package:difogo/core/track_energy.dart';

void main() {
  test('compositeEnergyLevel pesos y extremos', () {
    expect(
      compositeEnergyLevel(
        rmsEnergy: 0,
        beatDensity: 0,
        brightness: 0,
        bpm: 70,
      ),
      1,
    );
    expect(
      compositeEnergyLevel(
        rmsEnergy: 1,
        beatDensity: 1,
        brightness: 1,
        bpm: 160,
      ),
      10,
    );
    // Todos 0.5 (BPM 115) -> 0.5*9 = 4.5 -> nivel 6.
    expect(
      compositeEnergyLevel(
        rmsEnergy: 0.5,
        beatDensity: 0.5,
        brightness: 0.5,
        bpm: 115,
      ),
      6,
    );
    // 40% densidad manda mas que el RMS.
    final int dense = compositeEnergyLevel(
      rmsEnergy: 0.2,
      beatDensity: 1.0,
      brightness: 0.2,
      bpm: 80,
    );
    final int loud = compositeEnergyLevel(
      rmsEnergy: 1.0,
      beatDensity: 0.2,
      brightness: 0.2,
      bpm: 80,
    );
    expect(dense > loud, isTrue);
  });

  test('harmonicEnergyScore ola y salto', () {
    expect(harmonicEnergyScore(5, 5, waveUp: true), kEnergyWaveBonus);
    expect(harmonicEnergyScore(5, 6, waveUp: true), kEnergyWaveBonus);
    expect(harmonicEnergyScore(5, 4, waveUp: true), 12);
    expect(harmonicEnergyScore(5, 7, waveUp: true), 6);
    expect(harmonicEnergyScore(5, 3, waveUp: true), 0);
    expect(harmonicEnergyScore(5, 8, waveUp: true), -kEnergyJumpPenalty);
    expect(harmonicEnergyScore(5, 2, waveUp: true), -kEnergyJumpPenalty);
    expect(energyJumpOk(5, 7), isTrue);
    expect(energyJumpOk(5, 8), isFalse);
    expect(harmonicEnergyScore(6, 5, waveUp: false), kEnergyWaveBonus);
    expect(harmonicEnergyScore(null, 5, waveUp: true), 0);
  });

  test('camelotFromChroma triad C y Am', () {
    final List<double> cMajor = List<double>.filled(12, 0);
    cMajor[0] = 1; // C
    cMajor[4] = 1; // E
    cMajor[7] = 1; // G
    expect(camelotFromChroma(cMajor), '8B');
    final List<double> aMinor = List<double>.filled(12, 0);
    aMinor[9] = 1; // A
    aMinor[0] = 1; // C
    aMinor[4] = 1; // E
    expect(camelotFromChroma(aMinor), '8A');
  });

  test('camelotFromFileName lee 8A al final del nombre', () {
    expect(camelotFromFileName(r'C:\Musica\Tema 8A.mp3'), '8A');
    expect(camelotFromFileName('/tmp/Song_11b_mix.mp3'), '11B');
    expect(camelotFromFileName('/tmp/Track 13A.mp3'), isNull);
    expect(isCamelotKey('12B'), isTrue);
    expect(isCamelotKey('13A'), isFalse);
    expect(normalizeCamelot(' 8a '), '8A');
  });

  test('chromaFromPcm acorde C mayor', () {
    const int rate = 11025;
    const int n = rate * 3;
    final ByteData data = ByteData(n * 2);
    const List<double> freqs = <double>[261.626, 329.628, 391.995];
    for (int i = 0; i < n; i++) {
      double s = 0;
      for (final double f in freqs) {
        s += 0.28 * math.sin(2 * math.pi * f * i / rate);
      }
      final int v = (s * 16000).round().clamp(-32767, 32767);
      data.setInt16(i * 2, v, Endian.little);
    }
    final String? key = camelotFromPcm(data.buffer.asUint8List(), rate);
    expect(key, isNotNull);
    expect(isCamelotKey(key), isTrue);
    expect(<String>['8B', '8A'].contains(key), isTrue, reason: 'key=$key');
  });

  test('TrackDnaEntry json y fill desde metricas en el espejo', () async {
    final Directory tmp = Directory.systemTemp.createTempSync('gmx3237_');
    addTearDown(() {
      debugLibraryRoots = null;
      debugLibraryCacheRoot = null;
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final String sep = Platform.pathSeparator;
    final String music = '${tmp.path}${sep}Music';
    final String regen = '$music${sep}ReGenial${sep}Rock';
    Directory(regen).createSync(recursive: true);
    debugLibraryRoots = <String>[music];
    debugLibraryCacheRoot = '${tmp.path}${sep}cache';
    Directory(debugLibraryCacheRoot!).createSync(recursive: true);

    final File audio = File('$regen${sep}Tema 8A.mp3')
      ..writeAsBytesSync(List<int>.filled(64, 0));
    final int mtime = audio.lastModifiedSync().millisecondsSinceEpoch;
    expect(const TrackDnaEntry(energy: 0.5).toJson()['energyLevel'], isNull);

    await saveTrackDna(
      audio.path,
      TrackDnaEntry(
        energy: 0.5,
        brightness: 0.5,
        beatDensity: 0.5,
        mtimeMs: mtime,
      ),
    );
    expect(trackEnergyNeedsFill(peekTrackDna(audio.path), mtime), isTrue);
    final TrackDnaEntry? got = await fillTrackEnergyIfStale(audio.path);
    expect(got?.energyLevel, 6);
    expect(got?.camelot, '8A');
    expect(trackEnergyNeedsFill(peekTrackDna(audio.path), mtime), isFalse);
    expect(trackCamelotNeedsFill(peekTrackDna(audio.path)), isFalse);

    final List<String> beside = Directory(
      regen,
    ).listSync().map((FileSystemEntity e) => e.path.split(sep).last).toList();
    expect(beside, <String>['Tema 8A.mp3']);

    final TrackDnaEntry? again = await fillTrackEnergyIfStale(audio.path);
    expect(again?.energyLevel, 6);
    expect(again?.camelot, '8A');

    final Map<String, dynamic> json = got!.toJson();
    expect(json['energyLevel'], 6);
    expect(json['camelot'], '8A');
    expect(TrackDnaEntry.fromJson(json)?.energyLevel, 6);
  });
}

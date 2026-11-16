import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/bpm_backfill_worker.dart';
import 'package:gatomix/core/gatomix_store.dart';

// 3.1.42: el BPM medido se guarda aunque la carpeta no tenga
// `.gatomix.json`, y el medidor arranca despues de las 2 pistas en decks.
// Todo en %TEMP%; nada toca ReGenial.
void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('gmx3142_'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Map<String, dynamic> doc() =>
      jsonDecode(
            File(
              '${tmp.path}${Platform.pathSeparator}$gatomixStoreName',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;

  test('stampBackfill crea .gatomix.json con BPM y mtime', () {
    final String p =
        '${tmp.path}${Platform.pathSeparator}Elefante - Durmiendo.mp3';
    File(p).writeAsBytesSync(<int>[0, 1, 2, 3]);
    stampBackfill(p, 112.4);
    expect(
      File(
        '${tmp.path}${Platform.pathSeparator}$gatomixStoreName',
      ).existsSync(),
      isTrue,
    );
    final Object? bpm = readDjMetadata(tmp.path)[p];
    expect(bpm is num ? bpm : (bpm as Map)['bpm'], closeTo(112.4, 0.01));
    expect(readDjTimestamps(tmp.path)[p], isA<int>());
    expect(doc()['schema'], 1);
  });

  test('stampBackfill sin BPM no crea el archivo', () {
    final String p = '${tmp.path}${Platform.pathSeparator}sin_bpm.mp3';
    File(p).writeAsBytesSync(<int>[0, 1]);
    stampBackfill(p, 0);
    expect(
      File(
        '${tmp.path}${Platform.pathSeparator}$gatomixStoreName',
      ).existsSync(),
      isFalse,
    );
  });

  test('candidatos: salta los decks, _K, repetidas y las ya medidas', () {
    final List<String> q = <String>[
      'a.mp3',
      'b.mp3',
      'c.mp3',
      'c_K.mp3',
      'd (120 BPM).mp3',
      'c.mp3',
      'e.mp3',
    ];
    double bpmOf(String p) => p.contains('BPM') ? 120 : 0;
    expect(backfillCandidates(q, 2, bpmOf), <String>['c.mp3', 'e.mp3']);
    expect(backfillCandidates(q, 0, bpmOf).first, 'a.mp3');
  });
}

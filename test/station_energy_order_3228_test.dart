import 'dart:io';
import 'dart:math';

import 'package:difogo/core/genre_stations.dart';
import 'package:flutter_test/flutter_test.dart';

// 3.2.28: estaciones bailables con energia pareja. Solo rutas sinteticas,
// sin disco, sin Rust y sin motor de audio.

String _src(String rel) =>
    File(rel).readAsStringSync().replaceAll('\r\n', '\n');

String _body(String s, String from, String to) {
  final int a = s.indexOf(from);
  expect(a, greaterThanOrEqualTo(0), reason: from);
  final int b = s.indexOf(to, a + from.length);
  expect(b, greaterThan(a), reason: to);
  return s.substring(a, b);
}

const List<String> _subs = <String>['Salsa', 'Cumbia', 'Merengue'];

/// Dos grupos de energia (92-103 y 124-135 BPM), artistas distintos y los
/// sub-generos entrelazados.
(List<String>, Map<String, double>) _party() {
  final List<String> paths = <String>[];
  final Map<String, double> bpm = <String, double>{};
  for (var i = 0; i < 12; i++) {
    final String slow =
        'C:/Fiesta/${_subs[i % 3]}/Lento ${i.toString().padLeft(2, '0')} - Tema.mp3';
    final String fast =
        'C:/Fiesta/${_subs[(i + 1) % 3]}/Rapido ${i.toString().padLeft(2, '0')} - Tema.mp3';
    paths
      ..add(slow)
      ..add(fast);
    bpm[slow] = 92.0 + i;
    bpm[fast] = 124.0 + i;
  }
  return (paths, bpm);
}

String? _block(String p) {
  for (final String s in _subs) {
    if (p.contains('/$s/')) return s;
  }
  return null;
}

int _jumps(List<String> out, Map<String, double> bpm) {
  var n = 0;
  for (var i = 1; i < out.length; i++) {
    if (!stationBpmNear(bpm[out[i - 1]]!, bpm[out[i]]!)) n++;
  }
  return n;
}

void main() {
  group('3.2.28 orden de energia pareja', () {
    test('vecinas a <= 8 % de BPM mientras haya alternativa', () {
      final (List<String> lib, Map<String, double> bpm) = _party();
      var legacyJumps = 0;
      for (var seed = 0; seed < 30; seed++) {
        final List<String> out = stationSmartShuffle(
          lib,
          Random(seed),
          blockOf: _block,
          bpmOf: (String p) => bpm[p] ?? 0,
        );
        expect(out.length, lib.length);
        expect(out.toSet().length, lib.length);
        for (var i = 1; i < out.length; i++) {
          final double prev = bpm[out[i - 1]]!;
          if (stationBpmNear(prev, bpm[out[i]]!)) continue;
          // Hubo salto: no quedaba ninguna cercana de otro artista.
          final String last = stationArtistKey(out[i - 1]);
          for (final String rest in out.sublist(i)) {
            final bool alt =
                stationArtistKey(rest) != last &&
                stationBpmNear(prev, bpm[rest]!);
            expect(alt, isFalse, reason: 'seed $seed pos $i: $rest');
          }
        }
        // Dos grupos de energia: a lo sumo ir y volver una vez (el borde de
        // un grupo puede quedar sin vecina a <= 8 %).
        expect(_jumps(out, bpm), lessThanOrEqualTo(2), reason: 'seed $seed');
        legacyJumps += _jumps(
          stationSmartShuffle(lib, Random(seed), blockOf: _block),
          bpm,
        );
      }
      // El orden de 3.2.1 (sin BPM) saltaba mucho mas.
      expect(legacyJumps, greaterThan(30 * 3));
    });

    test('no se fuerza la rotacion de bloque con un salto > 8 %', () {
      final List<String> lib = <String>[];
      final Map<String, double> bpm = <String, double>{};
      for (var i = 0; i < 6; i++) {
        final String a = 'C:/Fiesta/Salsa/Salsero $i - Tema.mp3';
        final String b = 'C:/Fiesta/Cumbia/Cumbiero $i - Tema.mp3';
        lib
          ..add(a)
          ..add(b);
        bpm[a] = 100.0 + i;
        bpm[b] = 140.0 + i;
      }
      for (var seed = 0; seed < 30; seed++) {
        final List<String> out = stationSmartShuffle(
          lib,
          Random(seed),
          blockOf: _block,
          bpmOf: (String p) => bpm[p] ?? 0,
        );
        expect(out.toSet().length, 12);
        expect(_jumps(out, bpm), 1, reason: 'seed $seed');
      }
    });

    test('separacion de artistas con BPM', () {
      final List<String> lib = <String>[];
      final Map<String, double> bpm = <String, double>{};
      for (var a = 0; a < 4; a++) {
        for (var t = 0; t < 4; t++) {
          final String p = 'C:/Fiesta/${_subs[t % 3]}/Artista $a - Tema $t.mp3';
          lib.add(p);
          bpm[p] = 118.0 + t;
        }
      }
      for (var seed = 0; seed < 30; seed++) {
        final List<String> out = stationSmartShuffle(
          lib,
          Random(seed),
          blockOf: _block,
          bpmOf: (String p) => bpm[p] ?? 0,
        );
        expect(out.toSet().length, 16);
        for (var i = 1; i < out.length; i++) {
          expect(
            stationArtistKey(out[i]),
            isNot(stationArtistKey(out[i - 1])),
            reason: 'seed $seed pos $i',
          );
        }
      }
    });

    test('sin BPM conocido el orden es el de 3.2.1', () {
      final (List<String> lib, _) = _party();
      for (var seed = 0; seed < 10; seed++) {
        expect(
          stationSmartShuffle(
            lib,
            Random(seed),
            blockOf: _block,
            bpmOf: (_) => 0,
          ),
          stationSmartShuffle(lib, Random(seed), blockOf: _block),
        );
      }
    });

    test('BPM desconocidos no se pierden (van al final)', () {
      final (List<String> lib, Map<String, double> bpm) = _party();
      final List<String> extra = <String>[
        for (var i = 0; i < 5; i++) 'C:/Fiesta/Salsa/Sin Bpm $i - Tema.mp3',
      ];
      final List<String> out = stationSmartShuffle(
        <String>[...lib, ...extra],
        Random(4),
        blockOf: _block,
        bpmOf: (String p) => bpm[p] ?? 0,
      );
      expect(out.toSet(), <String>{...lib, ...extra});
      expect(out.length, lib.length + extra.length);
    });
  });

  group('3.2.28 planStation', () {
    test('no repite antes del 100 % y reinicia al completar', () {
      final (List<String> lib, Map<String, double> bpm) = _party();
      final List<String> played = lib.sublist(0, 10);
      final StationPlan p = planStation(
        lib,
        GenreSession(playedPaths: played),
        rng: Random(1),
        bpmOf: (String x) => bpm[x] ?? 0,
      );
      final List<String> got = <String>[?p.currentTrackPath, ...p.queue];
      expect(got.toSet().length, got.length);
      expect(got.toSet(), lib.sublist(10).toSet());
      expect(got.any(played.contains), isFalse);

      final StationPlan again = planStation(
        lib,
        GenreSession(playedPaths: lib),
        rng: Random(1),
        bpmOf: (String x) => bpm[x] ?? 0,
      );
      expect(again.played, isEmpty);
      expect(again.queue.toSet(), lib.toSet());
      expect(again.queue.length, lib.length);
    });

    test('la reanudacion es igual: pista, segundo y cola guardada', () {
      final (List<String> lib, Map<String, double> bpm) = _party();
      // Cola guardada a proposito con saltos de energia: no se reordena.
      final List<String> rest = <String>[lib[1], lib[2], lib[3], lib[0]];
      final GenreSession saved = GenreSession(
        currentTrackPath: lib[5],
        positionMs: 42000,
        remainingQueuePaths: rest,
        playedPaths: <String>[lib[6]],
      );
      final StationPlan a = planStation(
        lib,
        saved,
        rng: Random(9),
        bpmOf: (String x) => bpm[x] ?? 0,
      );
      expect(a.resumed, isTrue);
      expect(a.currentTrackPath, lib[5]);
      expect(a.positionMs, 42000);
      expect(a.queue.sublist(0, 4), rest);
      expect(a.queue.contains(lib[6]), isFalse);
      expect(a.queue.length, lib.length - 2);
      final StationPlan b = planStation(
        lib,
        saved,
        rng: Random(9),
        bpmOf: (String x) => bpm[x] ?? 0,
      );
      expect(b.queue, a.queue);
    });

    test('stationWarmWindow: cola guardada primero, tope y sin repetir', () {
      final List<String> all = <String>[
        for (var i = 0; i < 500; i++) 'C:/E/Sub/Artista $i - T.mp3',
      ];
      final GenreSession s = GenreSession(
        currentTrackPath: all[7],
        remainingQueuePaths: <String>[all[3], all[4]],
      );
      final List<String> w = stationWarmWindow(all, s, limit: 20);
      expect(w.length, 20);
      expect(w.sublist(0, 3), <String>[all[7], all[3], all[4]]);
      expect(w.toSet().length, 20);
      expect(stationWarmWindow(all.sublist(0, 5), null), all.sublist(0, 5));
    });
  });

  group('3.2.28 fuente', () {
    test('Live DJ: loadStation deja la epoca del reorden en la cola', () {
      final String s = _src('lib/providers/livedj_provider.dart');
      final String body = _body(
        s,
        'Future<bool> loadStation(',
        'Future<void> savePlaylist',
      );
      expect(body.contains('_backfillEpoch = state.queue;'), isTrue);
      expect(body.contains('_backfillEpoch = null;'), isTrue);
      expect(
        body.indexOf('_backfillEpoch = state.queue;'),
        greaterThan(body.indexOf('sortMode: LiveDjSortMode.manual')),
      );
      // Phrase 8 conserva su regla en el reorden.
      expect(
        s,
        contains(
          'if (!mixFormulaMayReorderQueue(ref.read(mixFormulaProvider))) return;',
        ),
      );
    });

    test('Hub: calienta la ventana con tope y ordena con BPM/Camelot/ADN', () {
      final String s = _src('lib/providers/vibe_hub_provider.dart');
      expect(
        s,
        contains(
          'await _warmStation(stationWarmWindow(all, d.stations[key]));',
        ),
      );
      expect(s, contains('preloadQueueBpmAsync(win),'));
      expect(s, contains('warmHarmonicDna(win),'));
      expect(s, contains('.timeout(kDnaWarmWait'));
      expect(s, contains('bpmOf: memoryBpm,'));
      expect(s, contains('keyOf: camelotFromPath,'));
      expect(s, contains('dnaOf: harmonicDnaOf,'));
    });

    test('Automix: lista retomada tambien pasa por el orden armonico', () {
      final String s = _src('lib/providers/automix_provider.dart');
      final String body = _body(
        s,
        'Future<void> _loadPersistentQueue(',
        '/// 3.1.98: mapa de sesiones',
      );
      expect(body.contains('plan.fresh && random'), isFalse);
      expect(body, contains('if (random) {'));
      expect(body, contains('_shufflePlaylistAsync()'));
    });
  });
}

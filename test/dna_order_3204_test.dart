// 3.2.4: ADN acustico en el Shuffle armonico (dnaOf), tags/idioma de la
// cache `dna` en el clasificador y backfill de ADN (sin Rust: fakes).
import 'dart:io';
import 'dart:math';

import 'package:difogo/core/bpm_backfill_worker.dart';
import 'package:difogo/core/gatomix_store.dart';
import 'package:difogo/core/genre_stations.dart';
import 'package:difogo/core/library_guard.dart';
import 'package:difogo/core/livedj_order.dart';
import 'package:difogo/src/rust/api/core_dsp.dart' as rust_dsp;
import 'package:flutter_test/flutter_test.dart';

List<String> _lib(int n) => <String>[
  for (int i = 0; i < n; i++) '/m/Artista ${i % 37} - Tema $i.mp3',
];

int _idx(String p) => int.parse(RegExp(r'Tema (\d+)').firstMatch(p)!.group(1)!);

double _bpm(String p) {
  final int i = _idx(p);
  if (i % 11 == 5) return 0;
  return 90 + ((i * 37) % 41) * 0.75;
}

String? _key(String p) {
  final int i = _idx(p);
  if (i % 3 == 0) return null;
  return '${(i % 12) + 1}${i.isEven ? 'A' : 'B'}';
}

String _sig(HarmonicOrder o) {
  int h = 17;
  for (final String p in o.tracks) {
    h = (h * 31 + _idx(p)) & 0x3fffffff;
  }
  return 'len=${o.tracks.length} h=$h up=${o.waveUp} in=${o.inWave}';
}

// Medido con livedj_order.dart de 3.2.3 (ff7df7f) antes de este cambio.
const Map<String, String> _golden = <String, String>{
  '30/1': 'len=30 h=536649640 up=true in=3',
  '30/7': 'len=30 h=750089420 up=true in=3',
  '30/42': 'len=30 h=866128916 up=true in=3',
  '300/1': 'len=300 h=397865867 up=false in=3',
  '300/7': 'len=300 h=387581909 up=false in=3',
  '300/42': 'len=300 h=814135371 up=false in=3',
};

const HarmonicDna _soft = HarmonicDna(
  energy: 0.25,
  brightness: 0.3,
  beatDensity: 0.25,
  lang: 'es',
);
const HarmonicDna _hot = HarmonicDna(
  energy: 0.9,
  brightness: 0.8,
  beatDensity: 0.8,
  lang: 'es',
);

List<String> _cumbias(int n) => <String>[
  for (int i = 0; i < n; i++)
    i.isEven
        ? '/c/Grupo $i - Cumbia suave $i.mp3'
        : '/c/Grupo $i - Cumbia prendida $i.mp3',
];

bool _isSoft(String p) => p.contains('suave');

int _switches(List<String> order) {
  int s = 0;
  for (int i = 1; i < order.length; i++) {
    if (_isSoft(order[i]) != _isSoft(order[i - 1])) s++;
  }
  return s;
}

void main() {
  group('a) sin dnaOf el orden es el de 3.2.3', () {
    for (final int n in <int>[30, 300]) {
      for (final int seed in <int>[1, 7, 42]) {
        test('n=$n seed=$seed', () {
          HarmonicOrder run([HarmonicDna? Function(String)? dnaOf]) =>
              buildHarmonicShuffle(
                _lib(n),
                _bpm,
                keyOf: _key,
                rng: Random(seed),
                waveLength: 6,
                dnaOf: dnaOf,
              );
          final HarmonicOrder base = run();
          expect(_sig(base), _golden['$n/$seed']);
          // dnaOf que no conoce ninguna pista: mismo orden exacto.
          expect(run((String _) => null).tracks, base.tracks);
        });
      }
    }
  });

  group('b) con dnaOf agrupa energia/brillo/idioma parecidos', () {
    for (final int n in <int>[20, 300]) {
      test('cumbia suave vs prendida al mismo BPM, n=$n', () {
        final List<String> lib = _cumbias(n);
        int withDna = 0;
        int without = 0;
        for (int seed = 1; seed <= 5; seed++) {
          final HarmonicOrder a = buildHarmonicShuffle(
            lib,
            (String _) => 100,
            rng: Random(seed),
            dnaOf: (String p) => _isSoft(p) ? _soft : _hot,
          );
          final HarmonicOrder b = buildHarmonicShuffle(
            lib,
            (String _) => 100,
            rng: Random(seed),
          );
          expect(a.tracks.toSet(), lib.toSet());
          expect(a.tracks.length, n);
          withDna += _switches(a.tracks);
          without += _switches(b.tracks);
        }
        // Con ADN casi no cruza de grupo (1 vez al agotarse uno); sin ADN
        // salta de uno a otro muchas veces.
        expect(withDna, lessThanOrEqualTo(5 * 3));
        expect(without, greaterThan(withDna * 3));
      });
    }

    test('harmonicDnaScore: tope +-20 y castigo a saltos de energia', () {
      expect(harmonicDnaScore(_soft, _soft), 20);
      // -7 -4 -4 +5 (mismo idioma) -7,5 (salto de 0,65).
      expect(harmonicDnaScore(_soft, _hot), -17.5);
      expect(
        harmonicDnaScore(
          _soft,
          const HarmonicDna(
            energy: 0.95,
            brightness: 0.9,
            beatDensity: 0.9,
            lang: 'en',
          ),
        ),
        -20,
      );
      expect(harmonicDnaScore(null, _hot), 0);
      const HarmonicDna mid = HarmonicDna(energy: 0.5);
      expect(
        harmonicDnaScore(mid, const HarmonicDna(energy: 0.55)),
        closeTo(5.25, 1e-9),
      );
      expect(
        harmonicDnaScore(
          const HarmonicDna(lang: 'es'),
          const HarmonicDna(lang: 'en'),
        ),
        -3,
      );
    });

    test('el BPM sigue mandando sobre el ADN', () {
      // Actual 100 suave; candidatas: suave a 108 y prendida a 100.5.
      final HarmonicOrder o = buildHarmonicShuffle(
        <String>['/c/A - suave 108.mp3', '/c/B - prendida 100.mp3'],
        (String p) => p.contains('108') ? 108 : 100.5,
        continueFrom: '/c/X - suave 100.mp3',
        rng: Random(3),
        dnaOf: (String p) => p.contains('suave') ? _soft : _hot,
      );
      expect(o.tracks.length, 2);
    });
  });

  group('c) TrackTagHint desde la cache dna', () {
    late Directory root;
    final String sep = Platform.pathSeparator;

    setUp(() {
      root = Directory.systemTemp.createTempSync('difogo_dna3204_');
      debugLibraryRoots = <String>['${root.path}${sep}Biblioteca'];
      debugLibraryCacheRoot = '${root.path}${sep}cache';
      debugForgetTrackDnaMemory();
    });

    tearDown(() {
      GatomixStore.forget(<String>[
        '${root.path}${sep}Musica',
        '${root.path}${sep}Rock',
        '${root.path}${sep}Baladas',
      ]);
      debugForgetTrackDnaMemory();
      debugLibraryRoots = null;
      debugLibraryCacheRoot = null;
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });

    String mk(String rel) {
      final File f = File('${root.path}$sep$rel');
      f.parent.createSync(recursive: true);
      f.writeAsBytesSync(<int>[1, 2, 3]);
      return f.path;
    }

    test('genero ID3 y idioma clasifican sin nombre de carpeta', () async {
      final String salsa = mk('Musica${sep}zq7 - pista 1.mp3');
      final String rockEs = mk('Rock${sep}banda xyz - tema raro.mp3');
      final String rockEn = mk('Rock${sep}otra banda qwz - song.mp3');
      final String bal = mk('Baladas${sep}nadie conocido - lento.mp3');
      final String none = mk('Musica${sep}zq8 - pista 2.mp3');
      await saveTrackDna(
        salsa,
        const TrackDnaEntry(genre: 'Salsa', year: 1995),
      );
      await saveTrackDna(rockEs, const TrackDnaEntry(lang: 'es'));
      await saveTrackDna(rockEn, const TrackDnaEntry(lang: 'en'));
      await saveTrackDna(bal, const TrackDnaEntry(lang: 'en'));
      // Sin memoria: classifyTracks la carga (una lectura async por carpeta).
      debugForgetTrackDnaMemory();
      GatomixStore.forget(<String>[
        '${root.path}${sep}Musica',
        '${root.path}${sep}Rock',
        '${root.path}${sep}Baladas',
      ]);
      expect(peekTrackDna(salsa), isNull);

      final TrackGenreIndex idx = TrackGenreIndex(
        '${root.path}${sep}index.json',
      );
      final List<String> all = <String>[salsa, rockEs, rockEn, bal, none];
      final TrackGenreBuckets b = await classifyTracks(
        all,
        root: root.path,
        index: idx,
        mtimeOf: (String p) async => 1,
      );
      expect(peekTrackDna(salsa)?.genre, 'Salsa');
      String? where(String p) {
        for (final MapEntry<String, Map<String, List<String>>> s
            in b.byStation.entries) {
          for (final MapEntry<String, List<String>> e in s.value.entries) {
            if (e.value.contains(p)) return '${s.key}/${e.key}';
          }
        }
        return null;
      }

      expect(where(salsa), 'tropical/Salsa');
      expect(where(rockEs), 'rock/Rock Clásico Español');
      expect(where(rockEn), 'rock/Rock Clásico en Inglés');
      expect(where(bal), 'baladas/En Inglés');
      expect(where(none), isNull);
      expect(b.unknown, contains(none));
    });

    test(
      'entrada vieja del indice (nivel 3 Todas) se corrige con idioma',
      () async {
        final String p = mk('Rock${sep}banda xyz - tema raro.mp3');
        final TrackGenreIndex idx = TrackGenreIndex(
          '${root.path}${sep}index.json',
        );
        idx.put(p, 1, const TrackGenre('rock', 'Todas', 3));
        final TrackGenreBuckets before = await classifyTracks(
          <String>[p],
          root: root.path,
          index: idx,
          mtimeOf: (String _) async => 1,
          tagsOf: (String _) => null,
        );
        expect(before.byStation['rock']?['Todas'], contains(p));
        final TrackGenreBuckets after = await classifyTracks(
          <String>[p],
          root: root.path,
          index: idx,
          mtimeOf: (String _) async => 1,
          tagsOf: (String _) => const TrackTagHint(lang: 'en'),
        );
        expect(after.byStation['rock']?['Rock Clásico en Inglés'], contains(p));
        expect(idx.lookup(p, 1)?.subGenreId, 'Rock Clásico en Inglés');
      },
    );

    test('harmonicDnaOf lee la memoria; backfill conserva lang', () async {
      final String p = mk('Musica${sep}zq9 - pista 3.mp3');
      await saveTrackDna(p, const TrackDnaEntry(lang: 'pt'));
      int calls = 0;
      final bool wrote = await fillTrackDnaIfStale(
        p,
        readMeta: (String _) async {
          calls++;
          return const rust_dsp.TrackMeta(
            genre: 'Cumbia',
            year: 2001,
            artist: 'a',
            title: 't',
          );
        },
        measure: (String _) async => const rust_dsp.TrackDna(
          ok: true,
          energy: 0.7,
          bassRatio: 0.4,
          brightness: 0.5,
          beatDensity: 0.6,
        ),
      );
      expect(wrote, isTrue);
      expect(calls, 1);
      final TrackDnaEntry d = readTrackDna(p)!;
      expect((d.lang, d.genre, d.year, d.energy), ('pt', 'Cumbia', 2001, 0.7));
      expect(d.mtimeMs, File(p).statSync().modified.millisecondsSinceEpoch);
      final HarmonicDna h = harmonicDnaOf(p)!;
      expect(
        (h.energy, h.brightness, h.beatDensity, h.lang),
        (0.7, 0.5, 0.6, 'pt'),
      );
      // Mismo mtime: no vuelve a llamar a Rust.
      expect(
        await fillTrackDnaIfStale(
          p,
          readMeta: (String _) async => throw StateError('no'),
          measure: (String _) async => throw StateError('no'),
        ),
        isFalse,
      );
    });

    test('backfill en la biblioteca protegida: solo espejo', () async {
      final String lib = '${root.path}${sep}Biblioteca${sep}Salsa';
      final File a = File('$lib${sep}tema.mp3')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(<int>[1]);
      final List<String> before = Directory(
        '${root.path}${sep}Biblioteca',
      ).listSync(recursive: true).map((FileSystemEntity e) => e.path).toList();
      final bool ok = await fillTrackDnaIfStale(
        a.path,
        readMeta: (String _) async =>
            const rust_dsp.TrackMeta(genre: '', year: 0, artist: '', title: ''),
        measure: (String _) async => const rust_dsp.TrackDna(
          ok: true,
          energy: 0.3,
          bassRatio: 0.3,
          brightness: 0.3,
          beatDensity: 0.3,
        ),
      );
      expect(ok, isTrue);
      final List<String> after = Directory(
        '${root.path}${sep}Biblioteca',
      ).listSync(recursive: true).map((FileSystemEntity e) => e.path).toList();
      expect(after, before);
      expect(GatomixStore.fileOf(lib).path.startsWith(root.path), isTrue);
      expect(GatomixStore.fileOf(lib).existsSync(), isTrue);
      GatomixStore.forget(<String>[lib]);
    });

    test('worker: ADN tras el BPM y enqueueDna, pausado en cruces', () async {
      final List<String> filled = <String>[];
      bool paused = true;
      final BpmBackfillWorker w = BpmBackfillWorker(
        measure: (String _) async => 120,
        isPaused: () => paused,
        onBatch: (_) {},
        gap: const Duration(milliseconds: 1),
        fillDna: (String p) async {
          filled.add(p);
          return true;
        },
      );
      w.enqueue(<String>['/x/a.mp3']);
      w.enqueueDna(<String>['/x/b.mp3', '/x/a.mp3']);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(filled, isEmpty);
      paused = false;
      for (int i = 0; i < 50 && filled.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(filled, <String>['/x/a.mp3', '/x/b.mp3']);
      w.cancel();
    });
  });
}

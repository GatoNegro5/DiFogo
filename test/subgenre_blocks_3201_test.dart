import 'dart:math';

import 'package:difogo/core/genre_stations.dart';
import 'package:difogo/core/livedj_order.dart';
import 'package:flutter_test/flutter_test.dart';

// 3.2.1: micro-bloques de sub-genero/idioma + normalizacion de dieresis.

const String kEs = 'rock|Rock Clásico Español';
const String kEn = 'rock|Rock Clásico en Inglés';
const String kMe = 'rock|Heavy Metal';

List<int> runsOf(List<String> order, String? Function(String) blk) {
  final List<int> runs = <int>[];
  String? prev;
  for (final String p in order) {
    final String? b = blk(p);
    if (runs.isNotEmpty && b == prev) {
      runs[runs.length - 1]++;
    } else {
      runs.add(1);
    }
    prev = b;
  }
  return runs;
}

double sameRatio(List<String> order, String? Function(String) blk) {
  if (order.length < 2) return 0;
  var same = 0;
  for (var i = 1; i < order.length; i++) {
    if (blk(order[i]) == blk(order[i - 1])) same++;
  }
  return same / (order.length - 1);
}

void main() {
  group('a) dieresis y diccionario', () {
    test('stationFold normaliza dieresis, acentos europeos y NFD', () {
      expect(stationFold('Mägo de Oz'), 'mago de oz');
      expect(stationFold('Motörhead'), 'motorhead');
      expect(stationFold('Mötley Crüe'), 'motley crue');
      expect(stationFold('ÀÈÌÒÙ âêîôû Ç ë ï'), 'aeiou aeiou c e i');
      expect(stationFold('Ma\u0308go de Oz'), 'mago de oz');
    });

    test('Mago de Oz, Motorhead y Motley Crue hacen match', () {
      final TrackGenre mago = TrackGenreClassifier.classify(
        'D:/Descargas/Mägo de Oz - Fiesta Pagana.mp3',
      );
      expect('${mago.stationId}|${mago.subGenreId}', kEs);
      expect(mago.level, 2);
      final TrackGenre moto = TrackGenreClassifier.classify(
        'D:/Descargas/Motörhead - Ace of Spades.mp3',
      );
      expect('${moto.stationId}|${moto.subGenreId}', kMe);
      expect(moto.level, 2);
      final TrackGenre crue = TrackGenreClassifier.classify(
        'D:/Descargas/Mötley Crüe - Kickstart My Heart.mp3',
      );
      // Entrada existente del diccionario: Ochenteras > Rock.
      expect(crue.toString(), 'ochenteras/Rock@2');
      expect(
        TrackGenreClassifier.classify(
          'D:/Descargas/Ma\u0308go de Oz - Molinos de Viento.mp3',
        ).subGenreId,
        'Rock Clásico Español',
      );
    });

    test('version del indice sube y reclasifica niveles 2-4', () {
      expect(kTrackGenreIndexVersion, 3);
      final TrackGenreIndex idx = TrackGenreIndex(
        'x.json',
        <String, Map<String, Object?>>{
          stationPathKey('D:/a/old.mp3'): <String, Object?>{
            'mtime': 1,
            'stationId': null,
            'subGenreId': null,
            'level': 4,
            'v': 2,
          },
          stationPathKey('D:/a/cur.mp3'): <String, Object?>{
            'mtime': 1,
            'stationId': 'rock',
            'subGenreId': 'Heavy Metal',
            'level': 0,
            'v': 2,
          },
        },
      );
      expect(idx.lookup('D:/a/old.mp3', 1), isNull);
      expect(idx.lookup('D:/a/cur.mp3', 1)?.subGenreId, 'Heavy Metal');
    });
  });

  group('b) carpeta generica Rock por artista', () {
    test('Rock/ suelto: sub-genero real por artista', () {
      String? sub(String name) =>
          stationTrackGenre('C:/Users/Gabo/Music/Rock/$name.mp3').subGenreId;
      expect(sub('Iron Maiden - The Trooper'), 'Heavy Metal');
      expect(sub('Motörhead - Ace of Spades'), 'Heavy Metal');
      expect(sub('Soda Stereo - De Musica Ligera'), 'Rock Clásico Español');
      expect(sub('Mägo de Oz - Fiesta Pagana'), 'Rock Clásico Español');
      expect(
        sub("Guns N' Roses - Sweet Child O Mine"),
        'Rock Clásico en Inglés',
      );
      expect(sub('Mötley Crüe - Kickstart My Heart'), 'Rock Clásico en Inglés');
      expect(sub('Nirvana - Come As You Are'), 'Grunge');
      expect(sub('Banda Desconocida - Tema'), 'Todas');
      expect(
        stationTrackGenre(
          'C:/Music/Rock/Iron Maiden - Aces High.mp3',
        ).stationId,
        'rock',
      );
    });

    test('carpeta canonica <Rock>/Todas tambien se refina', () {
      final String t = universalStation('rock')!.title;
      expect(
        stationTrackGenre(
          'C:/Music/$t/Todas/Iron Maiden - Wasted Years.mp3',
        ).subGenreId,
        'Heavy Metal',
      );
      expect(
        stationTrackGenre(
          'C:/Music/$t/Todas/Banda Desconocida - Tema.mp3',
        ).subGenreId,
        'Todas',
      );
    });

    test('carpeta especifica manda y Todas no arma bloque', () {
      expect(
        stationTrackGenre(
          'C:/Music/Heavy Metal/Soda Stereo - Musica.mp3',
        ).subGenreId,
        'Heavy Metal',
      );
      expect(trackBlockKey('C:/Music/Rock/Iron Maiden - Run.mp3'), kMe);
      expect(
        trackBlockKey('C:/Music/Rock/Banda Desconocida - Tema.mp3'),
        isNull,
      );
    });
  });

  group('c) micro-bloques', () {
    const List<String> es = <String>[
      'Soda Stereo',
      'Heroes del Silencio',
      'Mägo de Oz',
      'Caifanes',
      'Enanitos Verdes',
      'Soda Stereo',
      'Heroes del Silencio',
      'Caifanes',
    ];
    const List<String> en = <String>[
      "Guns N' Roses",
      'Bon Jovi',
      'Led Zeppelin',
      'Aerosmith',
      'Kiss',
      "Guns N' Roses",
      'Bon Jovi',
      'Aerosmith',
    ];
    const List<String> me = <String>[
      'Iron Maiden',
      'Metallica',
      'Black Sabbath',
      'Motörhead',
      'Judas Priest',
      'Iron Maiden',
      'Metallica',
      'Judas Priest',
    ];
    List<String> lib(int perGroup) => <String>[
      for (var i = 0; i < perGroup; i++) ...<String>[
        'C:/Music/Rock/${es[i]} - Tema $i.mp3',
        'C:/Music/Rock/${en[i]} - Song $i.mp3',
        'C:/Music/Rock/${me[i]} - Metal $i.mp3',
      ],
    ];

    test('blockOf por defecto ve los 3 sub-generos', () {
      final Set<String?> b = lib(4).map(trackBlockKey).toSet();
      expect(b, <String?>{kEs, kEn, kMe});
    });

    test('stationSmartShuffle: 3 bloques de 4 (12 pistas)', () {
      for (var seed = 0; seed < 30; seed++) {
        final List<String> out = stationSmartShuffle(lib(4), Random(seed));
        expect(out.length, 12);
        expect(runsOf(out, trackBlockKey), <int>[4, 4, 4], reason: '$seed');
      }
    });

    test('stationSmartShuffle: bloques de 3-4 sin artista seguido (24)', () {
      for (var seed = 0; seed < 30; seed++) {
        final List<String> out = stationSmartShuffle(lib(8), Random(seed));
        expect(out.toSet().length, 24);
        for (var i = 1; i < out.length; i++) {
          expect(
            stationArtistKey(out[i]),
            isNot(stationArtistKey(out[i - 1])),
            reason: 'seed $seed pos $i',
          );
        }
        final List<int> runs = runsOf(out, trackBlockKey);
        expect(runs.length, lessThanOrEqualTo(8), reason: '$seed $runs');
        expect(runs.every((int r) => r <= 4), isTrue, reason: '$seed $runs');
        final int inBlocks = runs
            .where((int r) => r >= 3)
            .fold(0, (int a, int r) => a + r);
        expect(inBlocks, greaterThanOrEqualTo(20), reason: '$seed $runs');
      }
    });

    test('stationSmartShuffle: un solo bloque deja el orden de 3.1.70', () {
      final List<String> one = <String>[
        for (var i = 0; i < 10; i++) 'C:/Music/X/Artista $i - Tema.mp3',
      ];
      expect(
        stationSmartShuffle(one, Random(7)),
        stationSmartShuffle(one, Random(7), blockOf: (_) => null),
      );
    });

    test('stationSmartShuffle: after abre el bloque de la anterior', () {
      for (var seed = 0; seed < 10; seed++) {
        final List<String> out = stationSmartShuffle(
          lib(4),
          Random(seed),
          after: 'C:/Music/Rock/Kiss - Detroit.mp3',
        );
        expect(trackBlockKey(out[0]), kEn, reason: '$seed');
        expect(trackBlockKey(out[1]), kEn, reason: '$seed');
      }
    });

    // Biblioteca de rock con BPM repartidos (110-130) y los 3 sub-generos
    // entrelazados: sin subOf la mas cercana alterna de sub-genero.
    (List<String>, Map<String, double>) rockLib(int n) {
      final List<String> paths = <String>[];
      final Map<String, double> bpm = <String, double>{};
      final List<List<String>> groups = <List<String>>[es, en, me];
      for (var i = 0; i < n; i++) {
        final List<String> g = groups[i % 3];
        final String p = 'C:/Music/Rock/${g[(i ~/ 3) % 5]} - T$i.mp3';
        paths.add(p);
        bpm[p] = 110 + ((i * 37) % n) * 20 / n;
      }
      return (paths, bpm);
    }

    (double, double) harmonicStats(int n, String? Function(String)? subOf) {
      final (List<String> paths, Map<String, double> bpm) = rockLib(n);
      var ratio = 0.0;
      var runs = 0;
      var long = 0;
      for (var seed = 0; seed < 5; seed++) {
        final List<String> out = buildHarmonicShuffle(
          paths,
          (String p) => bpm[p] ?? 0,
          rng: Random(seed),
          subOf: subOf,
        ).tracks;
        expect(out.toSet().length, paths.length);
        ratio += sameRatio(out, trackBlockKey);
        final List<int> r = runsOf(out, trackBlockKey);
        runs += r.length;
        long += r.where((int x) => x > kHarmonicBlockMax).length;
      }
      return (ratio / 5, long / runs);
    }

    test('buildHarmonicShuffle con subOf arma bloques (< 240)', () {
      final (double withBlocks, double long) = harmonicStats(
        180,
        harmonicBlockOf,
      );
      final (double without, _) = harmonicStats(180, null);
      expect(withBlocks, greaterThanOrEqualTo(0.45), reason: '$withBlocks');
      expect(without, lessThan(0.35), reason: '$without');
      expect(long, lessThanOrEqualTo(0.1), reason: '$long');
    });

    test('buildHarmonicShuffle indexado (>= 240) tambien agrupa', () {
      final (double withBlocks, double long) = harmonicStats(
        300,
        harmonicBlockOf,
      );
      final (double without, _) = harmonicStats(300, null);
      expect(withBlocks, greaterThanOrEqualTo(0.55), reason: '$withBlocks');
      expect(without, lessThan(0.35), reason: '$without');
      expect(long, lessThanOrEqualTo(0.1), reason: '$long');
    });

    test('buildHarmonicShuffle: al llegar a 4 favorece rotar', () {
      expect(
        harmonicContinuityScore(
          'C:/Music/Rock/Iron Maiden - A.mp3',
          'C:/Music/Rock/Metallica - B.mp3',
          subOf: harmonicBlockOf,
          run: 3,
        ),
        kHarmonicBlockBonus,
      );
      expect(
        harmonicContinuityScore(
          'C:/Music/Rock/Iron Maiden - A.mp3',
          'C:/Music/Rock/Metallica - B.mp3',
          subOf: harmonicBlockOf,
          run: 4,
        ),
        -kHarmonicBlockBonus,
      );
      expect(
        harmonicContinuityScore(
          'C:/Music/Rock/Iron Maiden - A.mp3',
          'C:/Music/Rock/Iron Maiden - B.mp3',
        ),
        -kHarmonicSameArtistPenalty,
      );
    });
  });
}

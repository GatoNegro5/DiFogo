import 'dart:io';
import 'dart:math';

import 'package:difogo/core/gatomix_radio.dart';
import 'package:difogo/core/genre_stations.dart';
import 'package:difogo/providers/vibe_hub_provider.dart';
import 'package:flutter_test/flutter_test.dart';

// 3.2.2: micro-bloques en Automix/Radio y filtro de sub-generos que mira
// las carpetas generales. Solo rutas sinteticas.

String src(String rel) => File(rel).readAsStringSync().replaceAll('\r\n', '\n');

double sameRatio(List<String> order) {
  var same = 0;
  for (var i = 1; i < order.length; i++) {
    if (trackBlockKey(order[i]) == trackBlockKey(order[i - 1])) same++;
  }
  return same / (order.length - 1);
}

void main() {
  group('a) Automix y Radio pasan subOf', () {
    test('automix_provider: las 2 llamadas al Shuffle armonico', () {
      final String s = src('lib/providers/automix_provider.dart');
      expect('buildHarmonicShuffle('.allMatches(s).length, 2);
      expect('subOf: harmonicBlockOf'.allMatches(s).length, 2);
    });

    test('gatomix_radio: buildDifferentRound pasa subOf', () {
      final String s = src('lib/core/gatomix_radio.dart');
      expect('buildHarmonicShuffle('.allMatches(s).length, 1);
      expect('subOf: harmonicBlockOf'.allMatches(s).length, 1);
    });

    test('Radio: la vuelta arma micro-bloques de sub-genero', () {
      const List<List<String>> groups = <List<String>>[
        <String>[
          'Soda Stereo',
          'Heroes del Silencio',
          'Caifanes',
          'Enanitos Verdes',
          'Mägo de Oz',
        ],
        <String>[
          "Guns N' Roses",
          'Bon Jovi',
          'Led Zeppelin',
          'Aerosmith',
          'Kiss',
        ],
        <String>[
          'Iron Maiden',
          'Metallica',
          'Black Sabbath',
          'Motörhead',
          'Judas Priest',
        ],
      ];
      final List<String> pool = <String>[];
      final Map<String, double> bpm = <String, double>{};
      for (var i = 0; i < 180; i++) {
        final List<String> g = groups[i % 3];
        final String p = 'C:/Music/Rock/${g[(i ~/ 3) % 5]} - T$i.mp3';
        pool.add(p);
        bpm[p] = 110 + ((i * 37) % 180) * 20 / 180;
      }
      var ratio = 0.0;
      for (var seed = 0; seed < 5; seed++) {
        final List<String> out = buildDifferentRound(
          pool: pool,
          bpmOf: (String p) => bpm[p] ?? 0,
          rng: Random(seed),
          maxAttempts: 1,
        );
        expect(out.toSet().length, pool.length);
        ratio += sameRatio(out);
      }
      expect(ratio / 5, greaterThanOrEqualTo(0.45), reason: '${ratio / 5}');
    });
  });

  group('b) filtro de sub-generos en carpetas generales', () {
    const String root = 'C:/Music';
    final List<String> library = <String>[
      'Rock Mix',
      'Heavy Metal',
      'Rock',
      'Salsa',
      'Rock Ingles',
    ];

    test('solo Heavy Metal mira las carpetas generales de Rock', () {
      expect(
        stationFiltersSpecificSubs('rock', <String>['Heavy Metal']),
        isTrue,
      );
      expect(
        stationFallbackFolders('rock', <String>['Heavy Metal'], library),
        <String>['Rock Mix'],
      );
      // Con Todas en visto o sin sub-genero canonico: como siempre.
      expect(
        stationFallbackFolders('rock', <String>[
          'Heavy Metal',
          'Todas',
        ], library),
        isEmpty,
      );
      expect(stationFiltersSpecificSubs('rock', <String>['Todas']), isFalse);
      expect(
        stationFiltersSpecificSubs('rock', <String>['Mi Sesion']),
        isFalse,
      );
    });

    test('Iron Maiden dentro de Rock/ entra con solo Heavy Metal', () {
      final List<String> loose = <String>[
        '$root/Rock Mix/Iron Maiden - The Trooper.mp3',
        '$root/Rock Mix/Soda Stereo - Persiana Americana.mp3',
        '$root/Rock Mix/Banda Desconocida - Tema.mp3',
        '$root/Rock/Todas/Iron Maiden - Aces High.mp3',
        '$root/Rock/Iron Maiden - Run to the Hills.mp3',
        '$root/Rock/Motörhead - Ace of Spades.mp3',
      ];
      expect(
        stationRefinedTracks(
          'rock',
          <String>['Heavy Metal'],
          loose,
          root: root,
        ),
        <String>[
          '$root/Rock Mix/Iron Maiden - The Trooper.mp3',
          '$root/Rock/Todas/Iron Maiden - Aces High.mp3',
          '$root/Rock/Iron Maiden - Run to the Hills.mp3',
          '$root/Rock/Motörhead - Ace of Spades.mp3',
        ],
      );
      expect(
        stationRefinedTracks(
          'rock',
          <String>['Rock Clásico Español'],
          loose,
          root: root,
        ),
        <String>['$root/Rock Mix/Soda Stereo - Persiana Americana.mp3'],
      );
      expect(stationRefinedTracks('rock', <String>['Todas'], loose), isEmpty);
    });

    test('sin duplicados al unir con las carpetas de genero', () {
      final List<String> merged = mergeStationTracks(
        <String>[
          '$root/Heavy Metal/Metallica - One.mp3',
          '$root/Rock Mix/Iron Maiden - The Trooper.mp3',
        ],
        <String>[
          '$root/Rock Mix/Iron Maiden - The Trooper.mp3',
          '$root/Rock/Iron Maiden - Wasted Years.mp3',
        ],
      );
      expect(merged, <String>[
        '$root/Heavy Metal/Metallica - One.mp3',
        '$root/Rock Mix/Iron Maiden - The Trooper.mp3',
        '$root/Rock/Iron Maiden - Wasted Years.mp3',
      ]);
    });

    test('playStation y stationTracksFor usan el pool refinado', () {
      final String s = src('lib/providers/vibe_hub_provider.dart');
      expect(
        s,
        contains(
          'final List<String> all = await _stationPool(key, subGenres);',
        ),
      );
      expect(s, contains('      _stationPool(key, subs);'));
      expect(
        s,
        contains(
          'stationRefinedTracks(key, subs, loose, root: vibeMusicRoot())',
        ),
      );
    });
  });
}

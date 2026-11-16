import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/gatomix_store.dart';
import 'package:gatomix/core/phrase_grid.dart';
import 'package:gatomix/core/display_bpm.dart';
import 'package:gatomix/providers/directory_provider.dart';
import 'package:gatomix/services/track_tags.dart';

// 3.1.43: BPM de listas solo en memoria y guardia de `.lrc` hermanos.
void main() {
  const String dir = 'C:/Musica/Salsa';
  test('cache por ruta completa, aunque cambien separadores', () {
    final Map<String, double> cache = <String, double>{
      r'C:\Musica\Salsa\Elefante - Durmiendo.mp3': 112.4,
    };
    expect(displayBpmFor('$dir/Elefante - Durmiendo.mp3', cache), 112.4);
  });

  test('clave vieja solo con nombre, con espacios', () {
    final Map<String, double> cache = <String, double>{
      'Grupo Gale - Uno.mp3': 95,
    };
    expect(displayBpmFor('$dir/Grupo Gale - Uno.mp3', cache), 95);
  });

  test('sin cache usa TrackTags y luego el nombre', () {
    TrackTags.rememberBpm('$dir/Tito - Dos.mp3', 101);
    expect(displayBpmFor('$dir/Tito - Dos.mp3', <String, double>{}), 101);
    expect(displayBpmFor('$dir/Otro (128 BPM).mp3', <String, double>{}), 128);
    expect(displayBpmFor('$dir/Nada.mp3', <String, double>{}), 0);
  });

  test('lrcAudioCore quita (N BPM) y _K', () {
    expect(
      lrcAudioCore('$dir/Cancion (110 BPM)'),
      lrcAudioCore('$dir/Cancion'),
    );
    expect(lrcAudioCore('$dir/Cancion_K'), lrcAudioCore('$dir/cancion'));
    expect(
      lrcAudioCore('$dir/Cancion (95.5 BPM)_K'),
      lrcAudioCore('$dir/Cancion'),
    );
    expect(lrcAudioCore('$dir/Otra'), isNot(lrcAudioCore('$dir/Cancion')));
  });

  // 3.1.44: Live DJ resuelve con el `.gatomix.json` de su propia carpeta
  // aunque la cache de Automix apunte a otra ruta. Todo en %TEMP%.
  test('cache propia de Live DJ desde su carpeta, no la de Automix', () {
    final Directory live = Directory.systemTemp.createTempSync('gmx3144_l');
    final Directory auto = Directory.systemTemp.createTempSync('gmx3144_a');
    addTearDown(() {
      for (final Directory d in <Directory>[live, auto]) {
        try {
          d.deleteSync(recursive: true);
        } catch (_) {}
      }
    });
    final String song =
        '${live.path}${Platform.pathSeparator}Cantante - Tema.mp3';
    File(song).writeAsBytesSync(<int>[0, 1]);
    writeDjMetadata(live.path, <String, dynamic>{song: 110.0});
    writeDjMetadata(auto.path, <String, dynamic>{'otra.mp3': 90.0});
    final Map<String, double> automix = folderBpmCache(<String>[auto.path]);
    expect(displayBpmFor(song, automix), 0);
    final Map<String, double> liveDj = folderBpmCache(<String>[
      live.path,
      ...bpmDirsKey(<String?>[song, null]).split('\n'),
    ]);
    expect(displayBpmFor(song, liveDj), 110);
    expect(
      bpmMapFromMetadata(<String, dynamic>{
        'a': 100,
        'b': <String, dynamic>{'bpm': 120.5, 'key': '8A'},
      }),
      <String, double>{'a': 100, 'b': 120.5},
    );
  });

  test('pista en deck: BPM del perfil de frases en memoria', () {
    final Directory d = Directory.systemTemp.createTempSync('gmx3144_g');
    addTearDown(() {
      try {
        d.deleteSync(recursive: true);
      } catch (_) {}
    });
    final String song = '${d.path}${Platform.pathSeparator}Deck - Uno.mp3';
    PhraseGridMemory.save(
      song,
      const PhraseTrack(
        bpm: 96,
        beatMs: 625,
        durationMs: 200000,
        outroMs: 180000,
        introEndMs: 10000,
        bodyRms: 0.2,
        phrases: <PhrasePhrase>[],
      ),
    );
    expect(displayBpmFor(song, <String, double>{}), 96);
  });
}

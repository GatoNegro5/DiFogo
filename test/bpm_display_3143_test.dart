import 'package:flutter_test/flutter_test.dart';
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
}

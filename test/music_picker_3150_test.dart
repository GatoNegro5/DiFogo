import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/ui/mobile/music_picker_screen.dart';

// 3.1.50: partes de la fila del picker (badge BPM, artista, titulo).
void main() {
  test('Cantante (128) - Cancion: BPM, artista y titulo', () {
    final r = musicPickerRowParts('Cantante (128) - Cancion');
    expect(r.bpm, 128);
    expect(r.artist, 'Cantante');
    expect(r.title, 'Cancion');
  });

  test('sin guion: titulo completo, BPM al final', () {
    final r = musicPickerRowParts('Tema Libre (95)');
    expect(r.bpm, 95);
    expect(r.artist, '');
    expect(r.title, 'Tema Libre');
  });

  test('sin BPM ni guion: el titulo queda igual', () {
    final r = musicPickerRowParts('Pista Alfa');
    expect(r.bpm, isNull);
    expect(r.artist, '');
    expect(r.title, 'Pista Alfa');
  });

  test('parentesis que no es BPM se conserva', () {
    final r = musicPickerRowParts('Grupo - Tema (En Vivo)');
    expect(r.bpm, isNull);
    expect(r.artist, 'Grupo');
    expect(r.title, 'Tema (En Vivo)');
  });
}

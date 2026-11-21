import 'dart:io';

import 'package:difogo/core/library_guard.dart';
import 'package:difogo/core/safe_media_path.dart';
import 'package:difogo/ui/workspaces/karaoke_workspace.dart'
    show karaokeLrcFile, resolveKaraokeAudio;
import 'package:flutter_test/flutter_test.dart';

// 3.2.24: Karaoke lee el .lrc con la cascada de lrcReadFile y los servidores
// TV/LAN solo entregan audio o .lrc dentro de raices autorizadas. Todo en
// una carpeta de %TEMP%; nunca la biblioteca ni el %LOCALAPPDATA% reales.

final String _s = Platform.pathSeparator;

void main() {
  late Directory tmp;
  late String lib;
  late String cache;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gmx_3224_');
    lib = '${tmp.path}${_s}Music';
    cache = '${tmp.path}${_s}cache';
    Directory('$lib${_s}ReGenial${_s}Fiesta').createSync(recursive: true);
    Directory(cache).createSync(recursive: true);
    debugLibraryRoots = <String>[lib];
    debugLibraryCacheRoot = cache;
    debugLegacyLibraryCacheRoot = null;
  });

  tearDown(() async {
    debugLibraryRoots = null;
    debugLibraryCacheRoot = null;
    debugLegacyLibraryCacheRoot = null;
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('3.2.24 letra de Karaoke', () {
    test('encuentra el .lrc del espejo aunque no exista junto al mp3', () {
      final String audio = '$lib${_s}ReGenial${_s}Fiesta${_s}Tema.mp3';
      File(audio).writeAsBytesSync(<int>[1, 2, 3]);
      final File mirror = libraryLrcMirror(audio);
      mirror.parent.createSync(recursive: true);
      mirror.writeAsStringSync('[00:01.00]hola');
      expect(
        File('$lib${_s}ReGenial${_s}Fiesta${_s}Tema.lrc').existsSync(),
        isFalse,
      );
      final File got = karaokeLrcFile(audio);
      expect(got.path, mirror.path);
      expect(got.readAsStringSync(), '[00:01.00]hola');
      expect(got.path.startsWith(cache), isTrue);
    });

    test('sin espejo cae al .lrc junto al mp3', () {
      final String audio = '$lib${_s}ReGenial${_s}Fiesta${_s}Otro.MP3';
      final File got = karaokeLrcFile(audio);
      expect(got.path, '$lib${_s}ReGenial${_s}Fiesta${_s}Otro.lrc');
    });

    test('_K vs original async con las reglas de siempre', () async {
      final String src = '${tmp.path}${_s}Libre.mp3';
      final String k = '${tmp.path}${_s}Libre_K.mp3';
      File(src).writeAsBytesSync(List<int>.filled(400 * 1024, 1));
      expect(await resolveKaraokeAudio(src), src);
      File(k).writeAsBytesSync(List<int>.filled(100 * 1024, 1));
      expect(await resolveKaraokeAudio(src), src);
      File(k).writeAsBytesSync(List<int>.filled(300 * 1024, 1));
      expect(await resolveKaraokeAudio(src), k);
      File(src).writeAsBytesSync(List<int>.filled(1000 * 1024, 1));
      expect(await resolveKaraokeAudio(src), src);
    });
  });

  group('3.2.24 validador de rutas TV/LAN', () {
    List<String> roots() => <String>[lib, cache];

    test('acepta audio y .lrc dentro de la biblioteca y del espejo', () {
      expect(
        isSafeMediaPath(
          '$lib${_s}ReGenial${_s}Fiesta${_s}a.mp3',
          roots: roots(),
        ),
        isTrue,
      );
      expect(
        isSafeMediaPath('$lib${_s}ReGenial${_s}a.lrc', roots: roots()),
        isTrue,
      );
      expect(
        isSafeMediaPath('$cache${_s}lyrics${_s}abc${_s}a.lrc', roots: roots()),
        isTrue,
      );
      for (final String e in <String>['wav', 'flac', 'm4a', 'aac', 'ogg']) {
        expect(
          isSafeMediaPath('$lib${_s}x.$e', roots: roots()),
          isTrue,
          reason: e,
        );
      }
      // Raices por defecto: biblioteca y espejo (overrides de prueba).
      expect(isSafeMediaPath('$lib${_s}ReGenial${_s}b.mp3'), isTrue);
      expect(isSafeMediaPath('$cache${_s}lyrics${_s}b.lrc'), isTrue);
      if (Platform.isWindows) {
        expect(
          isSafeMediaPath('${lib.toUpperCase()}${_s}C.MP3', roots: roots()),
          isTrue,
        );
      }
    });

    test('rechaza fuera de raiz, ../, prefijo hermano y relativas', () {
      final List<String> bad = <String>[
        '${tmp.path}${_s}fuera${_s}a.mp3',
        '$lib$_s..${_s}fuera${_s}a.mp3',
        '$lib${_s}ReGenial$_s..$_s..${_s}a.mp3',
        '$lib/../a.lrc',
        '${lib}2${_s}a.mp3',
        '${cache}_x${_s}a.lrc',
        'ReGenial${_s}a.mp3',
        '..${_s}a.mp3',
        r'\\servidor\share\a.mp3',
        '',
        '$lib${_s}a.mp3\u0000.txt',
      ];
      for (final String p in bad) {
        expect(isSafeMediaPath(p, roots: roots()), isFalse, reason: p);
      }
    });

    test('rechaza extensiones no permitidas', () {
      for (final String e in <String>[
        'txt',
        'exe',
        'json',
        'dart',
        'lrc.exe',
      ]) {
        expect(
          isSafeMediaPath('$lib${_s}ReGenial${_s}a.$e', roots: roots()),
          isFalse,
          reason: e,
        );
      }
      expect(
        isSafeMediaPath('$lib${_s}ReGenial${_s}mp3', roots: roots()),
        isFalse,
      );
      // La cola del Karaoke solo acepta audio.
      expect(
        isSafeMediaPath(
          '$lib${_s}a.lrc',
          roots: roots(),
          allowedExts: kSafeMediaAudioExts,
        ),
        isFalse,
      );
    });

    test('prefijo con separador final', () {
      expect(isUnderRoot('c:/music2/a.mp3', 'c:/music'), isFalse);
      expect(isUnderRoot('c:/music/a.mp3', 'c:/music'), isTrue);
      expect(isUnderRoot('c:/music', 'c:/music'), isFalse);
    });
  });
}

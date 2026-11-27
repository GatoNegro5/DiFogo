// 3.2.34 (DIF-32): router de carpetas de ReGenial. Arbol sintetico en
// %TEMP% (nunca el ReGenial real) y genero externo falso (sin red).
import 'dart:io';

import 'package:difogo/core/folder_router.dart';
import 'package:difogo/core/library_guard.dart';
import 'package:flutter_test/flutter_test.dart';

final String _s = Platform.pathSeparator;

void main() {
  late Directory tmp;
  late String root;

  void song(String rel, String name, [String body = 'mp3']) {
    File('$root$_s$rel$_s$name')
      ..createSync(recursive: true)
      ..writeAsStringSync(body);
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('gmx_router_3234_');
    root = '${tmp.path}${_s}Music${_s}ReGenial';
    song('Salsa', 'Marc Anthony - Vivir Mi Vida.mp3');
    song('Salsa', 'Marc Anthony - Valio La Pena.mp3');
    song('Salsa', 'Marc Anthony - Valio La Pena_K.mp3');
    song('Salsa', 'Grupo Niche - Cali Pachanguero.mp3');
    song('Salsa', 'Joe Arroyo - La Rebelion.mp3');
    song('Salsa', 'Hector Lavoe - El Cantante.mp3');
    song('Actualidad Espanol${_s}Salsa', 'Marc Anthony - Ahora Quien.mp3');
    song('Baladas Espanol', 'Camilo Sesto - Perdoname.mp3');
    song('Baladas Espanol', 'Camilo Sesto, Isabel Pantoja - Amor.mp3');
    song('80s Ingles${_s}Rock', 'Toto - Africa.mp3');
    song('80s Ingles${_s}Rock', 'Toto - Rosanna.mp3');
    song('80s Ingles${_s}Rock', 'Journey - Separate Ways.mp3');
    debugRegenialRoot = root;
    debugLibraryCacheRoot = '${tmp.path}${_s}cache';
    debugArtistGenreLookup = (String a, String t) async => null;
    debugPlaceDurationProbe = (String p) async => 1000;
    folderRouteSuggestion.value = null;
  });

  tearDown(() {
    debugRegenialRoot = null;
    debugLibraryCacheRoot = null;
    debugArtistGenreLookup = null;
    debugPlaceDurationProbe = null;
    forgetLibraryIndex();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('artistas del nombre: ft., coma, &, x y +; sin " - " no hay', () {
    expect(routerArtistsOf('Karol G ft. Maluma - Creeme'), <String>[
      'karol g',
      'maluma',
    ]);
    expect(
      routerArtistsOf('Beele, Farruko & Feid x Bad Bunny - Tema'),
      <String>['beele', 'farruko', 'feid', 'bad bunny'],
    );
    expect(routerArtistsOf('Daddy Yankee + Diljit - Pokito'), hasLength(2));
    expect(routerArtistsOf('Llore'), isEmpty);
  });

  test(
    'indice: solo nombres, ignora _K, carpeta casi vacia va a su gemela',
    () {
      final LibraryIndex i = LibraryIndex.build(root);
      expect(i.folderCount['Salsa'], 5);
      expect(i.twin['Actualidad Espanol${_s}Salsa'], 'Salsa');
      expect(i.artistFolders['marc anthony'], <String, int>{'Salsa': 3});
      expect(i.artistFolders['isabel pantoja'], <String, int>{
        'Baladas Espanol': 1,
      });
    },
  );

  test('artista conocido: su carpeta con confianza alta', () async {
    final LibraryIndex i = LibraryIndex.build(root);
    final RouteDecision d = await decideFolder(
      nameOrPath: 'C:${_s}x${_s}Marc Anthony - Nueva.mp3',
      index: i,
    );
    expect(d.rel, 'Salsa');
    expect(d.confident, isTrue);
    final RouteDecision t = await decideFolder(
      nameOrPath: 'Toto - Hold The Line.mp3',
      index: i,
    );
    expect(t.rel, '80s Ingles${_s}Rock');
  });

  test('desconocido: Por clasificar; el genero externo solo sugiere', () async {
    final LibraryIndex i = LibraryIndex.build(root);
    final RouteDecision d = await decideFolder(
      nameOrPath: 'Zzqx Banda - Tema Raro.mp3',
      index: i,
    );
    expect(d.rel, kPorClasificar);
    expect(d.confident, isFalse);
    debugArtistGenreLookup = (String a, String t) async =>
        const ExternalGenre('Salsa', 2001);
    final RouteDecision e = await decideFolder(
      nameOrPath: 'Zzqx Banda - Tema Raro.mp3',
      index: i,
    );
    // El externo solo sugiere (acierta poco contra las carpetas reales).
    expect(e.rel, kPorClasificar);
    expect(e.suggestion, 'Salsa');
    // DESCUBRE: estacion conocida a la carpeta real.
    final RouteDecision s = await decideFolder(
      nameOrPath: 'Otro Grupo - Otro.mp3',
      index: i,
      stationId: 'tropical',
      subGenreId: 'Salsa',
      external: false,
    );
    expect(s.rel, 'Salsa');
  });

  test('nombre repetido: no pisa, queda (2) y el existente intacto', () async {
    song('Salsa', 'Marc Anthony - Nueva.mp3', 'VIEJO');
    final String src = '${tmp.path}${_s}stage${_s}Marc Anthony - Nueva.mp3';
    File(src)
      ..createSync(recursive: true)
      ..writeAsStringSync('NUEVO');
    final (PlaceResult r, RouteDecision d)? out = await routeIntoRegenial(src);
    expect(out, isNotNull);
    expect(out!.$2.rel, 'Salsa');
    expect(out.$1.path, '$root${_s}Salsa${_s}Marc Anthony - Nueva (2).mp3');
    expect(File(out.$1.path).readAsStringSync(), 'NUEVO');
    expect(
      File('$root${_s}Salsa${_s}Marc Anthony - Nueva.mp3').readAsStringSync(),
      'VIEJO',
    );
    expect(File(src).existsSync(), isFalse);
  });

  test('grupo completo (mp3, lrc, palabras, _K) se mueve junto y la cache '
      'de metadatos sigue a mp3 y _K', () async {
    final String stage = '${tmp.path}${_s}stage';
    final String src = '$stage${_s}Toto - Pamela.mp3';
    for (final String s in <String>[
      '.mp3',
      '.lrc',
      '.gmx_words.json',
      '_K.mp3',
    ]) {
      File('$stage${_s}Toto - Pamela$s')
        ..createSync(recursive: true)
        ..writeAsStringSync('x$s');
    }
    final List<String> re = <String>[];
    final (PlaceResult r, RouteDecision d)? out = await routeIntoRegenial(
      src,
      retarget: (String a, String b) async => re.add('$a>$b'),
    );
    final String dir = '$root${_s}80s Ingles${_s}Rock';
    expect(out!.$1.moved, hasLength(4));
    for (final String s in <String>[
      '.mp3',
      '.lrc',
      '.gmx_words.json',
      '_K.mp3',
    ]) {
      expect(File('$dir${_s}Toto - Pamela$s').readAsStringSync(), 'x$s');
      expect(File('$stage${_s}Toto - Pamela$s').existsSync(), isFalse);
    }
    expect(re, hasLength(2));
    expect(
      Directory(dir).listSync().where((e) => e.path.endsWith('.gmxplace')),
      isEmpty,
    );
  });

  test('vuelta atras: si la duracion no cuadra no queda nada y el origen '
      'sigue intacto', () async {
    final String stage = '${tmp.path}${_s}stage';
    final String src = '$stage${_s}Toto - Mala.mp3';
    File(src)
      ..createSync(recursive: true)
      ..writeAsStringSync('A');
    File('$stage${_s}Toto - Mala.lrc').writeAsStringSync('L');
    debugPlaceDurationProbe = (String p) async =>
        p.endsWith('.gmxplace') ? 9000 : 1000;
    await expectLater(
      placeTrackGroup(src: src, destDir: '$root${_s}Salsa'),
      throwsA(isA<StateError>()),
    );
    expect(File(src).readAsStringSync(), 'A');
    expect(File('$stage${_s}Toto - Mala.lrc').existsSync(), isTrue);
    expect(File('$root${_s}Salsa${_s}Toto - Mala.mp3').existsSync(), isFalse);
    expect(
      Directory(
        '$root${_s}Salsa',
      ).listSync().where((e) => e.path.endsWith('.gmxplace')),
      isEmpty,
    );
  });

  test(
    'reemplazo: el original va antes a Laboratorio/Cuarentena_MP3',
    () async {
      song('Salsa', 'Joe Arroyo - Tumbatecho.mp3', 'VIEJO');
      final String src = '${tmp.path}${_s}stage${_s}x.mp3';
      File(src)
        ..createSync(recursive: true)
        ..writeAsStringSync('NUEVO');
      final String q = quarantineFor(root, 'Salsa');
      expect(q, endsWith('Laboratorio${_s}Cuarentena_MP3${_s}Salsa'));
      final PlaceResult r = await placeTrackGroup(
        src: src,
        destDir: '$root${_s}Salsa',
        replace: '$root${_s}Salsa${_s}Joe Arroyo - Tumbatecho.mp3',
        quarantineDir: q,
      );
      expect(r.path, '$root${_s}Salsa${_s}Joe Arroyo - Tumbatecho.mp3');
      expect(File(r.path).readAsStringSync(), 'NUEVO');
      expect(
        File('$q${_s}Joe Arroyo - Tumbatecho.mp3').readAsStringSync(),
        'VIEJO',
      );
    },
  );

  test(
    'Por clasificar + toque en la sugerencia: mueve y fija el artista',
    () async {
      song('Salsa', 'Zzqx Banda - Uno.mp3');
      final String src = '${tmp.path}${_s}stage${_s}Zzqx Banda - Dos.mp3';
      File(src)
        ..createSync(recursive: true)
        ..writeAsStringSync('D');
      final (PlaceResult r, RouteDecision d)? out = await routeIntoRegenial(
        src,
      );
      expect(out!.$2.rel, kPorClasificar);
      expect(out.$1.path, startsWith('$root$_s$kPorClasificar$_s'));
      final RouteSuggestion? s = folderRouteSuggestion.value;
      expect(s, isNotNull);
      expect(s!.rel, 'Salsa');
      final String? moved = await acceptRouteSuggestion(s);
      expect(moved, '$root${_s}Salsa${_s}Zzqx Banda - Dos.mp3');
      expect(folderRouteSuggestion.value, isNull);
      forgetLibraryIndex();
      final RouteDecision again = await decideFolder(
        nameOrPath: 'Zzqx Banda - Tres.mp3',
        index: LibraryIndex.build(root),
      );
      expect(again.rel, 'Salsa');
      expect(again.reason, 'fijado');
    },
  );

  test('sin ReGenial: no coloca (respaldo de siempre)', () async {
    debugRegenialRoot = '${tmp.path}${_s}NoExiste';
    final String src = '${tmp.path}${_s}stage${_s}A - B.mp3';
    File(src)
      ..createSync(recursive: true)
      ..writeAsStringSync('x');
    expect(await routeIntoRegenial(src), isNull);
    expect(File(src).existsSync(), isTrue);
  });
}

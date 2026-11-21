import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/brand_paths.dart';
import 'package:difogo/core/gatomix_store.dart';
import 'package:difogo/core/library_guard.dart';

// 3.2.18: regreso de marca DiFogo -> GatoMix. Nombres principales GatoMix,
// migracion inversa solo si el destino GatoMix no existe, lectura con los
// dos nombres (gana el mas reciente) y library_guard siempre. Todo en
// carpetas sinteticas de %TEMP%: nada toca ReGenial ni el %LOCALAPPDATA% real.

final String _s = Platform.pathSeparator;

Map<String, String> _snap(String root) {
  final Map<String, String> out = <String, String>{};
  final Directory d = Directory(root);
  if (!d.existsSync()) return out;
  for (final FileSystemEntity e in d.listSync(recursive: true)) {
    out[e.path] = e is File ? e.readAsStringSync() : '<dir>';
  }
  return out;
}

File _doc(String path, Map<String, dynamic> body, DateTime at) {
  final File f = File(path)..createSync(recursive: true);
  f.writeAsStringSync(jsonEncode(<String, dynamic>{'schema': 1, ...body}));
  f.setLastModifiedSync(at);
  return f;
}

void main() {
  late Directory tmp;
  final DateTime t0 = DateTime(2025, 1, 1, 10);
  final DateTime t1 = DateTime(2026, 11, 1, 10);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('gmx_3218_');
  });

  tearDown(() {
    debugBrandCacheBases = null;
    debugBrandDataBase = null;
    debugLibraryRoots = null;
    debugLibraryCacheRoot = null;
    debugLegacyLibraryCacheRoot = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('3218 a) nombres principales GatoMix y heredados DiFogo', () {
    expect(kBrandDataName, 'GatoMix');
    expect(kOldBrandDataName, 'DiFogo');
    expect(kLabName, 'GatoMix_LAB');
    expect(kOldLabName, 'DiFogo_LAB');
    expect(kQuarantineName, 'Cuarentena_GatoMix');
    expect(kOldQuarantineName, 'Cuarentena_DiFogo');
    expect(kInboxName, 'GatoMix_Inbox');
    expect(kOldInboxName, 'DiFogo_Inbox');
    expect(kOriginalDirName, '.gatomix_original');
    expect(kOldOriginalDirName, '.difogo_original');
    expect(gatomixStoreName, '.gatomix.json');
    expect(gatomixOldStoreName, '.difogo.json');
    expect(kMirrorStoreSuffix, '.gatomix.json');
    expect(kOldMirrorStoreSuffix, '.difogo.json');
    // Ruta real del espejo (solo texto, sin E/S).
    final String real = libraryCacheRoot().replaceAll('\\', '/');
    expect(
      real,
      endsWith(Platform.isWindows ? 'GatoMix/folder_cache' : 'folder_cache'),
    );
    expect(real.contains('DiFogo'), isFalse);
  });

  test('3218 b) DiFogo -> GatoMix solo si GatoMix no existe; nunca borra', () {
    // 1) Solo DiFogo: se renombra con todo adentro.
    final String base = '${tmp.path}${_s}LocalAppData';
    final File sess = File('$base${_s}DiFogo${_s}difogo_genre_sessions.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"active":"salsa"}');
    debugBrandCacheBases = <String>[base];
    expect(migrateBrandCache(), <BrandMove>[BrandMove.renamed]);
    expect(sess.existsSync(), isFalse);
    expect(
      File(
        '$base${_s}GatoMix${_s}difogo_genre_sessions.json',
      ).readAsStringSync(),
      '{"active":"salsa"}',
    );
    expect(migrateBrandCache(), <BrandMove>[BrandMove.current]);

    // 2) GatoMix ya existe: no se migra y DiFogo queda intacta.
    final String b2 = '${tmp.path}${_s}B2';
    File('$b2${_s}GatoMix${_s}a.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('gato');
    File('$b2${_s}DiFogo${_s}b.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('fogo');
    final Map<String, String> before = _snap(b2);
    debugBrandCacheBases = <String>[b2];
    expect(migrateBrandCache(), <BrandMove>[BrandMove.both]);
    expect(_snap(b2), before);
    expect(ensureBrandDataDirMove(b2), BrandMove.both);
    expect(_snap(b2), before);

    // 3) Ninguna: nada que hacer, nada creado.
    final String b3 = '${tmp.path}${_s}B3';
    Directory(b3).createSync();
    debugBrandCacheBases = <String>[b3];
    expect(migrateBrandCache(), <BrandMove>[BrandMove.none]);
    expect(Directory(b3).listSync(), isEmpty);

    // ensureBrandDataDir con base de prueba: GatoMix.
    debugBrandDataBase = '${tmp.path}${_s}B4';
    expect(ensureBrandDataDir('C:\\no').path, endsWith('${_s}GatoMix'));
  });

  test('3218 c) LAB, Cuarentena e Inbox: library_guard manda (cero escritura '
      'en la biblioteca); fuera se renombra', () {
    final String music = '${tmp.path}${_s}Music';
    final String regenial = '$music${_s}ReGenial';
    Directory('$regenial${_s}Salsa').createSync(recursive: true);
    File('$regenial${_s}Salsa${_s}t.mp3').writeAsStringSync('mp3');
    Directory('$music${_s}DiFogo_LAB').createSync();
    Directory('$regenial${_s}Cuarentena_DiFogo').createSync();
    debugLibraryRoots = <String>[music];
    final Map<String, String> before = _snap(music);
    // Dentro de la biblioteca: se reusa la carpeta DiFogo, no se renombra.
    expect(labFolder(music), '$music${_s}DiFogo_LAB');
    expect(
      migrateBrandFolder(music, kOldLabName, kLabName),
      BrandMove.protected,
    );
    expect(quarantineDir(regenial).path, '$regenial${_s}Cuarentena_DiFogo');
    expect(
      brandFolderPath(regenial, kOldInboxName, kInboxName),
      '$regenial$_s$kInboxName',
    );
    expect(_snap(music), before);
    expect(Directory('$music${_s}GatoMix_LAB').existsSync(), isFalse);
    // Fuera de la biblioteca: DiFogo -> GatoMix.
    final String other = '${tmp.path}${_s}Otra';
    Directory('$other${_s}DiFogo_LAB').createSync(recursive: true);
    Directory('$other${_s}Cuarentena_DiFogo').createSync();
    Directory('$other${_s}DiFogo_Inbox').createSync();
    expect(labFolder(other), '$other${_s}GatoMix_LAB');
    expect(quarantineDir(other).path, '$other${_s}Cuarentena_GatoMix');
    expect(
      brandFolderPath(other, kOldInboxName, kInboxName),
      '$other${_s}GatoMix_Inbox',
    );
    expect(Directory('$other${_s}DiFogo_LAB').existsSync(), isFalse);
    // Con las dos fuera: manda GatoMix y DiFogo no se borra.
    Directory('$other${_s}DiFogo_LAB').createSync();
    expect(labFolder(other), '$other${_s}GatoMix_LAB');
    expect(Directory('$other${_s}DiFogo_LAB').existsSync(), isTrue);
    // Los dos nombres siguen fuera del blindaje y cuentan como LAB.
    for (final String f in <String>[
      'GatoMix_LAB',
      'DiFogo_LAB',
      'GatoMix_Inbox',
      'DiFogo_Inbox',
    ]) {
      expect(isLibraryPath('$music$_s$f${_s}a.mp3'), isFalse, reason: f);
      expect(pathIsLab('$music$_s$f${_s}a.mp3'), f.endsWith('_LAB'));
    }
  });

  test('3218 d) documento por carpeta: lee .gatomix.json y .difogo.json '
      '(gana el mas reciente) y escribe .gatomix.json', () {
    debugLibraryRoots = <String>['${tmp.path}${_s}NoEsBiblioteca'];
    final String dir = '${tmp.path}${_s}Lab';
    Directory(dir).createSync();
    // Solo el heredado .difogo.json: se lee.
    final File old = _doc(
      '$dir$_s.difogo.json',
      <String, dynamic>{
        'djMetadata': <String, dynamic>{'a.mp3': 101},
      },
      t1,
    );
    GatomixStore.forget(<String>[dir]);
    expect(GatomixStore.readFileOf(dir).path, old.path);
    // Un .gatomix.json viejo (antes de 3.1.81) no tapa al .difogo.json vigente.
    final File stale = _doc(
      '$dir$_s.gatomix.json',
      <String, dynamic>{
        'djMetadata': <String, dynamic>{'viejo.mp3': 1},
      },
      t0,
    );
    GatomixStore.forget(<String>[dir]);
    expect(GatomixStore.readFileOf(dir).path, old.path);
    expect(GatomixStore.readMap(dir, 'djMetadata').keys, contains('a.mp3'));
    // La escritura va a .gatomix.json con lo vigente; el heredado, intacto.
    final String oldText = old.readAsStringSync();
    GatomixStore.putSection(dir, 'probe3218', <String, int>{'v': 1});
    expect(stale.path, GatomixStore.fileOf(dir).path);
    final Map<String, dynamic> doc =
        jsonDecode(stale.readAsStringSync()) as Map<String, dynamic>;
    expect((doc['djMetadata'] as Map)['a.mp3'], 101);
    expect(doc['probe3218'], <String, dynamic>{'v': 1});
    expect(old.readAsStringSync(), oldText);
    GatomixStore.forget(<String>[dir]);
    expect(GatomixStore.readFileOf(dir).path, stale.path);
  });

  test('3218 e) espejo de la biblioteca: raiz GatoMix y heredada DiFogo, '
      'el mas reciente manda y la biblioteca queda intacta', () {
    final String music = '${tmp.path}${_s}Music';
    final String dir = '$music${_s}ReGenial${_s}Salsa';
    Directory(dir).createSync(recursive: true);
    File('$dir${_s}s.mp3').writeAsStringSync('mp3');
    final String neu = '${tmp.path}${_s}L${_s}GatoMix${_s}folder_cache';
    final String leg = '${tmp.path}${_s}L${_s}DiFogo${_s}folder_cache';
    debugLibraryRoots = <String>[music];
    debugLibraryCacheRoot = neu;
    debugLegacyLibraryCacheRoot = leg;
    final String key = libraryMirrorKey(dir);
    String read() {
      GatomixStore.forget(<String>[dir]);
      return GatomixStore.readFileOf(dir).path;
    }

    final Map<String, String> libBefore = _snap(music);
    // Tras el rename: el .gatomix.json de antes de 3.1.75 (viejo) y el
    // .difogo.json vigente conviven en GatoMix\folder_cache.
    final File stale = _doc(
      '$neu$_s$key.gatomix.json',
      <String, dynamic>{
        'djMetadata': <String, dynamic>{'p0': 0},
      },
      t0,
    );
    final File cur = _doc(
      '$neu$_s$key.difogo.json',
      <String, dynamic>{
        'djMetadata': <String, dynamic>{'p1': 1},
      },
      t1,
    );
    expect(read(), cur.path);
    expect(GatomixStore.readMap(dir, 'djMetadata').keys, contains('p1'));
    // Rename fallido: el espejo DiFogo mas nuevo tambien se lee.
    final File legacy = _doc(
      '$leg$_s$key.difogo.json',
      <String, dynamic>{
        'djMetadata': <String, dynamic>{'p2': 2},
      },
      t1.add(const Duration(days: 1)),
    );
    expect(read(), legacy.path);
    // Escritura: siempre <hash>.gatomix.json en GatoMix, nunca en ReGenial.
    final String legText = legacy.readAsStringSync();
    final String curText = cur.readAsStringSync();
    GatomixStore.forget(<String>[dir]);
    GatomixStore.putSection(dir, 'probe3218', <String, int>{'v': 2});
    expect(GatomixStore.fileOf(dir).path, stale.path);
    expect(read(), stale.path);
    expect(GatomixStore.readMap(dir, 'djMetadata').keys, contains('p2'));
    expect(GatomixStore.section(dir, 'probe3218'), <String, dynamic>{'v': 2});
    expect(legacy.readAsStringSync(), legText);
    expect(cur.readAsStringSync(), curText);
    expect(_snap(music), libBefore);
    expect(libraryWriteBlocked('$dir$_s.gatomix.json'), isTrue);
    expect(libraryWriteBlocked('$dir$_s.difogo.json'), isTrue);
  });

  test('3218 f) respaldos .gatomix_original con fallback .difogo_original', () {
    final String folder = '${tmp.path}${_s}Lab';
    final String mp3 = '$folder${_s}t.mp3';
    File(mp3)
      ..createSync(recursive: true)
      ..writeAsStringSync('live');
    expect(originalBackupOf(mp3), isNull);
    final File oldB = File('$folder$_s.difogo_original${_s}t.mp3')
      ..createSync(recursive: true);
    expect(originalBackupOf(mp3)!.path, oldB.path);
    expect(originalDirIn(folder), '$folder$_s.gatomix_original');
    final File newB = File('$folder$_s.gatomix_original${_s}t.mp3')
      ..createSync(recursive: true);
    expect(originalBackupOf(mp3)!.path, newB.path);
    expect(pathInOriginalDir('C:\\M\\.difogo_original\\a.mp3'), isTrue);
    expect(pathInOriginalDir('C:/M/.gatomix_original/a.mp3'), isTrue);
    expect(pathInOriginalDir('C:/M/Salsa/a.mp3'), isFalse);
    // newestFile: empate -> el primero; ninguno -> null.
    final File a = File('${tmp.path}${_s}a.json')..writeAsStringSync('a');
    final File b = File('${tmp.path}${_s}b.json')..writeAsStringSync('b');
    a.setLastModifiedSync(t1);
    b.setLastModifiedSync(t1);
    expect(newestFile(<File>[a, b])!.path, a.path);
    expect(newestFile(<File>[b, a])!.path, b.path);
    expect(newestFile(<File>[File('${tmp.path}${_s}no.json')]), isNull);
  });
}

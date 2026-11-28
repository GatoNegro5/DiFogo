import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/brand_paths.dart';
import 'package:difogo/core/gatomix_store.dart';
import 'package:difogo/core/lan_sync_plan.dart';
import 'package:difogo/core/library_guard.dart';

// 3.1.75 (rebrand fase 1; 3.2.18 invertida): migracion DiFogo -> GatoMix
// de datos y espejo,
// lectura en cascada y exclusiones. Todo en carpetas efimeras de %TEMP%:
// nada toca ReGenial ni el %LOCALAPPDATA% real.

final String _s = Platform.pathSeparator;

Map<String, String> _snap(String root) {
  final Map<String, String> out = <String, String>{};
  final Directory d = Directory(root);
  if (!d.existsSync()) return out;
  for (final FileSystemEntity e in d.listSync(recursive: true)) {
    if (e is File) out[e.path] = e.readAsStringSync();
  }
  return out;
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('gmx_3175_');
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

  test('3175 a) DiFogo -> GatoMix conserva el <hash>.difogo.json previo', () {
    final String base = '${tmp.path}${_s}LocalAppData';
    const String key = '0123456789abcdef';
    final File old = File(
      '$base${_s}DiFogo${_s}folder_cache$_s$key.difogo.json',
    )..createSync(recursive: true);
    old.writeAsStringSync('{"schema":1,"djMetadata":{"a.mp3":101.0}}');
    File('$base${_s}DiFogo${_s}artists${_s}x.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{}');
    debugBrandCacheBases = <String>[base];
    expect(migrateBrandCache(), <BrandMove>[BrandMove.renamed]);
    final File moved = File(
      '$base${_s}GatoMix${_s}folder_cache$_s$key.difogo.json',
    );
    expect(
      moved.readAsStringSync(),
      '{"schema":1,"djMetadata":{"a.mp3":101.0}}',
    );
    expect(
      File('$base${_s}GatoMix${_s}artists${_s}x.json').existsSync(),
      isTrue,
    );
    expect(Directory('$base${_s}DiFogo').existsSync(), isFalse);
    // Segunda vez: nada que hacer.
    expect(migrateBrandCache(), <BrandMove>[BrandMove.current]);
    // Las dos: la nueva manda, la vieja queda intacta para lectura.
    final File keep = File('$base${_s}DiFogo${_s}folder_cache${_s}k.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('x');
    expect(migrateBrandCache(), <BrandMove>[BrandMove.both]);
    expect(keep.readAsStringSync(), 'x');
    // Cadena de la marca anterior a 1.0.0: solo si no hay DiFogo ni GatoMix.
    final String b2 = '${tmp.path}${_s}B2';
    Directory(
      '$b2$_s$legacyBrand${_s}folder_cache',
    ).createSync(recursive: true);
    expect(ensureBrandDataDirMove(b2), BrandMove.renamed);
    expect(Directory('$b2${_s}GatoMix${_s}folder_cache').existsSync(), isTrue);
    // ensureBrandDataDir con base de prueba crea GatoMix.
    debugBrandDataBase = '${tmp.path}${_s}B3';
    expect(ensureBrandDataDir('C:\\no').path, endsWith('${_s}GatoMix'));
    expect(Directory('${tmp.path}${_s}B3${_s}GatoMix').existsSync(), isTrue);
    // Rename bloqueado por el SO (archivo abierto en Windows): no revienta
    // y la carpeta vieja queda como lectura.
    if (Platform.isWindows) {
      final String b4 = '${tmp.path}${_s}B4';
      final File lockFile = File('$b4${_s}DiFogo${_s}lock.bin')
        ..createSync(recursive: true);
      final RandomAccessFile h = lockFile.openSync(mode: FileMode.append);
      try {
        expect(
          migrateBrandFolder(b4, 'DiFogo', 'GatoMix'),
          anyOf(BrandMove.failed, BrandMove.renamed),
        );
      } finally {
        h.closeSync();
      }
    }
  });

  test('3175 a) LAB, Cuarentena e Inbox: renombra fuera de la biblioteca y '
      'no toca nada dentro', () {
    final String music = '${tmp.path}${_s}Music';
    final String lab = '$music${_s}DiFogo_LAB';
    Directory(lab).createSync(recursive: true);
    File('$lab${_s}a.mp3').writeAsStringSync('a');
    debugLibraryRoots = <String>[music];
    final Map<String, String> before = _snap(music);
    // Dentro de la biblioteca protegida: se sigue usando DiFogo_LAB.
    expect(labFolder(music), lab);
    expect(
      migrateBrandFolder(music, kOldLabName, kLabName),
      BrandMove.protected,
    );
    expect(_snap(music), before);
    expect(Directory('$music${_s}GatoMix_LAB').existsSync(), isFalse);
    // Fuera: DiFogo_LAB -> GatoMix_LAB.
    final String other = '${tmp.path}${_s}Otra';
    Directory('$other${_s}DiFogo_LAB').createSync(recursive: true);
    expect(labFolder(other), '$other${_s}GatoMix_LAB');
    expect(Directory('$other${_s}GatoMix_LAB').existsSync(), isTrue);
    expect(labFolder('${tmp.path}${_s}Nueva'), endsWith('GatoMix_LAB'));
    expect(pathIsLab('C:\\Music\\GatoMix_LAB\\a.mp3'), isTrue);
    expect(pathIsLab('C:\\Music\\DiFogo_LAB\\a.mp3'), isTrue);
    expect(pathIsLab('C:\\Music\\Cumbias\\a.mp3'), isFalse);
    // Cuarentena fuera de la biblioteca.
    final String q = '${tmp.path}${_s}Q';
    Directory('$q${_s}Cuarentena_DiFogo').createSync(recursive: true);
    expect(quarantineDir(q).path, '$q${_s}Cuarentena_GatoMix');
    // Bandeja: DiFogo_Inbox -> GatoMix_Inbox.
    final String dl = '${tmp.path}${_s}Downloads';
    Directory('$dl${_s}DiFogo_Inbox').createSync(recursive: true);
    expect(
      brandFolderPath(dl, kOldInboxName, kInboxName),
      '$dl${_s}GatoMix_Inbox',
    );
    expect(Directory('$dl${_s}DiFogo_Inbox').existsSync(), isFalse);
  });

  test('3175 b) cascada .gatomix.json > .difogo.json heredado > raiz vieja > '
      'carpeta, y escritura nueva .gatomix.json', () {
    final String music = '${tmp.path}${_s}Music';
    final String dir = '$music${_s}Salsa';
    Directory(dir).createSync(recursive: true);
    File('$dir${_s}s.mp3').writeAsStringSync('mp3');
    final String neu = '${tmp.path}${_s}L${_s}GatoMix${_s}folder_cache';
    final String old = '${tmp.path}${_s}L${_s}DiFogo${_s}folder_cache';
    debugLibraryRoots = <String>[music];
    debugLibraryCacheRoot = neu;
    debugLegacyLibraryCacheRoot = old;
    final String key = libraryMirrorKey(dir);
    String read() {
      GatomixStore.forget(<String>[dir]);
      return GatomixStore.readFileOf(dir).path;
    }

    // 4) solo el .difogo.json viejo de la carpeta musical.
    final File inFolder = File('$dir$_s$gatomixOldStoreName')
      ..writeAsStringSync('{"schema":1,"djMetadata":{"p4":4.0}}');
    expect(read(), inFolder.path);
    expect(GatomixStore.hasDocument(dir), isTrue);
    // 3) espejo de DiFogo (rename fallido).
    final File f3 = File('$old$_s$key.difogo.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"schema":1,"djMetadata":{"p3":3.0}}');
    expect(read(), f3.path);
    // 2) .difogo.json heredado en GatoMix.
    final File f2 = File('$neu$_s$key.difogo.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"schema":1,"djMetadata":{"p2":2.0}}');
    expect(read(), f2.path);
    expect(GatomixStore.readMap(dir, 'djMetadata').keys, contains('p2'));
    // Escritura: siempre a <hash>.gatomix.json en GatoMix.
    final Map<String, String> libBefore = _snap(music);
    final String t3 = f3.readAsStringSync();
    final String t2 = f2.readAsStringSync();
    GatomixStore.forget(<String>[dir]);
    GatomixStore.putSection(dir, 'probe3175', <String, int>{'v': 1});
    final File f1 = File('$neu$_s$key$kMirrorStoreSuffix');
    expect(GatomixStore.fileOf(dir).path, f1.path);
    expect(f1.path, endsWith('.gatomix.json'));
    expect(f1.existsSync(), isTrue);
    // 1) el nuevo manda y conserva lo heredado.
    expect(read(), f1.path);
    expect(GatomixStore.readMap(dir, 'djMetadata').keys, contains('p2'));
    expect(GatomixStore.section(dir, 'probe3175'), <String, dynamic>{'v': 1});
    // Nada heredado se borro ni reescribio; la biblioteca, intacta.
    expect(f2.readAsStringSync(), t2);
    expect(f3.readAsStringSync(), t3);
    expect(_snap(music), libBefore);
    // Sin raiz vieja de prueba no hay paso 3 (nunca el LOCALAPPDATA real).
    debugLegacyLibraryCacheRoot = null;
    expect(legacyLibraryCacheRoot(), isNull);
    // Ruta real (solo texto, sin E/S): GatoMix\folder_cache.
    debugLibraryCacheRoot = null;
    final String real = libraryCacheRoot().replaceAll('\\', '/');
    expect(
      real,
      endsWith(Platform.isWindows ? 'GatoMix/folder_cache' : 'folder_cache'),
    );
    expect(real.contains('DiFogo'), isFalse);
  });

  test('3175 c) exclusiones gatomix_lab/gatomix_inbox y difogo_lab/'
      'difogo_inbox; respaldos .gatomix_original y .difogo_original', () {
    final String music = '${tmp.path}${_s}Music';
    debugLibraryRoots = <String>[music];
    for (final String f in <String>[
      'GatoMix_LAB',
      'DiFogo_LAB',
      'GatoMix_Inbox',
      'DiFogo_Inbox',
      'gatomix_lab',
      'difogo_inbox',
    ]) {
      expect(isLibraryPath('$music$_s$f${_s}a.mp3'), isFalse, reason: f);
      expect(libraryWriteBlocked('$music$_s$f${_s}a.mp3'), isFalse, reason: f);
      expect(lanIsHiddenDest('$f/x/a.mp3'), isTrue, reason: f);
      expect(lanIsHiddenDest('ROOT/$f'), isTrue, reason: f);
    }
    expect(isLibraryPath('$music${_s}Salsa${_s}a.mp3'), isTrue);
    expect(lanIsHiddenDest('Salsa/a.mp3'), isFalse);
    // Respaldos de Masterizar: los dos nombres se excluyen.
    expect(pathInOriginalDir('C:\\M\\.gatomix_original\\a.mp3'), isTrue);
    expect(pathInOriginalDir('C:/M/.difogo_original/a.mp3'), isTrue);
    expect(pathInOriginalDir('C:/M/.difogo_original'), isTrue);
    expect(pathInOriginalDir('C:/M/Salsa/a.mp3'), isFalse);
    final String folder = '${tmp.path}${_s}Lab';
    final String mp3 = '$folder${_s}t.mp3';
    File(mp3)
      ..createSync(recursive: true)
      ..writeAsStringSync('live');
    expect(originalBackupOf(mp3), isNull);
    final File oldB = File('$folder$_s$kOldOriginalDirName${_s}t.mp3')
      ..createSync(recursive: true);
    expect(originalBackupOf(mp3)!.path, oldB.path);
    final File newB = File('${originalDirIn(folder)}${_s}t.mp3')
      ..createSync(recursive: true);
    expect(originalBackupOf(mp3)!.path, newB.path);
    // 3.2.35: bitacora con nombre nuevo; el viejo se sigue leyendo/copiando.
    final String trace = File('lib/core/dj_trace.dart').readAsStringSync();
    expect(trace.contains('gatomix_livedj_trace.txt'), isTrue);
    expect(trace.contains('difogo_livedj_trace.txt'), isTrue);
  });
}

import 'dart:io';

import 'library_guard.dart' show isLibraryPath;

/// Nombre de la carpeta anterior a 1.0.0. Va partido a propósito: el nombre
/// viejo completo está solo en CHANGELOG.md.
const legacyBrand =
    'DJ'
    'Studio';

/// 3.1.75 (rebrand fase 1): carpetas de datos de la marca nueva y de la
/// anterior. Los datos viejos se migran o se leen, nunca se borran.
const String kBrandDataName = 'DiFogo';
const String kOldBrandDataName = 'GatoMix';
const String kLabName = 'DiFogo_LAB';
const String kOldLabName = 'GatoMix_LAB';
const String kQuarantineName = 'Cuarentena_DiFogo';
const String kOldQuarantineName = 'Cuarentena_GatoMix';
const String kInboxName = 'DiFogo_Inbox';
const String kOldInboxName = 'GatoMix_Inbox';

/// 3.1.75: respaldos de Masterizar. Los nuevos van a `.difogo_original`; los
/// viejos `.gatomix_original` se siguen leyendo y excluyendo.
const String kOriginalDirName = '.difogo_original';
const String kOldOriginalDirName = '.gatomix_original';

/// Resultado de mover una carpeta de marca vieja a la nueva.
enum BrandMove {
  /// No habia carpeta vieja: nada que hacer.
  none,

  /// Solo existia la nueva.
  current,

  /// La vieja se renombro a la nueva.
  renamed,

  /// Existen las dos: la nueva manda y la vieja queda como lectura.
  both,

  /// El rename fallo (bloqueo del SO): la vieja queda como lectura.
  failed,

  /// La carpeta vieja esta dentro de la biblioteca protegida: no se toca.
  protected,
}

/// Mueve `parent/oldName` a `parent/newName` una sola vez. Nunca lanza,
/// nunca borra y nunca renombra dentro de la biblioteca protegida (ahi se
/// sigue usando el nombre viejo si existe).
BrandMove migrateBrandFolder(String parent, String oldName, String newName) {
  try {
    final String sep = Platform.pathSeparator;
    final Directory next = Directory('$parent$sep$newName');
    final Directory old = Directory('$parent$sep$oldName');
    final bool hasNext = next.existsSync();
    final bool hasOld = old.existsSync();
    if (hasNext) return hasOld ? BrandMove.both : BrandMove.current;
    if (!hasOld) return BrandMove.none;
    if (isLibraryPath(parent) || isLibraryPath(old.path)) {
      return BrandMove.protected;
    }
    try {
      old.renameSync(next.path);
      return BrandMove.renamed;
    } catch (_) {
      return BrandMove.failed;
    }
  } catch (_) {
    return BrandMove.failed;
  }
}

/// Carpeta a usar entre la nueva y la vieja tras intentar la migracion:
/// la vieja solo si no se pudo (o no se debia) renombrar.
String brandFolderPath(String parent, String oldName, String newName) {
  final String sep = Platform.pathSeparator;
  final BrandMove m = migrateBrandFolder(parent, oldName, newName);
  if (m == BrandMove.failed || m == BrandMove.protected) {
    return '$parent$sep$oldName';
  }
  return '$parent$sep$newName';
}

/// Base de datos de la app por plataforma (`%LOCALAPPDATA%` en Windows).
String brandDataBase() {
  if (Platform.isWindows) {
    return Platform.environment['LOCALAPPDATA'] ??
        '${Platform.environment['USERPROFILE'] ?? 'C:'}\\AppData\\Local';
  }
  return Directory.systemTemp.path;
}

/// `%LOCALAPPDATA%\DiFogo` (y el equivalente en macOS/Linux). 3.1.75: si
/// existe la carpeta `GatoMix` y la nueva no, la renombra; si no se puede,
/// sigue con la nueva (el espejo lee la vieja en cascada). La carpeta de la
/// marca anterior a 1.0.0 se renombra a DiFogo solo si no hay ninguna.
Directory ensureBrandDataDir(String base) {
  final String root = brandSafeBase(base);
  final next = Directory('$root${Platform.pathSeparator}$kBrandDataName');
  ensureBrandDataDirMove(root);
  try {
    if (!next.existsSync()) next.createSync(recursive: true);
  } catch (_) {}
  return next;
}

/// Solo pruebas: bases donde migrar (nunca el %LOCALAPPDATA% real).
List<String>? debugBrandCacheBases;

/// Solo pruebas: base que reemplaza a la real en [ensureBrandDataDir].
String? debugBrandDataBase;

/// 3.1.75: bajo `flutter test` (FLUTTER_TEST=true) la carpeta de datos va a
/// una base temporal propia: ninguna prueba renombra ni crea nada en el
/// %LOCALAPPDATA% real (p. ej. la cache de artistas del panel Spotify).
String brandSafeBase(String base) {
  final String? o = debugBrandDataBase;
  if (o != null) return o;
  if (Platform.environment['FLUTTER_TEST'] == 'true') {
    return '${Directory.systemTemp.path}${Platform.pathSeparator}difogo_flutter_test';
  }
  return base;
}

/// 3.1.75: migracion de arranque (una vez, sincrona y barata: un rename).
/// Windows: `%LOCALAPPDATA%\GatoMix` -> `DiFogo`; macOS/Linux/iOS:
/// `~/.gatomix` -> `~/.difogo`; Android: temp `GatoMix` -> `DiFogo`.
/// Nunca lanza; si falla, las lecturas usan la carpeta vieja en cascada.
List<BrandMove> migrateBrandCache() {
  final List<BrandMove> out = <BrandMove>[];
  try {
    final List<String>? o = debugBrandCacheBases;
    if (o != null) {
      for (final String base in o) {
        out.add(migrateBrandFolder(base, kOldBrandDataName, kBrandDataName));
      }
      return out;
    }
    if (Platform.environment['FLUTTER_TEST'] == 'true') return out;
    if (Platform.isWindows || Platform.isAndroid) {
      out.add(ensureBrandDataDirMove(brandDataBase()));
      return out;
    }
    final String? home = Platform.environment['HOME'];
    if (home != null) out.add(migrateBrandFolder(home, '.gatomix', '.difogo'));
  } catch (_) {}
  return out;
}

/// Igual que [ensureBrandDataDir] pero devuelve que paso (arranque).
BrandMove ensureBrandDataDirMove(String base) {
  final BrandMove m = migrateBrandFolder(
    base,
    kOldBrandDataName,
    kBrandDataName,
  );
  if (m == BrandMove.none) {
    return migrateBrandFolder(base, legacyBrand, kBrandDataName);
  }
  return m;
}

/// True si [path] está dentro de la carpeta de laboratorio (nueva, de
/// GatoMix o de la marca anterior).
bool pathIsLab(String path) {
  final String legacy = '${legacyBrand}_LAB';
  for (final String part in path.replaceAll('\\', '/').split('/')) {
    if (part == kLabName || part == kOldLabName || part == legacy) return true;
  }
  return false;
}

/// Carpeta de laboratorio junto a [base]. 3.1.75: `GatoMix_LAB` pasa a
/// `DiFogo_LAB`; si [base] es la biblioteca protegida no se renombra nada y
/// se sigue usando la carpeta vieja que exista.
String labFolder(String base) {
  final sep = Platform.pathSeparator;
  final next = Directory('$base$sep$kLabName');
  if (next.existsSync()) return next.path;
  for (final String old in <String>[kOldLabName, '${legacyBrand}_LAB']) {
    if (Directory('$base$sep$old').existsSync()) {
      return brandFolderPath(base, old, kLabName);
    }
  }
  return next.path;
}

/// Cuarentena junto al archivo dañado. 3.1.75: `Cuarentena_GatoMix` pasa a
/// `Cuarentena_DiFogo` fuera de la biblioteca; dentro se reusa la vieja.
Directory quarantineDir(String parent) {
  final sep = Platform.pathSeparator;
  Directory next = Directory('$parent$sep$kQuarantineName');
  if (!next.existsSync()) {
    for (final String old in <String>[
      kOldQuarantineName,
      'Cuarentena_$legacyBrand',
    ]) {
      if (Directory('$parent$sep$old').existsSync()) {
        next = Directory(brandFolderPath(parent, old, kQuarantineName));
        break;
      }
    }
  }
  if (!next.existsSync()) next.createSync();
  return next;
}

/// 3.1.75: cierto si [path] esta dentro de un respaldo de Masterizar
/// (`.difogo_original` o el viejo `.gatomix_original`).
bool pathInOriginalDir(String path) {
  final String p = path.replaceAll('\\', '/').toLowerCase();
  for (final String n in <String>[kOriginalDirName, kOldOriginalDirName]) {
    if (p.contains('/$n/') || p.endsWith('/$n')) return true;
  }
  return false;
}

/// Carpeta de respaldo nueva junto a [folder].
String originalDirIn(String folder) =>
    '$folder${Platform.pathSeparator}$kOriginalDirName';

/// Respaldo existente de [mp3Path]: el nuevo, si no el viejo; null si no hay.
File? originalBackupOf(String mp3Path) {
  final File live = File(mp3Path);
  final String sep = Platform.pathSeparator;
  final String name = live.uri.pathSegments.last;
  for (final String n in <String>[kOriginalDirName, kOldOriginalDirName]) {
    final File f = File('${live.parent.path}$sep$n$sep$name');
    if (f.existsSync()) return f;
  }
  return null;
}

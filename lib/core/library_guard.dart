import 'dart:convert';
import 'dart:io';

/// 3.1.72: blindaje de solo lectura de la biblioteca musical.
///
/// La biblioteca (la carpeta de Musica del usuario, con ReGenial adentro) es
/// solo lectura para la app: ningun tag ID3, `.gatomix.json`, `.gatomix.log`
/// ni `LiveDj_Radio.json` se escribe dentro. Esos datos viven en un espejo
/// local (`%LOCALAPPDATA%\DiFogo\folder_cache\<hash>.difogo.json` en
/// Windows desde 3.1.75; antes `GatoMix\...\<hash>.gatomix.json`, que se
/// sigue leyendo en cascada) con una clave
/// estable por carpeta. Se siguen LEYENDO los `.gatomix.json` viejos de cada
/// carpeta, sin borrarlos ni reescribirlos.
///
/// Quedan fuera del blindaje las carpetas propias de la app dentro de
/// Musica: DjPlaylists (sesiones), DiFogo_LAB / GatoMix_LAB y DiFogo_Inbox /
/// GatoMix_Inbox (3.1.75: nombres nuevos y heredados). 3.2.10: DESCUBRE
/// (canciones nuevas de la Radio, fuera de ReGenial).

/// Solo pruebas: raices de biblioteca falsas (p. ej. en %TEMP%).
List<String>? debugLibraryRoots;

/// Solo pruebas: carpeta del espejo local.
String? debugLibraryCacheRoot;

/// Solo pruebas: carpeta del espejo de la marca anterior (GatoMix). Con
/// [debugLibraryCacheRoot] puesto y esta en null no hay paso 3 de la
/// cascada (las pruebas nunca leen el %LOCALAPPDATA% real).
String? debugLegacyLibraryCacheRoot;

/// 3.1.75: sufijo del documento por carpeta en el espejo (nuevo y heredado).
const String kMirrorStoreSuffix = '.difogo.json';
const String kOldMirrorStoreSuffix = '.gatomix.json';
const String kMirrorLogSuffix = '.difogo.log';

/// Escrituras bloqueadas en este proceso (diagnostico y pruebas).
int libraryGuardBlocked = 0;

/// Ultimas rutas bloqueadas (cola corta, diagnostico).
final List<String> libraryGuardLog = <String>[];

const Set<String> _appFolders = <String>{
  'djplaylists',
  'difogo_lab',
  'gatomix_lab',
  'djstudio_lab',
  'difogo_inbox',
  'gatomix_inbox',
  // 3.2.10: canciones nuevas de la Radio (Musica/DESCUBRE).
  'descubre',
  // Salida propia del descargador de YouTube (Musica\Descargas).
  'descargas',
};

String _norm(String p) {
  String s = p.replaceAll('\\', '/');
  while (s.length > 1 && s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return Platform.isWindows ? s.toLowerCase() : s;
}

/// Carpeta de Musica del sistema (igual que gatomixMusicRoot, sin UI).
String? _systemMusicRoot() {
  if (Platform.isIOS) return null;
  if (Platform.isWindows) {
    final String? up = Platform.environment['USERPROFILE'];
    return up == null ? null : '$up\\Music';
  }
  if (Platform.isAndroid) return '/storage/emulated/0/Music';
  final String? home = Platform.environment['HOME'];
  return home == null ? null : '$home/Music';
}

/// Raices protegidas (solo lectura).
List<String> libraryRoots() {
  final List<String>? o = debugLibraryRoots;
  if (o != null) return o;
  final String? m = _systemMusicRoot();
  return m == null ? const <String>[] : <String>[m];
}

/// Cierto si [path] (archivo o carpeta) esta dentro de la biblioteca
/// protegida y no en una carpeta propia de la app.
bool isLibraryPath(String path) {
  if (path.isEmpty) return false;
  final String p = _norm(path);
  for (final String root in libraryRoots()) {
    final String r = _norm(root);
    if (r.isEmpty) continue;
    if (p != r && !p.startsWith('$r/')) continue;
    final String rest = p.length > r.length ? p.substring(r.length + 1) : '';
    final List<String> parts = rest.split('/');
    final bool app = parts.any(
      (String s) => _appFolders.contains(s.toLowerCase()),
    );
    if (app) continue;
    return true;
  }
  return false;
}

/// Cierto (y lo anota) si la app NO debe escribir en [path]. Quien llama
/// salta la escritura.
bool libraryWriteBlocked(String path, {String what = ''}) {
  if (!isLibraryPath(path)) return false;
  libraryGuardBlocked++;
  libraryGuardLog.add(what.isEmpty ? path : '$what $path');
  if (libraryGuardLog.length > 50) libraryGuardLog.removeAt(0);
  return true;
}

/// Carpeta del espejo local de metadatos de la biblioteca.
String libraryCacheRoot() {
  final String? o = debugLibraryCacheRoot;
  if (o != null) return o;
  final String sep = Platform.pathSeparator;
  if (Platform.isWindows) {
    final String base =
        Platform.environment['LOCALAPPDATA'] ??
        '${Platform.environment['USERPROFILE'] ?? 'C:'}\\AppData\\Local';
    return '$base${sep}DiFogo${sep}folder_cache';
  }
  final String? home = Platform.environment['HOME'];
  if (home != null && !Platform.isAndroid) {
    return '$home$sep.difogo${sep}folder_cache';
  }
  return '${Directory.systemTemp.path}${sep}DiFogo${sep}folder_cache';
}

/// 3.1.75: espejo de la marca anterior (`%LOCALAPPDATA%\GatoMix\
/// folder_cache`, `~/.gatomix/folder_cache`, temp `GatoMix`). Solo se lee,
/// por si el rename de arranque no pudo hacerse. null en pruebas sin
/// [debugLegacyLibraryCacheRoot].
String? legacyLibraryCacheRoot() {
  final String? o = debugLegacyLibraryCacheRoot;
  if (o != null) return o;
  if (debugLibraryCacheRoot != null) return null;
  final String sep = Platform.pathSeparator;
  if (Platform.isWindows) {
    final String base =
        Platform.environment['LOCALAPPDATA'] ??
        '${Platform.environment['USERPROFILE'] ?? 'C:'}\\AppData\\Local';
    return '$base${sep}GatoMix${sep}folder_cache';
  }
  final String? home = Platform.environment['HOME'];
  if (home != null && !Platform.isAndroid) {
    return '$home$sep.gatomix${sep}folder_cache';
  }
  return '${Directory.systemTemp.path}${sep}GatoMix${sep}folder_cache';
}

/// 3.1.75: archivo espejo a LEER de [dir] en cascada, sin crear carpetas:
/// por cada raiz (nueva y luego la de GatoMix) prueba cada sufijo en orden
/// (p. ej. `.difogo.json` y luego `.gatomix.json`). null si no hay ninguno.
File? libraryMirrorRead(String dir, List<String> suffixes) {
  final String key = libraryMirrorKey(dir);
  final String sep = Platform.pathSeparator;
  for (final String? root in <String?>[
    libraryCacheRoot(),
    legacyLibraryCacheRoot(),
  ]) {
    if (root == null) continue;
    for (final String suffix in suffixes) {
      final File f = File('$root$sep$key$suffix');
      try {
        if (f.existsSync()) return f;
      } catch (_) {}
    }
  }
  return null;
}

/// Clave estable (FNV-1a 64) de una carpeta: igual en cada arranque.
String libraryMirrorKey(String dir) {
  final List<int> bytes = utf8.encode(_norm(dir));
  BigInt h = BigInt.parse('cbf29ce484222325', radix: 16);
  final BigInt prime = BigInt.parse('100000001b3', radix: 16);
  final BigInt mask = (BigInt.one << 64) - BigInt.one;
  for (final int b in bytes) {
    h = ((h ^ BigInt.from(b)) * prime) & mask;
  }
  return h.toRadixString(16).padLeft(16, '0');
}

/// Archivo espejo de [dir] con el sufijo [suffix] (p. ej. `.gatomix.json`).
/// Crea la carpeta del espejo si falta.
File libraryMirrorFile(String dir, String suffix) {
  final String root = libraryCacheRoot();
  try {
    Directory(root).createSync(recursive: true);
  } catch (_) {}
  return File('$root${Platform.pathSeparator}${libraryMirrorKey(dir)}$suffix');
}

/// 3.1.72: espejo local de la letra `.lrc` de [audioPath] cuando el audio
/// esta en la biblioteca protegida.
File libraryLrcMirror(String audioPath) {
  final String sep = Platform.pathSeparator;
  final String norm = audioPath.replaceAll('\\', '/');
  final int cut = norm.lastIndexOf('/');
  final String dir = cut < 0 ? '' : audioPath.substring(0, cut);
  String name = cut < 0 ? audioPath : audioPath.substring(cut + 1);
  final int dot = name.lastIndexOf('.');
  if (dot > 0) name = name.substring(0, dot);
  return File(
    '${libraryCacheRoot()}${sep}lyrics$sep${libraryMirrorKey(dir)}$sep$name.lrc',
  );
}

/// Letra a LEER: el espejo si existe (3.1.75: tambien el de GatoMix), si
/// no la `.lrc` junto al audio.
File lrcReadFile(String audioPath, String lrcPath) {
  if (!isLibraryPath(audioPath)) return File(lrcPath);
  final File m = libraryLrcMirror(audioPath);
  if (m.existsSync()) return m;
  final String? old = legacyLibraryCacheRoot();
  if (old != null) {
    final String root = libraryCacheRoot();
    final File o = File(old + m.path.substring(root.length));
    try {
      if (o.existsSync()) return o;
    } catch (_) {}
  }
  return File(lrcPath);
}

/// Letra a ESCRIBIR: en la biblioteca, el espejo (nunca junto al audio).
File lrcWriteFile(String audioPath, String lrcPath) {
  if (!libraryWriteBlocked(lrcPath, what: 'LRC')) return File(lrcPath);
  final File m = libraryLrcMirror(audioPath);
  try {
    m.parent.createSync(recursive: true);
  } catch (_) {}
  return m;
}

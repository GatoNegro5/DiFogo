import 'dart:io';

import 'library_guard.dart';

/// 3.2.24: validador de rutas que llegan por red (TV Sync :55056 y la cola
/// del Karaoke en LAN Sync :55055). Solo deja pasar audio o `.lrc` que este
/// estrictamente dentro de una raiz autorizada: la biblioteca y el espejo
/// local de letras (GatoMix y el heredado de la marca anterior).
/// Funciones puras salvo la lectura opcional de enlaces simbolicos.

/// Extensiones que el servidor puede entregar.
const Set<String> kSafeMediaAudioExts = <String>{
  '.mp3',
  '.wav',
  '.flac',
  '.m4a',
  '.aac',
  '.ogg',
};

/// Audio mas la letra.
const Set<String> kSafeMediaExts = <String>{...kSafeMediaAudioExts, '.lrc'};

/// Raices autorizadas: biblioteca, espejo nuevo, espejo heredado y [extra]
/// (p. ej. la carpeta de Musica de LAN Sync en iPhone).
List<String> safeMediaRoots({Iterable<String> extra = const <String>[]}) {
  final String? legacy = legacyLibraryCacheRoot();
  return <String>[...libraryRoots(), libraryCacheRoot(), ?legacy, ...extra];
}

bool get _win => Platform.isWindows;

/// Forma canonica comparable: separador `/`, sin `.` ni barras repetidas,
/// absoluta y en minusculas en Windows. null si la ruta trae `..`, un byte
/// nulo, es relativa o es UNC / de dispositivo.
String? canonicalMediaPath(String raw) {
  if (raw.isEmpty || raw.contains('\u0000')) return null;
  String s = raw.trim().replaceAll('\\', '/');
  if (s.startsWith('//')) return null;
  final bool drive = RegExp(r'^[A-Za-z]:/').hasMatch(s);
  if (_win) {
    if (!drive) return null;
  } else if (!s.startsWith('/')) {
    return null;
  }
  final List<String> out = <String>[];
  for (final String seg in s.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') return null;
    out.add(seg);
  }
  if (out.isEmpty) return null;
  s = _win ? out.join('/') : '/${out.join('/')}';
  return _win ? s.toLowerCase() : s;
}

/// Sigue enlaces simbolicos solo si la ruta existe; si no, la deja igual.
String _resolved(String raw) {
  try {
    if (FileSystemEntity.typeSync(raw, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return raw;
    }
    String r = File(raw).resolveSymbolicLinksSync();
    if (r.startsWith(r'\\?\')) r = r.substring(4);
    return r;
  } catch (_) {
    return raw;
  }
}

/// Extension en minusculas con el punto, o '' si no hay.
String mediaExtension(String path) {
  final String s = path.replaceAll('\\', '/');
  final String name = s.substring(s.lastIndexOf('/') + 1);
  final int dot = name.lastIndexOf('.');
  return dot <= 0 ? '' : name.substring(dot).toLowerCase();
}

/// Cierto si [candidate] (ya canonica) cuelga de [root] (ya canonica). Usa
/// el separador final: `C:/Music2` no esta dentro de `C:/Music`.
bool isUnderRoot(String candidate, String root) {
  if (root.isEmpty) return false;
  final String r = root.endsWith('/') ? root : '$root/';
  return candidate.startsWith(r) && candidate.length > r.length;
}

/// 3.2.24: cierto si [raw] puede leerse por red. Exige extension de
/// [allowedExts] y que la ruta canonica (y la real tras enlaces, si existe)
/// este dentro de alguna de [roots] (por defecto [safeMediaRoots]).
bool isSafeMediaPath(
  String raw, {
  Iterable<String>? roots,
  Set<String> allowedExts = kSafeMediaExts,
}) {
  final String? lexical = canonicalMediaPath(raw);
  if (lexical == null) return false;
  if (!allowedExts.contains(mediaExtension(lexical))) return false;
  final String? real = canonicalMediaPath(_resolved(raw));
  if (real == null) return false;
  if (!allowedExts.contains(mediaExtension(real))) return false;
  final List<String> canonRoots = <String>[
    for (final String root in roots ?? safeMediaRoots())
      for (final String form in <String>{root, _resolved(root)})
        if (canonicalMediaPath(form) case final String c) c,
  ];
  bool inside(String p) => canonRoots.any((String r) => isUnderRoot(p, r));
  return inside(lexical) && inside(real);
}

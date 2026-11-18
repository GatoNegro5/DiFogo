import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

/// 3.1.87: anti-duplicados de la Radio Descubrimiento.
///
/// Huella normalizada de cada cancion (artista y titulo sin extension, sin
/// etiquetas de BPM, anos, `official video/audio`, acentos ni puntuacion, y
/// sin importar el orden `Artista - Titulo` / `Titulo - Artista`). Un
/// `Set` en memoria con la biblioteca local y los descartes responde en
/// O(1) si un candidato ya lo tiene el usuario o ya lo descarto.

const Map<String, String> _fpAccents = <String, String>{
  'á': 'a',
  'à': 'a',
  'ä': 'a',
  'â': 'a',
  'ã': 'a',
  'é': 'e',
  'è': 'e',
  'ë': 'e',
  'ê': 'e',
  'í': 'i',
  'ì': 'i',
  'ï': 'i',
  'î': 'i',
  'ó': 'o',
  'ò': 'o',
  'ö': 'o',
  'ô': 'o',
  'õ': 'o',
  'ú': 'u',
  'ù': 'u',
  'ü': 'u',
  'û': 'u',
  'ñ': 'n',
  'ç': 'c',
};

final RegExp _fpExt = RegExp(
  r'\.(mp3|m4a|wav|webm|flac|ogg|aac|opus|mp4|lrc)$',
  caseSensitive: false,
);
final RegExp _fpKaraoke = RegExp(r'[_ ][kKrR]$');
final RegExp _fpBracket = RegExp(r'[\(\[\{]([^\)\]\}]*)[\)\]\}]');
final RegExp _fpBareNumber = RegExp(r'^\d{1,4}$');
final RegExp _fpBpm = RegExp(r'^\d{2,3}(?:[.,]\d+)?\s*bpm$');
final RegExp _fpCamelot = RegExp(r'^\d{1,2}\s*[ab]$');
final RegExp _fpJunkInside = RegExp(
  r'official|oficial|audio|video|lyric|letra|visuali[sz]er|\bhd\b|\bhq\b|\b4k\b|remaster|topic|videoclip',
);
final RegExp _fpJunkOutside = RegExp(
  r'\b(?:(?:official|oficial)\s+(?:music\s+)?(?:video|audio)|(?:video|audio)\s+oficial|lyric\s+video|con\s+letras?|lyrics?|videoclip|\d{2,3}\s*bpm|hd|hq|4k)\b',
);
final RegExp _fpLeadBpm = RegExp(r'^\s*\d{2,3}\s*(?:bpm)?\s*-\s*');
final RegExp _fpLeadCamelot = RegExp(r'^\s*\d{1,2}\s*[ab]\s*-\s*');
final RegExp _fpNonWord = RegExp(r'[^a-z0-9]+');
final RegExp _fpYear = RegExp(r'^(?:19|20)\d\d$');

String _fpFold(String s) {
  String t = s.toLowerCase();
  if (t.contains(RegExp(r'[^\x00-\x7f]'))) {
    final StringBuffer b = StringBuffer();
    for (final int r in t.runes) {
      final String ch = String.fromCharCode(r);
      b.write(_fpAccents[ch] ?? ch);
    }
    t = b.toString();
  }
  return t;
}

/// Huella de una cancion para comparar sin importar el formato del nombre.
/// Usa [artist] y [title] si alguno viene; si no, [filename] (con o sin
/// carpeta y extension). Vacia si no queda nada que comparar.
String normalizeTrackFingerprint({
  String artist = '',
  String title = '',
  String filename = '',
}) {
  String raw;
  if (artist.trim().isNotEmpty || title.trim().isNotEmpty) {
    raw = '${artist.trim()} - ${title.trim()}';
  } else {
    raw = filename.replaceAll('\\', '/');
    final int slash = raw.lastIndexOf('/');
    if (slash >= 0) raw = raw.substring(slash + 1);
  }
  String s = raw.trim();
  while (_fpExt.hasMatch(s)) {
    s = s.replaceFirst(_fpExt, '');
  }
  s = s.replaceFirst(_fpKaraoke, '');
  s = _fpFold(s);
  s = s.replaceFirst(_fpLeadBpm, '');
  s = s.replaceFirst(_fpLeadCamelot, '');
  s = s.replaceAllMapped(_fpBracket, (Match m) {
    final String inner = (m.group(1) ?? '').trim();
    if (inner.isEmpty ||
        _fpBareNumber.hasMatch(inner) ||
        _fpBpm.hasMatch(inner) ||
        _fpCamelot.hasMatch(inner) ||
        _fpJunkInside.hasMatch(inner)) {
      return ' ';
    }
    return ' $inner ';
  });
  s = s.replaceAll(_fpJunkOutside, ' ');
  final List<String> words = <String>[
    for (final String w in s.split(_fpNonWord))
      if (w.isNotEmpty && !_fpYear.hasMatch(w)) w,
  ]..sort();
  return words.join(' ');
}

/// Huellas de [paths] (por nombre de archivo). Listas grandes van a un
/// isolate: el hilo de la UI no hace este trabajo.
Future<Set<String>> trackFingerprintsAsync(List<String> paths) {
  if (paths.length <= 256) return Future<Set<String>>.value(_fingerprints(paths));
  return Isolate.run(() => _fingerprints(paths));
}

Set<String> _fingerprints(List<String> paths) {
  final Set<String> out = <String>{};
  for (final String p in paths) {
    final String f = normalizeTrackFingerprint(filename: p);
    if (f.isNotEmpty) out.add(f);
  }
  return out;
}

const Set<String> _audioExt = <String>{
  '.mp3',
  '.m4a',
  '.wav',
  '.webm',
  '.flac',
  '.ogg',
  '.aac',
  '.opus',
};

/// Audio bajo [roots] con listado async (sin I/O sincrono en la UI).
/// Solo lectura: nunca escribe en la biblioteca.
Future<List<String>> listLibraryAudioAsync(Iterable<String> roots) async {
  final List<String> out = <String>[];
  for (final String root in roots) {
    if (root.isEmpty) continue;
    final Directory d = Directory(root);
    try {
      if (!await d.exists()) continue;
      await for (final FileSystemEntity f in d.list(
        recursive: true,
        followLinks: false,
      )) {
        if (f is! File) continue;
        final String lower = f.path.toLowerCase();
        final int dot = lower.lastIndexOf('.');
        if (dot < 0 || !_audioExt.contains(lower.substring(dot))) continue;
        out.add(f.path);
      }
    } catch (_) {}
  }
  return out;
}

class DiscoveryDedupController {
  DiscoveryDedupController({this.discardPath});

  /// JSON con las huellas descartadas (null: solo en memoria).
  final String? discardPath;

  final Set<String> _library = <String>{};
  final Set<String> _discarded = <String>{};
  Future<void>? _libraryLoad;
  Future<void>? _discardLoad;
  Future<void> _write = Future<void>.value();
  bool _libraryReady = false;

  bool get libraryReady => _libraryReady;
  int get librarySize => _library.length;
  int get discardedSize => _discarded.length;

  /// O(1): la huella ya esta en la biblioteca o se descarto.
  bool isBlocked(String fingerprint) =>
      fingerprint.isNotEmpty &&
      (_library.contains(fingerprint) || _discarded.contains(fingerprint));

  bool isDiscarded(String fingerprint) => _discarded.contains(fingerprint);

  bool blocksCandidate({
    String artist = '',
    String title = '',
    String filename = '',
  }) => isBlocked(
    normalizeTrackFingerprint(artist: artist, title: title, filename: filename),
  );

  void addLibraryPath(String path) {
    final String f = normalizeTrackFingerprint(filename: path);
    if (f.isNotEmpty) _library.add(f);
  }

  Future<void> addLibraryPaths(List<String> paths) async {
    _library.addAll(await trackFingerprintsAsync(paths));
  }

  /// Arma una sola vez el indice de la biblioteca con [loader] (listado
  /// async) y carga los descartes guardados.
  Future<void> ensureLibrary(Future<List<String>> Function() loader) {
    return _libraryLoad ??= () async {
      try {
        await addLibraryPaths(await loader());
      } catch (_) {}
      await loadDiscards();
      _libraryReady = true;
    }();
  }

  Future<void> loadDiscards() {
    return _discardLoad ??= () async {
      final String? p = discardPath;
      if (p == null) return;
      try {
        final File f = File(p);
        if (!await f.exists()) return;
        final Object? raw = jsonDecode(await f.readAsString());
        final Object? list = raw is Map ? raw['discarded'] : raw;
        if (list is List) {
          for (final Object? e in list) {
            if (e is String && e.isNotEmpty) _discarded.add(e);
          }
        }
      } catch (_) {}
    }();
  }

  /// Descarta la cancion: su huella queda bloqueada y se guarda en disco.
  Future<bool> discard({
    String artist = '',
    String title = '',
    String filename = '',
  }) async {
    final Set<String> fps = <String>{
      normalizeTrackFingerprint(artist: artist, title: title),
      normalizeTrackFingerprint(filename: filename),
    }..remove('');
    if (fps.isEmpty) return false;
    await loadDiscards();
    _discarded.addAll(fps);
    await _saveDiscards();
    return true;
  }

  Future<void> _saveDiscards() {
    final String? p = discardPath;
    if (p == null) return Future<void>.value();
    final List<String> data = _discarded.toList()..sort();
    _write = _write.catchError((Object _) {}).then((_) async {
      final File f = File(p);
      await f.parent.create(recursive: true);
      final File tmp = File('$p.tmp');
      await tmp.writeAsString(
        jsonEncode(<String, Object?>{'version': 1, 'discarded': data}),
        flush: true,
      );
      if (await f.exists()) await f.delete();
      await tmp.rename(p);
    });
    return _write;
  }
}

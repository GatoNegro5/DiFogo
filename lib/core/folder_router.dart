// 3.2.34 (DIF-32): las canciones nuevas (Descargas YT y DESCUBRE) van a su
// carpeta real de ReGenial. Orden de decision:
//   0) artista fijado por el usuario (un toque en la sugerencia);
//   a) indice artista -> carpetas con los NOMBRES de archivo de ReGenial
//      (sin abrir audio; separa ft., feat., &, coma, + y x; ignora _K);
//   b) estacion/sub de DESCUBRE o TrackGenreClassifier, llevados a la
//      carpeta real (desempate por idioma);
//   c) genero externo (iTunes Search y luego Deezer) + anio, con cache por
//      artista y timeout corto;
//   d) confianza baja: ReGenial/Por clasificar y una sugerencia discreta.
// La unica escritura en ReGenial es [placeTrackGroup]: temporal unico en la
// carpeta destino, verificacion de tamano y duracion, nunca pisa un nombre,
// el grupo (mp3, .lrc, .gmx_words.json y _K) va junto con vuelta atras y un
// reemplazo manda antes el original a Laboratorio/Cuarentena_MP3/<carpeta>.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../providers/session_provider.dart' show vibeMusicRoot;
import '../src/rust/api/core_dsp.dart' as rust_dsp;
import 'genre_stations.dart';
import 'library_guard.dart' show libraryCacheRoot;

/// Carpeta de ReGenial para lo que no se pudo clasificar con confianza.
const String kPorClasificar = 'Por clasificar';

/// Confianza minima para colocar sin preguntar.
const double kRouteMinConfidence = 0.6;

/// Solo pruebas: raiz de ReGenial (arbol sintetico en %TEMP%).
@visibleForTesting
String? debugRegenialRoot;

/// Solo pruebas: genero externo falso (sin red).
@visibleForTesting
ArtistGenreLookup? debugArtistGenreLookup;

/// Solo pruebas: medidor de duracion falso (sin motor Rust).
@visibleForTesting
Future<int> Function(String path)? debugPlaceDurationProbe;

bool get _inFlutterTest => Platform.environment.containsKey('FLUTTER_TEST');

/// ReGenial real o null (sin ReGenial se usa el respaldo de siempre).
String? regenialRoot() {
  final String? o = debugRegenialRoot;
  if (o != null) return Directory(o).existsSync() ? o : null;
  final String v = vibeMusicRoot();
  final String last = v.split(RegExp(r'[\\/]')).last.toLowerCase();
  if (last != 'regenial') return null;
  return Directory(v).existsSync() ? v : null;
}

String _fold(String s) {
  const String from = 'áàäâãéèëêíìïîóòöôõúùüûñç';
  const String to = 'aaaaaeeeeiiiiooooouuuunc';
  final StringBuffer b = StringBuffer();
  for (final int r in s.toLowerCase().runes) {
    final String ch = String.fromCharCode(r);
    final int i = from.indexOf(ch);
    b.write(i >= 0 ? to[i] : ch);
  }
  return b
      .toString()
      .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// Artistas del nombre `Artista ft. Otro - Titulo` (vacio si no hay " - ").
List<String> routerArtistsOf(String stem) {
  final int cut = stem.indexOf(' - ');
  if (cut <= 0) return const <String>[];
  final List<String> parts = stem
      .substring(0, cut)
      .split(
        RegExp(
          r'\s*(?:,|&|\+|\bfeat\.?|\bft\.?|\bfeaturing\b|\bx\b|\bvs\.?)\s*',
          caseSensitive: false,
        ),
      );
  return <String>[
    for (final String p in parts)
      if (_fold(p).length >= 2) _fold(p),
  ];
}

String _stemOf(String nameOrPath) {
  String n = nameOrPath.split(RegExp(r'[\\/]')).last;
  final int dot = n.lastIndexOf('.');
  if (dot > 0 && n.length - dot <= 5) n = n.substring(0, dot);
  return n;
}

String _leafKey(String rel) {
  String l = _fold(rel.split(RegExp(r'[\\/]')).last);
  if (l.endsWith('s')) l = l.substring(0, l.length - 1);
  return l;
}

/// Carpetas de ReGenial que no cuentan como destino.
bool _skipFolder(String rel) {
  final String f = _fold(rel);
  return f.isEmpty ||
      f.startsWith(_fold(kPorClasificar)) ||
      f.contains('cuarentena') ||
      f.contains('tempai') ||
      f.startsWith('djplaylists');
}

/// Indice de ReGenial: canciones por carpeta y artista -> carpetas.
class LibraryIndex {
  LibraryIndex._(this.root, this.folderCount, this.artistFolders, this.twin);

  final String root;

  /// Carpeta relativa (con el separador del sistema) -> canciones.
  final Map<String, int> folderCount;

  /// Artista normalizado -> carpeta (ya canonica) -> canciones.
  final Map<String, Map<String, int>> artistFolders;

  /// Carpeta casi vacia (<= 3) -> la de primer nivel con el mismo nombre
  /// (Actualidad Espanol/Salsa -> Salsa).
  final Map<String, String> twin;

  String canon(String rel) => twin[rel] ?? rel;

  /// Solo nombres de archivo; nunca abre audio.
  static LibraryIndex build(String root) {
    final String sep = Platform.pathSeparator;
    final Map<String, int> count = <String, int>{};
    final List<MapEntry<String, String>> songs = <MapEntry<String, String>>[];
    try {
      for (final FileSystemEntity e in Directory(
        root,
      ).listSync(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        final String p = e.path;
        if (!p.toLowerCase().endsWith('.mp3')) continue;
        final String stem = _stemOf(p);
        if (stem.toLowerCase().endsWith('_k')) continue;
        final int cut = p.lastIndexOf(sep);
        if (cut <= root.length) continue;
        final String rel = p.substring(root.length + 1, cut);
        if (_skipFolder(rel)) continue;
        count[rel] = (count[rel] ?? 0) + 1;
        songs.add(MapEntry<String, String>(rel, stem));
      }
    } catch (_) {}
    final Map<String, String> twin = <String, String>{};
    for (final MapEntry<String, int> f in count.entries) {
      if (f.value > 3) continue;
      String? best;
      for (final MapEntry<String, int> o in count.entries) {
        if (o.key == f.key || o.key.contains(sep) || o.value <= f.value) {
          continue;
        }
        if (_leafKey(o.key) != _leafKey(f.key)) continue;
        if (best == null || o.value > count[best]!) best = o.key;
      }
      if (best != null) twin[f.key] = best;
    }
    final Map<String, Map<String, int>> artists = <String, Map<String, int>>{};
    for (final MapEntry<String, String> s in songs) {
      final String rel = twin[s.key] ?? s.key;
      for (final String a in routerArtistsOf(s.value)) {
        final Map<String, int> m = artists.putIfAbsent(
          a,
          () => <String, int>{},
        );
        m[rel] = (m[rel] ?? 0) + 1;
      }
    }
    return LibraryIndex._(root, count, artists, twin);
  }

  /// Carpeta real de [station]/[sub]: la mas grande que lo alimenta; si no
  /// hay, la mas grande de la estacion (desempate por idioma).
  String? folderFor(String station, String? sub, {String? lang}) {
    String? exact;
    String? same;
    int ne = -1;
    int ns = -1;
    for (final MapEntry<String, int> f in folderCount.entries) {
      if (twin.containsKey(f.key)) continue;
      final MapEntry<String, String>? m = stationSubOf(
        f.key.replaceAll('\\', '/'),
      );
      if (m == null || m.key != station) continue;
      final String fl = _fold(f.key);
      final bool langOk =
          lang == null ||
          (lang == 'es' && !fl.contains('ingles')) ||
          (lang == 'en' && !fl.contains('espanol'));
      final int score = f.value + (langOk ? 100000 : 0);
      if (sub != null && m.value == sub && score > ne) {
        ne = score;
        exact = f.key;
      }
      if (score > ns) {
        ns = score;
        same = f.key;
      }
    }
    return exact ?? same;
  }
}

/// Genero externo de un artista (iTunes/Deezer).
class ExternalGenre {
  const ExternalGenre(this.genre, this.year);
  final String genre;
  final int? year;

  Map<String, Object?> toJson() => <String, Object?>{'g': genre, 'y': year};
}

typedef ArtistGenreLookup =
    Future<ExternalGenre?> Function(String artist, String title);

/// Decision del router.
class RouteDecision {
  const RouteDecision({
    required this.rel,
    required this.confidence,
    required this.reason,
    this.suggestion,
    this.artist,
  });

  /// Carpeta relativa a ReGenial (Por clasificar si la confianza es baja).
  final String rel;
  final double confidence;
  final String reason;

  /// Mejor candidata cuando cae en Por clasificar.
  final String? suggestion;
  final String? artist;

  bool get confident => confidence >= kRouteMinConfidence;

  @override
  String toString() =>
      '$rel (${(confidence * 100).round()} %, $reason'
      '${suggestion == null ? '' : ', sugerencia $suggestion'})';
}

LibraryIndex? _cached;
DateTime _cachedAt = DateTime(2000);

/// Indice en memoria (se rehace a los 10 min o tras colocar).
Future<LibraryIndex> libraryIndexFor(String root) async {
  final LibraryIndex? c = _cached;
  if (c != null &&
      c.root == root &&
      DateTime.now().difference(_cachedAt) < const Duration(minutes: 10)) {
    return c;
  }
  final LibraryIndex i = await Future<LibraryIndex>(
    () => LibraryIndex.build(root),
  );
  _cached = i;
  _cachedAt = DateTime.now();
  return i;
}

void forgetLibraryIndex() => _cached = null;

String _sidePath(String name) =>
    '${libraryCacheRoot()}${Platform.pathSeparator}$name';

Map<String, dynamic> _readJson(String path) {
  try {
    final File f = File(path);
    if (!f.existsSync()) return <String, dynamic>{};
    final Object? j = jsonDecode(f.readAsStringSync());
    return j is Map<String, dynamic> ? j : <String, dynamic>{};
  } catch (_) {
    return <String, dynamic>{};
  }
}

void _writeJson(String path, Map<String, dynamic> data) {
  try {
    final File f = File(path);
    f.parent.createSync(recursive: true);
    final File tmp = File('$path.$pid.tmp');
    tmp.writeAsStringSync(jsonEncode(data));
    tmp.renameSync(path);
  } catch (_) {}
}

/// Artista fijado por el usuario -> carpeta relativa.
Map<String, dynamic> routerPins() =>
    _readJson(_sidePath('folder_router_pins.json'));

void pinArtist(String artist, String rel) {
  final Map<String, dynamic> p = routerPins();
  p[_fold(artist)] = rel;
  _writeJson(_sidePath('folder_router_pins.json'), p);
}

/// Genero externo con cache por artista (iTunes y luego Deezer).
Future<ExternalGenre?> lookupArtistGenre(String artist, String title) async {
  final ArtistGenreLookup? fake = debugArtistGenreLookup;
  if (fake != null) return fake(artist, title);
  if (_inFlutterTest) return null;
  final String key = _fold(artist);
  final String cachePath = _sidePath('artist_genre_cache.json');
  final Map<String, dynamic> cache = _readJson(cachePath);
  final Object? hit = cache[key];
  if (hit is Map) {
    final Object? g = hit['g'];
    if (g is String && g.isNotEmpty) {
      final Object? y = hit['y'];
      return ExternalGenre(g, y is int ? y : null);
    }
    return null;
  }
  ExternalGenre? out;
  const Duration t = Duration(seconds: 4);
  try {
    final Uri u = Uri.https('itunes.apple.com', '/search', <String, String>{
      'term': '$artist $title',
      'entity': 'song',
      'limit': '1',
    });
    final http.Response r = await http.get(u).timeout(t);
    if (r.statusCode == 200) {
      final Object? j = jsonDecode(r.body);
      if (j is Map &&
          j['results'] is List &&
          (j['results'] as List).isNotEmpty) {
        final Object? s = (j['results'] as List).first;
        if (s is Map && s['primaryGenreName'] is String) {
          out = ExternalGenre(
            s['primaryGenreName'] as String,
            int.tryParse('${s['releaseDate'] ?? ''}'.split('-').first),
          );
        }
      }
    }
  } catch (_) {}
  if (out == null) {
    try {
      final Uri u = Uri.https('api.deezer.com', '/search', <String, String>{
        'q': '$artist $title',
        'limit': '1',
      });
      final http.Response r = await http.get(u).timeout(t);
      final Object? j = r.statusCode == 200 ? jsonDecode(r.body) : null;
      if (j is Map && j['data'] is List && (j['data'] as List).isNotEmpty) {
        final Object? tr = (j['data'] as List).first;
        final Object? al = tr is Map ? tr['album'] : null;
        final Object? id = al is Map ? al['id'] : null;
        if (id != null) {
          final http.Response a = await http
              .get(Uri.https('api.deezer.com', '/album/$id'))
              .timeout(t);
          final Object? aj = a.statusCode == 200 ? jsonDecode(a.body) : null;
          if (aj is Map && aj['genres'] is Map) {
            final Object? gl = (aj['genres'] as Map)['data'];
            if (gl is List && gl.isNotEmpty && gl.first is Map) {
              final Object? name = (gl.first as Map)['name'];
              if (name is String) {
                out = ExternalGenre(
                  name,
                  int.tryParse('${aj['release_date'] ?? ''}'.split('-').first),
                );
              }
            }
          }
        }
      }
    } catch (_) {}
  }
  cache[key] = out?.toJson() ?? <String, Object?>{'g': ''};
  _writeJson(cachePath, cache);
  return out;
}

/// Decide la carpeta de ReGenial de [nameOrPath] (nombre `Artista - Titulo`).
/// [stationId]/[subGenreId]: los de DESCUBRE si se conocen.
Future<RouteDecision> decideFolder({
  required String nameOrPath,
  required LibraryIndex index,
  String? stationId,
  String? subGenreId,
  String? genreHint,
  int? year,
  String? lang,
  double bpm = 0,
  bool external = true,
}) async {
  final String stem = _stemOf(nameOrPath);
  final List<String> artists = routerArtistsOf(stem);
  final String? artist = artists.isEmpty ? null : artists.first;
  RouteDecision ok(String rel, double c, String why) =>
      RouteDecision(rel: rel, confidence: c, reason: why, artist: artist);
  // 0) fijado por el usuario.
  final Map<String, dynamic> pins = routerPins();
  for (final String a in artists) {
    final Object? r = pins[a];
    if (r is String && r.isNotEmpty) return ok(r, 1.0, 'fijado');
  }
  // a) indice de artistas.
  final Map<String, int> votes = <String, int>{};
  for (final String a in artists) {
    index.artistFolders[a]?.forEach((String rel, int n) {
      votes[rel] = (votes[rel] ?? 0) + n;
    });
  }
  String? weak;
  if (votes.isNotEmpty) {
    final int total = votes.values.fold(0, (int s, int v) => s + v);
    final MapEntry<String, int> top = votes.entries.reduce(
      (MapEntry<String, int> x, MapEntry<String, int> y) =>
          y.value > x.value ? y : x,
    );
    final double share = top.value / total;
    if (total >= 2 && share >= 0.75) {
      return ok(top.key, 0.9, 'artista ${top.value}/$total');
    }
    // 3.2.34: con menos del 75 % (medido: ~49 % de acierto) solo sugiere.
    weak = top.key;
  }
  // b) estacion conocida o clasificador por nombre.
  if (stationId != null) {
    final String? f = index.folderFor(stationId, subGenreId, lang: lang);
    if (f != null) return ok(f, 0.75, 'estacion $stationId/$subGenreId');
  }
  final TrackGenre g = TrackGenreClassifier.classify(
    '$stem.mp3',
    tags: TrackTagHint(genre: genreHint, year: year, lang: lang),
    bpm: bpm,
  );
  String? byName;
  if (g.stationId != null && g.level <= 2) {
    byName = index.folderFor(g.stationId!, g.subGenreId, lang: lang);
    // 3.2.34: por nombre solo (nivel 2) acierta ~51 %: solo sugiere; con
    // genero de tags (nivel <= 1) coloca.
    if (byName != null && g.level <= 1) {
      return ok(byName, 0.7, 'clasificador $g');
    }
  }
  // c) genero externo.
  String? extHint;
  if (external && artist != null) {
    final int cut = stem.indexOf(' - ');
    final String title = cut > 0 ? stem.substring(cut + 3) : stem;
    ExternalGenre? x;
    try {
      x = await lookupArtistGenre(
        stem.substring(0, cut),
        title,
      ).timeout(const Duration(seconds: 10));
    } catch (_) {}
    if (x != null) {
      final TrackGenre e = TrackGenreClassifier.classify(
        '$stem.mp3',
        tags: TrackTagHint(genre: x.genre, year: x.year ?? year, lang: lang),
        bpm: bpm,
      );
      // 3.2.34: el genero externo acierta poco contra las carpetas de
      // ReGenial (muestra: ~22 %): solo sugiere.
      if (e.stationId != null && e.level <= 1) {
        external = false;
        extHint = index.folderFor(e.stationId!, e.subGenreId, lang: lang);
      }
    }
  }
  // d) baja: Por clasificar con la mejor sugerencia.
  String? hint = weak ?? byName ?? extHint;
  if (hint == null && g.stationId != null) {
    hint = index.folderFor(g.stationId!, g.subGenreId, lang: lang);
  }
  return RouteDecision(
    rel: kPorClasificar,
    confidence: 0.3,
    reason: 'confianza baja',
    suggestion: hint,
    artist: artist,
  );
}

/// Sugerencia pendiente (archivo en Por clasificar y carpeta propuesta).
class RouteSuggestion {
  const RouteSuggestion(this.path, this.rel, this.artist);
  final String path;
  final String rel;
  final String? artist;
}

/// Ultima sugerencia discreta (la muestra Descargas YT como chip).
final ValueNotifier<RouteSuggestion?> folderRouteSuggestion =
    ValueNotifier<RouteSuggestion?>(null);

/// Archivos del grupo de [mp3] que existen: mp3, .lrc, .gmx_words.json, _K.
List<String> trackGroupOf(String mp3) {
  final int dot = mp3.lastIndexOf('.');
  final String base = dot > 0 ? mp3.substring(0, dot) : mp3;
  return <String>[
    mp3,
    for (final String s in <String>['.lrc', '.gmx_words.json', '_K.mp3'])
      if (File('$base$s').existsSync()) '$base$s',
  ];
}

String _suffixOf(String mp3, String file) {
  final int dot = mp3.lastIndexOf('.');
  final String base = dot > 0 ? mp3.substring(0, dot) : mp3;
  return file.substring(base.length);
}

/// Resultado de colocar un grupo: ruta nueva del mp3 y pares viejo -> nuevo.
class PlaceResult {
  const PlaceResult(this.path, this.moved);
  final String path;
  final Map<String, String> moved;
}

Future<int?> _durationOf(String path) async {
  final Future<int> Function(String)? fake = debugPlaceDurationProbe;
  if (fake != null) return fake(path);
  if (_inFlutterTest) return null;
  try {
    return (await rust_dsp.exactDurationMs(inputPath: path)).toInt();
  } catch (_) {
    return null;
  }
}

int _seq = 0;

/// Coloca el grupo de [src] en [destDir] con nombre libre (nunca pisa).
/// Copia a un temporal unico en la carpeta destino, verifica tamano y
/// duracion y lo renombra; si algo falla deshace lo hecho y el origen queda
/// intacto. Con [keepSource] (Guardar en 1 clic) el origen no se borra. Con
/// [replace] (ruta existente) ese original va antes a [quarantineDir].
Future<PlaceResult> placeTrackGroup({
  required String src,
  required String destDir,
  bool keepSource = false,
  String? replace,
  String? quarantineDir,
  String? name,
  Future<void> Function(String oldPath, String newPath)? retarget,
}) async {
  final String sep = Platform.pathSeparator;
  if (!File(src).existsSync()) throw StateError('No existe: $src');
  await Directory(destDir).create(recursive: true);
  final List<String> group = trackGroupOf(src);
  String stem = name ?? _stemOf(src);
  final Map<String, String> moved = <String, String>{};
  final List<String> made = <String>[];
  if (replace != null && File(replace).existsSync()) {
    final String q = quarantineDir ?? '$destDir${sep}Cuarentena_MP3';
    await Directory(q).create(recursive: true);
    for (final String f in trackGroupOf(replace)) {
      final String name = f.split(sep).last;
      String to = '$q$sep$name';
      int n = 2;
      while (File(to).existsSync()) {
        to = '$q$sep${n++}_$name';
      }
      await File(f).rename(to);
    }
    stem = _stemOf(replace);
  } else {
    final String base = stem;
    int n = 2;
    bool taken() => group.any(
      (String f) => File('$destDir$sep$stem${_suffixOf(src, f)}').existsSync(),
    );
    while (taken()) {
      stem = '$base ($n)';
      n++;
    }
  }
  try {
    for (final String f in group) {
      final String dst = '$destDir$sep$stem${_suffixOf(src, f)}';
      final String tmp = '$destDir$sep.$stem.${pid}_${_seq++}.gmxplace';
      made.add(tmp);
      await File(f).copy(tmp);
      if (File(tmp).lengthSync() != File(f).lengthSync()) {
        throw StateError('Copia incompleta: $f');
      }
      if (f.toLowerCase().endsWith('.mp3')) {
        final int? a = await _durationOf(f);
        final int? b = await _durationOf(tmp);
        if (a != null && b != null && (a - b).abs() > 400) {
          throw StateError('Empalme evitado: $tmp dura $b ms y $f $a ms');
        }
      }
      if (File(dst).existsSync()) throw StateError('Ya existe: $dst');
      await File(tmp).rename(dst);
      made
        ..remove(tmp)
        ..add(dst);
      moved[f] = dst;
    }
  } catch (_) {
    for (final String p in made) {
      try {
        File(p).deleteSync();
      } catch (_) {}
    }
    rethrow;
  }
  if (!keepSource) {
    for (final String f in group) {
      try {
        File(f).deleteSync();
      } catch (_) {}
    }
  }
  forgetLibraryIndex();
  if (retarget != null) {
    for (final MapEntry<String, String> m in moved.entries) {
      if (!m.key.toLowerCase().endsWith('.mp3')) continue;
      try {
        await retarget(m.key, m.value);
      } catch (_) {}
    }
  }
  return PlaceResult(moved[src]!, moved);
}

/// `Laboratorio/Cuarentena_MP3/<carpeta relativa>` junto a ReGenial.
String quarantineFor(String root, String rel) {
  final String sep = Platform.pathSeparator;
  final String music = Directory(root).parent.path;
  return '$music${sep}Laboratorio${sep}Cuarentena_MP3$sep$rel';
}

/// Coloca [src] (ya terminado: masterizado, letra, _K) en ReGenial. Devuelve
/// null si no hay ReGenial (el que llama deja el archivo donde estaba).
Future<(PlaceResult, RouteDecision)?> routeIntoRegenial(
  String src, {
  String? stationId,
  String? subGenreId,
  String? genreHint,
  bool keepSource = false,
  String? name,
  Future<void> Function(String oldPath, String newPath)? retarget,
}) async {
  final String? root = regenialRoot();
  if (root == null) return null;
  final LibraryIndex index = await libraryIndexFor(root);
  final RouteDecision d = await decideFolder(
    nameOrPath: name ?? src,
    index: index,
    stationId: stationId,
    subGenreId: subGenreId,
    genreHint: genreHint,
  );
  final String sep = Platform.pathSeparator;
  final PlaceResult r = await placeTrackGroup(
    src: src,
    destDir: '$root$sep${d.rel}',
    keepSource: keepSource,
    name: name,
    retarget: retarget,
  );
  if (!d.confident && d.suggestion != null) {
    folderRouteSuggestion.value = RouteSuggestion(
      r.path,
      d.suggestion!,
      d.artist,
    );
  }
  return (r, d);
}

/// Un toque en la sugerencia: mueve el grupo y fija el artista.
Future<String?> acceptRouteSuggestion(
  RouteSuggestion s, {
  Future<void> Function(String oldPath, String newPath)? retarget,
}) async {
  final String? root = regenialRoot();
  if (root == null || !File(s.path).existsSync()) return null;
  final PlaceResult r = await placeTrackGroup(
    src: s.path,
    destDir: '$root${Platform.pathSeparator}${s.rel}',
    retarget: retarget,
  );
  final String? a = s.artist;
  if (a != null) pinArtist(a, s.rel);
  if (folderRouteSuggestion.value == s) folderRouteSuggestion.value = null;
  return r.path;
}

/// Destino de Descargas YT: automatico (por defecto) o carpeta a mano.
class YtDestination {
  const YtDestination(this.auto, this.folder);
  final bool auto;
  final String folder;
}

YtDestination loadYtDestination() {
  final Map<String, dynamic> j = _readJson(_sidePath('yt_destination.json'));
  final Object? f = j['folder'];
  return YtDestination(j['auto'] != false, f is String ? f : '');
}

void saveYtDestination(YtDestination d) => _writeJson(
  _sidePath('yt_destination.json'),
  <String, dynamic>{'auto': d.auto, 'folder': d.folder},
);

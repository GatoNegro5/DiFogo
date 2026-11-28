import 'dart:io';
import 'dart:math';

import 'gatomix_store.dart' show peekTrackDna, warmTrackDnaFor, TrackDnaEntry;
import 'livedj_order.dart' show buildHarmonicShuffle, HarmonicDna;
import 'session_store.dart';
export 'brand_paths.dart' show kTrackGenreIndexName, kOldTrackGenreIndexName;

/// 3.1.61 Estaciones DiFogo (3.1.64: catalogo universal de 7 estaciones con
/// sub-generos canonicos, sin nombres de carpeta), y la sesion persistente de cada
/// estacion (pista, segundo, cola restante y ya sonadas). Dart puro: no
/// toca el motor de audio ni la biblioteca.

class GenreStation {
  const GenreStation(
    this.key,
    this.title,
    this.subGenres,
    this.count, {
    this.folders = const <String, List<String>>{},
    this.subCounts = const <String, int>{},
  });

  /// Clave estable en el JSON (una de las 7 estaciones universales).
  final String key;
  final String title;

  /// 3.1.64: sub-generos canonicos visibles (nunca nombres de carpeta).
  final List<String> subGenres;
  final int count;

  /// Carpetas locales que alimentan cada sub-genero (solo interno).
  final Map<String, List<String>> folders;

  /// Canciones locales por sub-genero.
  final Map<String, int> subCounts;
}

/// Sub-genero canonico y los terminos que usa el Auto-Curador.
class StationSub {
  const StationSub(this.label, this.terms);
  final String label;
  final String terms;
}

class UniversalStation {
  const UniversalStation(this.key, this.title, this.subs);
  final String key;
  final String title;
  final List<StationSub> subs;
}

/// 3.1.64: catalogo universal fijo de DiFogo, en este orden. No depende de
/// como se llamen las carpetas del disco.
const List<UniversalStation> kUniversalStations = <UniversalStation>[
  UniversalStation('momento', 'Música del Momento', <StationSub>[
    StationSub('Pop', 'Pop Rock Pop Latino Pop Inglés hits'),
    StationSub('Reggaetón', 'Reggaetón hits'),
    StationSub('HipHop', 'Hip Hop Rap hits'),
    StationSub('Electrónica', 'Electrónica EDM hits'),
    StationSub('R&B', 'R&B hits'),
    StationSub('Todas las Demás Nuevas', 'nuevos éxitos musicales'),
  ]),
  UniversalStation('ochenteras', 'Ochenteras', <StationSub>[
    StationSub('Disco', 'Disco 80s hits'),
    StationSub('Punk', 'Punk 80s'),
    StationSub('Pop', 'Pop 80s hits'),
    StationSub('Rock', 'Rock 80s hits'),
    StationSub('HipHop', 'Hip Hop 80s'),
    StationSub('Eurodance', 'Eurodance Dance 80s'),
    // 3.1.68: bucket de respaldo (canciones sin match en el lexico).
    StationSub('Todas', 'Ochenteras 80s hits'),
  ]),
  UniversalStation('tropical', 'Tropical', <StationSub>[
    StationSub('Salsa', 'Salsa'),
    StationSub('Cumbia', 'Cumbia'),
    StationSub('Merengue', 'Merengue'),
    StationSub('Bachatas', 'Bachata'),
    StationSub('Vallenatos', 'Vallenato'),
    StationSub('Todas', 'Música tropical bailable'),
  ]),
  UniversalStation('fiesta', 'Fiesta MIX', <StationSub>[
    StationSub('Crossover & Hora Loca', 'Crossover Hora Loca'),
    StationSub('Electro Fiesta & Guaracha', 'Guaracha Electro Fiesta'),
    StationSub('Hits Bailables', 'Hits bailables'),
    StationSub('Todas', 'Fiesta mix'),
  ]),
  UniversalStation('rock', 'Rock', <StationSub>[
    StationSub('Rock Clásico Español', 'Rock clásico en español'),
    StationSub('Rock Clásico en Inglés', 'Classic Rock'),
    StationSub('Heavy Metal', 'Heavy Metal'),
    StationSub('Grunge', 'Grunge'),
    StationSub('Todas', 'Rock'),
  ]),
  UniversalStation('baladas', 'Baladas', <StationSub>[
    StationSub('En Inglés', 'Baladas en inglés love songs'),
    StationSub('En Español', 'Baladas románticas en español'),
    StationSub('Todas', 'Baladas románticas'),
  ]),
  UniversalStation('nacional', 'Música Nacional Bailable', <StationSub>[
    StationSub('Cumbia & Chicha Nacional', 'Cumbia Chicha Ecuador'),
    StationSub('Paseíto & Sanjuanito', 'Paseíto Sanjuanito Ecuador'),
    StationSub('Tecnocumbia', 'Tecnocumbia Ecuador'),
    StationSub('Todas', 'Música nacional bailable Ecuador'),
  ]),
];

/// 3.1.68: estaciones que recibieron el sub-genero "Todas".
const List<String> kTodasAddedIn3168 = <String>[
  'ochenteras',
  'tropical',
  'baladas',
];

// Claves de la 3.1.61/62 que pueden seguir en sesiones guardadas.
const Map<String, String> _legacyTitles = <String, String>{
  'actualidad': 'Actualidad',
  'romanticas': 'Románticas & Baladas',
  'rockpop': 'Rock & Pop',
};

String stationFold(String s) {
  // 3.2.1: tambien dieresis y acentos europeos (Mago de Oz, Motorhead,
  // Motley Crue) y marcas combinadas sueltas (nombres NFD de macOS).
  const String from = 'áéíóúüñÁÉÍÓÚÜÑäöëïàèìòùâêîôûçÄÖËÏÀÈÌÒÙÂÊÎÔÛÇ';
  const String to = 'aeiouunaeiouunaoeiaeiouaeioucaoeiaeiouaeiouc';
  final StringBuffer b = StringBuffer();
  for (final int r in s.runes) {
    if (r >= 0x0300 && r <= 0x036F) continue;
    final String c = String.fromCharCode(r);
    final int i = from.indexOf(c);
    b.write(i < 0 ? c : to[i]);
  }
  return b.toString().toLowerCase();
}

bool _has(String f, List<String> words) => words.any(f.contains);

final RegExp _rapWord = RegExp(r'(^|[^a-z])(rap|hip)');

/// 3.1.64: estacion y sub-genero canonico de una carpeta local, por reglas
/// sobre su nombre; null si no encaja en ninguna (no se muestra).
/// 3.1.67: null tambien para carpetas genericas (Descargas, Mix...) y para
/// las raices canonicas `<Estacion>/`: sus canciones se clasifican una a una.
MapEntry<String, String>? stationSubOf(String folder) {
  final String slug = stationSlug(folder).toLowerCase();
  for (final UniversalStation u in kUniversalStations) {
    if (stationSlug(u.title).toLowerCase() == slug) return null;
  }
  final MapEntry<String, String>? raw = _stationSubOfRaw(folder);
  if (isGenericMusicFolder(folder) &&
      (raw == null || raw.value == 'Todas las Demás Nuevas')) {
    return null;
  }
  return raw;
}

MapEntry<String, String>? _stationSubOfRaw(String folder) {
  final String f = stationFold(folder);
  MapEntry<String, String> m(String k, String s) =>
      MapEntry<String, String>(k, s);
  if (_has(f, <String>[
    'nacional',
    'chicha',
    'sanjuan',
    'paseit',
    'tecnocumbia',
  ])) {
    if (f.contains('tecno')) return m('nacional', 'Tecnocumbia');
    if (_has(f, <String>['sanjuan', 'paseit'])) {
      return m('nacional', 'Paseíto & Sanjuanito');
    }
    if (_has(f, <String>['chicha', 'cumbia'])) {
      return m('nacional', 'Cumbia & Chicha Nacional');
    }
    return m('nacional', 'Todas');
  }
  if (_has(f, <String>['80', 'ochent'])) {
    if (f.contains('disco')) return m('ochenteras', 'Disco');
    if (f.contains('punk')) return m('ochenteras', 'Punk');
    if (_has(f, <String>['euro', 'dance'])) return m('ochenteras', 'Eurodance');
    if (_rapWord.hasMatch(f)) return m('ochenteras', 'HipHop');
    if (f.contains('rock')) return m('ochenteras', 'Rock');
    return m('ochenteras', 'Pop');
  }
  if (_has(f, <String>[
    'fiesta',
    'guarach',
    'crossover',
    'hora loca',
    'bailable',
  ])) {
    if (_has(f, <String>['crossover', 'hora loca'])) {
      return m('fiesta', 'Crossover & Hora Loca');
    }
    if (_has(f, <String>['guarach', 'electro'])) {
      return m('fiesta', 'Electro Fiesta & Guaracha');
    }
    if (_has(f, <String>['bailable', 'hits'])) {
      return m('fiesta', 'Hits Bailables');
    }
    return m('fiesta', 'Todas');
  }
  if (f.contains('salsa')) return m('tropical', 'Salsa');
  if (f.contains('cumbia')) return m('tropical', 'Cumbia');
  if (f.contains('merengue')) return m('tropical', 'Merengue');
  if (f.contains('bachat')) return m('tropical', 'Bachatas');
  if (f.contains('vallenato')) return m('tropical', 'Vallenatos');
  if (_has(f, <String>['balada', 'romant'])) {
    return _has(f, <String>['ingl', 'english'])
        ? m('baladas', 'En Inglés')
        : m('baladas', 'En Español');
  }
  if (_has(f, <String>['rock', 'metal', 'grunge', 'espanola'])) {
    if (f.contains('metal')) return m('rock', 'Heavy Metal');
    if (f.contains('grunge')) return m('rock', 'Grunge');
    if (_has(f, <String>['ingl', 'english'])) {
      return m('rock', 'Rock Clásico en Inglés');
    }
    if (f.contains('espan')) return m('rock', 'Rock Clásico Español');
    return m('rock', 'Todas');
  }
  if (_has(f, <String>[
        'actualidad',
        'pop',
        'reggaeton',
        'electr',
        'r&b',
        'rnb',
        'nuev',
        'urban',
      ]) ||
      _rapWord.hasMatch(f)) {
    if (f.contains('reggaeton')) return m('momento', 'Reggaetón');
    if (_rapWord.hasMatch(f)) return m('momento', 'HipHop');
    if (f.contains('electr')) return m('momento', 'Electrónica');
    if (_has(f, <String>['r&b', 'rnb'])) return m('momento', 'R&B');
    if (_has(f, <String>['actualidad', 'pop'])) return m('momento', 'Pop');
    return m('momento', 'Todas las Demás Nuevas');
  }
  return null;
}

UniversalStation? universalStation(String key) {
  for (final UniversalStation u in kUniversalStations) {
    if (u.key == key) return u;
  }
  return null;
}

/// true si [label] es un sub-genero canonico de la estacion [key].
bool isStationSub(String key, String label) =>
    universalStation(key)?.subs.any((StationSub s) => s.label == label) ??
    false;

/// Arma las 7 estaciones universales (siempre todas, en orden) con las
/// carpetas (nombre, canciones) mapeadas a cada sub-genero.
/// 3.1.67: [extra] suma las canciones clasificadas una a una (carpetas
/// genericas) por estacion y sub-genero.
List<GenreStation> groupStations(
  List<MapEntry<String, int>> folders, {
  Map<String, Map<String, int>> extra = const <String, Map<String, int>>{},
}) {
  final Map<String, Map<String, List<MapEntry<String, int>>>> by =
      <String, Map<String, List<MapEntry<String, int>>>>{};
  for (final MapEntry<String, int> f in folders) {
    final MapEntry<String, String>? s = stationSubOf(f.key);
    if (s == null) continue;
    ((by[s.key] ??= <String, List<MapEntry<String, int>>>{})[s.value] ??=
            <MapEntry<String, int>>[])
        .add(f);
  }
  int byName(MapEntry<String, int> a, MapEntry<String, int> b) =>
      stationFold(a.key).compareTo(stationFold(b.key));
  final List<GenreStation> out = <GenreStation>[];
  for (final UniversalStation u in kUniversalStations) {
    final Map<String, List<MapEntry<String, int>>> g =
        by[u.key] ?? const <String, List<MapEntry<String, int>>>{};
    final Map<String, List<String>> fol = <String, List<String>>{};
    final Map<String, int> counts = <String, int>{};
    int total = 0;
    for (final StationSub s in u.subs) {
      final List<MapEntry<String, int>> l = List<MapEntry<String, int>>.from(
        g[s.label] ?? const <MapEntry<String, int>>[],
      )..sort(byName);
      fol[s.label] = <String>[for (final MapEntry<String, int> e in l) e.key];
      final int c =
          l.fold<int>(0, (int a, MapEntry<String, int> e) => a + e.value) +
          (extra[u.key]?[s.label] ?? 0);
      counts[s.label] = c;
      total += c;
    }
    out.add(
      GenreStation(
        u.key,
        u.title,
        <String>[for (final StationSub s in u.subs) s.label],
        total,
        folders: fol,
        subCounts: counts,
      ),
    );
  }
  return out;
}

/// Carpetas locales de los sub-generos [subs] de [key]. Lo que no es un
/// sub-genero canonico (sesiones de la 3.1.61/62) se usa tal cual.
List<String> stationFolders(
  String key,
  List<String> subs,
  Iterable<String> library,
) {
  final Set<String> want = <String>{
    for (final String s in subs)
      if (isStationSub(key, s)) s,
  };
  final List<String> out = <String>[
    for (final String s in subs)
      if (!isStationSub(key, s)) s,
  ];
  if (want.isEmpty) return out;
  for (final String f in library) {
    final MapEntry<String, String>? m = stationSubOf(f);
    if (m != null &&
        m.key == key &&
        want.contains(m.value) &&
        !out.contains(f)) {
      out.add(f);
    }
  }
  return out;
}

class StationFeed {
  const StationFeed(this.folder, this.query, [this.sub]);

  /// Carpeta destino si el usuario acepta el tema en la bandeja.
  final String folder;

  /// Terminos canonicos de busqueda (null = el nombre de la carpeta).
  final String? query;

  /// 3.1.68: sub-genero canonico pedido (viaja con el tema a la bandeja).
  final String? sub;
}

/// Que pide el Auto-Curador para una estacion corta: el sub-genero en visto
/// con menos canciones, con sus terminos canonicos.
StationFeed? stationFeedFor(
  String key,
  List<String> subs,
  Map<String, int> library, {
  Map<String, Map<String, int>> extra = const <String, Map<String, int>>{},
}) {
  if (subs.isEmpty) return null;
  final UniversalStation? u = universalStation(key);
  StationFeed? best;
  int bestN = 1 << 30;
  for (final String s in subs) {
    StationSub? def;
    for (final StationSub d in u?.subs ?? const <StationSub>[]) {
      if (d.label == s) def = d;
    }
    if (def == null) {
      final int n = library[s] ?? 0;
      if (n < bestN) {
        bestN = n;
        best = StationFeed(s, null);
      }
      continue;
    }
    int n = extra[key]?[s] ?? 0;
    String? folder;
    int top = -1;
    for (final MapEntry<String, int> e in library.entries) {
      final MapEntry<String, String>? m = stationSubOf(e.key);
      if (m == null || m.key != key || m.value != s) continue;
      n += e.value;
      if (e.value > top) {
        top = e.value;
        folder = e.key;
      }
    }
    if (n < bestN) {
      bestN = n;
      // 3.1.67: sin carpeta previa, destino canonico <Estacion>/<Sub>.
      best = StationFeed(
        folder ?? stationCanonicalRel(key, s),
        def.terms,
        def.label,
      );
    }
  }
  return best;
}

/// Titulo visible de una clave de estacion.
String stationTitleOf(String key) {
  final UniversalStation? u = universalStation(key);
  if (u != null) return u.title;
  final String? old = _legacyTitles[key];
  if (old != null) return old;
  return key.startsWith('g:') ? key.substring(2) : key;
}

String stationPathKey(String p) =>
    p.replaceAll('\\', '/').replaceAll(RegExp(r'/+'), '/').toLowerCase();

class GenreSession {
  const GenreSession({
    this.subGenresChecked = const <String>[],
    this.currentTrackPath,
    this.positionMs = 0,
    this.remainingQueuePaths = const <String>[],
    this.playedPaths = const <String>[],
    this.shuffleEnabled = true,
    this.updatedAt,
  });

  final List<String> subGenresChecked;
  final String? currentTrackPath;
  final int positionMs;
  final List<String> remainingQueuePaths;
  final List<String> playedPaths;
  final bool shuffleEnabled;
  final String? updatedAt;

  GenreSession copyWith({
    List<String>? subGenresChecked,
    String? currentTrackPath,
    bool clearCurrent = false,
    int? positionMs,
    List<String>? remainingQueuePaths,
    List<String>? playedPaths,
  }) => GenreSession(
    subGenresChecked: subGenresChecked ?? this.subGenresChecked,
    currentTrackPath: clearCurrent
        ? null
        : (currentTrackPath ?? this.currentTrackPath),
    positionMs: positionMs ?? this.positionMs,
    remainingQueuePaths: remainingQueuePaths ?? this.remainingQueuePaths,
    playedPaths: playedPaths ?? this.playedPaths,
    shuffleEnabled: shuffleEnabled,
    updatedAt: DateTime.now().toIso8601String(),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'subGenresChecked': subGenresChecked,
    'currentTrackPath': currentTrackPath,
    'positionMs': positionMs,
    'remainingQueuePaths': remainingQueuePaths,
    'playedPaths': playedPaths,
    'shuffleEnabled': shuffleEnabled,
    'updatedAt': updatedAt ?? DateTime.now().toIso8601String(),
  };

  static List<String> _list(Object? v) => <String>[
    if (v is List)
      for (final Object? e in v)
        if (e is String && e.isNotEmpty) e,
  ];

  static GenreSession fromJson(Object? raw) {
    if (raw is! Map) return const GenreSession();
    final Object? cur = raw['currentTrackPath'];
    final Object? pos = raw['positionMs'];
    final Object? up = raw['updatedAt'];
    return GenreSession(
      subGenresChecked: _list(raw['subGenresChecked']),
      currentTrackPath: cur is String && cur.isNotEmpty ? cur : null,
      positionMs: pos is int && pos > 0 ? pos : 0,
      remainingQueuePaths: _list(raw['remainingQueuePaths']),
      playedPaths: _list(raw['playedPaths']),
      shuffleEnabled: raw['shuffleEnabled'] != false,
      updatedAt: up is String ? up : null,
    );
  }
}

/// Archivo `gatomix_genre_sessions.json`: `{active, stations: {clave: sesion}}`.
class GenreSessionDoc {
  GenreSessionDoc({this.active, Map<String, GenreSession>? stations})
    : stations = stations ?? <String, GenreSession>{};

  String? active;
  final Map<String, GenreSession> stations;

  static GenreSessionDoc read(String path) {
    final Object? raw = SessionStore.readJson(path);
    final GenreSessionDoc d = GenreSessionDoc();
    if (raw is! Map) return d;
    final Object? a = raw['active'];
    d.active = a is String && a.isNotEmpty ? a : null;
    final Object? s = raw['stations'];
    if (s is Map) {
      for (final MapEntry<dynamic, dynamic> e in s.entries) {
        if (e.key is String) {
          d.stations[e.key as String] = GenreSession.fromJson(e.value);
        }
      }
    }
    // 3.1.68: sesiones de antes (schema 1) no conocian "Todas" en
    // Ochenteras, Tropical y Baladas: entra en visto por defecto.
    final Object? sc = raw['schema'];
    if (sc is! int || sc < 2) {
      for (final String k in kTodasAddedIn3168) {
        final GenreSession? g = d.stations[k];
        if (g == null ||
            g.subGenresChecked.isEmpty ||
            g.subGenresChecked.contains('Todas') ||
            !g.subGenresChecked.every((String x) => isStationSub(k, x))) {
          continue;
        }
        d.stations[k] = GenreSession(
          subGenresChecked: <String>[...g.subGenresChecked, 'Todas'],
          currentTrackPath: g.currentTrackPath,
          positionMs: g.positionMs,
          remainingQueuePaths: g.remainingQueuePaths,
          playedPaths: g.playedPaths,
          shuffleEnabled: g.shuffleEnabled,
          updatedAt: g.updatedAt,
        );
      }
    }
    return d;
  }

  /// Escritura atomica (.tmp y rename) en la carpeta de datos de la app.
  Future<void> write(String path) {
    try {
      File(path).parent.createSync(recursive: true);
    } catch (_) {}
    return SessionStore.writeJson(path, <String, dynamic>{
      'schema': 2,
      'active': active,
      'stations': <String, dynamic>{
        for (final MapEntry<String, GenreSession> e in stations.entries)
          e.key: e.value.toJson(),
      },
    });
  }
}

class StationPlan {
  const StationPlan({
    required this.currentTrackPath,
    required this.positionMs,
    required this.queue,
    required this.played,
    required this.resumed,
  });

  /// Pista con la que arranca (null = la primera de [queue]).
  final String? currentTrackPath;
  final int positionMs;
  final List<String> queue;
  final List<String> played;

  /// true si continua una sesion guardada (misma pista y segundo).
  final bool resumed;
}

/// Arma la cola de una estacion con [all] (pistas de las sub-carpetas en
/// visto). Si hay sesion guardada, sigue en su pista y segundo, respeta el
/// orden restante y agrega al final (barajadas) las pistas nuevas. Nunca
/// repite [GenreSession.playedPaths]; solo lo reinicia cuando ya sono el
/// 100 % de la estacion.
/// 3.2.28: con [bpmOf] (y [keyOf]/[dnaOf]) las pistas nuevas salen en orden
/// de energia pareja (ver [stationSmartShuffle]); la cola guardada no se
/// reordena.
StationPlan planStation(
  List<String> all,
  GenreSession? saved, {
  Random? rng,
  bool Function(String path)? exists,
  double Function(String path)? bpmOf,
  String? Function(String path)? keyOf,
  HarmonicDna? Function(String path)? dnaOf,
}) {
  final Random r = rng ?? Random();
  final bool Function(String) ok = exists ?? (String p) => true;
  final Map<String, String> byKey = <String, String>{
    for (final String p in all) stationPathKey(p): p,
  };
  final Set<String> played = <String>{
    for (final String p in saved?.playedPaths ?? const <String>[])
      if (byKey.containsKey(stationPathKey(p))) stationPathKey(p),
  };
  String? current;
  int pos = 0;
  final String? sc = saved?.currentTrackPath;
  if (sc != null) {
    final String k = stationPathKey(sc);
    if (byKey.containsKey(k) && !played.contains(k) && ok(byKey[k]!)) {
      current = byKey[k];
      pos = saved!.positionMs;
    }
  }
  final Set<String> used = <String>{
    ...played,
    if (current != null) stationPathKey(current),
  };
  final List<String> queue = <String>[];
  for (final String p in saved?.remainingQueuePaths ?? const <String>[]) {
    final String k = stationPathKey(p);
    if (byKey.containsKey(k) && used.add(k)) queue.add(byKey[k]!);
  }
  final List<String> fresh = <String>[
    for (final MapEntry<String, String> e in byKey.entries)
      if (!used.contains(e.key)) e.value,
  ]..sort();
  // 3.1.70: Smart Shuffle (Fisher-Yates + artistas dispersos), tambien en
  // la union con lo que ya estaba en la cola.
  queue.addAll(
    stationSmartShuffle(
      fresh,
      r,
      after: queue.isNotEmpty ? queue.last : current,
      bpmOf: bpmOf,
      keyOf: keyOf,
      dnaOf: dnaOf,
    ),
  );
  if (current == null && queue.isEmpty && all.isNotEmpty) {
    // Ya sono el 100 %: se reinicia lo sonado y se baraja todo de nuevo.
    final List<String> again = stationSmartShuffle(
      byKey.values.toList()..sort(),
      r,
      bpmOf: bpmOf,
      keyOf: keyOf,
      dnaOf: dnaOf,
    );
    return StationPlan(
      currentTrackPath: null,
      positionMs: 0,
      queue: again,
      played: const <String>[],
      resumed: false,
    );
  }
  return StationPlan(
    currentTrackPath: current,
    positionMs: pos,
    queue: queue,
    played: <String>[
      for (final String p in saved?.playedPaths ?? const <String>[])
        if (played.contains(stationPathKey(p))) p,
    ],
    resumed: current != null,
  );
}

/// 3.1.70: artista de `Artista - Titulo` (sin acentos, minusculas, sin
/// "feat."). Vacio si el nombre no lo trae: no cuenta como repetido.
String stationArtistKey(String path) {
  final String t = stationTrackTitle(path);
  final int i = t.indexOf(' - ');
  if (i <= 0) return '';
  String a = stationFold(t.substring(0, i));
  for (final String cut in const <String>[
    ' feat',
    ' ft.',
    ' ft ',
    ' featuring',
    ' & ',
    ' x ',
    ' y ',
    ',',
  ]) {
    final int j = a.indexOf(cut);
    if (j > 0) a = a.substring(0, j);
  }
  return a.trim();
}

/// 3.2.1: largo de los micro-bloques de sub-genero/idioma en las estaciones.
const int kStationBlockMin = 3;
const int kStationBlockMax = 4;

/// 3.2.28: salto maximo de BPM entre dos pistas vecinas de una estacion
/// (8 % del BPM de la anterior) mientras quede alternativa.
const double kStationBpmStep = 0.08;

/// 3.2.28: pistas de la estacion cuyo BPM y ADN se calientan antes de
/// armar la cola (la cola guardada primero y una muestra pareja del resto).
const int kStationWarmWindow = 96;

/// 3.2.28: true si [b] queda a <= [kStationBpmStep] de [a]. Sin BPM de
/// alguna de las dos no hay regla (true).
bool stationBpmNear(double a, double b) {
  if (a <= 0 || b <= 0) return true;
  return (b - a).abs() <= a * kStationBpmStep + 1e-9;
}

/// 3.2.28: ventana a calentar (BPM y ADN) antes de [planStation]: pista y
/// cola guardadas primero (hasta la mitad) y luego una muestra pareja de
/// [all], sin azar y sin repetir, hasta [limit] pistas.
List<String> stationWarmWindow(
  List<String> all,
  GenreSession? saved, {
  int limit = kStationWarmWindow,
}) {
  final List<String> out = <String>[];
  if (limit <= 0) return out;
  final Set<String> seen = <String>{};
  void add(String p) {
    if (p.isNotEmpty && out.length < limit && seen.add(stationPathKey(p))) {
      out.add(p);
    }
  }

  final String? cur = saved?.currentTrackPath;
  if (cur != null) add(cur);
  for (final String p in saved?.remainingQueuePaths ?? const <String>[]) {
    if (out.length >= limit ~/ 2) break;
    add(p);
  }
  if (all.isNotEmpty) {
    final int step = all.length <= limit ? 1 : all.length ~/ limit;
    for (int i = 0; i < all.length && out.length < limit; i += step) {
      add(all[i]);
    }
  }
  return out;
}

/// 3.2.28: semilla del Smart Shuffle. Con [bpmOf] y 2 o mas BPM conocidos
/// es el orden armonico existente ([buildHarmonicShuffle]: BPM, Camelot,
/// ADN de energia y micro-bloques); lo que ese orden no devuelve (karaoke,
/// duplicados, [after]) va al final para no perder ninguna pista. Sin eso,
/// Fisher-Yates como en 3.1.70 (mismo uso de [rng]). El bool dice si la
/// semilla es armonica.
(List<String>, bool) _stationSeed(
  List<String> tracks,
  Random rng, {
  String? after,
  String? Function(String path)? blockOf,
  double Function(String path)? bpmOf,
  String? Function(String path)? keyOf,
  HarmonicDna? Function(String path)? dnaOf,
}) {
  if (bpmOf != null) {
    int known = 0;
    for (final String p in tracks) {
      if (bpmOf(p) > 0 && ++known >= 2) break;
    }
    if (known >= 2) {
      final List<String> seed = List<String>.from(
        buildHarmonicShuffle(
          tracks,
          bpmOf,
          keyOf: keyOf,
          continueFrom: after,
          rng: rng,
          subOf: blockOf ?? trackBlockKey,
          dnaOf: dnaOf,
        ).tracks,
      );
      final Set<String> got = <String>{
        for (final String p in seed) stationPathKey(p),
      };
      for (final String p in tracks) {
        if (got.add(stationPathKey(p))) seed.add(p);
      }
      return (seed, true);
    }
  }
  final List<String> pool = List<String>.from(tracks);
  for (int i = pool.length - 1; i > 0; i--) {
    final int j = rng.nextInt(i + 1);
    final String t = pool[i];
    pool[i] = pool[j];
    pool[j] = t;
  }
  return (pool, false);
}

/// 3.1.70 Smart Shuffle: Fisher-Yates y despues dispersion de artistas, para
/// que nunca suenen dos canciones del mismo artista seguidas (salvo que ya
/// no quede otra). [after] es la pista que suena justo antes de la primera.
/// 3.2.1: micro-bloques de 3-4 pistas del mismo sub-genero/idioma
/// ([blockOf], por defecto [trackBlockKey]) antes de rotar al siguiente,
/// sin romper la regla de artistas. Con menos de dos bloques distintos el
/// orden es el de la 3.1.70.
/// 3.2.28: con [bpmOf] (2 o mas BPM conocidos) la semilla es el orden
/// armonico y cada paso prefiere una pista a <= 8 % de BPM de la anterior:
/// primero la del bloque que toca, si no hay, otra cercana (no se fuerza la
/// rotacion de bloque con un salto > 8 %), y solo sin alternativa se salta.
/// La regla de artistas manda siempre. Sin [bpmOf] el orden es el de 3.2.1.
List<String> stationSmartShuffle(
  List<String> tracks,
  Random rng, {
  String? after,
  String? Function(String path)? blockOf,
  double Function(String path)? bpmOf,
  String? Function(String path)? keyOf,
  HarmonicDna? Function(String path)? dnaOf,
}) {
  final (List<String> pool, bool harmonic) = _stationSeed(
    tracks,
    rng,
    after: after,
    blockOf: blockOf,
    bpmOf: bpmOf,
    keyOf: keyOf,
    dnaOf: dnaOf,
  );
  if (pool.isEmpty) return pool;
  final double Function(String path)? bo = harmonic ? bpmOf : null;
  final List<double> bpms = <double>[
    for (final String p in pool) bo == null ? 0 : bo(p),
  ];
  double lastBpm = bo != null && after != null ? bo(after) : 0;
  final List<String> keys = <String>[
    for (final String p in pool) stationArtistKey(p),
  ];
  final Map<String, int> left = <String, int>{};
  for (final String k in keys) {
    if (k.isNotEmpty) left[k] = (left[k] ?? 0) + 1;
  }
  int maxLeft = 0;
  for (final int v in left.values) {
    if (v > maxLeft) maxLeft = v;
  }
  final String? Function(String path) bf = blockOf ?? trackBlockKey;
  final List<String> blocks = <String>[
    for (final String p in pool) bf(p) ?? '',
  ];
  final Map<String, int> blockLeft = <String, int>{};
  for (final String bk in blocks) {
    blockLeft[bk] = (blockLeft[bk] ?? 0) + 1;
  }
  final bool grouped =
      blockLeft.length >= 2 && blockLeft.keys.any((String k) => k.isNotEmpty);
  // La pista anterior abre el bloque: siguen 2 mas de su sub-genero.
  String? curBlock = grouped && after != null ? (bf(after) ?? '') : null;
  int run = curBlock == null ? 0 : 1;
  int target = curBlock == null ? 0 : kStationBlockMin;
  final List<int> idx = List<int>.generate(pool.length, (int i) => i);
  final List<String> out = <String>[];
  String last = after == null ? '' : stationArtistKey(after);
  int scan(bool Function(int at) okAt) {
    for (int q = 0; q < idx.length; q++) {
      if (okAt(idx[q])) return q;
    }
    return -1;
  }

  while (idx.isNotEmpty) {
    final int r = idx.length;
    // Un artista con mas de la mitad de lo que queda tiene que ir ya.
    String? force;
    if (maxLeft * 2 > r) {
      maxLeft = 0;
      for (final MapEntry<String, int> e in left.entries) {
        if (e.value > maxLeft) maxLeft = e.value;
        if (force == null && e.key != last && e.value * 2 > r) force = e.key;
      }
    }
    final String? forced = force;
    bool artistOk(String k) =>
        forced != null ? k == forced : (k.isEmpty || k != last);
    bool near(int at) => stationBpmNear(lastBpm, bpms[at]);
    int pick = -1;
    if (grouped && forced == null) {
      // Bloque abierto (< meta): sigue el mismo sub-genero; bloque cumplido:
      // rota a otro. Siempre sin repetir artista.
      final bool stay = curBlock != null && run < target;
      bool blockOk(int at) {
        final bool same = blocks[at] == curBlock;
        return stay ? same : !same;
      }

      // 3.2.28: sin BPM [near] siempre es true (orden de 3.2.1).
      pick = scan((int at) => artistOk(keys[at]) && blockOk(at) && near(at));
      if (pick < 0 && harmonic) {
        // 3.2.28: el bloque que toca saltaria > 8 %: otra cercana.
        pick = scan((int at) => artistOk(keys[at]) && near(at));
      }
      if (pick < 0 && harmonic) {
        pick = scan((int at) => artistOk(keys[at]) && blockOk(at));
      }
    }
    if (pick < 0 && harmonic) {
      pick = scan((int at) => artistOk(keys[at]) && near(at));
    }
    if (pick < 0) pick = scan((int at) => artistOk(keys[at]));
    if (pick < 0) pick = 0;
    final int at = idx.removeAt(pick);
    out.add(pool[at]);
    if (bpms[at] > 0) lastBpm = bpms[at];
    final String k = keys[at];
    if (k.isNotEmpty) {
      final int n = left[k]! - 1;
      if (n <= 0) {
        left.remove(k);
      } else {
        left[k] = n;
      }
    }
    last = k;
    if (grouped) {
      final String bk = blocks[at];
      if (bk == curBlock) {
        run++;
      } else {
        curBlock = bk;
        run = 1;
        target = _stationBlockTarget(blockLeft[bk]!, rng);
      }
      blockLeft[bk] = blockLeft[bk]! - 1;
    }
  }
  return out;
}

/// 3.2.1: largo del micro-bloque que abre un sub-genero con [rem] pistas:
/// 3 o 4 al azar, prefiriendo el que no deja un resto de 1, 2 o 5 (que no
/// se puede partir en bloques de 3-4). Con 4 o menos van todas juntas.
int _stationBlockTarget(int rem, Random rng) {
  if (rem <= kStationBlockMax) return rem;
  bool bad(int l) => l == 1 || l == 2 || l == 5;
  int t = kStationBlockMin + rng.nextInt(2);
  if (bad(rem - t)) {
    final int alt = t == kStationBlockMin ? kStationBlockMax : kStationBlockMin;
    if (!bad(rem - alt)) t = alt;
  }
  return t;
}

/// Cambio de pista en Live DJ: la anterior pasa a sonadas y la sesion
/// guarda la nueva, segundo 0 y la cola restante.
GenreSession stationTrackChanged(
  GenreSession s, {
  required String? previous,
  required String? next,
  required List<String> queue,
}) {
  final List<String> played = List<String>.from(s.playedPaths);
  if (previous != null &&
      !played.any(
        (String p) => stationPathKey(p) == stationPathKey(previous),
      )) {
    played.add(previous);
  }
  return s.copyWith(
    currentTrackPath: next,
    clearCurrent: next == null,
    positionMs: 0,
    remainingQueuePaths: queue,
    playedPaths: played,
  );
}

String stationClock(int ms) {
  final int t = ms < 0 ? 0 : ms ~/ 1000;
  final String s = (t % 60).toString().padLeft(2, '0');
  return '${t ~/ 60}:$s';
}

String stationTrackTitle(String path) {
  final String n = path.replaceAll('\\', '/').split('/').last;
  final int dot = n.lastIndexOf('.');
  return dot > 0 ? n.substring(0, dot) : n;
}

// ---- 3.1.67 Clasificador por cancion para carpetas mezcladas ("shampoo") ----

/// Nombre del indice rapido por cancion (`path + mtime`).
/// 3.2.35: `gatomix_track_genre_index.json` (constante en brand_paths.dart);
/// el heredado `difogo_track_genre_index.json` se copia si el nuevo no existe.

/// 3.1.70: version del clasificador guardada en cada entrada del indice.
/// 3.2.1: 3 (normalizacion de dieresis: niveles 2-4 se recalculan una vez).
const int kTrackGenreIndexVersion = 3;

String _normWords(String s) => stationFold(
  s,
).replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim().replaceAll(RegExp(r' +'), ' ');

const Set<String> _genericExact = <String>{
  '',
  'music',
  'musica',
  'mi musica',
  'my music',
  'mis canciones',
  'canciones',
  'songs',
  'mix',
  'mixes',
  'mezcla',
  'mezclas',
  'otros',
  'other',
  'others',
  'temas',
  'audio',
  'audios',
  'mp3',
  'todo',
  'general',
  'escritorio',
  'desktop',
};

const List<String> _genericParts = <String>[
  'shampoo',
  'descarga',
  'download',
  'nueva carpeta',
  'new folder',
  'varios',
  'various',
  'misc',
  'sin clasificar',
  'unsorted',
  'whatsapp',
  'telegram',
];

/// 3.1.67: carpeta generica (Descargas, Music, Mi Musica, Mix, Varios,
/// Nueva carpeta, raiz...): su nombre no dice el genero y cada cancion se
/// clasifica sola.
bool isGenericMusicFolder(String name) {
  final String f = _normWords(name);
  if (_genericExact.contains(f)) return true;
  final String padded = ' $f ';
  return _genericParts.any((String p) => padded.contains(p));
}

/// Estacion y sub-genero de una cancion, con el nivel de la cascada que
/// decidio (0 = registro propio/carpeta canonica, 1 = tags en cache,
/// 2 = lexico del nombre, 3 = carpeta contenedora, 4 = fallback).
class TrackGenre {
  const TrackGenre(this.stationId, this.subGenreId, this.level);

  /// null = sin estacion (va al bucket "Todas" de la estacion activa).
  final String? stationId;
  final String? subGenreId;
  final int level;

  bool get known => stationId != null && subGenreId != null;

  @override
  String toString() => '$stationId/$subGenreId@$level';
}

/// Tags que ya estan en cache (nunca se decodifica para clasificar).
/// 3.2.4: [lang] (`es`/`en` de Whisper) desempata Rock/Baladas "Todas".
class TrackTagHint {
  const TrackTagHint({this.genre, this.year, this.lang});
  final String? genre;
  final int? year;
  final String? lang;

  bool get isEmpty =>
      (genre == null || genre!.trim().isEmpty) &&
      (year == null || year! <= 0) &&
      lang != 'es' &&
      lang != 'en';
}

/// 3.2.4: [TrackTagHint] desde la cache en memoria `dna[path]` (genero y
/// anio ID3 del backfill, idioma de Whisper). Nunca lee el disco.
TrackTagHint? trackTagHintOf(String path) {
  final TrackDnaEntry? d = peekTrackDna(path);
  if (d == null) return null;
  final TrackTagHint h = TrackTagHint(
    genre: d.genre,
    year: d.year,
    lang: d.lang,
  );
  return h.isEmpty ? null : h;
}

class _ArtistRule {
  const _ArtistRule(this.station, this.sub, this.names);
  final String station;
  final String sub;
  final List<String> names;
}

/// Lexico embebido de artistas por sub-genero canonico (nombres en
/// minusculas, sin tildes; se normalizan al cargar).
const List<_ArtistRule> _artistRules = <_ArtistRule>[
  _ArtistRule('tropical', 'Salsa', <String>[
    'marc anthony',
    'hector lavoe',
    'willie colon',
    'celia cruz',
    'oscar de leon',
    'gilberto santa rosa',
    'victor manuelle',
    'grupo niche',
    'joe arroyo',
    'ruben blades',
    'eddie santiago',
    'frankie ruiz',
    'jerry rivera',
    'tito nieves',
    'el gran combo',
    'el gran combo de puerto rico',
    'la india',
    'tito rojas',
    'guayacan orquesta',
    'fruko y sus tesos',
    'rey ruiz',
    'luis enrique',
    'maelo ruiz',
    'tony vega',
    'ismael rivera',
    'ray barretto',
    'sonora poncena',
    'cheo feliciano',
    'johnny pacheco',
    'lalo rodriguez',
    'charlie aponte',
    'la sonora carruseles',
    'orquesta de la luz',
    'n samble',
    'sonora carruseles',
  ]),
  _ArtistRule('tropical', 'Cumbia', <String>[
    'los angeles azules',
    'la sonora dinamita',
    'sonora dinamita',
    'rodolfo aicardi',
    'los mirlos',
    'aniceto molina',
    'celso pina',
    'grupo canaveral',
    'los wawanco',
    'lisandro meza',
    'pastor lopez',
    'los hispanos',
    'los graduados',
    'la sonora santanera',
    'sonora santanera',
    'grupo 5',
    'agua marina',
    'armonia 10',
    'corazon serrano',
    'los palmeras',
    'damas gratis',
    'la nueva luna',
    'los askis',
    'alberto pedraza',
    'los karkiks',
    'margarita la diosa de la cumbia',
  ]),
  _ArtistRule('tropical', 'Merengue', <String>[
    'juan luis guerra',
    'wilfrido vargas',
    'los hermanos rosario',
    'elvis crespo',
    'olga tanon',
    'eddy herrera',
    'sergio vargas',
    'fernando villalona',
    'johnny ventura',
    'tono rosario',
    'milly quezada',
    'oro solido',
    'kinito mendez',
    'jossie esteban',
    'la patrulla 15',
    'rikarena',
    'proyecto uno',
    'grupo mania',
    'los vecinos',
    'bonny cepeda',
    'cuco valoy',
    'las chicas del can',
    'banda gorda',
  ]),
  _ArtistRule('tropical', 'Bachatas', <String>[
    'romeo santos',
    'aventura',
    'prince royce',
    'frank reyes',
    'anthony santos',
    'antony santos',
    'raulin rodriguez',
    'monchy alexandra',
    'monchy y alexandra',
    'zacarias ferreira',
    'hector acosta',
    'luis vargas',
    'joe veras',
    'xtreme',
    'grupo extra',
    'elvis martinez',
    'yoskar sarante',
    'toby love',
    'kiko rodriguez',
    'daniel santacruz',
    'luis miguel del amargue',
  ]),
  _ArtistRule('tropical', 'Vallenatos', <String>[
    'carlos vives',
    'diomedes diaz',
    'binomio de oro',
    'binomio de oro de america',
    'jorge celedon',
    'silvestre dangond',
    'los diablitos',
    'peter manjarres',
    'ivan villazon',
    'los inquietos',
    'los inquietos del vallenato',
    'los gigantes del vallenato',
    'rafael orozco',
    'poncho zuleta',
    'los hermanos zuleta',
    'martin elias',
    'kaleth morales',
    'felipe pelaez',
    'los betos',
    'nelson velasquez',
    'otto serge',
    'miguel morales',
    'jean carlos centeno',
    'los chiches del vallenato',
  ]),
  _ArtistRule('rock', 'Rock Clásico Español', <String>[
    'soda stereo',
    'gustavo cerati',
    'heroes del silencio',
    'enanitos verdes',
    'hombres g',
    'caifanes',
    'mana',
    'los prisioneros',
    'aterciopelados',
    'los fabulosos cadillacs',
    'charly garcia',
    'fito paez',
    'la ley',
    'los bunkers',
    'babasonicos',
    'los rodriguez',
    'el tri',
    'molotov',
    'cafe tacvba',
    'cafe tacuba',
    'miguel mateos',
    'virus',
    'radio futura',
    'duncan dhu',
    'los suaves',
    'extremoduro',
    'fito y fitipaldis',
    'los secretos',
    'la union',
    'enrique bunbury',
    'bunbury',
    'jaguares',
    'los toreros muertos',
    'el ultimo de la fila',
    'los abuelos de la nada',
    'patricio rey y sus redonditos de ricota',
    'los redondos',
    'los enanitos verdes',
    'vilma palma e vampiros',
    'los auténticos decadentes',
    'los autenticos decadentes',
    'la oreja de van gogh',
    'mago de oz',
  ]),
  _ArtistRule('rock', 'Rock Clásico en Inglés', <String>[
    'the beatles',
    'the rolling stones',
    'rolling stones',
    'led zeppelin',
    'pink floyd',
    'queen',
    'ac dc',
    'acdc',
    'the who',
    'the doors',
    'eagles',
    'the eagles',
    'creedence clearwater revival',
    'creedence',
    'ccr',
    'lynyrd skynyrd',
    'aerosmith',
    'kiss',
    'deep purple',
    'bon jovi',
    'guns n roses',
    'scorpions',
    'def leppard',
    'dire straits',
    'journey',
    'boston',
    'foreigner',
    'toto',
    'van halen',
    'eric clapton',
    'jimi hendrix',
    'the police',
    'u2',
    'bruce springsteen',
    'the clash',
    'rush',
    'supertramp',
    'styx',
    'kansas',
    'fleetwood mac',
    'the kinks',
    'the animals',
    'santana',
    'red hot chili peppers',
    'oasis',
    'the cranberries',
    'r e m',
    'rem',
    'the cure',
  ]),
  _ArtistRule('rock', 'Heavy Metal', <String>[
    'metallica',
    'iron maiden',
    'black sabbath',
    'judas priest',
    'megadeth',
    'slayer',
    'ozzy osbourne',
    'dio',
    'motorhead',
    'pantera',
    'anthrax',
    'manowar',
    'helloween',
    'sepultura',
    'rata blanca',
    'warcry',
    'baron rojo',
    'slipknot',
    'system of a down',
    'korn',
    'avenged sevenfold',
    'testament',
    'accept',
    'saxon',
    'rammstein',
    'stratovarius',
    'blind guardian',
    'dream theater',
    'tierra santa',
    'angeles del infierno',
    'obus',
  ]),
  _ArtistRule('rock', 'Grunge', <String>[
    'nirvana',
    'pearl jam',
    'soundgarden',
    'alice in chains',
    'stone temple pilots',
    'foo fighters',
    'silverchair',
    'bush',
    'temple of the dog',
    'mudhoney',
    'screaming trees',
    'audioslave',
    'candlebox',
    'mad season',
    'hole',
    'creed',
  ]),
  _ArtistRule('ochenteras', 'Disco', <String>[
    'bee gees',
    'donna summer',
    'gloria gaynor',
    'kc and the sunshine band',
    'kc the sunshine band',
    'village people',
    'boney m',
    'abba',
    'chic',
    'earth wind fire',
    'kool the gang',
    'kool and the gang',
    'sister sledge',
    'barry white',
    'the trammps',
    'sylvester',
    'irene cara',
    'lipps inc',
    'baccara',
    'gibson brothers',
    'la bionda',
    'patrick hernandez',
    'indeep',
    'the jacksons',
    'evelyn champagne king',
    'odyssey',
    'cerrone',
  ]),
  _ArtistRule('ochenteras', 'Pop', <String>[
    'michael jackson',
    'madonna',
    'cyndi lauper',
    'a ha',
    'duran duran',
    'wham',
    'george michael',
    'culture club',
    'tears for fears',
    'depeche mode',
    'pet shop boys',
    'phil collins',
    'whitney houston',
    'prince',
    'rick astley',
    'men at work',
    'the bangles',
    'roxette',
    'eurythmics',
    'spandau ballet',
    'simple minds',
    'a flock of seagulls',
    'mecano',
    'timbiriche',
    'flans',
    'menudo',
    'miguel bose',
    'yuri',
    'pandora',
    'laura branigan',
    'kim wilde',
    'belinda carlisle',
    'olivia newton john',
    'hall oates',
    'daryl hall john oates',
    'the human league',
    'soft cell',
    'alphaville',
    'talk talk',
    'level 42',
    'paul young',
    'kajagoogoo',
    'thompson twins',
    'nena',
    'falco',
    'gloria estefan',
    'miami sound machine',
    'stevie wonder',
    'kenny loggins',
    'tina turner',
    'janet jackson',
    'samantha fox',
    'tiffany',
    'debbie gibson',
    'new kids on the block',
    'the b 52s',
    'b 52s',
    'blondie',
  ]),
  _ArtistRule('ochenteras', 'Eurodance', <String>[
    'dj bobo',
    'haddaway',
    '2 unlimited',
    'snap',
    'corona',
    'ace of base',
    'culture beat',
    'la bouche',
    'real mccoy',
    'technotronic',
    'dr alban',
    'captain hollywood project',
    'cappella',
    'whigfield',
    'eiffel 65',
    'vengaboys',
    'alexia',
    'gala',
    'n trance',
    '2 brothers on the 4th floor',
    'fun factory',
    'masterboy',
    'black box',
    'modern talking',
    'sandra',
    'c c catch',
    'bad boys blue',
    'london boys',
    'savage',
    'ken laszlo',
    'valerie dore',
    'den harrow',
    'sabrina',
    'londonbeat',
    'army of lovers',
    'e type',
    'scatman john',
    'mr president',
    'outhere brothers',
    'aqua',
  ]),
  _ArtistRule('ochenteras', 'Punk', <String>[
    'ramones',
    'the ramones',
    'sex pistols',
    'misfits',
    'dead kennedys',
    'bad religion',
    'the damned',
    'buzzcocks',
    'the stooges',
    'black flag',
    'the exploited',
  ]),
  _ArtistRule('ochenteras', 'HipHop', <String>[
    'run dmc',
    'beastie boys',
    'grandmaster flash',
    'public enemy',
    'll cool j',
    'salt n pepa',
    'sugarhill gang',
    'eric b rakim',
    'kurtis blow',
    'mc hammer',
    'vanilla ice',
    'afrika bambaataa',
    'tone loc',
    'young mc',
  ]),
  _ArtistRule('ochenteras', 'Rock', <String>[
    'billy idol',
    'survivor',
    'europe',
    'twisted sister',
    'motley crue',
    'poison',
    'whitesnake',
    'ratt',
    'cinderella',
    'warrant',
    'skid row',
    'night ranger',
    'loverboy',
    'rick springfield',
    'pat benatar',
    'joan jett',
    'joan jett the blackhearts',
    'bryan adams',
    'john cougar mellencamp',
    'john mellencamp',
    'the outfield',
    'inxs',
    'tom petty',
  ]),
  _ArtistRule('baladas', 'En Español', <String>[
    'camilo sesto',
    'jose jose',
    'julio iglesias',
    'raphael',
    'roberto carlos',
    'jose luis perales',
    'rocio durcal',
    'juan gabriel',
    'nino bravo',
    'sandro',
    'leonardo favio',
    'ricardo montaner',
    'franco de vita',
    'ricardo arjona',
    'cristian castro',
    'luis miguel',
    'marco antonio solis',
    'los bukis',
    'alejandro sanz',
    'laura pausini',
    'eros ramazzotti',
    'chayanne',
    'ana gabriel',
    'pimpinela',
    'emmanuel',
    'braulio',
    'dyango',
    'jeanette',
    'los iracundos',
    'los terricolas',
    'los pasteles verdes',
    'myriam hernandez',
    'ednita nazario',
    'alejandro fernandez',
    'jose feliciano',
    'mijares',
    'manuel mijares',
    'pedro fernandez',
    'enrique iglesias',
    'rocio jurado',
    'isabel pantoja',
    'jose luis rodriguez',
    'el puma',
    'yolandita monge',
    'lucia mendez',
    'daniela romo',
    'paloma san basilio',
    'amanda miguel',
    'diego verdaguer',
    'leo dan',
    'palito ortega',
    'jose alfredo jimenez',
    'alberto plaza',
    'ricardo ceratto',
    'gianmarco',
    'tommy torres',
    'reik',
    'sin bandera',
    'jesse joy',
    'jesse y joy',
    'yuridia',
    'rio roma',
    'pablo alboran',
    'joan sebastian',
  ]),
  _ArtistRule('baladas', 'En Inglés', <String>[
    'celine dion',
    'mariah carey',
    'air supply',
    'chicago',
    'richard marx',
    'elton john',
    'michael bolton',
    'rod stewart',
    'toni braxton',
    'boyz ii men',
    'backstreet boys',
    'westlife',
    'adele',
    'lewis capaldi',
    'sam smith',
    'james blunt',
    'bonnie tyler',
    'the carpenters',
    'carpenters',
    'barry manilow',
    'extreme',
    'mr big',
    'cutting crew',
    'berlin',
    'peter cetera',
    'savage garden',
    'lionel richie',
    'kenny rogers',
    'bette midler',
    'roberta flack',
    'christopher cross',
    'eric carmen',
    'nazareth',
    'bread',
    'chris de burgh',
    'shania twain',
    'leann rimes',
    'vanessa williams',
    'all 4 one',
    'brian mcknight',
    'kenny g',
    'john legend',
  ]),
  _ArtistRule('momento', 'Reggaetón', <String>[
    'karol g',
    'bad bunny',
    'daddy yankee',
    'j balvin',
    'ozuna',
    'anuel aa',
    'anuel',
    'maluma',
    'nicky jam',
    'farruko',
    'myke towers',
    'rauw alejandro',
    'feid',
    'sech',
    'wisin',
    'yandel',
    'wisin y yandel',
    'wisin yandel',
    'don omar',
    'arcangel',
    'jhay cortez',
    'jhayco',
    'manuel turizo',
    'young miko',
    'tainy',
    'de la ghetto',
    'zion lennox',
    'zion y lennox',
    'plan b',
    'tito el bambino',
    'ivy queen',
    'lunay',
    'mora',
    'blessd',
    'ryan castro',
    'eladio carrion',
    'natti natasha',
    'becky g',
    'justin quiles',
    'lenny tavarez',
    'jowell randy',
    'jowell y randy',
    'chencho corleone',
    'kevvo',
    'dalex',
    'reykon',
    'piso 21',
    'tego calderon',
    'hector el father',
    'bryant myers',
    'cosculluela',
    'yng lvcas',
    'kenia os',
  ]),
  _ArtistRule('momento', 'Pop', <String>[
    'shakira',
    'camilo',
    'sebastian yatra',
    'morat',
    'aitana',
    'taylor swift',
    'dua lipa',
    'the weeknd',
    'harry styles',
    'olivia rodrigo',
    'billie eilish',
    'ed sheeran',
    'bruno mars',
    'ariana grande',
    'justin bieber',
    'miley cyrus',
    'sabrina carpenter',
    'rosalia',
    'carlos rivera',
    'mau y ricky',
    'mau ricky',
    'lali',
    'danna paola',
    'danna',
    'tini',
    'coldplay',
    'imagine dragons',
    'maroon 5',
    'katy perry',
    'lady gaga',
    'selena gomez',
    'shawn mendes',
    'doja cat',
    'benson boone',
    'chappell roan',
    'emilia',
    'maria becerra',
    'nathy peluso',
    'anitta',
    'tate mcrae',
    'gracie abrams',
    'teddy swims',
    'lord huron',
    'one direction',
    'jonas brothers',
    'charlie puth',
    'sia',
  ]),
  _ArtistRule('momento', 'HipHop', <String>[
    'drake',
    'kendrick lamar',
    'eminem',
    'travis scott',
    'kanye west',
    'j cole',
    '50 cent',
    'snoop dogg',
    'post malone',
    'cardi b',
    'nicki minaj',
    'lil nas x',
    'duki',
    'trueno',
    'residente',
    'calle 13',
    'canserbero',
    'c tangana',
    'bizarrap',
    'bzrp',
    'lil wayne',
    'jay z',
    'future',
    'lil baby',
    'tyler the creator',
    'a ap rocky',
    'asap rocky',
    'peso pluma',
    'natanael cano',
    'junior h',
    'fuerza regida',
  ]),
  _ArtistRule('momento', 'Electrónica', <String>[
    'david guetta',
    'calvin harris',
    'avicii',
    'tiesto',
    'martin garrix',
    'marshmello',
    'kygo',
    'alok',
    'the chainsmokers',
    'zedd',
    'skrillex',
    'daft punk',
    'swedish house mafia',
    'armin van buuren',
    'alan walker',
    'fred again',
    'peggy gou',
    'diplo',
    'major lazer',
    'deadmau5',
    'meduza',
    'fisher',
    'john summit',
    'dom dolla',
    'robin schulz',
    'felix jaehn',
    'lost frequencies',
    'clean bandit',
    'disclosure',
    'kungs',
  ]),
  _ArtistRule('momento', 'R&B', <String>[
    'sza',
    'beyonce',
    'rihanna',
    'usher',
    'chris brown',
    'alicia keys',
    'frank ocean',
    'h e r',
    'daniel caesar',
    'giveon',
    'summer walker',
    'bryson tiller',
    'jhene aiko',
    'khalid',
    'brent faiyaz',
    'ne yo',
    'victoria monet',
    'tems',
    'ella mai',
  ]),
  _ArtistRule('fiesta', 'Electro Fiesta & Guaracha', <String>[
    'dj peligro',
    'alex sensation',
    'el alfa',
    'dj kass',
  ]),
  _ArtistRule('nacional', 'Tecnocumbia', <String>[
    'sharon la hechicera',
    'delfin quishpe',
    'hipatia balseca',
    'widinson',
    'jaime enrique aymara',
    'yolanda la gringa',
    'gerardo moran',
    'jessica jaramillo',
    'tierra canela',
    'pepito el ninito',
  ]),
  _ArtistRule('nacional', 'Cumbia & Chicha Nacional', <String>[
    'angel guaraca',
    'maria de los angeles',
    'patricia gonzalez',
    'los hermanos nunez',
    'hermanos nunez',
    'grupo coctel',
    'aladino',
    'segundo rosero',
    'jaime guevara',
    'la toquilla',
  ]),
  _ArtistRule('nacional', 'Paseíto & Sanjuanito', <String>[
    'banda la chola',
    'los conquistadores',
    'nanda manachi',
    'juanita burbano',
    'bayron caicedo',
    'byron caicedo',
    'los chasquis',
  ]),
  _ArtistRule('nacional', 'Todas', <String>[
    'julio jaramillo',
    'olimpo cardenas',
    'carlos rubira infante',
    'azucar ecuador',
    'grupo azucar',
    'juan fernando velasco',
    'la bandida',
    'mirella cesa',
  ]),
];

/// Palabras clave del nombre de la pista (despues del lexico de artistas).
const List<List<String>> _keywordRules = <List<String>>[
  <String>['nacional', 'Tecnocumbia', 'tecnocumbia'],
  <String>['nacional', 'Cumbia & Chicha Nacional', 'chicha'],
  <String>['nacional', 'Paseíto & Sanjuanito', 'sanjuanito'],
  <String>['nacional', 'Paseíto & Sanjuanito', 'paseito'],
  <String>['nacional', 'Paseíto & Sanjuanito', 'pasacalle'],
  <String>['nacional', 'Todas', 'ecuador'],
  <String>['nacional', 'Todas', 'pasillo'],
  <String>['tropical', 'Salsa', 'salsa'],
  <String>['tropical', 'Cumbia', 'cumbia'],
  <String>['tropical', 'Merengue', 'merengue'],
  <String>['tropical', 'Bachatas', 'bachata'],
  <String>['tropical', 'Vallenatos', 'vallenato'],
  <String>['momento', 'Reggaetón', 'reggaeton'],
  <String>['momento', 'Reggaetón', 'perreo'],
  <String>['fiesta', 'Crossover & Hora Loca', 'hora loca'],
  <String>['fiesta', 'Crossover & Hora Loca', 'crossover'],
  <String>['fiesta', 'Crossover & Hora Loca', 'enganchados'],
  <String>['fiesta', 'Electro Fiesta & Guaracha', 'guaracha'],
  <String>['fiesta', 'Electro Fiesta & Guaracha', 'aleteo'],
  <String>['fiesta', 'Electro Fiesta & Guaracha', 'zapateo'],
  <String>['ochenteras', 'Eurodance', 'eurodance'],
  <String>['ochenteras', 'Eurodance', 'italo disco'],
  <String>['rock', 'Heavy Metal', 'heavy metal'],
  <String>['rock', 'Grunge', 'grunge'],
  <String>['baladas', 'En Español', 'balada'],
  <String>['baladas', 'En Inglés', 'love song'],
];

class _LexEntry {
  const _LexEntry(this.station, this.sub, this.name);
  final String station;
  final String sub;
  final String name;
}

List<_LexEntry>? _lexMulti;
Map<String, _LexEntry>? _lexSingle;

void _buildLexicon() {
  if (_lexMulti != null) return;
  final List<_LexEntry> multi = <_LexEntry>[];
  final Map<String, _LexEntry> single = <String, _LexEntry>{};
  void add(_ArtistRule r, String n) {
    if (n.isEmpty) return;
    final _LexEntry e = _LexEntry(r.station, r.sub, n);
    if (n.contains(' ')) {
      multi.add(e);
    } else {
      single.putIfAbsent(n, () => e);
    }
  }

  for (final _ArtistRule r in _artistRules) {
    for (final String raw in r.names) {
      final String n = _normWords(raw);
      add(r, n);
      if (n.startsWith('the ')) add(r, n.substring(4));
    }
  }
  // El nombre mas largo gana (Camilo Sesto antes que Camilo).
  multi.sort((_LexEntry a, _LexEntry b) => b.name.length - a.name.length);
  _lexMulti = multi;
  _lexSingle = single;
}

final RegExp _yearTag = RegExp(r'[\(\[]\s*((?:19[5-9]|20[0-4])\d)\s*[\)\]]');
final RegExp _bracketed = RegExp(r'[\(\[\{][^\)\]\}]*[\)\]\}]');
final RegExp _segmentCut = RegExp(r'\s+[-\u2013\u2014]+\s+|\s*_-_\s*');
final RegExp _chunkCut = RegExp(
  r'\s*(?:,|&|/|\+|;|\bfeat\b\.?|\bft\b\.?|\bx\b|\by\b|\band\b|\bcon\b|\bvs\b\.?)\s*',
);
final RegExp _leadNumber = RegExp(r'^\d{1,3}\s*[\.\)_-]?\s+');

String _stem(String path) {
  final String n = path.replaceAll('\\', '/').split('/').last;
  final int dot = n.lastIndexOf('.');
  return dot > 0 ? n.substring(0, dot) : n;
}

/// Ano entre parentesis en el nombre del archivo, p. ej. `(1982)`.
int? trackYearFromName(String path) {
  final RegExpMatch? m = _yearTag.firstMatch(_stem(path));
  return m == null ? null : int.parse(m.group(1)!);
}

/// Segmentos `Artista - Titulo` del nombre (sin parentesis ni numero de pista).
List<String> _segments(String path) {
  String s = _stem(path).replaceAll(_bracketed, ' ');
  s = s.replaceAll('_', ' ').trim();
  List<String> parts = s.split(_segmentCut);
  if (parts.length == 1 && s.contains('-')) parts = s.split('-');
  final List<String> out = <String>[];
  for (String p in parts) {
    p = p.trim().replaceFirst(_leadNumber, '');
    if (p.isEmpty || RegExp(r'^\d+$').hasMatch(p)) continue;
    out.add(p);
  }
  return out;
}

_LexEntry? _artistOf(String path) {
  _buildLexicon();
  // `Artista - Titulo`: gana el primer segmento con artista conocido (el
  // titulo no pisa al artista); dentro del segmento, el nombre mas largo.
  final List<String> segs = _segments(path);
  for (int i = 0; i < segs.length; i++) {
    final String seg = segs[i];
    _LexEntry? best;
    final String words = ' ${_normWords(seg)} ';
    for (final _LexEntry e in _lexMulti!) {
      if (words.contains(' ${e.name} ')) {
        best = e;
        break;
      }
    }
    // Nombres de una palabra solo en el primer segmento (artista): en el
    // titulo, "Survivor" o "Corona" no son artistas.
    for (final String c
        in i == 0 ? stationFold(seg).split(_chunkCut) : const <String>[]) {
      final _LexEntry? e = _lexSingle![_normWords(c)];
      if (e != null && (best == null || e.name.length > best.name.length)) {
        best = e;
      }
    }
    if (best != null) return best;
  }
  return null;
}

TrackGenre? _keywordOf(String path, int level) {
  final String words = ' ${_normWords(_stem(path))} ';
  for (final List<String> k in _keywordRules) {
    if (words.contains(' ${k[2]} ')) return TrackGenre(k[0], k[1], level);
  }
  return null;
}

/// Cancion de los 80: la estacion pasa a Ochenteras con su sub-genero.
TrackGenre _to80s(TrackGenre g) {
  if (g.stationId == 'rock') return TrackGenre('ochenteras', 'Rock', g.level);
  if (g.stationId != 'momento') return g;
  switch (g.subGenreId) {
    case 'HipHop':
      return TrackGenre('ochenteras', 'HipHop', g.level);
    case 'Electrónica':
      return TrackGenre('ochenteras', 'Eurodance', g.level);
    default:
      return TrackGenre('ochenteras', 'Pop', g.level);
  }
}

bool _is80s(int? y) => y != null && y >= 1980 && y <= 1989;

/// Slug ASCII de carpeta: `Música del Momento` -> `Musica_del_Momento`.
String stationSlug(String s) {
  const String from = 'áéíóúüñÁÉÍÓÚÜÑ';
  const String to = 'aeiouunAEIOUUN';
  final RegExp ok = RegExp(r'[A-Za-z0-9]');
  final StringBuffer b = StringBuffer();
  bool gap = false;
  for (final int r in s.runes) {
    String c = String.fromCharCode(r);
    final int i = from.indexOf(c);
    if (i >= 0) c = to[i];
    if (ok.hasMatch(c)) {
      if (gap && b.isNotEmpty) b.write('_');
      b.write(c);
      gap = false;
    } else {
      gap = true;
    }
  }
  return b.toString();
}

/// 3.1.67: carpeta canonica relativa de un sub-genero nuevo:
/// `Tropical/Salsa`, `Musica_del_Momento/Reggaeton`.
String stationCanonicalRel(String key, String sub) {
  final UniversalStation? u = universalStation(key);
  return '${stationSlug(u?.title ?? key)}/${stationSlug(sub)}';
}

/// Estacion y sub-genero de una carpeta canonica (`<Estacion>/<Sub>`).
MapEntry<String, String>? stationSubOfCanonical(String station, String sub) {
  final String a = stationSlug(station).toLowerCase();
  final String b = stationSlug(sub).toLowerCase();
  for (final UniversalStation u in kUniversalStations) {
    if (stationSlug(u.title).toLowerCase() != a) continue;
    for (final StationSub s in u.subs) {
      if (stationSlug(s.label).toLowerCase() == b) {
        return MapEntry<String, String>(u.key, s.label);
      }
    }
  }
  return null;
}

/// Carpeta donde se guarda una cancion nueva de [key] > [sub]: la carpeta
/// local que ya alimenta ese sub-genero (la mas grande) o, si no hay, la
/// ruta canonica `<root>/<Estacion>/<Sub>`. Nunca mueve archivos existentes.
String stationSaveDir(
  String root,
  String key,
  String sub, {
  Map<String, int> library = const <String, int>{},
}) {
  String? best;
  int top = -1;
  for (final MapEntry<String, int> e in library.entries) {
    final MapEntry<String, String>? m = stationSubOf(e.key);
    if (m == null || m.key != key || m.value != sub) continue;
    if (e.value > top) {
      top = e.value;
      best = e.key;
    }
  }
  final String sep = Platform.pathSeparator;
  final String rel = (best ?? stationCanonicalRel(key, sub)).replaceAll(
    '/',
    sep,
  );
  return '$root$sep$rel';
}

/// Sub-genero "Todas" / "Todas las Demas Nuevas" de una estacion (null si
/// la estacion no tiene bucket general).
String? stationFallbackSub(String key) {
  for (final StationSub s
      in universalStation(key)?.subs ?? const <StationSub>[]) {
    if (s.label.startsWith('Todas')) return s.label;
  }
  return null;
}

/// 3.1.67 Clasificador en cascada por cancion. Solo nombre de archivo,
/// carpetas y caches: nunca decodifica audio ni lee tags del disco.
class TrackGenreClassifier {
  const TrackGenreClassifier._();

  static TrackGenre classify(
    String path, {
    String? root,
    TrackTagHint? tags,
    double bpm = 0,
  }) {
    final List<String> dirs = _dirsUnder(path, root);
    // Nivel 0: carpeta canonica de DiFogo (<Estacion>/<Sub>/archivo).
    if (dirs.length >= 2) {
      final MapEntry<String, String>? c = stationSubOfCanonical(
        dirs[dirs.length - 2],
        dirs.last,
      );
      if (c != null) return TrackGenre(c.key, c.value, 0);
    }
    final int? year = tags?.year ?? trackYearFromName(path);
    // Nivel 1: genero + ano de los tags en cache.
    final String? tg = tags?.genre;
    if (tg != null && tg.trim().isNotEmpty) {
      final MapEntry<String, String>? m = stationSubOf(tg);
      if (m != null) {
        final TrackGenre g = TrackGenre(
          m.key,
          _saysLanguage(<String>[tg])
              ? m.value
              : _subForLang(m.key, m.value, tags?.lang),
          1,
        );
        return _is80s(tags?.year) ? _to80s(g) : g;
      }
    }
    // Nivel 2: lexico de artistas, palabras clave y ano del nombre.
    final _LexEntry? a = _artistOf(path);
    if (a != null) {
      final TrackGenre g = TrackGenre(a.station, a.sub, 2);
      return _is80s(year) ? _to80s(g) : g;
    }
    final TrackGenre? k = _keywordOf(path, 2);
    if (k != null) return _is80s(year) ? _to80s(k) : k;
    if (_is80s(year)) return const TrackGenre('ochenteras', 'Pop', 2);
    if (year != null && year >= 2018) {
      return const TrackGenre('momento', 'Todas las Demás Nuevas', 2);
    }
    // Nivel 3: carpeta contenedora especifica (la mas cercana).
    for (int i = dirs.length - 1; i >= 0; i--) {
      if (isGenericMusicFolder(dirs[i])) continue;
      final MapEntry<String, String>? m = _stationSubOfRaw(dirs[i]);
      if (m != null) {
        // 3.1.70: el idioma de las carpetas de arriba (Espanol/Ingles en
        // cualquier nivel) elige la variante de Baladas y Rock Clasico.
        // 3.2.4: si las carpetas no dicen el idioma, el de Whisper desempata.
        return TrackGenre(
          m.key,
          _saysLanguage(dirs)
              ? _subForLanguage(m.key, m.value, dirs)
              : _subForLang(m.key, m.value, tags?.lang),
          3,
        );
      }
    }
    // Nivel 4: BPM en cache o bucket "Todas" de la estacion activa.
    if (bpm >= 88 && bpm <= 100) {
      return const TrackGenre('momento', 'Reggaetón', 4);
    }
    if (bpm >= 118 && bpm <= 132) {
      return const TrackGenre('fiesta', 'Hits Bailables', 4);
    }
    return const TrackGenre(null, null, 4);
  }

  /// 3.2.4: sin idioma en carpetas ni en el genero, el de Whisper (`es`/
  /// `en`) elige la variante de Baladas (Todas o el Espanol por defecto) y
  /// de Rock (Todas o Rock Clasico). Heavy Metal y Grunge no cambian.
  static String _subForLang(String station, String sub, String? lang) {
    if (lang != 'es' && lang != 'en') return sub;
    final bool en = lang == 'en';
    if (station == 'baladas' &&
        (sub == 'Todas' || sub == 'En Inglés' || sub == 'En Español')) {
      return en ? 'En Inglés' : 'En Español';
    }
    if (station == 'rock' &&
        (sub == 'Todas' ||
            sub == 'Rock Clásico Español' ||
            sub == 'Rock Clásico en Inglés')) {
      return en ? 'Rock Clásico en Inglés' : 'Rock Clásico Español';
    }
    return sub;
  }

  /// 3.2.4: cierto si algun nombre ya dice el idioma (mismas palabras que
  /// [_subForLanguage]).
  static bool _saysLanguage(Iterable<String> names) {
    for (final String d in names) {
      final String f = stationFold(d);
      if (f.contains('ingl') ||
          f.contains('english') ||
          f.contains('espan') ||
          f.contains('spanish') ||
          f.contains('latin')) {
        return true;
      }
    }
    return false;
  }

  static String _subForLanguage(String station, String sub, List<String> dirs) {
    bool en = false;
    bool es = false;
    bool classic = false;
    for (final String d in dirs) {
      final String f = stationFold(d);
      if (f.contains('ingl') || f.contains('english')) en = true;
      if (f.contains('espan') || f.contains('spanish') || f.contains('latin')) {
        es = true;
      }
      if (f.contains('clasic') || f.contains('classic')) classic = true;
    }
    if (en == es) return sub;
    if (station == 'baladas' &&
        (sub == 'En Inglés' || sub == 'En Español' || sub == 'Todas')) {
      return en ? 'En Inglés' : 'En Español';
    }
    if (station == 'rock' &&
        (sub == 'Rock Clásico Español' ||
            sub == 'Rock Clásico en Inglés' ||
            (sub == 'Todas' && classic))) {
      return en ? 'Rock Clásico en Inglés' : 'Rock Clásico Español';
    }
    return sub;
  }

  /// Carpetas entre [root] y el archivo (sin la raiz ni el archivo).
  static List<String> _dirsUnder(String path, String? root) {
    final List<String> p = path
        .replaceAll('\\', '/')
        .split('/')
        .where((String s) => s.isNotEmpty)
        .toList();
    if (p.isNotEmpty) p.removeLast();
    if (root != null) {
      final List<String> r = root
          .replaceAll('\\', '/')
          .split('/')
          .where((String s) => s.isNotEmpty)
          .toList();
      int i = 0;
      while (i < r.length &&
          i < p.length &&
          r[i].toLowerCase() == p[i].toLowerCase()) {
        i++;
      }
      if (i == r.length) return p.sublist(i);
    }
    return p.length > 3 ? p.sublist(p.length - 3) : p;
  }
}

/// 3.2.1: estacion y sub-genero real de una pista para armar micro-bloques.
/// Carpeta especifica (Heavy Metal, Rock Ingles...) manda. Carpeta general
/// de una estacion ("Todas", p. ej. `Rock/` o `<Rock>/Todas`): el
/// diccionario de artistas y palabras clave da el sub-genero real si es de
/// la misma estacion; un artista desconocido se queda en "Todas". Sin
/// carpeta de estacion: la cascada de siempre. Solo nombres, sin disco.
TrackGenre stationTrackGenre(String path, {String? root}) {
  final List<String> dirs = TrackGenreClassifier._dirsUnder(path, root);
  if (dirs.length >= 2) {
    final MapEntry<String, String>? c = stationSubOfCanonical(
      dirs[dirs.length - 2],
      dirs.last,
    );
    if (c != null) {
      return c.value == stationFallbackSub(c.key)
          ? _refineFallbackTrack(path, c.key, c.value)
          : TrackGenre(c.key, c.value, 0);
    }
  }
  for (int i = dirs.length - 1; i >= 0; i--) {
    if (isGenericMusicFolder(dirs[i])) continue;
    final MapEntry<String, String>? m = _stationSubOfRaw(dirs[i]);
    if (m == null) continue;
    final String sub = TrackGenreClassifier._subForLanguage(
      m.key,
      m.value,
      dirs,
    );
    if (sub == stationFallbackSub(m.key)) {
      return _refineFallbackTrack(path, m.key, sub);
    }
    return TrackGenre(m.key, sub, 3);
  }
  return TrackGenreClassifier.classify(path, root: root);
}

TrackGenre _refineFallbackTrack(String path, String station, String fallback) {
  final _LexEntry? a = _artistOf(path);
  if (a != null) {
    if (a.station == station) return TrackGenre(station, a.sub, 2);
    // Rock ochentero del diccionario (Motley Crue, Bon Jovi de los 80...)
    // dentro de una carpeta Rock general: rock en ingles.
    if (station == 'rock' && a.station == 'ochenteras' && a.sub == 'Rock') {
      return const TrackGenre('rock', 'Rock Clásico en Inglés', 2);
    }
  }
  final TrackGenre? k = _keywordOf(path, 2);
  if (k != null && k.stationId == station) return k;
  return TrackGenre(station, fallback, 3);
}

final Map<String, String?> _blockKeyCache = <String, String?>{};

/// 3.2.1: clave del micro-bloque de una pista (`estacion|sub-genero`; el
/// sub-genero ya trae el idioma: Rock Clasico Espanol / en Ingles, Baladas
/// En Espanol / En Ingles). null si queda en el bucket general ("Todas")
/// o sin estacion: no arma bloque. Cache por ruta (solo nombres).
String? trackBlockKey(String path) {
  if (_blockKeyCache.containsKey(path)) return _blockKeyCache[path];
  final TrackGenre g = stationTrackGenre(path);
  final String? key =
      !g.known || g.subGenreId == stationFallbackSub(g.stationId!)
      ? null
      : '${g.stationId}|${g.subGenreId}';
  if (_blockKeyCache.length >= 20000) _blockKeyCache.clear();
  _blockKeyCache[path] = key;
  return key;
}

/// Indice rapido `gatomix_track_genre_index.json`: clave = ruta normalizada,
/// valido mientras el `mtime` no cambie.
class TrackGenreIndex {
  TrackGenreIndex(this.path, [Map<String, Map<String, Object?>>? tracks])
    : _tracks = tracks ?? <String, Map<String, Object?>>{};

  final String path;
  final Map<String, Map<String, Object?>> _tracks;
  bool _dirty = false;

  bool get dirty => _dirty;
  int get length => _tracks.length;

  static TrackGenreIndex read(String path) {
    final Map<String, Map<String, Object?>> m =
        <String, Map<String, Object?>>{};
    try {
      final Object? raw = SessionStore.readJson(path);
      final Object? t = raw is Map ? raw['tracks'] : null;
      if (t is Map) {
        for (final MapEntry<dynamic, dynamic> e in t.entries) {
          if (e.key is String && e.value is Map) {
            m[e.key as String] = Map<String, Object?>.from(e.value as Map);
          }
        }
      }
    } catch (_) {}
    return TrackGenreIndex(path, m);
  }

  TrackGenre? lookup(String trackPath, int mtimeMs) {
    final Map<String, Object?>? e = _tracks[stationPathKey(trackPath)];
    if (e == null || e['mtime'] != mtimeMs) return null;
    // 3.1.70: el nivel 3 ahora mira el idioma de las carpetas: las entradas
    // de antes (sin 'v') se vuelven a clasificar una vez.
    // 3.2.1: con la normalizacion de dieresis tambien los niveles 2 y 4
    // (lexico / fallback). Nivel 0 (Curador) y 1 (tags) se conservan.
    final Object? lv = e['level'];
    if ((lv == 2 || lv == 3 || lv == 4) && e['v'] != kTrackGenreIndexVersion) {
      return null;
    }
    final Object? s = e['stationId'];
    final Object? g = e['subGenreId'];
    final Object? l = e['level'];
    return TrackGenre(
      s is String ? s : null,
      g is String ? g : null,
      l is int ? l : 4,
    );
  }

  void put(String trackPath, int mtimeMs, TrackGenre g) {
    _tracks[stationPathKey(trackPath)] = <String, Object?>{
      'path': trackPath,
      'mtime': mtimeMs,
      'stationId': g.stationId,
      'subGenreId': g.subGenreId,
      'level': g.level,
      'v': kTrackGenreIndexVersion,
    };
    _dirty = true;
  }

  Future<void> write() async {
    try {
      File(path).parent.createSync(recursive: true);
    } catch (_) {}
    await SessionStore.writeJson(path, <String, dynamic>{
      'schema': kTrackGenreIndexVersion,
      'tracks': _tracks,
    });
    _dirty = false;
  }
}

/// Canciones clasificadas fuera de las carpetas de genero.
class TrackGenreBuckets {
  final Map<String, Map<String, List<String>>> byStation =
      <String, Map<String, List<String>>>{};
  final List<String> unknown = <String>[];

  bool get isEmpty => byStation.isEmpty && unknown.isEmpty;

  void add(String path, TrackGenre g) {
    if (!g.known) {
      unknown.add(path);
      return;
    }
    ((byStation[g.stationId!] ??= <String, List<String>>{})[g.subGenreId!] ??=
            <String>[])
        .add(path);
  }

  /// Canciones por sub-genero (para sumar a [groupStations]).
  Map<String, Map<String, int>> counts() => <String, Map<String, int>>{
    for (final MapEntry<String, Map<String, List<String>>> s
        in byStation.entries)
      s.key: <String, int>{
        for (final MapEntry<String, List<String>> e in s.value.entries)
          e.key: e.value.length,
      },
  };

  /// Pistas de [subs] en [key]; el bucket "Todas" de la estacion activa
  /// tambien recibe las canciones sin estacion (nivel 4).
  List<String> tracksFor(String key, Iterable<String> subs) {
    final Map<String, List<String>> m =
        byStation[key] ?? const <String, List<String>>{};
    final String? all = stationFallbackSub(key);
    return <String>[
      for (final String s in subs) ...?m[s],
      if (all != null && subs.contains(all)) ...unknown,
    ];
  }
}

/// Clasifica [paths] (canciones de carpetas genericas o sueltas en la
/// raiz) usando el indice: solo las nuevas o cambiadas pasan por la
/// cascada. Cede el hilo cada 200 pistas para no trabar la UI.
/// 3.2.4: [tagsOf] (por defecto [trackTagHintOf], cache `dna` en memoria
/// cargada antes con una lectura async por carpeta) da genero/anio/idioma.
/// Una entrada del indice de nivel 2-4 se vuelve a clasificar (solo
/// nombres) si la pista ya trae tags o idioma; sin tags, igual que antes.
Future<TrackGenreBuckets> classifyTracks(
  List<String> paths, {
  required String root,
  required TrackGenreIndex index,
  Future<int> Function(String path)? mtimeOf,
  double Function(String path)? bpmOf,
  TrackTagHint? Function(String path)? tagsOf,
}) async {
  final Future<int> Function(String) mt =
      mtimeOf ??
      (String p) async =>
          (await File(p).stat()).modified.millisecondsSinceEpoch;
  final TrackTagHint? Function(String) hintOf = tagsOf ?? trackTagHintOf;
  if (tagsOf == null) await warmTrackDnaFor(paths);
  final TrackGenreBuckets out = TrackGenreBuckets();
  int n = 0;
  for (final String p in paths) {
    int m = 0;
    try {
      m = await mt(p);
    } catch (_) {}
    final TrackTagHint? hint = hintOf(p);
    final bool hinted = hint != null && !hint.isEmpty;
    TrackGenre? g = index.lookup(p, m);
    if (g != null && hinted && g.level >= 2) {
      final TrackGenre fresh = TrackGenreClassifier.classify(
        p,
        root: root,
        tags: hint,
        bpm: bpmOf == null ? 0 : bpmOf(p),
      );
      if (fresh.stationId != g.stationId ||
          fresh.subGenreId != g.subGenreId ||
          fresh.level != g.level) {
        index.put(p, m, fresh);
      }
      g = fresh;
    }
    if (g == null) {
      g = TrackGenreClassifier.classify(
        p,
        root: root,
        tags: hinted ? hint : null,
        bpm: bpmOf == null ? 0 : bpmOf(p),
      );
      index.put(p, m, g);
    }
    out.add(p, g);
    if (++n % 200 == 0) await Future<void>.delayed(Duration.zero);
  }
  return out;
}

/// Registra en el indice una cancion nueva guardada por el Curador:
/// estacion y sub-genero de su carpeta canonica (o de su carpeta de
/// genero). Devuelve lo registrado (null si no se pudo deducir).
Future<TrackGenre?> registerSavedTrack(
  String indexPath,
  String root,
  String savedPath, {
  String? stationId,
  String? subGenreId,
}) async {
  // Carpeta canonica o carpeta de genero elegida por el Curador antes que
  // el lexico: el destino ya dice el sub-genero. 3.1.68: si el tema trae
  // estacion y sub-genero de la bandeja, mandan esos.
  final TrackGenre c = TrackGenreClassifier.classify(savedPath, root: root);
  TrackGenre? g =
      stationId != null &&
          subGenreId != null &&
          isStationSub(stationId, subGenreId)
      ? TrackGenre(stationId, subGenreId, 0)
      : (c.level == 0 ? c : null);
  final List<String> dirs = TrackGenreClassifier._dirsUnder(savedPath, root);
  for (int i = dirs.length - 1; g == null && i >= 0; i--) {
    if (isGenericMusicFolder(dirs[i])) continue;
    final MapEntry<String, String>? m = _stationSubOfRaw(dirs[i]);
    if (m != null) g = TrackGenre(m.key, m.value, 0);
  }
  if (g == null && c.known) g = TrackGenre(c.stationId, c.subGenreId, 0);
  if (g == null) return null;
  int m = 0;
  try {
    m = File(savedPath).statSync().modified.millisecondsSinceEpoch;
  } catch (_) {}
  final TrackGenreIndex idx = TrackGenreIndex.read(indexPath);
  idx.put(savedPath, m, g);
  await idx.write();
  return g;
}

/// 3.1.68: estacion y sub-genero de un tema de la bandeja del curador para
/// agruparlo: los que trae el tema, su carpeta destino (`Tropical/Salsa` o
/// carpeta de genero) o el lexico sobre el titulo. null = "Otros".
MapEntry<String, String>? stationSubOfCurator({
  String? stationId,
  String? subGenreId,
  required String genre,
  required String title,
}) {
  if (stationId != null &&
      subGenreId != null &&
      isStationSub(stationId, subGenreId)) {
    return MapEntry<String, String>(stationId, subGenreId);
  }
  final List<String> parts = genre
      .replaceAll('\\', '/')
      .split('/')
      .where((String s) => s.isNotEmpty)
      .toList();
  if (parts.length >= 2) {
    final MapEntry<String, String>? c = stationSubOfCanonical(
      parts[parts.length - 2],
      parts.last,
    );
    if (c != null) return c;
  }
  if (parts.isNotEmpty && !isGenericMusicFolder(parts.last)) {
    final MapEntry<String, String>? f = _stationSubOfRaw(parts.last);
    if (f != null) return f;
  }
  final TrackGenre g = TrackGenreClassifier.classify('$title.mp3');
  return g.known ? MapEntry<String, String>(g.stationId!, g.subGenreId!) : null;
}

/// 3.1.69: vistos del selector de estaciones. Cada estacion tiene su visto
/// maestro: activo si tiene al menos un sub-genero en visto. Quitarlo apaga
/// todos sus sub-generos y ponerlo los enciende todos; si el usuario apaga
/// uno por uno, el maestro queda apagado solo. Suena una estacion a la vez
/// (sesiones y cola por estacion): la ultima tocada que tenga vistos o, si
/// no, la primera marcada del catalogo.
class StationChecks {
  StationChecks(List<GenreStation> stations) : _stations = stations;

  List<GenreStation> _stations;
  final Map<String, Set<String>> _on = <String, Set<String>>{};
  String? _focus;

  /// Primera apertura: [key] (ultima seleccion guardada) con sus sub-generos
  /// [saved] o todos; sin seleccion guardada, Musica del Momento con todos.
  void seed({String? key, List<String>? saved}) {
    _on.clear();
    _focus = null;
    GenreStation? st = _find(key);
    Set<String> subs = <String>{
      if (st != null)
        for (final String g in saved ?? const <String>[])
          if (st.subGenres.contains(g)) g,
    };
    if (subs.isEmpty) {
      st ??= _find('momento') ?? (_stations.isEmpty ? null : _stations.first);
      if (st == null) return;
      subs = st.subGenres.toSet();
    }
    if (subs.isEmpty) return;
    _on[st!.key] = subs;
    _focus = st.key;
  }

  /// El Hub recarga sus estaciones sin perder los vistos.
  void updateStations(List<GenreStation> stations) => _stations = stations;

  GenreStation? _find(String? key) {
    if (key == null) return null;
    for (final GenreStation s in _stations) {
      if (s.key == key) return s;
    }
    return null;
  }

  bool master(String key) => _on[key]?.isNotEmpty ?? false;

  bool isOn(String key, String sub) => _on[key]?.contains(sub) ?? false;

  bool get any => _on.values.any((Set<String> s) => s.isNotEmpty);

  void toggleMaster(String key) {
    final GenreStation? st = _find(key);
    if (st == null) return;
    if (master(key)) {
      _on.remove(key);
      if (_focus == key) _focus = null;
      return;
    }
    if (st.subGenres.isEmpty) return;
    _on[key] = st.subGenres.toSet();
    _focus = key;
  }

  void toggleSub(String key, String sub) {
    final Set<String> s = _on.putIfAbsent(key, () => <String>{});
    if (!s.remove(sub)) s.add(sub);
    if (s.isNotEmpty) {
      _focus = key;
      return;
    }
    _on.remove(key);
    if (_focus == key) _focus = null;
  }

  /// Sub-generos en visto de [key], en el orden del catalogo.
  List<String> picked(String key) => <String>[
    for (final String g in _find(key)?.subGenres ?? const <String>[])
      if (isOn(key, g)) g,
  ];

  /// Estacion que suena con Play (null si no hay nada en visto).
  MapEntry<String, List<String>>? pick() {
    final String? f = _focus;
    if (f != null && master(f) && picked(f).isNotEmpty) {
      return MapEntry<String, List<String>>(f, picked(f));
    }
    for (final GenreStation s in _stations) {
      final List<String> p = picked(s.key);
      if (p.isNotEmpty) return MapEntry<String, List<String>>(s.key, p);
    }
    return null;
  }

  /// 3.2.31: la estacion que suena cambio (Play, reanudar, Fiesta): los
  /// vistos siguen a [key] para que el Hub no deje marcada otra estacion
  /// (antes Tropical quedaba en visto mientras sonaba Rock). True si resembro.
  bool follow(String key, {List<String>? saved}) {
    if (_focus == key && master(key)) return false;
    if (_find(key) == null) return false;
    seed(key: key, saved: saved);
    return true;
  }
}

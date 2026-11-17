import 'dart:io';
import 'dart:math';

import 'session_store.dart';

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
  ]),
  UniversalStation('tropical', 'Tropical', <StationSub>[
    StationSub('Salsa', 'Salsa'),
    StationSub('Cumbia', 'Cumbia'),
    StationSub('Merengue', 'Merengue'),
    StationSub('Bachatas', 'Bachata'),
    StationSub('Vallenatos', 'Vallenato'),
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
  ]),
  UniversalStation('nacional', 'Música Nacional Bailable', <StationSub>[
    StationSub('Cumbia & Chicha Nacional', 'Cumbia Chicha Ecuador'),
    StationSub('Paseíto & Sanjuanito', 'Paseíto Sanjuanito Ecuador'),
    StationSub('Tecnocumbia', 'Tecnocumbia Ecuador'),
    StationSub('Todas', 'Música nacional bailable Ecuador'),
  ]),
];

// Claves de la 3.1.61/62 que pueden seguir en sesiones guardadas.
const Map<String, String> _legacyTitles = <String, String>{
  'actualidad': 'Actualidad',
  'romanticas': 'Románticas & Baladas',
  'rockpop': 'Rock & Pop',
};

String stationFold(String s) {
  const String from = 'áéíóúüñÁÉÍÓÚÜÑ';
  const String to = 'aeiouunaeiouun';
  final StringBuffer b = StringBuffer();
  for (final int r in s.runes) {
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
MapEntry<String, String>? stationSubOf(String folder) {
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
List<GenreStation> groupStations(List<MapEntry<String, int>> folders) {
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
      final int c = l.fold<int>(
        0,
        (int a, MapEntry<String, int> e) => a + e.value,
      );
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
  const StationFeed(this.folder, this.query);

  /// Carpeta destino si el usuario acepta el tema en la bandeja.
  final String folder;

  /// Terminos canonicos de busqueda (null = el nombre de la carpeta).
  final String? query;
}

/// Que pide el Auto-Curador para una estacion corta: el sub-genero en visto
/// con menos canciones, con sus terminos canonicos.
StationFeed? stationFeedFor(
  String key,
  List<String> subs,
  Map<String, int> library,
) {
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
    int n = 0;
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
      best = StationFeed(folder ?? s, def.terms);
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

/// Archivo `difogo_genre_sessions.json`: `{active, stations: {clave: sesion}}`.
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
    return d;
  }

  /// Escritura atomica (.tmp y rename) en la carpeta de datos de la app.
  Future<void> write(String path) {
    try {
      File(path).parent.createSync(recursive: true);
    } catch (_) {}
    return SessionStore.writeJson(path, <String, dynamic>{
      'schema': 1,
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
StationPlan planStation(
  List<String> all,
  GenreSession? saved, {
  Random? rng,
  bool Function(String path)? exists,
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
  fresh.shuffle(r);
  queue.addAll(fresh);
  if (current == null && queue.isEmpty && all.isNotEmpty) {
    // Ya sono el 100 %: se reinicia lo sonado y se baraja todo de nuevo.
    final List<String> again = byKey.values.toList()..sort();
    again.shuffle(r);
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

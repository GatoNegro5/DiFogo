import 'dart:io';
import 'dart:math';

import 'session_store.dart';

/// 3.1.61 Estaciones DiFogo: macro-generos estilo Spotify que agrupan las
/// carpetas de genero de primer nivel, y la sesion persistente de cada
/// estacion (pista, segundo, cola restante y ya sonadas). Dart puro: no
/// toca el motor de audio ni la biblioteca.

class GenreStation {
  const GenreStation(this.key, this.title, this.subGenres, this.count);

  /// Clave estable en el JSON (macro fija o `g:<carpeta>`).
  final String key;
  final String title;

  /// Carpetas de primer nivel que agrupa, en orden alfabetico.
  final List<String> subGenres;
  final int count;
}

class _Macro {
  const _Macro(this.key, this.title, this.words);
  final String key;
  final String title;
  final List<String> words;
}

// El orden decide: Actualidad y los 80 ganan antes que Rock o Baladas.
const List<_Macro> _macros = <_Macro>[
  _Macro('actualidad', 'Actualidad', <String>['actualidad']),
  _Macro('ochenteras', 'Ochenteras', <String>['80']),
  _Macro('romanticas', 'Románticas & Baladas', <String>['balada', 'romant']),
  _Macro('tropical', 'Tropical & Fiesta', <String>[
    'bachat',
    'cumbia',
    'merengue',
    'fiesta',
    'guarach',
    'salsa',
    'vallenato',
    'reggaeton',
  ]),
  _Macro('rockpop', 'Rock & Pop', <String>[
    'rock',
    'espanola',
    'nacional',
    'pop',
  ]),
];

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

/// Clave de la macro de [folder]; null si no encaja (estacion propia).
String? stationMacroOf(String folder) {
  final String f = stationFold(folder);
  for (final _Macro m in _macros) {
    if (m.words.any(f.contains)) return m.key;
  }
  return null;
}

/// Agrupa las carpetas (nombre, canciones) en estaciones: primero las
/// macros fijas con contenido y luego cada carpeta suelta como estacion.
List<GenreStation> groupStations(List<MapEntry<String, int>> folders) {
  final Map<String, List<MapEntry<String, int>>> by =
      <String, List<MapEntry<String, int>>>{};
  final List<MapEntry<String, int>> loose = <MapEntry<String, int>>[];
  for (final MapEntry<String, int> f in folders) {
    final String? k = stationMacroOf(f.key);
    if (k == null) {
      loose.add(f);
    } else {
      (by[k] ??= <MapEntry<String, int>>[]).add(f);
    }
  }
  int byName(MapEntry<String, int> a, MapEntry<String, int> b) =>
      stationFold(a.key).compareTo(stationFold(b.key));
  final List<GenreStation> out = <GenreStation>[];
  for (final _Macro m in _macros) {
    final List<MapEntry<String, int>>? g = by[m.key];
    if (g == null || g.isEmpty) continue;
    g.sort(byName);
    out.add(
      GenreStation(m.key, m.title, <String>[
        for (final MapEntry<String, int> e in g) e.key,
      ], g.fold<int>(0, (int s, MapEntry<String, int> e) => s + e.value)),
    );
  }
  loose.sort(byName);
  for (final MapEntry<String, int> e in loose) {
    out.add(GenreStation('g:${e.key}', e.key, <String>[e.key], e.value));
  }
  return out;
}

/// Titulo visible de una clave de estacion (macro fija o `g:<carpeta>`).
String stationTitleOf(String key) {
  for (final _Macro m in _macros) {
    if (m.key == key) return m.title;
  }
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

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'automix_genre_session.dart' show AutomixGenreSessionState;
import 'genre_stations.dart' show GenreSession;
import 'library_guard.dart' show libraryWriteBlocked;
import 'session_store.dart';

/// 3.2.6 Motor de listas persistentes completas.
///
/// Cada contexto (genero `genre:<id>` o carpeta `folder:<ruta>`) guarda su
/// orden COMPLETO (100 % de las pistas, no una ventana de 48), lo ya sonado,
/// la pista actual y el segundo. Volver al contexto retoma en la siguiente
/// pendiente; nada se repite hasta agotar el 100 %.
///
/// Archivo: `Music/DjPlaylists/persistent_lists.json` (carpeta de sesiones,
/// fuera de la biblioteca). Toda escritura pasa por [libraryWriteBlocked].
/// Dos espacios (Automix y Live DJ), cada uno con su LRU de
/// [kPersistentListCap] listas y su lista activa.

const String kPersistentListsName = 'persistent_lists.json';
const String kPersistentSpaceAutomix = 'automix';
const String kPersistentSpaceLiveDj = 'livedj';

/// Listas por espacio (LRU: la usada hace mas tiempo sale primero).
const int kPersistentListCap = 40;

/// Debounce: a lo sumo una escritura cada 3 s por cambios menores.
const int kPersistentSaveEveryMs = 3000;

/// Con mas rutas que esto el JSON se arma y escribe en otro isolate.
const int kPersistentIsolatePaths = 1500;

/// Archivo mas grande que esto se lee en otro isolate.
const int kPersistentIsolateReadBytes = 256 * 1024;

/// Solo pruebas: ruta fija del archivo.
String? debugPersistentListsPath;

/// Solo pruebas: reloj fijo.
int Function()? debugPersistentNow;

int _now() =>
    (debugPersistentNow ?? () => DateTime.now().millisecondsSinceEpoch)();

/// `persistent_lists.json` junto al archivo de sesion [sessionFile].
String persistentListsPathNear(String sessionFile) {
  final String? o = debugPersistentListsPath;
  if (o != null) return o;
  return '${File(sessionFile).parent.path}${Platform.pathSeparator}'
      '$kPersistentListsName';
}

String _slash(String p) =>
    p.trim().replaceAll('\\', '/').replaceAll(RegExp(r'/+'), '/');

/// Identidad de una pista: minusculas y barras normales.
String persistentPathKey(String p) => _slash(p).toLowerCase();

/// Clave de genero estable: `genre:<id en minusculas>`.
String persistentGenreKey(String id) => 'genre:${id.trim().toLowerCase()}';

/// Clave de carpeta estable en Win/Mac/Android: minusculas, barras
/// normales y sin barra final.
String persistentFolderKey(String folder) {
  String p = _slash(folder).toLowerCase();
  while (p.length > 1 && p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  return 'folder:$p';
}

class PersistentList {
  const PersistentList({
    required this.order,
    this.played = const <String>[],
    this.currentPath,
    this.positionMs = 0,
    this.updatedAtMs = 0,
    this.meta = const <String, Object?>{},
  });

  /// Orden completo: sonadas, actual y pendientes.
  final List<String> order;

  /// Ya sonadas (conjunto; se guarda en el orden en que sonaron).
  final List<String> played;
  final String? currentPath;
  final int positionMs;
  final int updatedAtMs;
  final Map<String, Object?> meta;

  Set<String> get playedKeys => <String>{
    for (final String p in played) persistentPathKey(p),
  };

  /// Pendientes en orden (la actual incluida).
  List<String> get pending {
    final Set<String> pk = playedKeys;
    return <String>[
      for (final String p in order)
        if (!pk.contains(persistentPathKey(p))) p,
    ];
  }

  bool get exhausted => pending.isEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'order': order,
    'played': played,
    'currentPath': currentPath,
    'positionMs': positionMs,
    'updatedAtMs': updatedAtMs,
    if (meta.isNotEmpty) 'meta': meta,
  };

  static List<String> _list(Object? v) => <String>[
    if (v is List)
      for (final Object? e in v)
        if (e is String && e.isNotEmpty) e,
  ];

  static PersistentList? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final List<String> order = _list(raw['order']);
    if (order.isEmpty) return null;
    final Object? cur = raw['currentPath'];
    final Object? pos = raw['positionMs'];
    final Object? at = raw['updatedAtMs'];
    final Object? meta = raw['meta'];
    return PersistentList(
      order: order,
      played: _list(raw['played']),
      currentPath: cur is String && cur.isNotEmpty ? cur : null,
      positionMs: pos is int && pos > 0 ? pos : 0,
      updatedAtMs: at is int ? at : 0,
      meta: meta is Map
          ? <String, Object?>{
              for (final MapEntry<dynamic, dynamic> e in meta.entries)
                if (e.key is String) e.key as String: e.value,
            }
          : const <String, Object?>{},
    );
  }
}

/// Resultado de [persistentPlan]: [queue] empieza en la pista a sonar.
class PersistentPlan {
  const PersistentPlan({
    required this.list,
    required this.queue,
    required this.resumed,
    required this.fresh,
  });

  final PersistentList list;
  final List<String> queue;

  /// Sigue una lista guardada (no es nueva).
  final bool resumed;

  /// Lista nueva (no existia o ya sono el 100 %).
  final bool fresh;

  String? get current => queue.isEmpty ? null : queue.first;
  int get positionMs => list.positionMs;
}

typedef PersistentBuildOrder = List<String> Function(List<String> tracks);

/// Lo que devuelve [build] filtrado a [candidates], sin repetir, y al final
/// lo que [build] haya olvidado.
List<String> _sanitize(List<String> built, List<String> candidates) {
  final Map<String, String> byKey = <String, String>{};
  for (final String c in candidates) {
    byKey.putIfAbsent(persistentPathKey(c), () => c);
  }
  final Set<String> seen = <String>{};
  final List<String> out = <String>[];
  for (final String b in built) {
    final String k = persistentPathKey(b);
    final String? c = byKey[k];
    if (c != null && seen.add(k)) out.add(c);
  }
  for (final String c in candidates) {
    if (seen.add(persistentPathKey(c))) out.add(c);
  }
  return out;
}

/// [pending] empezando en [at]: de ahi en adelante y las anteriores al final.
List<String> _rotate(List<String> pending, int at) {
  if (at <= 0 || at >= pending.length) return List<String>.from(pending);
  return <String>[...pending.sublist(at), ...pending.sublist(0, at)];
}

/// Plan puro de un contexto. Sin lista guardada (o con el 100 % sonado):
/// lista completa nueva con [buildOrder] (shuffle/ADN). Con lista: quita las
/// borradas, suma las nuevas al final de las pendientes (ordenadas con
/// [buildOrder]) y retoma en la siguiente pendiente (la guardada y su
/// segundo si sigue pendiente).
PersistentPlan persistentPlan(
  PersistentList? saved,
  List<String> allTracks,
  PersistentBuildOrder buildOrder, {
  int nowMs = 0,
}) {
  final Map<String, String> byKey = <String, String>{};
  for (final String p in allTracks) {
    if (p.trim().isEmpty) continue;
    byKey.putIfAbsent(persistentPathKey(p), () => p);
  }
  final List<String> all = byKey.values.toList();
  final Map<String, Object?> meta = saved?.meta ?? const <String, Object?>{};

  PersistentPlan fresh() {
    final List<String> order = all.isEmpty
        ? <String>[]
        : _sanitize(buildOrder(List<String>.from(all)), all);
    return PersistentPlan(
      list: PersistentList(
        order: order,
        currentPath: order.isEmpty ? null : order.first,
        updatedAtMs: nowMs,
        meta: meta,
      ),
      queue: order,
      resumed: false,
      fresh: true,
    );
  }

  if (saved == null || all.isEmpty) return fresh();
  final Set<String> seen = <String>{};
  final List<String> order0 = <String>[];
  for (final String p in saved.order) {
    final String k = persistentPathKey(p);
    final String? c = byKey[k];
    if (c != null && seen.add(k)) order0.add(c);
  }
  final Set<String> playedKeys = <String>{};
  final List<String> played = <String>[];
  for (final String p in saved.played) {
    final String k = persistentPathKey(p);
    final String? c = byKey[k];
    if (c == null || !playedKeys.add(k)) continue;
    played.add(c);
    if (seen.add(k)) order0.add(c);
  }
  final List<String> newOnes = <String>[
    for (final String c in all)
      if (!seen.contains(persistentPathKey(c))) c,
  ];
  final List<String> pending0 = <String>[
    for (final String c in order0)
      if (!playedKeys.contains(persistentPathKey(c))) c,
  ];
  if (pending0.isEmpty && newOnes.isEmpty) return fresh();
  final List<String> appended = newOnes.isEmpty
      ? const <String>[]
      : _sanitize(buildOrder(List<String>.from(newOnes)), newOnes);
  final List<String> pendingAll = <String>[...pending0, ...appended];
  final String? sc = saved.currentPath;
  final String? sck = sc == null ? null : persistentPathKey(sc);
  int at = sck == null
      ? -1
      : pendingAll.indexWhere((String p) => persistentPathKey(p) == sck);
  int pos = 0;
  if (at >= 0) {
    pos = saved.positionMs;
  } else {
    at = 0;
  }
  final List<String> queue = _rotate(pendingAll, at);
  return PersistentPlan(
    list: PersistentList(
      order: <String>[...played, ...queue],
      played: played,
      currentPath: queue.first,
      positionMs: pos,
      updatedAtMs: nowMs,
      meta: meta,
    ),
    queue: queue,
    resumed: true,
    fresh: false,
  );
}

/// [path] ya sono. Si era la actual, la actual pasa a la siguiente
/// pendiente. Null si no cambia nada o [path] no es de la lista.
PersistentList? persistentMarkPlayed(
  PersistentList l,
  String path, {
  int nowMs = 0,
}) {
  final String k = persistentPathKey(path);
  final int idx = l.order.indexWhere((String p) => persistentPathKey(p) == k);
  if (idx < 0) return null;
  final String? cur = l.currentPath;
  final bool isCurrent = cur != null && persistentPathKey(cur) == k;
  final Set<String> pk = l.playedKeys;
  if (pk.contains(k) && !isCurrent) return null;
  final List<String> played = List<String>.from(l.played);
  if (pk.add(k)) played.add(l.order[idx]);
  final List<String> after = <String>[];
  final List<String> before = <String>[];
  for (int i = 0; i < l.order.length; i++) {
    final String p = l.order[i];
    if (pk.contains(persistentPathKey(p))) continue;
    (i > idx ? after : before).add(p);
  }
  String? next = cur;
  int pos = l.positionMs;
  List<String> pending = <String>[...before, ...after];
  if (isCurrent) {
    pending = <String>[...after, ...before];
    next = pending.isEmpty ? null : pending.first;
    pos = 0;
  } else if (cur != null) {
    final String ck = persistentPathKey(cur);
    final int at = pending.indexWhere((String p) => persistentPathKey(p) == ck);
    pending = _rotate(pending, at);
  }
  return PersistentList(
    order: <String>[...played, ...pending],
    played: played,
    currentPath: next,
    positionMs: pos,
    updatedAtMs: nowMs,
    meta: l.meta,
  );
}

/// Play en una fila: la actual anterior queda como sonada, [path] suena y
/// las pendientes siguen desde ahi; las pendientes anteriores a [path] van
/// al final (0 repeticiones, nada se pierde).
PersistentList? persistentPlayAt(
  PersistentList l,
  String path, {
  int nowMs = 0,
}) {
  final String k = persistentPathKey(path);
  final int idx = l.order.indexWhere((String p) => persistentPathKey(p) == k);
  if (idx < 0) return null;
  final Set<String> pk = l.playedKeys;
  final List<String> played = List<String>.from(l.played);
  final String? cur = l.currentPath;
  if (cur != null) {
    final String ck = persistentPathKey(cur);
    if (ck != k) {
      final int ci = l.order.indexWhere(
        (String p) => persistentPathKey(p) == ck,
      );
      if (ci >= 0 && pk.add(ck)) played.add(l.order[ci]);
    }
  }
  if (pk.remove(k)) {
    played.removeWhere((String p) => persistentPathKey(p) == k);
  }
  final List<String> after = <String>[];
  final List<String> before = <String>[];
  for (int i = 0; i < l.order.length; i++) {
    final String p = l.order[i];
    final String pkk = persistentPathKey(p);
    if (pkk == k || pk.contains(pkk)) continue;
    (i > idx ? after : before).add(p);
  }
  return PersistentList(
    order: <String>[...played, l.order[idx], ...after, ...before],
    played: played,
    currentPath: l.order[idx],
    updatedAtMs: nowMs,
    meta: l.meta,
  );
}

bool _sameList(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Lo que suena ahora en el motor: [current] (si es de la lista) pasa a
/// actual; la actual anterior y [alsoPlayed] quedan como sonadas; las
/// pendientes siguen el orden de [upcoming] y las que no esten ahi quedan
/// detras en su orden (una cola vaciada no borra nada). Pistas ajenas a la
/// lista se ignoran. Null si no cambia nada.
PersistentList? persistentNoteState(
  PersistentList l, {
  required String? current,
  int positionMs = 0,
  List<String> upcoming = const <String>[],
  Iterable<String> alsoPlayed = const <String>[],
  int nowMs = 0,
}) {
  if (current == null) return null;
  final Map<String, String> byKey = <String, String>{
    for (final String p in l.order) persistentPathKey(p): p,
  };
  final String ck = persistentPathKey(current);
  final String? cur = byKey[ck];
  if (cur == null) return null;
  final Set<String> pk = l.playedKeys;
  final List<String> played = List<String>.from(l.played);
  void mark(String k) {
    final String? p = byKey[k];
    if (p != null && k != ck && pk.add(k)) played.add(p);
  }

  final String? prev = l.currentPath;
  if (prev != null) mark(persistentPathKey(prev));
  for (final String a in alsoPlayed) {
    mark(persistentPathKey(a));
  }
  if (pk.remove(ck)) {
    played.removeWhere((String p) => persistentPathKey(p) == ck);
  }
  final Set<String> used = <String>{ck, ...pk};
  final List<String> aligned = <String>[];
  for (final String u in upcoming) {
    final String k = persistentPathKey(u);
    final String? p = byKey[k];
    if (p != null && used.add(k)) aligned.add(p);
  }
  for (final String p in l.order) {
    if (used.add(persistentPathKey(p))) aligned.add(p);
  }
  final List<String> order = <String>[...played, cur, ...aligned];
  final int pos = positionMs < 0 ? 0 : positionMs;
  if (l.currentPath == cur &&
      l.positionMs == pos &&
      _sameList(l.played, played) &&
      _sameList(l.order, order)) {
    return null;
  }
  return PersistentList(
    order: order,
    played: played,
    currentPath: cur,
    positionMs: pos,
    updatedAtMs: nowMs,
    meta: l.meta,
  );
}

/// Puente 3.1.61 -> 3.2.6: sesion de estacion de Live DJ a lista completa.
/// Las pendientes que ya tenia [existing] y que la sesion no trae (cola
/// vaciada o quitada) quedan al final: vaciar la cola no borra la lista.
PersistentList persistentFromStation(
  PersistentList? existing,
  GenreSession s,
  String stationKey, {
  int nowMs = 0,
}) {
  final Set<String> used = <String>{};
  final List<String> played = <String>[
    for (final String p in s.playedPaths)
      if (used.add(persistentPathKey(p))) p,
  ];
  String? cur = s.currentTrackPath;
  if (cur != null) {
    final String ck = persistentPathKey(cur);
    if (!used.add(ck)) {
      played.removeWhere((String p) => persistentPathKey(p) == ck);
    }
  }
  final List<String> remaining = <String>[
    for (final String p in s.remainingQueuePaths)
      if (used.add(persistentPathKey(p))) p,
  ];
  final List<String> retained = <String>[
    for (final String p in existing?.pending ?? const <String>[])
      if (used.add(persistentPathKey(p))) p,
  ];
  return PersistentList(
    order: <String>[...played, ?cur, ...remaining, ...retained],
    played: played,
    currentPath: cur,
    positionMs: s.positionMs,
    updatedAtMs: nowMs,
    meta: <String, Object?>{
      ...?existing?.meta,
      'station': stationKey,
      'subs': List<String>.from(s.subGenresChecked),
      'shuffle': s.shuffleEnabled,
    },
  );
}

/// Lista completa a sesion de estacion (lo que usa planStation).
GenreSession stationFromPersistent(PersistentList l, {GenreSession? base}) {
  final String? cur = l.currentPath;
  final String? ck = cur == null ? null : persistentPathKey(cur);
  final Object? subs = l.meta['subs'];
  return GenreSession(
    subGenresChecked:
        base?.subGenresChecked ??
        <String>[
          if (subs is List)
            for (final Object? e in subs)
              if (e is String && e.isNotEmpty) e,
        ],
    currentTrackPath: cur,
    positionMs: l.positionMs,
    remainingQueuePaths: <String>[
      for (final String p in l.pending)
        if (persistentPathKey(p) != ck) p,
    ],
    playedPaths: List<String>.from(l.played),
    shuffleEnabled: base?.shuffleEnabled ?? (l.meta['shuffle'] != false),
    updatedAt: l.updatedAtMs > 0
        ? DateTime.fromMillisecondsSinceEpoch(l.updatedAtMs).toIso8601String()
        : base?.updatedAt,
  );
}

/// Migracion suave desde `automix_genres.json` (ventana de 48): por cada
/// estacion la sesion mas reciente. Las pistas fuera de la ventana entran
/// como nuevas en el siguiente plan. El archivo viejo no se toca.
Map<String, PersistentList> persistentListsFromAutomixSessions(
  Map<String, AutomixGenreSessionState> sessions,
) {
  final Map<String, AutomixGenreSessionState> best =
      <String, AutomixGenreSessionState>{};
  for (final MapEntry<String, AutomixGenreSessionState> e in sessions.entries) {
    final String station = e.key.split('|').first.trim();
    if (station.isEmpty) continue;
    final String key = persistentGenreKey(station);
    final AutomixGenreSessionState? had = best[key];
    if (had == null || e.value.savedAtMs >= had.savedAtMs) best[key] = e.value;
  }
  return <String, PersistentList>{
    for (final MapEntry<String, AutomixGenreSessionState> e in best.entries)
      e.key: _fromAutomixSession(e.value),
  };
}

PersistentList _fromAutomixSession(AutomixGenreSessionState s) {
  final Set<String> windowKeys = <String>{
    for (final String p in s.window) persistentPathKey(p),
  };
  final Set<String> used = <String>{};
  final List<String> played = <String>[
    for (final String p in s.played)
      if (!windowKeys.contains(persistentPathKey(p)) &&
          used.add(persistentPathKey(p)))
        p,
  ];
  final List<String> window = <String>[
    for (final String p in s.window)
      if (used.add(persistentPathKey(p))) p,
  ];
  return PersistentList(
    order: <String>[...played, ...window],
    played: played,
    currentPath: window.isEmpty ? null : window.first,
    positionMs: s.positionMs,
    updatedAtMs: s.savedAtMs,
  );
}

class _Space {
  String? active;
  bool legacyDone = false;
  final Map<String, PersistentList> lists = <String, PersistentList>{};
}

/// Archivo `persistent_lists.json` en memoria (uno por ruta), con escritura
/// atomica en fila, debounce sin timers y guardia de biblioteca.
class PersistentListsStore {
  PersistentListsStore._(this.path);

  static final Map<String, PersistentListsStore> _all =
      <String, PersistentListsStore>{};

  factory PersistentListsStore.at(String path) => _all.putIfAbsent(
    persistentPathKey(path),
    () => PersistentListsStore._(path),
  );

  /// Solo pruebas: olvida lo cargado en memoria.
  static void debugForgetAll() => _all.clear();

  final String path;
  Map<String, _Space>? _spaces;
  Future<void>? _loading;
  Future<void> _chain = Future<void>.value();
  bool _dirty = false;
  int _lastWriteMs = 0;

  bool get isLoaded => _spaces != null;
  bool get isDirty => _dirty;

  static Map<String, _Space> _parse(Object? raw) {
    final Map<String, _Space> out = <String, _Space>{};
    if (raw is! Map) return out;
    final Object? spaces = raw['spaces'];
    if (spaces is! Map) return out;
    for (final MapEntry<dynamic, dynamic> e in spaces.entries) {
      final Object? v = e.value;
      if (e.key is! String || v is! Map) continue;
      final _Space s = _Space();
      final Object? a = v['active'];
      s.active = a is String && a.isNotEmpty ? a : null;
      s.legacyDone = v['legacyDone'] == true;
      final Object? lists = v['lists'];
      if (lists is Map) {
        for (final MapEntry<dynamic, dynamic> le in lists.entries) {
          if (le.key is! String) continue;
          final PersistentList? l = PersistentList.fromJson(le.value);
          if (l != null) s.lists[le.key as String] = l;
        }
      }
      out[e.key as String] = s;
    }
    return out;
  }

  /// Lectura en el hilo actual (archivos chicos o caminos sincronos).
  void ensureLoadedSync() {
    if (_spaces != null) return;
    Object? raw;
    try {
      raw = SessionStore.readJson(path);
    } catch (_) {}
    _spaces = _parse(raw);
  }

  /// Lectura asincrona; un archivo grande se lee en otro isolate.
  Future<void> load() {
    if (_spaces != null) return Future<void>.value();
    return _loading ??= _loadAsync();
  }

  Future<void> _loadAsync() async {
    Object? raw;
    final String p = path;
    try {
      final File f = File(p);
      final bool big =
          f.existsSync() && f.lengthSync() > kPersistentIsolateReadBytes;
      raw = big
          ? await Isolate.run(() => SessionStore.readJson(p))
          : SessionStore.readJson(p);
    } catch (_) {}
    _spaces ??= _parse(raw);
  }

  _Space _space(String name) {
    ensureLoadedSync();
    return _spaces!.putIfAbsent(name, _Space.new);
  }

  PersistentList? get(String space, String key) => _space(space).lists[key];

  Map<String, PersistentList> listsOf(String space) =>
      Map<String, PersistentList>.unmodifiable(_space(space).lists);

  /// Guarda [list] como la mas reciente y aplica el LRU (la activa nunca
  /// sale).
  void put(String space, String key, PersistentList list) {
    final _Space s = _space(space);
    s.lists.remove(key);
    s.lists[key] = list;
    while (s.lists.length > kPersistentListCap) {
      final String? old = s.lists.keys.cast<String?>().firstWhere(
        (String? k) => k != s.active && k != key,
        orElse: () => null,
      );
      if (old == null) break;
      s.lists.remove(old);
    }
    _dirty = true;
  }

  bool remove(String space, String key) {
    final bool had = _space(space).lists.remove(key) != null;
    if (had) _dirty = true;
    return had;
  }

  String? activeOf(String space) => _space(space).active;

  void setActive(String space, String? key) {
    final _Space s = _space(space);
    if (s.active == key) return;
    s.active = key;
    _dirty = true;
  }

  bool legacyDone(String space) => _space(space).legacyDone;

  void markLegacyDone(String space) {
    final _Space s = _space(space);
    if (s.legacyDone) return;
    s.legacyDone = true;
    _dirty = true;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'schema': 1,
    'spaces': <String, dynamic>{
      for (final MapEntry<String, _Space> e
          in (_spaces ?? const <String, _Space>{}).entries)
        e.key: <String, dynamic>{
          'active': e.value.active,
          'legacyDone': e.value.legacyDone,
          'lists': <String, dynamic>{
            for (final MapEntry<String, PersistentList> l
                in e.value.lists.entries)
              l.key: l.value.toJson(),
          },
        },
    },
  };

  int get pathCount {
    int n = 0;
    for (final _Space s in (_spaces ?? const <String, _Space>{}).values) {
      for (final PersistentList l in s.lists.values) {
        n += l.order.length + l.played.length;
      }
    }
    return n;
  }

  /// Escribe ya (en fila, atomico). Nunca dentro de la biblioteca.
  Future<void> flush() {
    if (_spaces == null || !_dirty) return _chain;
    _dirty = false;
    _lastWriteMs = _now();
    final Map<String, dynamic> data = toJson();
    final String p = path;
    final bool big = pathCount > kPersistentIsolatePaths;
    _chain = _chain.catchError((Object _) {}).then((_) async {
      if (libraryWriteBlocked(p, what: 'persistent_lists')) return;
      try {
        if (big) {
          await Isolate.run(() => SessionStore.writeJsonSync(p, data));
        } else {
          SessionStore.writeJsonSync(p, data);
        }
      } catch (_) {}
    });
    return _chain;
  }

  /// Debounce sin timers: escribe si la ultima escritura tiene mas de
  /// [kPersistentSaveEveryMs]; si no, queda pendiente para la siguiente
  /// llamada, [flushIfDirty] (pausa/cierre de la app) o [flush].
  void saveSoon() {
    _dirty = true;
    if (_now() - _lastWriteMs >= kPersistentSaveEveryMs) unawaited(flush());
  }

  Future<void> flushIfDirty() => _dirty ? flush() : _chain;

  Future<void> get settled => _chain;
}

/// Vista de un espacio (Automix o Live DJ) del archivo de listas.
class PersistentLists {
  PersistentLists(this.store, this.space);

  final PersistentListsStore store;
  final String space;

  bool has(String key) => store.get(space, key) != null;

  PersistentList? get(String key) => store.get(space, key);

  Map<String, PersistentList> get lists => store.listsOf(space);

  String? get activeKey => store.activeOf(space);

  set activeKey(String? key) => store.setActive(space, key);

  /// Plan del contexto [key] (ver [persistentPlan]); queda guardado.
  PersistentPlan planOrResume(
    String key,
    List<String> allTracks,
    PersistentBuildOrder buildOrder,
  ) {
    final PersistentPlan plan = persistentPlan(
      get(key),
      allTracks,
      buildOrder,
      nowMs: _now(),
    );
    if (plan.list.order.isNotEmpty) store.put(space, key, plan.list);
    return plan;
  }

  bool _apply(String key, PersistentList? Function(PersistentList l) f) {
    final PersistentList? l = get(key);
    if (l == null) return false;
    final PersistentList? next = f(l);
    if (next == null) return false;
    store.put(space, key, next);
    return true;
  }

  bool markPlayed(String key, String path) => _apply(
    key,
    (PersistentList l) => persistentMarkPlayed(l, path, nowMs: _now()),
  );

  bool playAt(String key, String path) => _apply(
    key,
    (PersistentList l) => persistentPlayAt(l, path, nowMs: _now()),
  );

  bool noteState(
    String key, {
    required String? current,
    int positionMs = 0,
    List<String> upcoming = const <String>[],
    Iterable<String> alsoPlayed = const <String>[],
  }) => _apply(
    key,
    (PersistentList l) => persistentNoteState(
      l,
      current: current,
      positionMs: positionMs,
      upcoming: upcoming,
      alsoPlayed: alsoPlayed,
      nowMs: _now(),
    ),
  );

  /// Reinicio intencional: borra SOLO [key]; el siguiente plan arma un
  /// orden nuevo.
  bool reset(String key) => store.remove(space, key);

  /// Sesion de estacion de Live DJ hacia `genre:<estacion>`.
  PersistentList upsertStation(String stationKey, GenreSession s) {
    final String key = persistentGenreKey(stationKey);
    final PersistentList l = persistentFromStation(
      get(key),
      s,
      stationKey,
      nowMs: _now(),
    );
    store.put(space, key, l);
    return l;
  }

  /// Migracion de lectura, una sola vez por espacio: solo entra lo que aun
  /// no tiene clave. Los archivos viejos no se borran ni se reescriben.
  void importLegacyOnce(Map<String, PersistentList> Function() read) {
    if (store.legacyDone(space)) return;
    try {
      for (final MapEntry<String, PersistentList> e in read().entries) {
        if (!has(e.key)) store.put(space, e.key, e.value);
      }
    } catch (_) {}
    store.markLegacyDone(space);
  }

  void saveSoon() => store.saveSoon();

  Future<void> flush() => store.flush();
}

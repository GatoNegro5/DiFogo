import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' show min;

import 'audio_path.dart';
import 'genre_track_pool.dart' show kRollingWindowSize;
import 'session_restore.dart';
import 'session_store.dart';

/// 3.1.86: sesion de Mix con Letra por genero y carga sin ANR.
///
/// La sesion de Automix guarda `genreSignature` junto a la cola, la pista
/// (`currentIndex`) y el segundo (`positionMs`) que ya se guardaban. La firma
/// sale de la estacion y sub-generos elegidos en Estaciones & Generos
/// (compartida con Live DJ, cada motor con su propia cola y posicion).

/// Firma estable de la seleccion: `estacion|sub1,sub2` (subs ordenados y sin
/// mayusculas). Vacia si no hay estacion.
String automixGenreSignature(String? stationKey, Iterable<String> subGenres) {
  final String key = (stationKey ?? '').trim();
  if (key.isEmpty) return '';
  final List<String> subs = <String>{
    for (final String s in subGenres)
      if (s.trim().isNotEmpty) s.trim().toLowerCase(),
  }.toList()..sort();
  return '${key.toLowerCase()}|${subs.join(',')}';
}

enum AutomixGenreAction {
  /// Sin estacion elegida: no se toca nada.
  none,

  /// Misma firma: la cola guardada sigue tal cual (pista y segundo).
  restore,

  /// Cola armada a mano (sin firma): no se borra trabajo del usuario.
  keepManual,

  /// Cola vacia o firma distinta: se arma la cola de los generos elegidos.
  build,
}

AutomixGenreAction automixGenreAction({
  required String? savedSignature,
  required String currentSignature,
  required bool hasQueue,
}) {
  if (currentSignature.isEmpty) return AutomixGenreAction.none;
  if (!hasQueue) return AutomixGenreAction.build;
  final String saved = savedSignature ?? '';
  if (saved.isEmpty) return AutomixGenreAction.keepManual;
  if (saved == currentSignature) return AutomixGenreAction.restore;
  return AutomixGenreAction.build;
}

/// Campos de la sesion de Automix para una cola nueva de generos: lista,
/// pista 0, segundo 0 y la firma. Se escribe con `patchModeDoc`.
Map<String, dynamic> automixGenreSessionPatch({
  required String signature,
  required List<String> playlist,
}) => <String, dynamic>{
  'genreSignature': signature,
  'playlist': playlist,
  'queue': playlist,
  'currentIndex': playlist.isEmpty ? -1 : 0,
  'positionMs': 0,
  'wasPlaying': false,
};

/// Lotes con los que se procesa una cola grande sin congelar la UI.
const int kAutomixChunk = 128;

/// 3.1.86: carga por lotes. [onFirst] recibe la primera pista valida en
/// cuanto se conoce (arranque inmediato del Deck A); el resto se deduplica
/// por lotes de [chunk] cediendo el event loop entre lote y lote. Devuelve
/// la cola completa sin duplicados ni pistas `_K`.
Future<List<String>> automixLoadInChunks(
  List<String> paths, {
  FutureOr<void> Function(String first)? onFirst,
  int chunk = kAutomixChunk,
  bool? foldCase,
}) async {
  final List<String> out = <String>[];
  final Set<String> seen = <String>{};
  bool first = true;
  for (var i = 0; i < paths.length; i++) {
    final String p = paths[i];
    if (!isKaraokeAudioPath(p) &&
        seen.add(audioPathKey(p, foldCase: foldCase))) {
      out.add(p);
      if (first) {
        first = false;
        if (onFirst != null) await onFirst(p);
      }
    }
    if ((i + 1) % chunk == 0) await Future<void>.delayed(Duration.zero);
  }
  return out;
}

/// Claves de una lista (comparacion O(1) en lugar de `any(sameAudioPath)`).
Set<String> audioKeySet(Iterable<String> paths, {bool? foldCase}) => <String>{
  for (final String p in paths) audioPathKey(p, foldCase: foldCase),
};

/// 3.1.86: hasta este tamano la restauracion sigue en el hilo actual (colas
/// chicas, sin costo); mas grande va a `Isolate.run`.
const int kAutomixSyncLimit = 64;

/// 3.1.86: debounce del guardado de la sesion de Automix.
const int kAutomixSaveDebounceMs = 800;

/// Resultado de [restoreAutomixPlaylist]; viaja entre isolates.
class AutomixPlaylistRestore {
  const AutomixPlaylistRestore(this.restored, this.playlist, this.index);
  final AutomixSessionRestore restored;
  final List<String> playlist;
  final int? index;
}

/// Lista de la sesion de Automix: reencuentra pistas renombradas, resuelve
/// enlaces y quita duplicados (mismo resultado que antes en el provider).
/// Hace I/O de disco por pista: con colas grandes se llama en otro isolate.
AutomixPlaylistRestore restoreAutomixPlaylist(
  Map<dynamic, dynamic> data,
  int strategyCount,
) {
  final AutomixSessionRestore restored = restoreAutomixSession(
    data,
    strategyCount: strategyCount,
  );
  final List<String> playlist = <String>[];
  final Map<String, int> at = <String, int>{};
  int? index;
  for (var i = 0; i < restored.playlist.length; i++) {
    final String c = canonicalAudioPath(restored.playlist[i]);
    final String key = audioPathKey(c);
    final int? prev = at[key];
    if (prev != null) {
      if (i == restored.index) index = prev;
      continue;
    }
    if (i == restored.index) index = playlist.length;
    at[key] = playlist.length;
    playlist.add(c);
  }
  if (index == null && playlist.isNotEmpty && restored.index != null) {
    index = restored.index!.clamp(0, playlist.length - 1);
  }
  return AutomixPlaylistRestore(restored, playlist, index);
}

/// 3.1.86: [restoreAutomixPlaylist] en otro isolate (cierre sin `this`).
Future<AutomixPlaylistRestore> restoreAutomixPlaylistAsync(
  Map<dynamic, dynamic> data,
  int strategyCount,
) => Isolate.run(() => restoreAutomixPlaylist(data, strategyCount));

/// 3.1.86: cola guardada de Automix (rutas jugables, resueltas y sin
/// duplicados). [resolve] es la funcion de la cola; con listas grandes corre
/// en otro isolate.
Future<List<String>> resolveQueuePathsAsync(
  List<String> raw,
  List<String> Function(List<String> raw) resolve,
) => Isolate.run(() => resolve(raw));

/// Rutas canonicas (existsSync + resolveSymbolicLinks) de muchas pistas sin
/// tocar el hilo de UI.
Future<List<String>> canonicalAudioPathsAsync(List<String> paths) =>
    Isolate.run(() => <String>[for (final String p in paths) canonicalAudioPath(p)]);

/// Pistas que existen en disco, en otro isolate.
Future<List<String>> existingAudioPathsAsync(List<String> paths) =>
    Isolate.run(() => <String>[
      for (final String p in paths)
        if (File(p).existsSync()) p,
    ]);

// 3.1.98: sesion independiente por firma de genero. Al cambiar de genero la
// sesion saliente (pista, segundo, ventana de 48 y ya sonadas) queda en un
// mapa por firma; al volver se retoma donde quedo.

/// Archivo del mapa, junto a `automix.json` (carpeta de sesiones
/// `Music/DjPlaylists`, permitida por library_guard; nunca la biblioteca).
/// Va aparte para que el guardado de posicion de `automix.json` (cada 5 s)
/// y `clearModeQueueSync` no reescriban ni borren las sesiones guardadas.
const String automixGenreSessionsName = 'automix_genres.json';

/// Clave JSON del mapa firma -> sesion. Orden = LRU (la mas vieja primero).
const String kAutomixGenreSessionsKey = 'sessionsByGenre';

/// Maximo de firmas de genero guardadas (LRU).
const int kAutomixGenreSessionCap = 20;

/// Maximo de rutas ya sonadas por genero (se quedan las mas recientes).
const int kAutomixGenrePlayedCap = 256;

/// Ruta de [automixGenreSessionsName] en la carpeta de [automixPath].
String automixGenreSessionsPathFor(String automixPath) =>
    '${File(automixPath).parent.path}${Platform.pathSeparator}'
    '$automixGenreSessionsName';

/// Sesion congelada de un genero: [window] empieza en la pista actual y
/// guarda hasta [kRollingWindowSize] pistas; [played] esta acotado.
class AutomixGenreSessionState {
  const AutomixGenreSessionState({
    required this.window,
    required this.positionMs,
    required this.played,
    this.savedAtMs = 0,
  });

  final List<String> window;
  final int positionMs;
  final List<String> played;
  final int savedAtMs;

  String? get current => window.isEmpty ? null : window.first;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'window': window,
    'positionMs': positionMs,
    'played': played,
    'savedAtMs': savedAtMs,
  };

  static AutomixGenreSessionState? fromJson(Object? raw) {
    if (raw is! Map) return null;
    List<String> list(Object? v) => v is List
        ? <String>[
            for (final Object? e in v)
              if (e != null && e.toString().isNotEmpty) e.toString(),
          ]
        : <String>[];
    final List<String> window = list(raw['window']);
    if (window.isEmpty) return null;
    final Object? pos = raw['positionMs'];
    final Object? at = raw['savedAtMs'];
    return AutomixGenreSessionState(
      window: window.length > kRollingWindowSize
          ? window.sublist(0, kRollingWindowSize)
          : window,
      positionMs: pos is int && pos > 0 ? pos : 0,
      played: capAutomixGenrePlayed(list(raw['played'])),
      savedAtMs: at is int ? at : 0,
    );
  }
}

/// Ya sonadas sin duplicados y con las [cap] mas recientes (orden original).
List<String> capAutomixGenrePlayed(
  Iterable<String> played, {
  int cap = kAutomixGenrePlayedCap,
}) {
  final List<String> all = played.toList();
  final Set<String> seen = <String>{};
  final List<String> rev = <String>[];
  for (var i = all.length - 1; i >= 0 && rev.length < cap; i--) {
    if (seen.add(audioPathKey(all[i]))) rev.add(all[i]);
  }
  return rev.reversed.toList();
}

/// Congela la sesion de un genero. Las pistas antes de la actual cuentan
/// como sonadas (aunque la vista no estuviera abierta para marcarlas).
AutomixGenreSessionState? freezeAutomixGenreSession({
  required List<String> playlist,
  required int currentIndex,
  required int positionMs,
  required Iterable<String> played,
  int savedAtMs = 0,
}) {
  if (playlist.isEmpty || currentIndex < 0 || currentIndex >= playlist.length) {
    return null;
  }
  final int end = min(playlist.length, currentIndex + kRollingWindowSize);
  return AutomixGenreSessionState(
    window: List<String>.of(playlist.sublist(currentIndex, end)),
    positionMs: positionMs > 0 ? positionMs : 0,
    played: capAutomixGenrePlayed(<String>[
      ...playlist.take(currentIndex),
      ...played,
    ]),
    savedAtMs: savedAtMs,
  );
}

/// Pone [session] como la mas reciente y descarta las mas viejas sobre [cap].
Map<String, AutomixGenreSessionState> putAutomixGenreSession(
  Map<String, AutomixGenreSessionState> sessions,
  String signature,
  AutomixGenreSessionState session, {
  int cap = kAutomixGenreSessionCap,
}) {
  final Map<String, AutomixGenreSessionState> out =
      <String, AutomixGenreSessionState>{
        for (final MapEntry<String, AutomixGenreSessionState> e
            in sessions.entries)
          if (e.key != signature) e.key: e.value,
      };
  out[signature] = session;
  while (out.length > cap) {
    out.remove(out.keys.first);
  }
  return out;
}

Map<String, AutomixGenreSessionState> removeAutomixGenreSession(
  Map<String, AutomixGenreSessionState> sessions,
  String signature,
) => <String, AutomixGenreSessionState>{
  for (final MapEntry<String, AutomixGenreSessionState> e in sessions.entries)
    if (e.key != signature) e.key: e.value,
};

/// Mapa desde el JSON de [automixGenreSessionsName] (orden del archivo).
Map<String, AutomixGenreSessionState> automixGenreSessionsFromJson(
  Object? doc, {
  int cap = kAutomixGenreSessionCap,
}) {
  Map<String, AutomixGenreSessionState> out =
      <String, AutomixGenreSessionState>{};
  if (doc is! Map) return out;
  final Object? raw = doc[kAutomixGenreSessionsKey];
  if (raw is! Map) return out;
  for (final MapEntry<dynamic, dynamic> e in raw.entries) {
    final String sig = e.key.toString();
    if (sig.isEmpty) continue;
    final AutomixGenreSessionState? s = AutomixGenreSessionState.fromJson(
      e.value,
    );
    if (s != null) out = putAutomixGenreSession(out, sig, s, cap: cap);
  }
  return out;
}

Map<String, dynamic> automixGenreSessionsToJson(
  Map<String, AutomixGenreSessionState> sessions,
) => <String, dynamic>{
  'schema': 1,
  kAutomixGenreSessionsKey: <String, dynamic>{
    for (final MapEntry<String, AutomixGenreSessionState> e in sessions.entries)
      e.key: e.value.toJson(),
  },
};

/// Migracion desde la sesion unica de `automix.json` (3.1.86): su firma,
/// lista, pista, segundo y ya sonadas pasan a ser la primera entrada.
/// `automix.json` no se toca.
Map<String, AutomixGenreSessionState> migrateAutomixGenreSessions(
  Object? automixDoc,
) {
  if (automixDoc is! Map) return <String, AutomixGenreSessionState>{};
  final Object? sig = automixDoc['genreSignature'];
  if (sig is! String || sig.isEmpty) {
    return <String, AutomixGenreSessionState>{};
  }
  List<String> list(Object? v) => v is List
      ? <String>[for (final Object? e in v) if (e != null) e.toString()]
      : <String>[];
  final Object? idx = automixDoc['currentIndex'];
  final Object? pos = automixDoc['positionMs'];
  final AutomixGenreSessionState? s = freezeAutomixGenreSession(
    playlist: list(automixDoc['playlist']),
    currentIndex: idx is int ? idx : -1,
    positionMs: pos is int ? pos : 0,
    played: list(automixDoc['played']),
  );
  if (s == null) return <String, AutomixGenreSessionState>{};
  return <String, AutomixGenreSessionState>{sig: s};
}

/// Lee el mapa o, si aun no existe, lo migra desde [automixPath]. Hace I/O:
/// en la app se llama con [readAutomixGenreSessionsAsync].
Map<String, AutomixGenreSessionState> readAutomixGenreSessions(
  String automixPath,
) {
  final Object? doc = SessionStore.readJson(
    automixGenreSessionsPathFor(automixPath),
  );
  if (doc is Map && doc[kAutomixGenreSessionsKey] is Map) {
    return automixGenreSessionsFromJson(doc);
  }
  return migrateAutomixGenreSessions(SessionStore.readJson(automixPath));
}

Future<Map<String, AutomixGenreSessionState>> readAutomixGenreSessionsAsync(
  String automixPath,
) => Isolate.run(() => readAutomixGenreSessions(automixPath));

/// Resultado de [resumeAutomixGenreSession]: cola desde la pista actual.
class AutomixGenreResume {
  const AutomixGenreResume({
    required this.playlist,
    required this.positionMs,
    required this.played,
    required this.sameTrack,
  });

  final List<String> playlist;
  final int positionMs;
  final List<String> played;

  /// true: la pista guardada sigue (se retoma en [positionMs]).
  final bool sameTrack;
}

/// Cola del genero que vuelve: la pista guardada (si sigue en el pool y en
/// disco), el resto de su ventana y luego el pool, sin las ya sonadas.
/// null si no queda nada (genero agotado: cola nueva y sonadas en cero).
AutomixGenreResume? resumeAutomixGenreSession(
  AutomixGenreSessionState session,
  List<String> pool, {
  bool Function(String path)? exists,
  bool? foldCase,
}) {
  final bool Function(String) ok =
      exists ?? (String p) => File(p).existsSync();
  final Set<String> inPool = audioKeySet(pool, foldCase: foldCase);
  final Set<String> played = audioKeySet(session.played, foldCase: foldCase);
  final List<String> out = <String>[];
  final Set<String> seen = <String>{};
  bool sameTrack = false;
  for (var i = 0; i < session.window.length; i++) {
    final String p = session.window[i];
    final String k = audioPathKey(p, foldCase: foldCase);
    if (!inPool.contains(k) || !ok(p)) continue;
    if (i == 0) {
      if (seen.add(k)) {
        out.add(p);
        sameTrack = true;
      }
      continue;
    }
    if (played.contains(k) || !seen.add(k)) continue;
    out.add(p);
  }
  for (final String p in pool) {
    final String k = audioPathKey(p, foldCase: foldCase);
    if (played.contains(k) || !seen.add(k)) continue;
    out.add(p);
  }
  if (out.isEmpty) return null;
  return AutomixGenreResume(
    playlist: out,
    positionMs: sameTrack ? session.positionMs : 0,
    played: session.played,
    sameTrack: sameTrack,
  );
}

/// [resumeAutomixGenreSession] en otro isolate con pools grandes.
Future<AutomixGenreResume?> resumeAutomixGenreSessionAsync(
  AutomixGenreSessionState session,
  List<String> pool,
) => pool.length > kAutomixSyncLimit
    ? Isolate.run(() => resumeAutomixGenreSession(session, pool))
    : Future<AutomixGenreResume?>.value(
        resumeAutomixGenreSession(session, pool),
      );

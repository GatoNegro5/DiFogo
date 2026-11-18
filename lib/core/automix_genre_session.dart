import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'audio_path.dart';
import 'session_restore.dart';

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

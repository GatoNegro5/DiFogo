import 'dart:math';

import 'audio_path.dart';
import 'bpm_backfill_worker.dart' show reorderQueueTail;

/// 3.1.87: ventana deslizante de Mix con Letra. La lista completa de la
/// estacion sigue en memoria solo como rutas; lo que se hidrata en cada
/// transicion (medicion de BPM y reorden armonico) queda acotado a
/// [kAutomixHydrateWindow] pistas desde la actual. La letra y los metadatos
/// ya eran solo de la actual y la siguiente. Asi el costo por transicion es
/// el mismo con 20 o con 5000 canciones.
const int kAutomixHydrateWindow = 48;

/// 3.1.88: la misma ventana para AutomixDj (Live DJ, vista de inicio).
const int kRollingWindowSize = kAutomixHydrateWindow;

/// Letras en memoria: la actual, la siguiente y un margen corto.
const int kLyricPrimeKeep = 4;

/// Candidatos a medir BPM: solo `queue[from..from+window)`.
List<String> backfillWindow(
  List<String> queue,
  int from,
  double Function(String path) bpmOf, {
  int window = kAutomixHydrateWindow,
}) {
  final int start = from < 0 ? 0 : from;
  final int end = min(queue.length, start + window);
  final List<String> out = <String>[];
  final Set<String> seen = <String>{};
  for (var i = start; i < end; i++) {
    final String p = queue[i];
    if (p.isEmpty || isKaraokeAudioPath(p)) continue;
    if (bpmOf(p) > 0) continue;
    if (seen.add(audioPathKey(p))) out.add(p);
  }
  return out;
}

/// Reorden armonico solo de `queue[fixed..fixed+window)`; el resto de la
/// lista queda igual y ninguna pista se pierde ni se duplica.
List<String>? reorderQueueWindow(
  List<String> queue,
  int fixed,
  List<String> Function(List<String> tail, String? continueFrom) order, {
  int window = kAutomixHydrateWindow,
}) {
  final int head = fixed < 0 ? 0 : fixed;
  final int end = min(queue.length, head + window);
  if (end - head < 2) return null;
  final List<String>? part = reorderQueueTail(
    queue.sublist(0, end),
    head,
    order,
  );
  if (part == null) return null;
  return <String>[...part, ...queue.sublist(end)];
}

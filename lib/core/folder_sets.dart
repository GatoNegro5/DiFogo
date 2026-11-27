import 'dart:math';

import 'gatomix_radio.dart' show warmHarmonicDna, kDnaWarmWait;
import 'genre_stations.dart'
    show stationPathKey, stationSmartShuffle, trackBlockKey;
import 'livedj_order.dart' show HarmonicDna, camelotFromPath, harmonicDnaOf;
import 'persistent_lists.dart';
import 'queue_bpm.dart' show memoryBpm, preloadQueueBpmAsync;

/// 3.2.29 Sets por carpeta y Modo Fiesta. Dart puro: arma los sets de
/// [kFolderSetSize] pistas desde las listas persistentes (`folder:<ruta>` y
/// `fiesta:<estacion>/<sub>`), sin repetir hasta agotar y retomando donde
/// quedo. No toca decks, fundidos, rampas ni preRoll.

/// Pistas por set (una carpeta elegida o un genero del Modo Fiesta).
const int kFolderSetSize = 8;

/// Grupo sin sub-genero propio en el Modo Fiesta.
const String kFiestaOtherSub = 'otros';

/// Set listo para la cola: [owner] es la clave de la lista persistente que
/// anota como sonadas sus pistas.
class TrackSet {
  const TrackSet(this.owner, this.paths);
  final String owner;
  final List<String> paths;
  bool get isEmpty => paths.isEmpty;
}

/// Clave persistente de un genero del Modo Fiesta de [station].
String fiestaListKey(String station, String sub) =>
    'fiesta:${station.trim().toLowerCase()}/${sub.trim().toLowerCase()}';

/// Genero (`<sub>`) de una clave [fiestaListKey]; null si no lo es.
String? fiestaSubOfKey(String? key) {
  if (key == null || !key.startsWith('fiesta:')) return null;
  final int slash = key.indexOf('/');
  return slash < 0 ? null : key.substring(slash + 1);
}

/// Hasta [size] pendientes de [pending] (en su orden), sin [exclude] (por
/// clave de ruta) ni repetidas.
List<String> takeFolderSet(
  List<String> pending, {
  Iterable<String> exclude = const <String>[],
  int size = kFolderSetSize,
}) {
  final Set<String> skip = <String>{
    for (final String p in exclude) persistentPathKey(p),
  };
  final List<String> out = <String>[];
  for (final String p in pending) {
    if (out.length >= size) break;
    if (skip.add(persistentPathKey(p))) out.add(p);
  }
  return out;
}

/// Siguiente set de la lista [key] con las pistas [all]. Retoma en la
/// siguiente pendiente; las de [exclude] (la que suena, la cola) no entran.
/// Si no queda ninguna pendiente fuera de [exclude], la lista se reinicia
/// (ciclo nuevo con [buildOrder]) y el set sale del ciclo nuevo.
List<String> nextListSet(
  PersistentLists lists,
  String key,
  List<String> all, {
  required PersistentBuildOrder buildOrder,
  Iterable<String> exclude = const <String>[],
  int size = kFolderSetSize,
}) {
  if (all.isEmpty) return const <String>[];
  final List<String> ex = List<String>.from(exclude);
  final PersistentPlan plan = lists.planOrResume(key, all, buildOrder);
  List<String> set = takeFolderSet(plan.queue, exclude: ex, size: size);
  if (set.isEmpty && !plan.fresh) {
    lists.reset(key);
    final PersistentPlan again = lists.planOrResume(key, all, buildOrder);
    set = takeFolderSet(again.queue, exclude: ex, size: size);
  }
  return set;
}

/// Cola tras elegir un set con musica sonando: [pinned] (siguiente ya
/// comprometida por el preRoll) primero y luego el set. Nunca la que suena
/// ni repetidas; nada del set anterior.
List<String> folderSetQueue({
  required List<String> set,
  String? current,
  List<String> pinned = const <String>[],
}) {
  final Set<String> seen = <String>{
    if (current != null) persistentPathKey(current),
  };
  final List<String> out = <String>[];
  for (final String p in <String>[...pinned, ...set]) {
    if (p.isEmpty) continue;
    if (seen.add(persistentPathKey(p))) out.add(p);
  }
  return out;
}

/// Orden dentro del set por energia (BPM, Camelot, ADN) con las reglas de
/// 3.2.28; con menos de 2 BPM conocidos queda como vino de la lista.
List<String> folderSetOrder(
  List<String> set, {
  String? after,
  Random? rng,
  double Function(String path)? bpmOf,
  String? Function(String path)? keyOf,
  HarmonicDna? Function(String path)? dnaOf,
}) {
  if (set.length < 2 || bpmOf == null) return List<String>.from(set);
  var known = 0;
  for (final String p in set) {
    if (bpmOf(p) > 0) known++;
  }
  if (known < 2) return List<String>.from(set);
  return stationSmartShuffle(
    set,
    rng ?? Random(),
    after: after,
    blockOf: (_) => null,
    bpmOf: bpmOf,
    keyOf: keyOf,
    dnaOf: dnaOf,
  );
}

/// Modo Fiesta: pistas de la estacion por sub-genero (las generales en
/// [kFiestaOtherSub]), en orden de ruta dentro de cada grupo.
Map<String, List<String>> fiestaGroups(
  List<String> all, {
  String? Function(String path)? subOf,
}) {
  final String? Function(String) f = subOf ?? trackBlockKey;
  final Map<String, List<String>> out = <String, List<String>>{};
  final Set<String> seen = <String>{};
  for (final String p in all) {
    if (!seen.add(stationPathKey(p))) continue;
    final String? raw = f(p);
    String sub = kFiestaOtherSub;
    if (raw != null && raw.isNotEmpty) {
      final int bar = raw.indexOf('|');
      sub = bar >= 0 ? raw.substring(bar + 1) : raw;
    }
    out.putIfAbsent(sub, () => <String>[]).add(p);
  }
  for (final List<String> g in out.values) {
    g.sort();
  }
  return out;
}

/// Modo Fiesta: siguiente genero. El que hace mas tiempo no suena
/// ([lastUsedMs], 0 = nunca), distinto de [current] si hay otro; empate por
/// nombre. Con un solo genero devuelve ese.
String? fiestaNextSub(Map<String, int> lastUsedMs, {String? current}) {
  if (lastUsedMs.isEmpty) return null;
  final List<String> subs = lastUsedMs.keys.toList()..sort();
  String? best;
  for (final String s in subs) {
    if (subs.length > 1 && s == current) continue;
    if (best == null || lastUsedMs[s]! < lastUsedMs[best]!) best = s;
  }
  return best ?? subs.first;
}

/// Modo Fiesta: siguiente set de [station]. Elige el genero con
/// [fiestaNextSub] (fecha de su lista persistente), toma sus proximas
/// [size] sin repetir (ciclo por genero) y las ordena con [order].
/// [current] es el genero del set anterior.
TrackSet fiestaNextSet(
  PersistentLists lists,
  String station,
  Map<String, List<String>> groups, {
  required PersistentBuildOrder buildOrder,
  String? current,
  Iterable<String> exclude = const <String>[],
  int size = kFolderSetSize,
  List<String> Function(List<String> set)? order,
}) {
  final Map<String, int> used = <String, int>{
    for (final MapEntry<String, List<String>> e in groups.entries)
      if (e.value.isNotEmpty)
        e.key: lists.get(fiestaListKey(station, e.key))?.updatedAtMs ?? 0,
  };
  final List<String> ex = List<String>.from(exclude);
  String? sub = fiestaNextSub(used, current: current);
  while (sub != null) {
    final String key = fiestaListKey(station, sub);
    final List<String> set = nextListSet(
      lists,
      key,
      groups[sub]!,
      buildOrder: buildOrder,
      exclude: ex,
      size: size,
    );
    if (set.isNotEmpty) {
      return TrackSet(key, order == null ? set : order(set));
    }
    used.remove(sub);
    sub = used.isEmpty ? null : fiestaNextSub(used, current: current);
  }
  return const TrackSet('', <String>[]);
}

/// Orden de las listas nuevas de sets (Smart Shuffle de 3.1.70/3.2.1).
List<String> folderSetBuildOrder(List<String> xs) =>
    stationSmartShuffle(xs, Random());

/// BPM y ADN del set a memoria, con tope [kDnaWarmWait]. Nunca falla.
Future<void> warmFolderSet(List<String> set) async {
  if (set.isEmpty) return;
  try {
    await Future.wait<void>(<Future<void>>[
      preloadQueueBpmAsync(set),
      warmHarmonicDna(set),
    ]).timeout(kDnaWarmWait, onTimeout: () => const <void>[]);
  } catch (_) {}
}

/// Orden de energia del set con lo que ya esta en memoria (sin disco).
List<String> folderSetEnergyOrder(List<String> set, {String? after}) =>
    folderSetOrder(
      set,
      after: after,
      bpmOf: memoryBpm,
      keyOf: camelotFromPath,
      dnaOf: harmonicDnaOf,
    );

/// Set de la carpeta [key] listo para la cola: siguiente de su lista
/// persistente, calentado ([warm]) y ordenado por energia. Con [keepHead]
/// la primera (la retomada) queda primera.
Future<TrackSet> folderSetFor(
  PersistentLists lists,
  String key,
  List<String> all, {
  List<String> exclude = const <String>[],
  bool keepHead = false,
  bool warm = true,
  PersistentBuildOrder buildOrder = folderSetBuildOrder,
}) async {
  final List<String> raw = nextListSet(
    lists,
    key,
    all,
    buildOrder: buildOrder,
    exclude: exclude,
  );
  if (raw.isEmpty) return TrackSet(key, const <String>[]);
  if (warm) await warmFolderSet(raw);
  final String? after = exclude.isEmpty ? null : exclude.first;
  final List<String> ordered = keepHead
      ? <String>[
          raw.first,
          ...folderSetEnergyOrder(raw.sublist(1), after: raw.first),
        ]
      : folderSetEnergyOrder(raw, after: after);
  return TrackSet(key, ordered);
}

/// Modo Fiesta: siguiente set de [station] calentado y ordenado por
/// energia (ver [fiestaNextSet]).
Future<TrackSet> fiestaSetFor(
  PersistentLists lists,
  String station,
  Map<String, List<String>> groups, {
  String? current,
  List<String> exclude = const <String>[],
  bool warm = true,
  PersistentBuildOrder buildOrder = folderSetBuildOrder,
}) async {
  final TrackSet raw = fiestaNextSet(
    lists,
    station,
    groups,
    buildOrder: buildOrder,
    current: current,
    exclude: exclude,
  );
  if (raw.isEmpty) return raw;
  if (warm) await warmFolderSet(raw.paths);
  return TrackSet(
    raw.owner,
    folderSetEnergyOrder(
      raw.paths,
      after: exclude.isEmpty ? null : exclude.first,
    ),
  );
}

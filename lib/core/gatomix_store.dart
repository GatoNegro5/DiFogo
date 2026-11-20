import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'audio_path.dart';
import 'library_guard.dart';

/// Un solo JSON por carpeta: `.difogo.json` (3.1.81; antes `.gatomix.json`,
/// que se sigue LEYENDO si no hay uno nuevo y nunca se borra).
///
/// Sustituye a `.dj_master_checkpoint.json`, `.gatomix_master_index.json`,
/// `.gatomix_lyric_fail.json`, `_dj_metadata.json`, `_dj_timestamps.json`,
/// `_lyrics_auto.json` y a los bancos de shuffle. La migración lee los
/// viejos, escribe el nuevo, verifica y solo entonces los borra.
/// Nunca borra mp3, `.lrc` ni pistas `_K`.
const String gatomixStoreName = '.difogo.json';

/// 3.1.81: nombre heredado del documento por carpeta (solo lectura).
const String gatomixOldStoreName = '.gatomix.json';
const String gatomixLogName = '.gatomix.log';

const int gatomixLogMaxBytes = 200 * 1024;
const int shufflePairCap = 1500;
const int shuffleRecentCap = 500;
const int shuffleAgeMax = 12;
const int shuffleSectionMaxBytes = 160 * 1024;

const Map<String, String> _legacySections = <String, String>{
  '.dj_master_checkpoint.json': 'checkpoint',
  '.gatomix_master_index.json': 'masterIndex',
  '.gatomix_lyric_fail.json': 'lyricFail',
  '_dj_metadata.json': 'djMetadata',
  '_dj_timestamps.json': 'djTimestamps',
  '_lyrics_auto.json': 'lyricsAuto',
};

const Set<String> _legacyLogs = <String>{
  '.pass1.log',
  'pass1.log',
  '.gatomix_master_headless.log',
};

const Set<String> _legacyTmp = <String>{
  '_dj_metadata.tmp',
  '_dj_timestamps.tmp',
};

bool isGatomixLegacyName(String name) =>
    _legacySections.containsKey(name) ||
    name == 'shuffle_banks.json' ||
    name == '_livedj_shuffle_banks.json' ||
    _legacyLogs.contains(name) ||
    _legacyTmp.contains(name);

bool _safeToDelete(String name) {
  final String n = name.toLowerCase();
  if (n.endsWith('.mp3') || n.endsWith('.lrc') || n.endsWith('.bak')) {
    return false;
  }
  if (n.contains('_k.')) return false;
  return isGatomixLegacyName(name);
}

class ShuffleMemory {
  final Set<String> pairs;
  final Map<String, int> age;
  const ShuffleMemory(this.pairs, this.age);
  static const ShuffleMemory empty = ShuffleMemory(<String>{}, <String, int>{});
}

class GatomixStore {
  static final String _sep = Platform.pathSeparator;

  /// Documento ya leído, por carpeta. Se invalida al escribir.
  static final Map<String, Map<String, dynamic>> _docs =
      <String, Map<String, dynamic>>{};

  /// Carpetas sin JSON viejo: `migrate` no vuelve a hacer `existsSync`.
  static final Set<String> _migratedClean = <String>{};

  /// Sube en cada escritura. Quien cachea un BPM derivado lo descarta.
  static int generation = 0;

  /// Lecturas reales del documento (no los aciertos de caché).
  static int debugDiskReads = 0;

  /// Escrituras reales del documento (síncronas y asíncronas).
  static int debugDiskWrites = 0;

  static final Map<String, Future<void>> _asyncLocks = <String, Future<void>>{};

  /// Olvida lo leído de [dirs]. Lo usa quien dejó que otro isolate leyera o
  /// escribiera esas carpetas: la próxima lectura va al disco.
  static void forget(Iterable<String> dirs) {
    for (final String dir in dirs) {
      _docs.remove(dir);
    }
    generation++;
  }

  /// Cierto si el documento de [dir] ya se leyó (o se escribió) en este proceso.
  static bool holdsDocument(String dir) => _docs.containsKey(dir);

  /// 3.2.4: seccion [key] del documento de [dir] solo si ya esta en
  /// memoria (null si no). Nunca toca el disco.
  static dynamic peekSection(String dir, String key) => _docs[dir]?[key];

  /// 3.1.72: dentro de la biblioteca protegida el documento vive en el
  /// espejo local; fuera, junto a la carpeta como siempre. 3.1.75: el
  /// espejo nuevo se escribe como `<hash>.difogo.json` en DiFogo. 3.1.81:
  /// fuera de la biblioteca se escribe `.difogo.json` junto a la carpeta.
  static File fileOf(String dir) => isLibraryPath(dir)
      ? libraryMirrorFile(dir, kMirrorStoreSuffix)
      : folderFileOf(dir);

  /// 3.1.81: `.difogo.json` dentro de la carpeta (fuera de la biblioteca).
  static File folderFileOf(String dir) => File('$dir$_sep$gatomixStoreName');

  /// `.gatomix.json` heredado dentro de la carpeta: solo lectura.
  static File legacyFileOf(String dir) => File('$dir$_sep$gatomixOldStoreName');

  /// Archivo a LEER. 3.1.75, cascada en la biblioteca protegida:
  /// 1) `<hash>.difogo.json` en DiFogo\folder_cache; 2) `<hash>.gatomix.json`
  /// heredado en DiFogo\folder_cache; 3) `<hash>.gatomix.json` en
  /// GatoMix\folder_cache (si el rename no se pudo); 4) `.gatomix.json`
  /// viejo de la carpeta musical (solo lectura). Ninguno se borra ni se
  /// reescribe: la siguiente escritura va a 1).
  /// 3.1.81, fuera de la biblioteca: `.difogo.json` y si no existe el
  /// `.gatomix.json` heredado (no se borra; la escritura va al nuevo).
  static File readFileOf(String dir) {
    if (!isLibraryPath(dir)) {
      final File neu = folderFileOf(dir);
      if (neu.existsSync()) return neu;
      final File old = legacyFileOf(dir);
      return old.existsSync() ? old : neu;
    }
    final File? mirror = libraryMirrorRead(dir, const <String>[
      kMirrorStoreSuffix,
      kOldMirrorStoreSuffix,
    ]);
    if (mirror != null) return mirror;
    final File old = legacyFileOf(dir);
    return old.existsSync() ? old : fileOf(dir);
  }

  /// Cierto si [dir] tiene documento (cualquier paso de la cascada).
  static bool hasDocument(String dir) {
    return readFileOf(dir).existsSync();
  }

  static bool migrate(String dir) {
    if (dir.isEmpty || _migratedClean.contains(dir)) return false;
    // 3.1.72: en la biblioteca no se migra ni se borra nada; los JSON
    // viejos se siguen leyendo con _legacySection.
    if (isLibraryPath(dir)) {
      _migratedClean.add(dir);
      return false;
    }
    final Directory folder = Directory(dir);
    if (!folder.existsSync()) return false;
    final List<File> pending = <File>[];
    for (final String name in <String>[
      ..._legacySections.keys,
      'shuffle_banks.json',
      '_livedj_shuffle_banks.json',
      ..._legacyLogs,
      ..._legacyTmp,
    ]) {
      final File f = File('$dir$_sep$name');
      if (f.existsSync()) pending.add(f);
    }
    if (pending.isEmpty) {
      _migratedClean.add(dir);
      return false;
    }

    final Map<String, dynamic>? existing = _read(dir);
    if (existing == null) return false;
    final Map<String, dynamic> doc = existing;
    final Map<String, dynamic> imported = _map(doc['imported']);
    final List<File> ready = <File>[];

    for (final File f in pending) {
      final String name = f.uri.pathSegments.last;
      if (_legacyTmp.contains(name)) {
        ready.add(f);
        continue;
      }
      if (_legacyLogs.contains(name)) {
        GatomixLog.fold(dir, f);
        ready.add(f);
        continue;
      }
      final Object? old = _decodeFile(f);
      if (old == null) continue;
      imported[name] = old;
      if (name == 'shuffle_banks.json') {
        final Map<String, dynamic> sh = _map(doc['shuffle']);
        sh['legacyAutomix'] = old;
        doc['shuffle'] = sh;
      } else if (name == '_livedj_shuffle_banks.json') {
        final Map<String, dynamic> sh = _map(doc['shuffle']);
        sh['legacyLive'] = old;
        doc['shuffle'] = sh;
      } else {
        final String? section = _legacySections[name];
        if (section != null) {
          doc[section] = mergeJson(doc[section], old);
        }
      }
      ready.add(f);
    }
    if (ready.isEmpty) return false;
    doc['imported'] = imported;
    if (!_write(dir, doc)) return false;
    final Map<String, dynamic>? check = _read(dir);
    if (check == null) return false;
    final Map<String, dynamic> got = _map(check['imported']);
    for (final File f in ready) {
      final String name = f.uri.pathSegments.last;
      if (!_safeToDelete(name)) continue;
      if (!_legacyLogs.contains(name) && !_legacyTmp.contains(name)) {
        final Object? old = imported[name];
        if (old == null || !jsonEqual(got[name], old)) continue;
      }
      try {
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
    _migratedClean.add(dir);
    return true;
  }

  /// Carpetas que todavía tienen un JSON o log viejo.
  static void migrateTree(String root) {
    migrate(root);
    final Directory dir = Directory(root);
    if (!dir.existsSync()) return;
    final Set<String> parents = <String>{};
    try {
      for (final FileSystemEntity e in dir.listSync(
        recursive: true,
        followLinks: false,
      )) {
        if (e is! File) continue;
        final String name = e.uri.pathSegments.last;
        if (!isGatomixLegacyName(name)) continue;
        parents.add(e.parent.path);
      }
    } catch (_) {}
    for (final String p in parents) {
      migrate(p);
    }
  }

  static dynamic section(String dir, String key) {
    migrate(dir);
    final Map<String, dynamic>? doc = _read(dir);
    if (doc != null && doc.containsKey(key)) return doc[key];
    return _legacySection(dir, key);
  }

  /// Una lectura y una escritura atómica asíncrona de la carpeta [dir].
  /// [edit] recibe el documento y devuelve cierto si cambió algo; si no
  /// cambió, no se escribe. Las llamadas de una misma carpeta van en fila.
  static Future<bool> editAsync(
    String dir,
    bool Function(Map<String, dynamic> doc) edit,
  ) {
    final Completer<bool> done = Completer<bool>();
    final Future<void> prev = _asyncLocks[dir] ?? Future<void>.value();
    final Future<void> next = prev.catchError((Object _) {}).then((_) async {
      try {
        done.complete(await _editNow(dir, edit));
      } catch (_) {
        done.complete(false);
      }
    });
    _asyncLocks[dir] = next;
    return done.future;
  }

  static Future<bool> _editNow(
    String dir,
    bool Function(Map<String, dynamic> doc) edit,
  ) async {
    if (dir.isEmpty) return false;
    migrate(dir);
    Map<String, dynamic>? doc = _docs[dir];
    if (doc == null) {
      final File f = readFileOf(dir);
      Map<String, dynamic> read = <String, dynamic>{'schema': 1};
      if (await f.exists()) {
        try {
          debugDiskReads++;
          final Object? d = jsonDecode(await f.readAsString());
          if (d is! Map) return false;
          read = Map<String, dynamic>.from(d);
        } catch (_) {
          return false;
        }
      }
      doc = _docs[dir] ?? read;
      _docs[dir] = doc;
    }
    if (!edit(doc)) return true;
    return _writeAsync(dir, doc);
  }

  static Future<bool> _writeAsync(String dir, Map<String, dynamic> doc) async {
    try {
      doc['schema'] = 1;
      final String text = jsonEncode(doc);
      final Object? parsed = jsonDecode(text);
      if (parsed is! Map) return false;
      final File dest = fileOf(dir);
      final File tmp = File('${dest.path}.tmp');
      await tmp.writeAsString(text, flush: true);
      final Object? back = jsonDecode(await tmp.readAsString());
      if (!jsonEqual(back, parsed)) {
        try {
          await tmp.delete();
        } catch (_) {}
        return false;
      }
      if (await dest.exists()) await dest.delete();
      await tmp.rename(dest.path);
      if (!isLibraryPath(dir)) hideOnWindows(dest.path);
      _docs[dir] = doc;
      _migratedClean.add(dir);
      debugDiskWrites++;
      generation++;
      return true;
    } catch (_) {
      _docs.remove(dir);
      return false;
    }
  }

  static void putSection(String dir, String key, Object? value) {
    migrate(dir);
    final Map<String, dynamic>? doc = _read(dir);
    if (doc == null) return;
    if (value == null) {
      doc.remove(key);
    } else {
      doc[key] = value;
    }
    _write(dir, doc);
  }

  static Map<String, dynamic>? readCheckpoint(String dir) {
    final dynamic v = section(dir, 'checkpoint');
    if (v is Map) return Map<String, dynamic>.from(v);
    return null;
  }

  static void writeCheckpoint(String dir, Map<String, dynamic> data) {
    putSection(dir, 'checkpoint', data);
  }

  static void clearCheckpoint(String dir) =>
      putSection(dir, 'checkpoint', null);

  static Map<String, dynamic> readMap(String dir, String key) {
    final dynamic v = section(dir, key);
    if (v is Map) return Map<String, dynamic>.from(v);
    return <String, dynamic>{};
  }

  static void writeMap(String dir, String key, Map<String, dynamic> data) {
    putSection(dir, key, data.isEmpty ? null : data);
  }

  static ShuffleMemory loadShuffleMemory(Iterable<String> paths) {
    final Set<String> pairs = <String>{};
    final Map<String, int> age = <String, int>{};
    final Set<String> dirs = <String>{
      for (final String p in paths)
        if (p.isNotEmpty) File(p).parent.path,
    };
    for (final String dir in dirs) {
      final dynamic raw = section(dir, 'shuffle');
      if (raw is! Map) continue;
      final dynamic list = raw['pairs'];
      if (list is List) {
        for (final dynamic p in list) {
          pairs.add(p.toString());
        }
      }
      final dynamic recent = raw['recent'];
      if (recent is List) {
        for (final dynamic row in recent) {
          final ({String k, int a})? parsed = _recentRow(row);
          if (parsed == null) continue;
          final int? prev = age[parsed.k];
          if (prev == null || parsed.a < prev) age[parsed.k] = parsed.a;
        }
      }
    }
    return ShuffleMemory(pairs, age);
  }

  static void commitShuffleMemory(List<String> order, {String? anchor}) {
    if (order.isEmpty && (anchor == null || anchor.isEmpty)) return;
    final List<String> seq = <String>[
      if (anchor != null && anchor.isNotEmpty) anchor,
      ...order,
    ];
    final List<String> freshPairs = <String>[];
    for (var i = 1; i < seq.length; i++) {
      if (sameAudioPath(seq[i - 1], seq[i])) continue;
      freshPairs.add(_pair(seq[i - 1], seq[i]));
    }
    final Set<String> played = <String>{
      for (final String p in seq) audioPathKey(p),
    };
    final Set<String> dirs = <String>{
      for (final String p in seq)
        if (p.isNotEmpty) File(p).parent.path,
    };
    for (final String dir in dirs) {
      final Map<String, dynamic> sh = _map(section(dir, 'shuffle'));
      final List<String> pairs = <String>[
        for (final dynamic p in (sh['pairs'] as List?) ?? const <dynamic>[])
          p.toString(),
        ...freshPairs,
      ];
      final Set<String> seen = <String>{};
      final List<String> newestFirst = <String>[];
      for (final String p in pairs.reversed) {
        if (seen.add(p)) newestFirst.add(p);
      }
      final List<String> kept = newestFirst.reversed.toList();
      final Map<String, int> ages = <String, int>{};
      final dynamic recent = sh['recent'];
      if (recent is List) {
        for (final dynamic row in recent) {
          final ({String k, int a})? parsed = _recentRow(row);
          if (parsed == null) continue;
          final int next = parsed.a + 1;
          if (next <= shuffleAgeMax) ages[parsed.k] = next;
        }
      }
      for (final String k in played) {
        ages[k] = 1;
      }
      final List<MapEntry<String, int>> ranked = ages.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      final List<MapEntry<String, int>> capped =
          ranked.length > shuffleRecentCap
          ? ranked.sublist(0, shuffleRecentCap)
          : ranked;
      sh['pairs'] = kept.length > shufflePairCap
          ? kept.sublist(kept.length - shufflePairCap)
          : kept;
      sh['recent'] = <List<Object>>[
        for (final MapEntry<String, int> e in capped) <Object>[e.key, e.value],
      ];
      _trimShuffle(sh);
      putSection(dir, 'shuffle', sh);
    }
  }

  static void _trimShuffle(Map<String, dynamic> sh) {
    List<String> pairs = <String>[
      for (final dynamic p in (sh['pairs'] as List?) ?? const <dynamic>[])
        p.toString(),
    ];
    while (pairs.length > 40 &&
        utf8.encode(jsonEncode(sh)).length > shuffleSectionMaxBytes) {
      pairs.removeAt(0);
      sh['pairs'] = pairs;
    }
  }

  static ({String k, int a})? _recentRow(dynamic row) {
    if (row is List && row.length >= 2) {
      final int? a = row[1] is num
          ? (row[1] as num).toInt()
          : int.tryParse('${row[1]}');
      if (a == null) return null;
      return (k: row[0].toString(), a: a);
    }
    if (row is Map && row['k'] != null) {
      final dynamic raw = row['a'];
      final int? a = raw is num ? raw.toInt() : int.tryParse('$raw');
      if (a == null) return null;
      return (k: '${row['k']}', a: a);
    }
    return null;
  }

  static String _pair(String a, String b) =>
      '${audioPathKey(a)}\u0001${audioPathKey(b)}';

  static dynamic _legacySection(String dir, String key) {
    for (final MapEntry<String, String> e in _legacySections.entries) {
      if (e.value != key) continue;
      final Object? old = _decodeFile(File('$dir$_sep${e.key}'));
      return old;
    }
    return null;
  }

  static Object? _decodeFile(File f) {
    if (!f.existsSync()) return null;
    try {
      return jsonDecode(f.readAsStringSync());
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic>? _read(String dir) {
    final Map<String, dynamic>? hit = _docs[dir];
    if (hit != null) return hit;
    final File f = readFileOf(dir);
    if (!f.existsSync()) return <String, dynamic>{'schema': 1};
    try {
      debugDiskReads++;
      final Object? d = jsonDecode(f.readAsStringSync());
      if (d is Map) {
        final Map<String, dynamic> map = Map<String, dynamic>.from(d);
        _docs[dir] = map;
        return map;
      }
    } catch (_) {}
    return null;
  }

  static bool _write(String dir, Map<String, dynamic> doc) {
    try {
      doc['schema'] = 1;
      final String text = jsonEncode(doc);
      final Object? parsed = jsonDecode(text);
      if (parsed is! Map) return false;
      final File dest = fileOf(dir);
      final File tmp = File('${dest.path}.tmp');
      tmp.writeAsStringSync(text, flush: true);
      final Object? back = jsonDecode(tmp.readAsStringSync());
      if (!jsonEqual(back, parsed)) {
        try {
          tmp.deleteSync();
        } catch (_) {}
        return false;
      }
      if (dest.existsSync()) dest.deleteSync();
      tmp.renameSync(dest.path);
      if (!isLibraryPath(dir)) hideOnWindows(dest.path);
      _docs[dir] = doc;
      _migratedClean.add(dir);
      debugDiskWrites++;
      generation++;
      return true;
    } catch (_) {
      _docs.remove(dir);
      return false;
    }
  }

  static Map<String, dynamic> _map(dynamic v) {
    if (v is Map) return Map<String, dynamic>.from(v);
    return <String, dynamic>{};
  }
}

Map<String, dynamic> readDjMetadata(String dir) =>
    GatomixStore.readMap(dir, 'djMetadata');

void writeDjMetadata(String dir, Map<String, dynamic> data) =>
    GatomixStore.writeMap(dir, 'djMetadata', data);

/// BPM y tonalidad de una pista, ya, en el `.gatomix.json` de su carpeta.
/// No toca el audio. Un BPM 0 no pisa uno que ya estaba.
void saveTrackMusic(String path, {required double bpm, String? camelot}) {
  if (path.isEmpty) return;
  final String dir = File(path).parent.path;
  final Map<String, dynamic> map = readDjMetadata(dir);
  if (!_mergeTrackMusic(map, null, path, bpm, camelot)) return;
  writeDjMetadata(dir, map);
}

typedef TrackMusic = ({String path, double bpm, String? camelot});

/// Igual que [saveTrackMusic] para muchas pistas: por carpeta, una lectura y
/// una escritura atómica asíncrona. No bloquea el hilo de la interfaz.
/// 3.1.17: con [stampMtime] (LAN Sync) guarda tambien en `djTimestamps` el
/// mtime actual de cada pista en la misma escritura, para no reescanearla.
Future<void> saveTrackMusicBatch(
  Iterable<TrackMusic> items, {
  bool stampMtime = false,
}) async {
  final Map<String, List<TrackMusic>> byDir = <String, List<TrackMusic>>{};
  for (final TrackMusic t in items) {
    if (t.path.isEmpty) continue;
    byDir.putIfAbsent(File(t.path).parent.path, () => <TrackMusic>[]).add(t);
  }
  for (final MapEntry<String, List<TrackMusic>> e in byDir.entries) {
    await GatomixStore.editAsync(e.key, (Map<String, dynamic> doc) {
      final dynamic raw = doc['djMetadata'];
      final Map<String, dynamic> map = raw is Map
          ? Map<String, dynamic>.from(raw)
          : <String, dynamic>{};
      final Map<String, String> slots = <String, String>{
        for (final String k in map.keys) audioPathKey(k): k,
      };
      var changed = false;
      Map<String, dynamic>? stamps;
      for (final TrackMusic t in e.value) {
        if (_mergeTrackMusic(map, slots, t.path, t.bpm, t.camelot)) {
          changed = true;
        }
        if (!stampMtime) continue;
        final int mtime;
        try {
          mtime = File(t.path).lastModifiedSync().millisecondsSinceEpoch;
        } catch (_) {
          continue;
        }
        final dynamic rawStamps = doc['djTimestamps'];
        stamps ??= rawStamps is Map
            ? Map<String, dynamic>.from(rawStamps)
            : <String, dynamic>{};
        stamps[t.path] = mtime;
      }
      if (changed) doc['djMetadata'] = map;
      if (stamps != null) {
        doc['djTimestamps'] = stamps;
        changed = true;
      }
      return changed;
    });
  }
}

/// Mezcla BPM/tonalidad de [path] en [map]. Cierto si [map] cambió.
/// [slots] (clave de ruta -> clave en [map]) evita recorrer todo el mapa
/// por pista cuando se guardan muchas; se mantiene al día.
bool _mergeTrackMusic(
  Map<String, dynamic> map,
  Map<String, String>? slots,
  String path,
  double bpm,
  String? camelot,
) {
  final String? key = camelot?.trim();
  final bool hasKey = key != null && key.isNotEmpty;
  if (bpm <= 0 && !hasKey) return false;
  final String want = audioPathKey(path);
  String? slot;
  if (slots != null) {
    slot = slots[want];
  } else {
    for (final String k in map.keys) {
      if (audioPathKey(k) != want) continue;
      slot = k;
      break;
    }
  }
  final dynamic prev = slot == null ? null : map[slot];
  var stored = bpm;
  if (stored <= 0 && prev is num) stored = prev.toDouble();
  if (stored <= 0 && prev is Map && prev['bpm'] is num) {
    stored = (prev['bpm'] as num).toDouble();
  }
  String? storedKey = hasKey ? key : null;
  if ((storedKey == null || storedKey.isEmpty) &&
      prev is Map &&
      prev['key'] is String) {
    storedKey = (prev['key'] as String).trim();
  }
  if (stored <= 0 && (storedKey == null || storedKey.isEmpty)) return false;
  final Object value = (storedKey == null || storedKey.isEmpty)
      ? stored
      : <String, dynamic>{if (stored > 0) 'bpm': stored, 'key': storedKey};
  if (slots != null && slot == path && jsonEqual(prev, value)) return false;
  if (slot != null && slot != path) map.remove(slot);
  map[path] = value;
  slots?[want] = path;
  return true;
}

/// Lo que escribe el índice de BPM. No borra una tonalidad `{bpm, key}`
/// ni pisa un BPM ya guardado con 0. Lo que no se volvió a medir se queda.
Map<String, dynamic> bpmIndexPreservingKeys(
  Map<String, dynamic> existing,
  Map<String, double> measured,
) {
  final Map<String, dynamic> out = <String, dynamic>{
    for (final MapEntry<String, dynamic> e in existing.entries) e.key: e.value,
  };
  String? slotFor(String key) {
    if (out.containsKey(key)) return key;
    final String want = audioPathKey(key);
    for (final String k in out.keys) {
      if (audioPathKey(k) == want) return k;
    }
    return null;
  }

  for (final MapEntry<String, double> e in measured.entries) {
    final String? slot = slotFor(e.key);
    final dynamic prev = slot == null ? null : out[slot];
    String? camelot;
    var prevBpm = 0.0;
    if (prev is Map) {
      if (prev['key'] is String && (prev['key'] as String).trim().isNotEmpty) {
        camelot = (prev['key'] as String).trim();
      }
      if (prev['bpm'] is num) prevBpm = (prev['bpm'] as num).toDouble();
    } else if (prev is num) {
      prevBpm = prev.toDouble();
    }
    final double bpm = e.value > 0 ? e.value : prevBpm;
    final Object value;
    if (camelot != null) {
      value = <String, dynamic>{if (bpm > 0) 'bpm': bpm, 'key': camelot};
    } else if (bpm > 0) {
      value = bpm;
    } else if (prev != null) {
      continue;
    } else {
      value = 0.0;
    }
    if (slot != null && slot != e.key) out.remove(slot);
    out[e.key] = value;
  }
  return out;
}

Map<String, dynamic> readDjTimestamps(String dir) =>
    GatomixStore.readMap(dir, 'djTimestamps');

void writeDjTimestamps(String dir, Map<String, dynamic> data) =>
    GatomixStore.writeMap(dir, 'djTimestamps', data);

Map<String, dynamic> readLyricsAuto(String dir) =>
    GatomixStore.readMap(dir, 'lyricsAuto');

void writeLyricsAuto(String dir, Map<String, dynamic> data) =>
    GatomixStore.writeMap(dir, 'lyricsAuto', data);

Map<String, dynamic> readLyricFailMap(String dir) =>
    GatomixStore.readMap(dir, 'lyricFail');

void writeLyricFailMap(String dir, Map<String, dynamic> data) =>
    GatomixStore.writeMap(dir, 'lyricFail', data);

// ---------------------------------------------------------------------------
// 3.2.3: ADN acustico por pista (seccion `dna` del documento de la carpeta).
// Escritura atomica (editAsync) y con mezcla: guardar el idioma no borra las
// metricas y guardar metricas no borra el idioma. En la biblioteca protegida
// GatomixStore.fileOf da el espejo: nunca se escribe junto al audio.
// ---------------------------------------------------------------------------

const String kTrackDnaSection = 'dna';

/// Entrada `dna[path]`. Los campos nulos no pisan lo guardado.
class TrackDnaEntry {
  final double? energy;
  final double? bassRatio;
  final double? brightness;
  final double? beatDensity;
  final String? genre;
  final int? year;
  final String? lang;
  final int? mtimeMs;

  const TrackDnaEntry({
    this.energy,
    this.bassRatio,
    this.brightness,
    this.beatDensity,
    this.genre,
    this.year,
    this.lang,
    this.mtimeMs,
  });

  bool get isEmpty =>
      energy == null &&
      bassRatio == null &&
      brightness == null &&
      beatDensity == null &&
      genre == null &&
      year == null &&
      lang == null &&
      mtimeMs == null;

  /// [newer] gana campo a campo; lo que trae nulo se conserva.
  TrackDnaEntry mergedWith(TrackDnaEntry newer) => TrackDnaEntry(
    energy: newer.energy ?? energy,
    bassRatio: newer.bassRatio ?? bassRatio,
    brightness: newer.brightness ?? brightness,
    beatDensity: newer.beatDensity ?? beatDensity,
    genre: newer.genre ?? genre,
    year: newer.year ?? year,
    lang: newer.lang ?? lang,
    mtimeMs: newer.mtimeMs ?? mtimeMs,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (_dnaUnit(energy) != null) 'energy': _dnaUnit(energy),
    if (_dnaUnit(bassRatio) != null) 'bassRatio': _dnaUnit(bassRatio),
    if (_dnaUnit(brightness) != null) 'brightness': _dnaUnit(brightness),
    if (_dnaUnit(beatDensity) != null) 'beatDensity': _dnaUnit(beatDensity),
    if (genre != null && genre!.trim().isNotEmpty) 'genre': genre!.trim(),
    if (year != null && year! > 0) 'year': year,
    if (whisperLangCode(lang) != null) 'lang': whisperLangCode(lang),
    if (mtimeMs != null && mtimeMs! > 0) 'mtimeMs': mtimeMs,
  };

  static TrackDnaEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    double? d(String k) {
      final Object? v = raw[k];
      return v is num ? _dnaUnit(v.toDouble()) : null;
    }

    int? i(String k) {
      final Object? v = raw[k];
      return v is num && v.isFinite && v > 0 ? v.toInt() : null;
    }

    final Object? g = raw['genre'];
    return TrackDnaEntry(
      energy: d('energy'),
      bassRatio: d('bassRatio'),
      brightness: d('brightness'),
      beatDensity: d('beatDensity'),
      genre: g is String && g.trim().isNotEmpty ? g.trim() : null,
      year: i('year'),
      lang: whisperLangCode(raw['lang']),
      mtimeMs: i('mtimeMs'),
    );
  }
}

double? _dnaUnit(double? v) {
  if (v == null || !v.isFinite) return null;
  return v.clamp(0.0, 1.0).toDouble();
}

String? _dnaSlot(Map<String, dynamic> map, String path) {
  if (map.containsKey(path)) return path;
  final String want = audioPathKey(path);
  for (final String k in map.keys) {
    if (audioPathKey(k) == want) return k;
  }
  return null;
}

/// ADN guardado de [path] (null si no hay).
TrackDnaEntry? readTrackDna(String path) {
  if (path.isEmpty) return null;
  final Map<String, dynamic> map = GatomixStore.readMap(
    File(path).parent.path,
    kTrackDnaSection,
  );
  final String? slot = _dnaSlot(map, path);
  final TrackDnaEntry? e = slot == null
      ? null
      : TrackDnaEntry.fromJson(map[slot]);
  _rememberDna(path, e);
  return e;
}

/// Mezcla [dna] en `dna[path]` sin borrar lo que ya habia. Una sola edicion
/// atomica por llamada; en la biblioteca protegida escribe en el espejo.
Future<bool> saveTrackDna(String path, TrackDnaEntry dna) async {
  if (path.isEmpty || dna.toJson().isEmpty) return false;
  Map<String, dynamic>? merged;
  final bool ok = await GatomixStore.editAsync(File(path).parent.path, (
    Map<String, dynamic> doc,
  ) {
    final dynamic raw = doc[kTrackDnaSection];
    final Map<String, dynamic> map = raw is Map
        ? Map<String, dynamic>.from(raw)
        : <String, dynamic>{};
    final String? slot = _dnaSlot(map, path);
    final dynamic prevRaw = slot == null ? null : map[slot];
    final TrackDnaEntry prev =
        TrackDnaEntry.fromJson(prevRaw) ?? const TrackDnaEntry();
    final Map<String, dynamic> next = prev.mergedWith(dna).toJson();
    merged = next;
    if (slot == path && jsonEqual(prevRaw, next)) return false;
    if (slot != null && slot != path) map.remove(slot);
    map[path] = next;
    doc[kTrackDnaSection] = map;
    return true;
  });
  if (ok && merged != null) _rememberDna(path, TrackDnaEntry.fromJson(merged));
  return ok;
}

// 3.2.4: cache en memoria de `dna` por pista (clave `audioPathKey`). La
// llenan saveTrackDna, readTrackDna y warmTrackDnaDir (una lectura async
// por carpeta); peekTrackDna nunca toca el disco (seguro en el hilo de UI).
final Map<String, TrackDnaEntry> _dnaMemory = <String, TrackDnaEntry>{};
final Set<String> _dnaDirsWarm = <String>{};
const int _dnaMemoryCap = 60000;

void _rememberDna(String path, TrackDnaEntry? e, {bool keep = false}) {
  if (e == null || path.isEmpty) return;
  if (_dnaMemory.length >= _dnaMemoryCap) {
    _dnaMemory.clear();
    _dnaDirsWarm.clear();
  }
  final String k = audioPathKey(path);
  if (keep && _dnaMemory.containsKey(k)) return;
  _dnaMemory[k] = e;
}

/// ADN de [path] solo desde memoria (null si no se cargo todavia).
TrackDnaEntry? peekTrackDna(String path) =>
    path.isEmpty ? null : _dnaMemory[audioPathKey(path)];

/// Carga a memoria la seccion `dna` de [dir] una vez por proceso: del
/// documento ya leido o con una lectura async del archivo (espejo en la
/// biblioteca protegida). Solo lectura; no pisa lo que ya hay en memoria.
Future<void> warmTrackDnaDir(String dir) async {
  if (dir.isEmpty || !_dnaDirsWarm.add(dir)) return;
  try {
    Object? raw = GatomixStore.peekSection(dir, kTrackDnaSection);
    if (raw == null && !GatomixStore.holdsDocument(dir)) {
      final File f = GatomixStore.readFileOf(dir);
      if (!await f.exists()) return;
      final Object? d = jsonDecode(await f.readAsString());
      raw = d is Map ? d[kTrackDnaSection] : null;
    }
    if (raw is! Map) return;
    for (final MapEntry<dynamic, dynamic> e in raw.entries) {
      final Object? k = e.key;
      if (k is String) {
        _rememberDna(k, TrackDnaEntry.fromJson(e.value), keep: true);
      }
    }
  } catch (_) {}
}

/// [warmTrackDnaDir] para las carpetas de [paths] (una por carpeta).
Future<void> warmTrackDnaFor(Iterable<String> paths) async {
  final Set<String> dirs = <String>{
    for (final String p in paths)
      if (p.isNotEmpty) File(p).parent.path,
  };
  for (final String d in dirs) {
    await warmTrackDnaDir(d);
  }
}

/// Pruebas: vacia la cache en memoria de `dna`.
void debugForgetTrackDnaMemory() {
  _dnaMemory.clear();
  _dnaDirsWarm.clear();
}

/// Codigo de idioma de Whisper valido (2-3 letras minusculas) o null.
String? whisperLangCode(Object? raw) {
  if (raw is! String) return null;
  final String s = raw.trim().toLowerCase();
  if (!RegExp(r'^[a-z]{2,3}$').hasMatch(s)) return null;
  return s;
}

/// Idioma detectado que Whisper deja en `words_json` (clave `lang`).
String? whisperLangOfWordsJson(String wordsJson) {
  try {
    final Object? o = jsonDecode(wordsJson);
    if (o is Map) return whisperLangCode(o['lang']);
  } catch (_) {}
  return null;
}

/// Guarda en `dna[audioPath].lang` el idioma que detecto Whisper, si es
/// valido. No toca las metricas. Nunca lanza.
Future<bool> saveWhisperLang(String audioPath, String wordsJson) async {
  final String? lang = whisperLangOfWordsJson(wordsJson);
  if (lang == null) return false;
  try {
    return await saveTrackDna(audioPath, TrackDnaEntry(lang: lang));
  } catch (_) {
    return false;
  }
}

dynamic mergeJson(dynamic fresh, dynamic old) {
  if (old == null) return fresh;
  if (fresh == null) return old;
  if (fresh is Map && old is Map) {
    final Map<String, dynamic> out = <String, dynamic>{};
    final Set<String> keys = <String>{
      for (final dynamic k in old.keys) k.toString(),
      for (final dynamic k in fresh.keys) k.toString(),
    };
    for (final String k in keys) {
      out[k] = mergeJson(fresh[k], old[k]);
    }
    return out;
  }
  if (fresh is List && old is List) {
    final List<dynamic> out = <dynamic>[];
    final Set<String> seen = <String>{};
    for (final dynamic item in <dynamic>[...old, ...fresh]) {
      if (seen.add(jsonEncode(item))) out.add(item);
    }
    return out;
  }
  return fresh;
}

bool jsonEqual(dynamic a, dynamic b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final dynamic k in a.keys) {
      if (!b.containsKey(k) || !jsonEqual(a[k], b[k])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!jsonEqual(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is num && b is num) return a == b;
  return a == b;
}

void hideOnWindows(String path) {
  if (!Platform.isWindows) return;
  try {
    Process.runSync('attrib', <String>['+h', path]);
  } catch (_) {}
}

/// Un solo `.gatomix.log` por carpeta. Al pasar ~200 KB se queda con la cola.
class GatomixLog {
  /// 3.1.72: en la biblioteca el log va al espejo local.
  static File fileOf(String dir) => isLibraryPath(dir)
      ? libraryMirrorFile(dir, kMirrorLogSuffix)
      : File('$dir${Platform.pathSeparator}$gatomixLogName');

  static void append(String dir, String line) {
    try {
      final File f = fileOf(dir);
      final String prev = f.existsSync() ? f.readAsStringSync() : '';
      _write(f, '$prev${DateTime.now().toIso8601String()} $line\n');
    } catch (_) {}
  }

  static void fold(String dir, File old) {
    try {
      if (!old.existsSync()) return;
      final String text = old.readAsStringSync();
      if (text.isEmpty) return;
      final File f = fileOf(dir);
      final String prev = f.existsSync() ? f.readAsStringSync() : '';
      final String name = old.uri.pathSegments.last;
      _write(f, '$prev--- $name ---\n$text');
    } catch (_) {}
  }

  static void _write(File f, String text) {
    var out = text;
    final List<int> bytes = utf8.encode(out);
    if (bytes.length > gatomixLogMaxBytes) {
      final List<int> tail = bytes.sublist(
        bytes.length - (gatomixLogMaxBytes ~/ 2),
      );
      out = utf8.decode(tail, allowMalformed: true);
      final int nl = out.indexOf('\n');
      if (nl >= 0 && nl < out.length - 1) out = out.substring(nl + 1);
    }
    // En Windows un archivo oculto no se reabre para escribir: se reemplaza.
    final File tmp = File('${f.path}.tmp');
    tmp.writeAsStringSync(out, flush: true);
    if (f.existsSync()) f.deleteSync();
    tmp.renameSync(f.path);
    hideOnWindows(f.path);
  }
}

/// 3.1.11: quita del indice de BPM (o de djTimestamps) las claves de mp3 de
/// [directoryPath] que ya no existen, p. ej. nombres viejos que un script
/// externo renombro a "(N BPM)". Se quedan las claves de los archivos
/// actuales ([presentPaths]), las de fuera de la carpeta y las que no son mp3.
Map<String, dynamic> pruneMissingBpmKeys(
  Map<String, dynamic> map, {
  required String directoryPath,
  required Iterable<String> presentPaths,
}) {
  final Set<String> keys = <String>{};
  final Set<String> names = <String>{};
  for (final String p in presentPaths) {
    keys.add(audioPathKey(p));
    final String slash = p.replaceAll('\\', '/');
    names.add(slash.substring(slash.lastIndexOf('/') + 1).toLowerCase());
  }
  var dirKey = audioPathKey(directoryPath);
  if (!dirKey.endsWith('/')) dirKey = '$dirKey/';
  bool orphan(String key) {
    if (!key.toLowerCase().endsWith('.mp3')) return false;
    if (!key.contains('/') && !key.contains('\\')) {
      return !names.contains(key.toLowerCase());
    }
    final String k = audioPathKey(key);
    if (!k.startsWith(dirKey)) return false;
    return !keys.contains(k);
  }

  return <String, dynamic>{
    for (final MapEntry<String, dynamic> e in map.entries)
      if (!orphan(e.key)) e.key: e.value,
  };
}

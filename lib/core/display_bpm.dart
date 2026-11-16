import 'dart:io';

import 'audio_path.dart';
import 'bpm_range.dart';
import 'gatomix_store.dart';
import 'phrase_grid.dart';
import '../services/track_tags.dart';

/// 3.1.43: BPM para pintar en listas y titulos, solo en memoria (cero disco
/// en build): cache de la carpeta (`bpmCacheProvider`) por ruta completa,
/// luego el BPM recordado por `TrackTags` (backfill o analisis) y al final
/// el ` (N BPM)` del nombre.
double displayBpmFor(String path, Map<String, double> cache) {
  double? raw = cache[path];
  raw ??= _indexes(cache).$1[audioPathKey(path)];
  raw ??= _indexes(cache).$2[_base(path).toLowerCase()];
  final double? fromCache = raw != null && raw > 0 ? fixBpmRange(raw) : null;
  if (fromCache != null) return fromCache;
  final double tag = TrackTags.peek(path)?.bpm ?? 0;
  final double? fromTag = tag > 0 ? fixBpmRange(tag) : null;
  if (fromTag != null) return fromTag;
  // 3.1.44: perfil de frases ya medido en memoria (pistas en decks que el
  // medidor no toca); sin abrir el archivo.
  final double grid = PhraseGridMemory.peek(path)?.bpm ?? 0;
  final double? fromGrid = grid > 0 ? fixBpmRange(grid) : null;
  if (fromGrid != null) return fromGrid;
  final RegExpMatch? m = _nameBpm.firstMatch(_base(path));
  if (m == null) return 0;
  return fixBpmRange(double.parse(m.group(1)!)) ?? 0;
}

/// 3.1.44: `djMetadata` (num o `{bpm, key}`) a mapa ruta -> BPM.
Map<String, double> bpmMapFromMetadata(Map<String, dynamic> meta) {
  final Map<String, double> out = <String, double>{};
  meta.forEach((String key, dynamic value) {
    if (value is num) {
      out[key] = value.toDouble();
    } else if (value is Map && value['bpm'] is num) {
      out[key] = (value['bpm'] as num).toDouble();
    }
  });
  return out;
}

/// 3.1.44: carpetas (sin repetir, ordenadas) de las rutas dadas, una por
/// linea; clave estable para no releer si no cambian.
String bpmDirsKey(Iterable<String?> paths) {
  final Set<String> dirs = <String>{};
  for (final String? p in paths) {
    if (p == null || p.isEmpty) continue;
    dirs.add(File(p).parent.path);
  }
  final List<String> sorted = dirs.toList()..sort();
  return sorted.join('\n');
}

/// 3.1.44: une el BPM del `.gatomix.json` de cada carpeta (el store ya
/// cachea el documento en memoria).
Map<String, double> folderBpmCache(Iterable<String> dirs) {
  final Map<String, double> out = <String, double>{};
  final Set<String> seen = <String>{};
  for (final String d in dirs) {
    if (d.isEmpty || !seen.add(d)) continue;
    try {
      out.addAll(bpmMapFromMetadata(readDjMetadata(d)));
    } catch (_) {}
  }
  return out;
}

final RegExp _nameBpm = RegExp(
  r'(?:\b|_|-)(\d{2,3}(?:\.\d+)?)\s*bpm\b',
  caseSensitive: false,
);

String _base(String path) => path.replaceAll('\\', '/').split('/').last;

// Indices por clave canonica y por nombre (claves viejas sin carpeta),
// rehechos solo cuando cambia la instancia de la cache.
Map<String, double>? _src;
(Map<String, double>, Map<String, double>) _idx = (
  <String, double>{},
  <String, double>{},
);

(Map<String, double>, Map<String, double>) _indexes(Map<String, double> c) {
  if (identical(c, _src)) return _idx;
  final Map<String, double> byKey = <String, double>{};
  final Map<String, double> byName = <String, double>{};
  for (final MapEntry<String, double> e in c.entries) {
    byKey[audioPathKey(e.key)] = e.value;
    byName.putIfAbsent(_base(e.key).toLowerCase(), () => e.value);
  }
  _src = c;
  _idx = (byKey, byName);
  return _idx;
}

import 'audio_path.dart';
import 'bpm_range.dart';
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
  final RegExpMatch? m = _nameBpm.firstMatch(_base(path));
  if (m == null) return 0;
  return fixBpmRange(double.parse(m.group(1)!)) ?? 0;
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

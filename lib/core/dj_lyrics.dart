import 'dart:io';

import 'library_guard.dart' show lrcReadFile;

/// 3.2.30 Letras en Dj: lectura de la `.lrc` de la pista que suena en Live
/// DJ. Solo lectura y Dart puro: no toca el motor de Mix con Letra ni su
/// rueda (mismo formato `[mm:ss.xx]` que lee Automix).
class DjLyricLine {
  const DjLyricLine(this.ms, this.text);

  final int ms;
  final String text;
}

final RegExp _lrcLine = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');

/// Lineas con tiempo de [content]; las vacias o sin marca se saltan.
List<DjLyricLine> parseDjLrc(String content) {
  final List<DjLyricLine> out = <DjLyricLine>[];
  for (final String raw in content.split(RegExp(r'\r?\n'))) {
    final Match? m = _lrcLine.firstMatch(raw);
    if (m == null) continue;
    final String text = m.group(4)!.trim();
    if (text.isEmpty) continue;
    final int min = int.parse(m.group(1)!);
    final int sec = int.parse(m.group(2)!);
    int ms = int.parse(m.group(3)!);
    if (m.group(3)!.length == 2) ms *= 10;
    out.add(DjLyricLine(min * 60000 + sec * 1000 + ms, text));
  }
  return out;
}

/// Linea activa en [posMs]: la ultima que ya empezo; -1 antes de la
/// primera o sin lineas.
int djLyricIndexAt(List<DjLyricLine> lines, int posMs) {
  int lo = 0;
  int hi = lines.length - 1;
  int best = -1;
  while (lo <= hi) {
    final int mid = (lo + hi) >> 1;
    if (lines[mid].ms <= posMs) {
      best = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return best;
}

/// `.lrc` junto al audio (mismo nombre que usa Mix con Letra).
String djLrcPathOf(String audioPath) => audioPath.replaceAll(
  RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
  '.lrc',
);

/// Letra de [audioPath] (espejo de la biblioteca si existe). Nunca falla:
/// sin letra devuelve lista vacia.
Future<List<DjLyricLine>> loadDjLyrics(String audioPath) async {
  try {
    final File f = lrcReadFile(audioPath, djLrcPathOf(audioPath));
    if (!f.existsSync()) return const <DjLyricLine>[];
    return parseDjLrc(await f.readAsString());
  } catch (_) {
    return const <DjLyricLine>[];
  }
}

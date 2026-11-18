import 'dart:async';
import 'dart:io';

import 'discovery_dedup_controller.dart';
import 'library_guard.dart';

/// 3.1.87: curaduria en 1 clic de la pista de Radio Descubrimiento que
/// suena (temporal, aun no guardada): Guardar y Descartar.

/// Baja la letra `.lrc` de [audioPath] y la deja junto al audio.
typedef RadioLyricFetcher = Future<void> Function(String audioPath);

/// Solo pruebas: carpeta de respaldo (en lugar de `Musica/Descargas`).
String? debugRadioFallbackRoot;

/// Carpeta propia de la app en Musica (`Descargas`, fuera del blindaje de
/// [isLibraryPath]): destino cuando la carpeta del genero cae en la
/// biblioteca protegida (ReGenial).
String radioFallbackRoot() {
  final String? o = debugRadioFallbackRoot;
  if (o != null) return o;
  final String sep = Platform.pathSeparator;
  if (Platform.isWindows) {
    final String? up = Platform.environment['USERPROFILE'];
    return '${up ?? 'C:'}${sep}Music${sep}Descargas';
  }
  if (Platform.isAndroid) return '/storage/emulated/0/Music/Descargas';
  final String? home = Platform.environment['HOME'];
  return '${home ?? Directory.systemTemp.path}${sep}Music${sep}Descargas';
}

/// [libraryDir] si se puede escribir; si cae en la biblioteca protegida,
/// [fallbackDir]. Nunca devuelve una carpeta de ReGenial.
String radioSaveDir({required String libraryDir, required String fallbackDir}) =>
    isLibraryPath(libraryDir) ? fallbackDir : libraryDir;

/// Ruta libre `stem.mp3`, `stem (2).mp3`... (consulta async).
Future<String> radioFreePath(String dir, String stem, {String ext = '.mp3'}) async {
  final String sep = Platform.pathSeparator;
  String p = '$dir$sep$stem$ext';
  int n = 2;
  while (await File(p).exists()) {
    p = '$dir$sep$stem ($n)$ext';
    n++;
  }
  return p;
}

class RadioSaveResult {
  const RadioSaveResult(this.path, this.lyrics);

  /// Donde quedo el audio guardado.
  final String path;

  /// Job de la letra en 2do plano (ya lanzado, no se espera para sonar).
  final Future<void> lyrics;
}

/// Guardar: copia el temporal a [targetDir] (la musica sigue sonando desde
/// el temporal, sin tocar los decks) y lanza sin esperar la letra.
Future<RadioSaveResult> radioSaveTrack({
  required String tempPath,
  required String targetDir,
  required String stem,
  RadioLyricFetcher? fetchLyrics,
}) async {
  if (libraryWriteBlocked(targetDir, what: 'RADIO')) {
    throw StateError('carpeta protegida: $targetDir');
  }
  await Directory(targetDir).create(recursive: true);
  final int dot = tempPath.lastIndexOf('.');
  final String ext = dot > 0 && tempPath.length - dot <= 5
      ? tempPath.substring(dot)
      : '.mp3';
  final String dst = await radioFreePath(targetDir, stem, ext: ext);
  await File(tempPath).copy(dst);
  Future<void> lyrics = Future<void>.value();
  if (fetchLyrics != null) {
    lyrics = Future<void>(() => fetchLyrics(dst)).catchError((Object _) {});
    unawaited(lyrics);
  }
  return RadioSaveResult(dst, lyrics);
}

/// Borra el temporal; si el deck aun lo tiene abierto (Windows) reintenta.
Future<bool> radioDeleteTemp(
  String path, {
  int attempts = 8,
  Duration every = const Duration(seconds: 4),
}) async {
  for (var i = 0; i < attempts; i++) {
    try {
      final File f = File(path);
      if (!await f.exists()) return true;
      await f.delete();
      return true;
    } catch (_) {}
    if (i < attempts - 1) await Future<void>.delayed(every);
  }
  return false;
}

/// Descartar: bloquea la huella, salta a la siguiente por el camino normal
/// ([skip]: siguiente con cruce del motor) y borra el temporal.
Future<bool> radioDiscardTrack({
  required String tempPath,
  required String title,
  required DiscoveryDedupController dedup,
  required Future<void> Function() skip,
  Duration retryEvery = const Duration(seconds: 4),
}) async {
  await dedup.discard(title: title, filename: tempPath);
  await skip();
  return radioDeleteTemp(tempPath, every: retryEvery);
}

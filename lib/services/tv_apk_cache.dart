import 'dart:async';
import 'dart:io';

import '../core/brand_paths.dart';
import '../core/net/safe_download.dart';

/// 3.2.25: cache local unica del APK de Karaoke para Google TV. La usan el
/// asistente sin ADB (lo sirve `TvSyncServer` en `/apk`) y el flujo ADB
/// avanzado. Windows: `%LOCALAPPDATA%\GatoMix\tv_cache\gatomix-tv.apk`;
/// macOS: `~/Library/Application Support/GatoMix/tv_cache/gatomix-tv.apk`.

/// Nombre fijo del artefacto (no cambiar: lo publica el CI con este nombre).
const String kTvApkName = 'gatomix-tv.apk';

/// APK compilado por el CI en el ultimo release.
const String kTvApkUrl =
    'https://github.com/GatoNegro5/DiFogo/releases/latest/download/$kTvApkName';

/// Un APK valido pesa mas de 10 MB (el real ronda 90 MB).
const int kTvApkMinBytes = 10 * 1024 * 1024;

/// Solo pruebas: carpeta de cache que reemplaza a la real.
String? debugTvApkCacheRoot;

/// Carpeta `tv_cache` dentro de la carpeta de datos de la marca.
String tvApkCacheDir() {
  final String? o = debugTvApkCacheRoot;
  if (o != null) return o;
  final String base = Platform.isWindows
      ? (Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path)
      : '${Platform.environment['HOME'] ?? Directory.systemTemp.path}'
            '${Platform.isMacOS ? '/Library/Application Support' : '/.local/share'}';
  return '${ensureBrandDataDir(base).path}${Platform.pathSeparator}tv_cache';
}

/// Archivo del APK en la cache ([root] reemplaza la carpeta, p. ej. pruebas).
File tvApkCacheFile({String? root}) =>
    File('${root ?? tvApkCacheDir()}${Platform.pathSeparator}$kTvApkName');

/// Avance de la descarga: bytes recibidos y total (null si no se conoce).
typedef TvApkProgress = void Function(int received, int? total);

/// Descarga rechazada (corta, truncada o sin forma de APK).
class TvApkDownloadException implements Exception {
  final String message;
  const TvApkDownloadException(this.message);
  @override
  String toString() => message;
}

class TvApkCache {
  /// [root] y [url] inyectables para pruebas. [fallback] permite el respaldo
  /// `downloadFileRobust` (curl/PowerShell en Windows) si HttpClient falla.
  TvApkCache({
    this.root,
    this.url = kTvApkUrl,
    this.minBytes = kTvApkMinBytes,
    this.fallback = true,
  });

  final String? root;
  final String url;
  final int minBytes;
  final bool fallback;

  /// Una sola descarga por archivo aunque la pidan el asistente y ADB.
  static final Map<String, Future<File>> _inflight = <String, Future<File>>{};

  File get file => tvApkCacheFile(root: root);

  File get _tmp => File('${file.path}.tmp');

  /// Cierto si el APK cacheado existe, pesa mas de [minBytes] y empieza
  /// como ZIP (`PK`).
  Future<bool> isValid() => _looksLikeApk(file);

  Future<bool> _looksLikeApk(File f) async {
    try {
      if (!await f.exists()) return false;
      if (await f.length() <= minBytes) return false;
      final RandomAccessFile raf = await f.open();
      try {
        final List<int> head = await raf.read(2);
        return head.length == 2 && head[0] == 0x50 && head[1] == 0x4B;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  /// Devuelve el APK de la cache; lo baja si falta, no es valido o [force]
  /// (boton 'Actualizar APK').
  Future<File> ensure({bool force = false, TvApkProgress? onProgress}) {
    final String key = file.path;
    final Future<File>? running = _inflight[key];
    if (running != null) return running;
    final Future<File> job = () async {
      if (!force && await isValid()) return file;
      await _download(onProgress);
      return file;
    }();
    _inflight[key] = job;
    return job.whenComplete(() => _inflight.remove(key));
  }

  /// Descarga atomica: `.tmp`, validacion (Content-Length y tamano minimo) y
  /// rename. El `.tmp` nunca queda; un APK valido previo solo se reemplaza
  /// por otro valido.
  Future<void> _download(TvApkProgress? onProgress) async {
    final File tmp = _tmp;
    await tmp.parent.create(recursive: true);
    try {
      if (await tmp.exists()) await tmp.delete();
      int? expected;
      bool viaHttp = false;
      try {
        expected = await _httpDownload(tmp, onProgress);
        viaHttp = true;
      } catch (_) {
        if (!fallback) rethrow;
        if (await tmp.exists()) await tmp.delete();
        await downloadFileRobust(url, tmp.path);
      }
      final int got = await tmp.exists() ? await tmp.length() : 0;
      if (viaHttp && expected != null && got != expected) {
        throw TvApkDownloadException(
          'Descarga incompleta del APK ($got de $expected bytes).',
        );
      }
      if (got <= minBytes) {
        throw TvApkDownloadException(
          'El APK descargado es demasiado chico ($got bytes).',
        );
      }
      if (!await _looksLikeApk(tmp)) {
        throw const TvApkDownloadException(
          'El archivo descargado no es un APK.',
        );
      }
      await _replace(tmp, file);
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }

  /// Baja [url] a [tmp] en streaming. Devuelve el Content-Length (null si
  /// el servidor no lo manda).
  Future<int?> _httpDownload(File tmp, TvApkProgress? onProgress) async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final HttpClientRequest req = await client.getUrl(Uri.parse(url));
      req.followRedirects = true;
      final HttpClientResponse res = await req.close();
      if (res.statusCode != HttpStatus.ok) {
        await res.drain<void>();
        throw TvApkDownloadException('HTTP ${res.statusCode} al bajar el APK.');
      }
      final int? total = res.contentLength >= 0 ? res.contentLength : null;
      final IOSink sink = tmp.openWrite();
      int received = 0;
      try {
        await for (final List<int> chunk in res) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      return total;
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> _replace(File from, File to) async {
    try {
      await from.rename(to.path);
    } on FileSystemException {
      if (await to.exists()) await to.delete();
      await from.rename(to.path);
    }
  }
}

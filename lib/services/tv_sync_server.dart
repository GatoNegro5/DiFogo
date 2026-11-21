import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/safe_media_path.dart';
import 'tv_apk_cache.dart';

class TvSyncServer {
  /// 3.2.25: [port] y [apkCacheRoot] inyectables (pruebas en puerto 0 y
  /// cache en %TEMP%); la app usa siempre 55056 y la cache real.
  TvSyncServer({this.port = 55056, this.apkCacheRoot});

  HttpServer? _server;
  final List<WebSocket> _clients = [];
  final int port;
  final String? apkCacheRoot;
  Future<void>? _starting;

  /// Puerto real (con [port] 0 lo elige el sistema).
  int get boundPort => _server?.port ?? port;

  bool get isRunning => _server != null;
  void Function(Map<String, dynamic> message)? onTvMessage;
  void Function()? onTvJoined;

  bool get hasTvClient =>
      _clients.any((client) => client.readyState == WebSocket.open);

  Future<void> start() => _starting ??= _start();

  /// 3.2.25: garantiza el nodo levantado antes de mostrar la URL de /apk;
  /// si el primer bind fallo, reintenta una vez.
  Future<bool> ensureStarted() async {
    await start();
    if (_server == null) {
      _starting = _start();
      await _starting;
    }
    return _server != null;
  }

  Future<void> _start() async {
    try {
      // 0.0.0.0 expone el puerto a toda tu red LAN (WiFi)
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      debugPrint("🟢 [TV SYNC] Nodo Emisor WebSocket activo en puerto $port");

      _server!.listen((HttpRequest request) {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          WebSocketTransformer.upgrade(request).then((WebSocket ws) {
            _clients.add(ws);
            debugPrint(
              "🟢 [TV SYNC] TV Conectada. Clientes activos: ${_clients.length}",
            );
            onTvJoined?.call();

            ws.listen(
              (data) {
                try {
                  final decoded = jsonDecode('$data');
                  if (decoded is Map<String, dynamic>) {
                    onTvMessage?.call(decoded);
                  }
                } catch (_) {}
              },
              onDone: () {
                _clients.remove(ws);
                debugPrint("🔴 [TV SYNC] TV Desconectada.");
              },
              onError: (e) {
                _clients.remove(ws);
              },
            );
          });
        } else {
          _serveKaraokeFile(request);
        }
      });
    } catch (e) {
      debugPrint("🔴 [TV SYNC FATAL] Fallo al iniciar puerto $port: $e");
    }
  }

  // Método genérico para disparar payloads JSON a la TV
  void broadcastPayload(Map<String, dynamic> payload) {
    if (_clients.isEmpty) return;

    final String msg = jsonEncode(payload);
    for (var ws in _clients) {
      if (ws.readyState == WebSocket.open) {
        ws.add(msg);
      }
    }
  }

  // Dispara el archivo LRC completo cuando cargas una canción
  void broadcastLrcTrack(String trackName, String lrcContent) {
    broadcastPayload({
      'type': 'LRC_LOAD',
      'track': trackName,
      'payload': lrcContent,
    });
  }

  // Dispara el reloj (Ping de sincronización)
  void broadcastSyncPing(int positionMs, bool isPlaying) {
    broadcastPayload({
      'type': 'SYNC_PING',
      'positionMs': positionMs,
      'isPlaying': isPlaying,
    });
  }

  void broadcastEdgeExecute({
    required String mp3Url,
    required String lrcUrl,
    required String trackName,
    required String singer,
  }) {
    broadcastPayload({
      'type': 'EDGE_EXECUTE',
      'mp3_url': mp3Url,
      'lrc_url': lrcUrl,
      'track_name': trackName,
      'singer': singer,
    });
  }

  void broadcastEdgePreload({
    required String mp3Url,
    required String lrcUrl,
    required String trackName,
    required String singer,
  }) {
    broadcastPayload({
      'type': 'EDGE_PRELOAD',
      'mp3_url': mp3Url,
      'lrc_url': lrcUrl,
      'track_name': trackName,
      'singer': singer,
    });
  }

  void broadcastScoreboard({
    required String singer,
    required String trackName,
    required Map<String, int> votes,
    String? nextSinger,
    String? nextTrack,
  }) {
    broadcastPayload({
      'type': 'SCOREBOARD',
      'singer': singer,
      'track_name': trackName,
      'votes': votes,
      'next_singer': nextSinger,
      'next_track': nextTrack,
    });
  }

  void broadcastEdgePause() {
    broadcastPayload({'type': 'EDGE_PAUSE'});
  }

  void broadcastEdgeResume() {
    broadcastPayload({'type': 'EDGE_RESUME'});
  }

  void broadcastEdgeStop() {
    broadcastPayload({'type': 'EDGE_STOP'});
  }

  void broadcastSessionEnd() {
    broadcastPayload({'type': 'SESSION_END'});
  }

  void broadcastStageState({
    required List<Map<String, String>> queue,
    required Map<String, String> current,
    required Map<String, int> votes,
    required bool sessionActive,
    required bool paused,
    required String qrUrl,
  }) {
    broadcastPayload({
      'type': 'STAGE_STATE',
      'queue': queue,
      'current': current,
      'votes': votes,
      'session': sessionActive,
      'paused': paused,
      'qr_url': qrUrl,
    });
  }

  Future<void> _serveKaraokeFile(HttpRequest request) async {
    try {
      // 3.2.25: /apk fijo (GET y HEAD) antes de cualquier otra ruta.
      if (request.uri.path == '/apk') {
        await _serveApk(request);
        return;
      }
      if (request.method != 'GET') {
        request.response
          ..statusCode = HttpStatus.methodNotAllowed
          ..close();
        return;
      }

      if (request.uri.path == '/api/whoami' || request.uri.path == '/whoami') {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({'role': 'gatomix-karaoke', 'service': 'tv-sync'}),
          );
        await request.response.close();
        return;
      }

      final raw = request.uri.queryParameters['p'];
      if (raw == null || raw.isEmpty) {
        request.response
          ..statusCode = HttpStatus.badRequest
          ..close();
        return;
      }

      // 3.2.24: solo audio o .lrc estrictamente dentro de la biblioteca o
      // del espejo de letras (ruta canonica, sin `..` ni prefijo hermano).
      // Cualquier otra ruta -> 403 sin detalles del disco.
      final file = File(raw);
      final bool allowed = isSafeMediaPath(raw) && await file.exists();
      if (!allowed) {
        request.response
          ..statusCode = HttpStatus.forbidden
          ..close();
        return;
      }

      request.response.headers.contentType = _mediaContentType(
        mediaExtension(raw),
      );
      await request.response.addStream(file.openRead());
      await request.response.close();
    } catch (e) {
      debugPrint('🔴 [TV SYNC] HTTP $e');
      try {
        request.response
          ..statusCode = HttpStatus.internalServerError
          ..close();
      } catch (_) {}
    }
  }

  /// 3.2.25: sirve SOLO el APK de la cache `tv_cache` (nunca una ruta que
  /// mande el cliente). Sin APK -> 404 en texto plano.
  Future<void> _serveApk(HttpRequest request) async {
    final HttpResponse res = request.response;
    if (request.method != 'GET' && request.method != 'HEAD') {
      res.statusCode = HttpStatus.methodNotAllowed;
      await res.close();
      return;
    }
    final File apk = tvApkCacheFile(root: apkCacheRoot);
    if (!await apk.exists()) {
      res
        ..statusCode = HttpStatus.notFound
        ..headers.contentType = ContentType('text', 'plain', charset: 'utf-8')
        ..write(
          'GatoMix: el APK de la TV todavia no esta listo. En la laptop abre '
          'Karaoke > Instalar en TV > Preparar APK y vuelve a intentar.',
        );
      await res.close();
      return;
    }
    final int length = await apk.length();
    res.statusCode = HttpStatus.ok;
    res.headers.contentType = ContentType(
      'application',
      'vnd.android.package-archive',
    );
    res.headers.set(
      'Content-Disposition',
      'attachment; filename="$kTvApkName"',
    );
    res.contentLength = length;
    if (request.method == 'HEAD') {
      await res.close();
      return;
    }
    await res.addStream(apk.openRead());
    await res.close();
  }

  /// 3.2.24: tipo MIME por extension permitida.
  static ContentType _mediaContentType(String ext) {
    switch (ext) {
      case '.lrc':
        return ContentType('text', 'plain', charset: 'utf-8');
      case '.wav':
        return ContentType('audio', 'wav');
      case '.flac':
        return ContentType('audio', 'flac');
      case '.m4a':
        return ContentType('audio', 'mp4');
      case '.aac':
        return ContentType('audio', 'aac');
      case '.ogg':
        return ContentType('audio', 'ogg');
      default:
        return ContentType('audio', 'mpeg');
    }
  }

  void stop() {
    for (var ws in _clients) {
      ws.close();
    }
    _clients.clear();
    _server?.close(force: true);
    _server = null;
    _starting = null;
    debugPrint("🔴 [TV SYNC] Nodo Emisor destruido.");
  }
}

// Inyección en Riverpod para que viva de forma global
final tvSyncProvider = Provider<TvSyncServer>((ref) {
  final server = TvSyncServer();
  server.start();

  ref.onDispose(() {
    server.stop();
  });

  return server;
});

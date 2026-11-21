import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/safe_media_path.dart';
import 'tv_apk_cache.dart';

/// 3.2.26: codigo de cierre WebSocket para PIN ausente o incorrecto.
const int kTvAuthCloseCode = 4001;

/// 3.2.26: sin TV_POS en este lapso la letra de la laptop se congela.
const Duration kTvPosTimeout = Duration(seconds: 2);

/// 3.2.26: comparacion de PIN en tiempo constante (no corta en el primer
/// digito distinto). PIN vacio nunca coincide.
bool tvPinMatches(String given, String expected) {
  if (expected.isEmpty) return false;
  final List<int> a = utf8.encode(given);
  final List<int> b = utf8.encode(expected);
  int diff = a.length ^ b.length;
  for (int i = 0; i < b.length; i++) {
    diff |= (i < a.length ? a[i] : 0) ^ b[i];
  }
  return diff == 0;
}

/// 3.2.26: posicion real que reporta la TV (`TV_POS`).
class TvPosition {
  final int positionMs;
  final int durationMs;
  final bool playing;
  final DateTime receivedAt;

  const TvPosition({
    required this.positionMs,
    required this.durationMs,
    required this.playing,
    required this.receivedAt,
  });

  /// `{type: TV_POS, positionMs, durationMs, playing}`; null si no cuadra.
  static TvPosition? tryParse(Map<String, dynamic> m, {DateTime? now}) {
    final Object? pos = m['positionMs'];
    final Object? dur = m['durationMs'];
    final Object? playing = m['playing'];
    if (pos is! num || playing is! bool) return null;
    final int p = pos.toInt();
    final int d = dur is num ? dur.toInt() : 0;
    return TvPosition(
      positionMs: p < 0 ? 0 : p,
      durationMs: d < 0 ? 0 : d,
      playing: playing,
      receivedAt: now ?? DateTime.now(),
    );
  }

  /// Posicion estimada en [now]: interpola solo si `playing`; null si el
  /// ultimo TV_POS es mas viejo que [timeout] (senal perdida).
  int? estimateMs(DateTime now, {Duration timeout = kTvPosTimeout}) {
    final int age = now.difference(receivedAt).inMilliseconds;
    if (age > timeout.inMilliseconds) return null;
    if (!playing || age <= 0) return positionMs;
    final int ms = positionMs + age;
    return durationMs > 0 && ms > durationMs ? durationMs : ms;
  }
}

class TvSyncServer {
  /// 3.2.25: [port] y [apkCacheRoot] inyectables (pruebas en puerto 0 y
  /// cache en %TEMP%); la app usa siempre 55056 y la cache real.
  /// 3.2.26: [authTimeout] = espera del TV_AUTH si la URL no trae `?pin=`.
  TvSyncServer({
    this.port = 55056,
    this.apkCacheRoot,
    this.authTimeout = const Duration(seconds: 5),
  });

  HttpServer? _server;

  /// 3.2.26: SOLO sockets autenticados (broadcasts y comandos).
  final List<WebSocket> _clients = [];

  /// 3.2.26: sockets abiertos que aun no mandan un PIN valido.
  final Set<WebSocket> _pending = <WebSocket>{};
  final Duration authTimeout;
  String _sessionPin = '';
  final StreamController<TvPosition> _positions =
      StreamController<TvPosition>.broadcast();
  TvPosition? _lastPosition;

  /// 3.2.26: PIN de 4 digitos de esta sesion del nodo (se ve en la UI de
  /// la laptop; nunca sale en /api/whoami).
  String get sessionPin => _sessionPin;

  /// 3.2.26: posiciones reales de la TV autenticada.
  Stream<TvPosition> get positions => _positions.stream;
  TvPosition? get lastPosition => _lastPosition;
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

  static String _newPin() => (1000 + Random.secure().nextInt(9000)).toString();

  Future<void> _start() async {
    if (_sessionPin.isEmpty) _sessionPin = _newPin();
    try {
      // 0.0.0.0 expone el puerto a toda tu red LAN (WiFi)
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      debugPrint("🟢 [TV SYNC] Nodo Emisor WebSocket activo en puerto $port");

      _server!.listen((HttpRequest request) {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          final String? urlPin = request.uri.queryParameters['pin'];
          WebSocketTransformer.upgrade(
            request,
          ).then((WebSocket ws) => _acceptSocket(ws, urlPin));
        } else {
          _serveKaraokeFile(request);
        }
      });
    } catch (e) {
      debugPrint("🔴 [TV SYNC FATAL] Fallo al iniciar puerto $port: $e");
    }
  }

  /// 3.2.26: un socket entra a [_clients] solo con el PIN correcto, por
  /// `?pin=` en la URL o por `{type: TV_AUTH, pin}` como primer mensaje
  /// (con [authTimeout]). Si falta o no coincide: cierre 4001 y ningun
  /// comando (TV_SKIP, TV_PAUSE, TV_POS...) llega a la app.
  void _acceptSocket(WebSocket ws, String? urlPin) {
    bool authed = false;
    bool rejected = false;
    Timer? authTimer;

    void admit() {
      authed = true;
      authTimer?.cancel();
      _pending.remove(ws);
      _clients.add(ws);
      debugPrint(
        "🟢 [TV SYNC] TV Conectada. Clientes activos: ${_clients.length}",
      );
      onTvJoined?.call();
    }

    void reject() {
      if (rejected) return;
      rejected = true;
      authTimer?.cancel();
      _pending.remove(ws);
      _clients.remove(ws);
      debugPrint('🔴 [TV SYNC] PIN ausente o incorrecto: cierre 4001.');
      unawaited(ws.close(kTvAuthCloseCode, 'PIN incorrecto'));
    }

    ws.listen(
      (data) {
        if (rejected) return;
        Map<String, dynamic>? decoded;
        try {
          final Object? d = jsonDecode('$data');
          if (d is Map<String, dynamic>) decoded = d;
        } catch (_) {}
        if (!authed) {
          if (decoded != null &&
              decoded['type'] == 'TV_AUTH' &&
              tvPinMatches('${decoded['pin'] ?? ''}', _sessionPin)) {
            admit();
          } else {
            reject();
          }
          return;
        }
        if (decoded == null) return;
        if (decoded['type'] == 'TV_POS') {
          final TvPosition? pos = TvPosition.tryParse(decoded);
          if (pos != null) {
            _lastPosition = pos;
            _positions.add(pos);
          }
          return;
        }
        onTvMessage?.call(decoded);
      },
      onDone: () {
        authTimer?.cancel();
        _pending.remove(ws);
        if (_clients.remove(ws)) debugPrint("🔴 [TV SYNC] TV Desconectada.");
      },
      onError: (e) {
        authTimer?.cancel();
        _pending.remove(ws);
        _clients.remove(ws);
      },
    );

    // El listen va antes de decidir: close() sobre un socket sin oyente
    // falla en dart:io.
    _pending.add(ws);
    if (urlPin != null) {
      if (tvPinMatches(urlPin, _sessionPin)) {
        admit();
      } else {
        reject();
      }
    } else {
      authTimer = Timer(authTimeout, () {
        if (!authed) reject();
      });
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
    for (final WebSocket ws in _pending) {
      ws.close(kTvAuthCloseCode, 'Nodo detenido');
    }
    _pending.clear();
    _sessionPin = '';
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

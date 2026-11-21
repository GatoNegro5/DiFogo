import 'dart:convert';
import 'dart:io';

import 'package:difogo/core/library_guard.dart';
import 'package:difogo/services/tv_apk_cache.dart';
import 'package:difogo/services/tv_sync_server.dart';
import 'package:flutter_test/flutter_test.dart';

// 3.2.25: /apk del nodo TV (GET y HEAD) servido solo desde la cache
// tv_cache, y la cache del APK (descarga atomica .tmp + validacion). Todo en
// %TEMP%, servidor en puerto efimero (nunca el 55056 real) y sin internet.

final String _s = Platform.pathSeparator;

List<int> _fakeApk(int size) {
  final List<int> b = List<int>.generate(size, (int i) => i % 251);
  b[0] = 0x50;
  b[1] = 0x4B;
  return b;
}

Future<({int status, HttpHeaders headers, List<int> body})> _call(
  int port,
  String method,
  String path,
) async {
  final HttpClient c = HttpClient();
  try {
    final HttpClientRequest req = await c.openUrl(
      method,
      Uri.parse('http://127.0.0.1:$port$path'),
    );
    final HttpClientResponse res = await req.close();
    final List<int> body = <int>[];
    await for (final List<int> chunk in res) {
      body.addAll(chunk);
    }
    return (status: res.statusCode, headers: res.headers, body: body);
  } finally {
    c.close(force: true);
  }
}

void main() {
  late Directory tmp;
  late String cacheDir;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gmx_3225_');
    cacheDir = '${tmp.path}${_s}tv_cache';
    debugLibraryRoots = <String>[tmp.path];
    debugLibraryCacheRoot = '${tmp.path}${_s}lyrics_cache';
    debugLegacyLibraryCacheRoot = null;
  });

  tearDown(() async {
    debugLibraryRoots = null;
    debugLibraryCacheRoot = null;
    debugLegacyLibraryCacheRoot = null;
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('3.2.25 endpoint /apk del nodo TV', () {
    late TvSyncServer server;

    setUp(() async {
      server = TvSyncServer(port: 0, apkCacheRoot: cacheDir);
      expect(await server.ensureStarted(), isTrue);
      expect(server.boundPort, isNot(55056));
    });

    tearDown(() => server.stop());

    test('GET /apk sin APK cacheado -> 404 texto plano', () async {
      final r = await _call(server.boundPort, 'GET', '/apk');
      expect(r.status, HttpStatus.notFound);
      expect(r.headers.contentType?.mimeType, 'text/plain');
      expect(utf8.decode(r.body), contains('APK'));
      final h = await _call(server.boundPort, 'HEAD', '/apk');
      expect(h.status, HttpStatus.notFound);
    });

    test('GET y HEAD /apk sirven el APK exacto de la cache', () async {
      final List<int> bytes = _fakeApk(300 * 1024);
      final File apk = tvApkCacheFile(root: cacheDir);
      apk.parent.createSync(recursive: true);
      apk.writeAsBytesSync(bytes);

      final r = await _call(server.boundPort, 'GET', '/apk');
      expect(r.status, HttpStatus.ok);
      expect(
        r.headers.contentType?.mimeType,
        'application/vnd.android.package-archive',
      );
      expect(
        r.headers.value('content-disposition'),
        'attachment; filename="gatomix-tv.apk"',
      );
      expect(r.headers.contentLength, bytes.length);
      expect(r.body, bytes);

      final h = await _call(server.boundPort, 'HEAD', '/apk');
      expect(h.status, HttpStatus.ok);
      expect(h.headers.contentLength, bytes.length);
      expect(h.body, isEmpty);

      final p = await _call(server.boundPort, 'POST', '/apk');
      expect(p.status, HttpStatus.methodNotAllowed);
    });

    test('?p= con .apk sigue en 403 y HEAD fuera de /apk en 405', () async {
      final File apk = File('${tmp.path}${_s}musica${_s}x.apk');
      apk.parent.createSync(recursive: true);
      apk.writeAsBytesSync(_fakeApk(1024));
      final File cached = tvApkCacheFile(root: cacheDir);
      cached.parent.createSync(recursive: true);
      cached.writeAsBytesSync(_fakeApk(1024));
      final String q = Uri.encodeQueryComponent(apk.path);
      final String qc = Uri.encodeQueryComponent(cached.path);
      for (final String path in <String>[
        '/?p=$q',
        '/karaoke/audio?p=$q',
        '/karaoke/audio?p=$qc',
      ]) {
        final r = await _call(server.boundPort, 'GET', path);
        expect(r.status, HttpStatus.forbidden, reason: path);
      }
      final h = await _call(server.boundPort, 'HEAD', '/karaoke/audio?p=$q');
      expect(h.status, HttpStatus.methodNotAllowed);
      final w = await _call(server.boundPort, 'GET', '/whoami');
      expect(utf8.decode(w.body), contains('gatomix-karaoke'));
    });
  });

  group('3.2.25 cache del APK', () {
    late HttpServer origin;
    late List<int> payload;
    int hits = 0;

    setUp(() async {
      hits = 0;
      payload = _fakeApk(11 * 1024 * 1024);
      origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      origin.listen((HttpRequest req) async {
        hits++;
        final List<int> body = req.uri.path == '/small.apk'
            ? _fakeApk(1024 * 1024)
            : payload;
        req.response.contentLength = body.length;
        req.response.add(body);
        await req.response.close();
      });
    });

    tearDown(() => origin.close(force: true));

    String url(String name) => 'http://127.0.0.1:${origin.port}/$name';

    bool noTmp() =>
        !File('${tvApkCacheFile(root: cacheDir).path}.tmp').existsSync();

    test('baja, valida, reutiliza y fuerza la actualizacion', () async {
      final TvApkCache cache = TvApkCache(
        root: cacheDir,
        url: url('ok.apk'),
        fallback: false,
      );
      expect(await cache.isValid(), isFalse);
      int? lastTotal;
      final File f = await cache.ensure(
        onProgress: (int got, int? total) => lastTotal = total,
      );
      expect(f.path, tvApkCacheFile(root: cacheDir).path);
      expect(f.lengthSync(), payload.length);
      expect(lastTotal, payload.length);
      expect(await cache.isValid(), isTrue);
      expect(noTmp(), isTrue);
      expect(hits, 1);

      await cache.ensure();
      expect(hits, 1);
      await cache.ensure(force: true);
      expect(hits, 2);
      expect(noTmp(), isTrue);
    });

    test('rechaza un APK de 10 MB o menos y conserva el valido', () async {
      final TvApkCache small = TvApkCache(
        root: cacheDir,
        url: url('small.apk'),
        fallback: false,
      );
      await expectLater(small.ensure(), throwsA(isA<TvApkDownloadException>()));
      expect(tvApkCacheFile(root: cacheDir).existsSync(), isFalse);
      expect(noTmp(), isTrue);

      await TvApkCache(
        root: cacheDir,
        url: url('ok.apk'),
        fallback: false,
      ).ensure();
      await expectLater(
        small.ensure(force: true),
        throwsA(isA<TvApkDownloadException>()),
      );
      expect(tvApkCacheFile(root: cacheDir).lengthSync(), payload.length);
      expect(noTmp(), isTrue);
    });

    test('rechaza un Content-Length distinto de lo recibido', () async {
      final ServerSocket raw = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final List<int> body = _fakeApk(11 * 1024 * 1024);
      raw.listen((Socket s) async {
        await s.first;
        s.add(
          ascii.encode(
            'HTTP/1.1 200 OK\r\n'
            'Content-Type: application/octet-stream\r\n'
            'Content-Length: ${body.length + 4096}\r\n'
            'Connection: close\r\n\r\n',
          ),
        );
        s.add(body);
        await s.flush();
        await s.close();
      });
      try {
        final TvApkCache cache = TvApkCache(
          root: cacheDir,
          url: 'http://127.0.0.1:${raw.port}/gatomix-tv.apk',
          fallback: false,
        );
        await expectLater(cache.ensure(), throwsA(anything));
        expect(tvApkCacheFile(root: cacheDir).existsSync(), isFalse);
        expect(noTmp(), isTrue);
      } finally {
        await raw.close();
      }
    });
  });
}

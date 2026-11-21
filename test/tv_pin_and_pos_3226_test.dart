import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:difogo/services/tv_sync_server.dart';
import 'package:flutter_test/flutter_test.dart';

// 3.2.26: PIN del WebSocket del nodo TV (cierre 4001 sin PIN valido, ningun
// comando llega sin autenticar) y TV_POS con la posicion real de la TV.
// Servidor en puerto efimero (nunca el 55056 real), cache en %TEMP%.

class _Client {
  final WebSocket ws;
  final List<Map<String, dynamic>> got = <Map<String, dynamic>>[];
  final Completer<void> done = Completer<void>();

  _Client(this.ws) {
    ws.listen(
      (dynamic data) {
        final Object? d = jsonDecode('$data');
        if (d is Map<String, dynamic>) got.add(d);
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      onError: (Object _) {
        if (!done.isCompleted) done.complete();
      },
    );
  }

  void send(Map<String, dynamic> m) {
    try {
      ws.add(jsonEncode(m));
    } catch (_) {}
  }

  Future<int?> closed() async {
    await done.future.timeout(const Duration(seconds: 5));
    return ws.closeCode;
  }
}

Future<void> _settle([int ms = 150]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late Directory tmp;
  late TvSyncServer server;
  late List<Map<String, dynamic>> commands;
  late int joined;

  Future<_Client> connect([String query = '']) async {
    final WebSocket ws = await WebSocket.connect(
      'ws://127.0.0.1:${server.boundPort}/$query',
    );
    return _Client(ws);
  }

  String wrongPin() => server.sessionPin == '1000' ? '1001' : '1000';

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gmx_3226_');
    commands = <Map<String, dynamic>>[];
    joined = 0;
    server = TvSyncServer(
      port: 0,
      apkCacheRoot: '${tmp.path}${Platform.pathSeparator}tv_cache',
      authTimeout: const Duration(milliseconds: 400),
    );
    server.onTvMessage = commands.add;
    server.onTvJoined = () => joined++;
    expect(await server.ensureStarted(), isTrue);
  });

  tearDown(() async {
    server.stop();
    await _settle(50);
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('3.2.26 PIN del WebSocket', () {
    test('PIN de 4 digitos y /api/whoami no lo expone', () async {
      final String pin = server.sessionPin;
      expect(RegExp(r'^\d{4}$').hasMatch(pin), isTrue);
      expect(int.parse(pin), inInclusiveRange(1000, 9999));
      final HttpClient c = HttpClient();
      try {
        for (final String path in <String>['/api/whoami', '/whoami']) {
          final HttpClientRequest req = await c.getUrl(
            Uri.parse('http://127.0.0.1:${server.boundPort}$path'),
          );
          final HttpClientResponse res = await req.close();
          final String body = await res.transform(utf8.decoder).join();
          expect(res.statusCode, 200);
          expect(body, contains('gatomix-karaoke'));
          expect(body, isNot(contains(pin)));
          expect(body.toLowerCase(), isNot(contains('pin')));
        }
      } finally {
        c.close(force: true);
      }
    });

    test(
      'sin PIN: TV_SKIP / TV_SESSION_END no disparan y cierra 4001',
      () async {
        final _Client cl = await connect();
        cl.send(<String, dynamic>{'type': 'TV_SKIP'});
        cl.send(<String, dynamic>{'type': 'TV_SESSION_END'});
        cl.send(<String, dynamic>{
          'type': 'TV_POS',
          'positionMs': 1,
          'durationMs': 2,
          'playing': true,
        });
        expect(await cl.closed(), kTvAuthCloseCode);
        await _settle();
        expect(commands, isEmpty);
        expect(joined, 0);
        expect(server.hasTvClient, isFalse);
        expect(server.lastPosition, isNull);
      },
    );

    test('PIN incorrecto en la URL: cierre 4001 y ningun comando', () async {
      final _Client cl = await connect('?pin=${wrongPin()}');
      cl.send(<String, dynamic>{'type': 'TV_SKIP'});
      cl.send(<String, dynamic>{'type': 'TV_SESSION_END'});
      expect(await cl.closed(), kTvAuthCloseCode);
      await _settle();
      expect(commands, isEmpty);
      expect(joined, 0);
    });

    test('TV_AUTH incorrecto como primer mensaje: cierre 4001', () async {
      final _Client cl = await connect();
      cl.send(<String, dynamic>{'type': 'TV_AUTH', 'pin': wrongPin()});
      cl.send(<String, dynamic>{'type': 'TV_SKIP'});
      expect(await cl.closed(), kTvAuthCloseCode);
      await _settle();
      expect(commands, isEmpty);
    });

    test('sin PIN y en silencio: cierre 4001 al vencer el plazo', () async {
      final _Client cl = await connect();
      expect(await cl.closed(), kTvAuthCloseCode);
      expect(joined, 0);
    });

    test('PIN correcto: conecta, TV_POS exacto y comandos llegan', () async {
      final List<TvPosition> pos = <TvPosition>[];
      final StreamSubscription<TvPosition> sub = server.positions.listen(
        pos.add,
      );
      final _Client cl = await connect('?pin=${server.sessionPin}');
      await _settle();
      expect(joined, 1);
      expect(server.hasTvClient, isTrue);
      cl.send(<String, dynamic>{
        'type': 'TV_POS',
        'positionMs': 61234,
        'durationMs': 215000,
        'playing': true,
      });
      cl.send(<String, dynamic>{
        'type': 'TV_POS',
        'positionMs': 61734,
        'durationMs': 215000,
        'playing': false,
      });
      cl.send(<String, dynamic>{'type': 'TV_SKIP'});
      await _settle();
      expect(pos.length, 2);
      expect(pos[0].positionMs, 61234);
      expect(pos[0].durationMs, 215000);
      expect(pos[0].playing, isTrue);
      expect(pos[1].positionMs, 61734);
      expect(pos[1].playing, isFalse);
      expect(server.lastPosition?.positionMs, 61734);
      // TV_POS va por el stream, no por onTvMessage.
      expect(commands.map((Map<String, dynamic> m) => m['type']), <Object?>[
        'TV_SKIP',
      ]);
      await sub.cancel();
      await cl.ws.close();
    });

    test('TV_AUTH correcto por primer mensaje tambien autentica', () async {
      final List<TvPosition> pos = <TvPosition>[];
      final StreamSubscription<TvPosition> sub = server.positions.listen(
        pos.add,
      );
      final _Client cl = await connect();
      cl.send(<String, dynamic>{'type': 'TV_AUTH', 'pin': server.sessionPin});
      await _settle();
      expect(joined, 1);
      cl.send(<String, dynamic>{
        'type': 'TV_POS',
        'positionMs': 1500,
        'durationMs': 3000,
        'playing': true,
      });
      cl.send(<String, dynamic>{'type': 'TV_PAUSE'});
      await _settle(600);
      expect(cl.done.isCompleted, isFalse);
      expect(pos.single.positionMs, 1500);
      expect(pos.single.durationMs, 3000);
      expect(pos.single.playing, isTrue);
      expect(commands.single['type'], 'TV_PAUSE');
      await sub.cancel();
      await cl.ws.close();
    });

    test('broadcasts solo a sockets autenticados', () async {
      final _Client ok = await connect('?pin=${server.sessionPin}');
      final _Client waiting = await connect();
      await _settle();
      server.broadcastEdgePause();
      await _settle();
      expect(ok.got.map((Map<String, dynamic> m) => m['type']), <Object?>[
        'EDGE_PAUSE',
      ]);
      expect(waiting.got, isEmpty);
      expect(await waiting.closed(), kTvAuthCloseCode);
      await ok.ws.close();
    });
  });

  group('3.2.26 helpers', () {
    test('tvPinMatches exacto', () {
      expect(tvPinMatches('4321', '4321'), isTrue);
      expect(tvPinMatches('4322', '4321'), isFalse);
      expect(tvPinMatches('432', '4321'), isFalse);
      expect(tvPinMatches('43210', '4321'), isFalse);
      expect(tvPinMatches('', ''), isFalse);
    });

    test('TvPosition interpola mientras suena y se corta sin senal', () {
      final DateTime t0 = DateTime(2026, 1, 1, 12);
      final TvPosition? p = TvPosition.tryParse(<String, dynamic>{
        'type': 'TV_POS',
        'positionMs': 10000,
        'durationMs': 10300,
        'playing': true,
      }, now: t0);
      expect(p, isNotNull);
      expect(p!.estimateMs(t0.add(const Duration(milliseconds: 100))), 10100);
      expect(p.estimateMs(t0.add(const Duration(milliseconds: 500))), 10300);
      expect(p.estimateMs(t0.add(const Duration(milliseconds: 2100))), isNull);
      final TvPosition paused = TvPosition.tryParse(<String, dynamic>{
        'positionMs': 5000,
        'durationMs': 9000,
        'playing': false,
      }, now: t0)!;
      expect(paused.estimateMs(t0.add(const Duration(seconds: 1))), 5000);
      expect(TvPosition.tryParse(<String, dynamic>{'positionMs': 'x'}), isNull);
    });

    test('protocolo sin SYNC_PING ni LRC_LOAD', () {
      for (final String f in <String>[
        'lib/services/tv_sync_server.dart',
        'lib/ui/workspaces/karaoke_workspace.dart',
      ]) {
        final String src = File(f).readAsStringSync();
        expect(src, isNot(contains('SYNC_PING')));
        expect(src, isNot(contains('LRC_LOAD')));
      }
    });
  });
}

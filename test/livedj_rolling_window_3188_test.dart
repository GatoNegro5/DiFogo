import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/discovery_dedup_controller.dart';
import 'package:difogo/core/genre_track_pool.dart';
import 'package:difogo/providers/automix_provider.dart';
import 'package:difogo/providers/curator_provider.dart';
import 'package:difogo/providers/livedj_provider.dart';
import 'package:difogo/providers/session_provider.dart';
import 'package:difogo/services/smart_discovery_service.dart';

// 3.1.88: ventana deslizante de 48 pistas en AutomixDj (Live DJ) con una
// cola sintetica de 2000 pistas, y Aceptar de la bandeja con letra en 2do
// plano y huella al anti-duplicados. Sin audio, sin red, todo en %TEMP%.

class _FakeQueue extends AutomixQueueNotifier {
  @override
  List<File> build() => <File>[];

  @override
  void addTrack(File file) => state = <File>[...state, file];
}

final String _sep = Platform.pathSeparator;

void main() {
  test('2000 pistas: siguiente = cabeza, medicion y reorden acotados a 48, '
      'por transicion en < 50 ms', () {
    final List<File> queue = <File>[
      for (int i = 0; i < 2000; i++) File('/m/Salsa/t$i (${90 + i % 40} BPM).mp3'),
    ];
    final List<File> small = queue.sublist(0, 100);
    final Stopwatch sw = Stopwatch()..start();
    final int next = liveDjHeadIndex(queue, '/m/Salsa/sonando.mp3');
    int measured = 0;
    final List<String> cands = liveDjBackfillCandidates(queue, 1, (String p) {
      measured++;
      return 0;
    });
    int ordered = 0;
    final List<File>? re = liveDjReorderWindow(queue, 1, (
      List<String> tail,
      String? from,
    ) {
      ordered = tail.length;
      return tail.reversed.toList();
    });
    final int armed = liveDjWindowIndexOf(queue, queue[3].path);
    sw.stop();
    // Lo que corre en cada transicion: siguiente, medicion, reorden, armada.
    expect(sw.elapsedMilliseconds, lessThan(50));
    // Agregar 510 a una cola de 2000 (Set de claves, no N x M): una vez por
    // carga, no por transicion; incluye el calculo en frio de 2510 claves.
    final Stopwatch add = Stopwatch()..start();
    final List<File> fresh = liveDjFreshTracks(queue, <File>[
      for (int i = 1990; i < 2500; i++) File('/m/Salsa/t$i (${90 + i % 40} BPM).mp3'),
    ], '/m/Salsa/sonando.mp3');
    add.stop();
    expect(add.elapsedMilliseconds, lessThan(250));
    // Regla 3.1.84: la siguiente es SIEMPRE la cabeza de la cola.
    expect(next, 0);
    expect(liveDjHeadIndex(queue, queue[0].path), 1);
    expect(kRollingWindowSize, 48);
    expect(measured, kRollingWindowSize);
    expect(cands, hasLength(kRollingWindowSize));
    expect(ordered, kRollingWindowSize);
    expect(re, hasLength(2000));
    expect(re!.first.path, queue.first.path);
    expect(identical(re[1 + kRollingWindowSize], queue[1 + kRollingWindowSize]), isTrue);
    expect(re.map((File f) => f.path).toSet(), hasLength(2000));
    expect(fresh, hasLength(500));
    expect(armed, 3);
    expect(liveDjWindowIndexOf(queue, queue[1500].path), -1);
    // Mismo trabajo por transicion con 100 o 2000 pistas.
    int smallMeasured = 0;
    liveDjBackfillCandidates(small, 1, (String p) {
      smallMeasured++;
      return 0;
    });
    expect(smallMeasured, measured);
  });

  test('fuente: sin sameAudioPath en bucle ni canonical por pista en las '
      'estaciones grandes de Live DJ', () {
    final String src = File('lib/providers/livedj_provider.dart').readAsStringSync();
    expect(src.contains('state.queue.any((File e) => sameAudioPath(e.path, f.path))'), isFalse);
    expect(src.contains('q.any((File e) => sameAudioPath(e.path, f.path))'), isFalse);
    expect(src.contains('reorderQueueTail('), isFalse);
    expect(src.contains('backfillCandidates('), isFalse);
    expect(src.contains('restoreLiveDjSessionAsync('), isTrue);
    expect(src.contains('final bool big = queue.length > kAutomixSyncLimit;'), isTrue);
  });

  group('Aceptar en Nuevas', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('gmx_3188_');
    });
    tearDown(() {
      debugVibeRootOverride = null;
      debugVibeStatePath = null;
      debugCuratorService = null;
      debugCuratorRegister = null;
      debugDisableCuratorWorker = false;
      CuratorNotifier.debugLyricFetcher = null;
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('dispara la letra en 2do plano y registra la huella', () async {
      final String root = '${tmp.path}${_sep}Musica';
      final String inbox = '${tmp.path}${_sep}Inbox';
      final String temp = '$inbox${_sep}Hector Lavoe - El Cantante.mp3';
      File(temp)
        ..createSync(recursive: true)
        ..writeAsStringSync('mp3');
      CuratorInboxStore(inbox).save(
        CuratorInboxData(
          entries: <CuratorEntry>[
            CuratorEntry(
              id: 'v1',
              title: 'Hector Lavoe - El Cantante',
              genre: 'Salsa',
              file: temp,
              status: CuratorStatus.pending,
              addedAt: '2026-11-18',
            ),
          ],
          lastRun: const <String, String>{},
        ),
      );
      debugVibeRootOverride = root;
      debugVibeStatePath = '${tmp.path}${_sep}state.json';
      debugDisableCuratorWorker = true;
      debugCuratorService = SmartDiscoveryService(
        inboxDir: inbox,
        search: (String q) async => const <DiscoveryCandidate>[],
        download: (DiscoveryCandidate c, String p) async {},
      );
      debugCuratorRegister = (String p, String g) async {};
      final List<String> jobs = <String>[];
      CuratorNotifier.debugLyricFetcher = (String audio) async {
        jobs.add(audio);
        await File(
          audio.replaceAll(RegExp(r'\.mp3$'), '.lrc'),
        ).writeAsString('[00:01.00] Yo soy el cantante');
      };
      final ProviderContainer c = ProviderContainer(
        overrides: [automixQueueProvider.overrideWith(_FakeQueue.new)],
      );
      addTearDown(c.dispose);
      final CuratorNotifier cur = c.read(curatorProvider.notifier);
      final String? dst = await cur.accept('v1');
      expect(dst, '$root${_sep}Salsa${_sep}Hector Lavoe - El Cantante.mp3');
      await cur.lastAcceptLyrics;
      expect(jobs, <String>[dst!]);
      expect(File('$root${_sep}Salsa${_sep}Hector Lavoe - El Cantante.lrc').existsSync(), isTrue);
      final DiscoveryDedupController d = c.read(discoveryDedupProvider);
      expect(d.blocksCandidate(filename: 'El Cantante - Hector Lavoe (Official Audio)'), isTrue);
    });
  });
}

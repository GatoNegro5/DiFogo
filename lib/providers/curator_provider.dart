import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/discovery_dedup_controller.dart';
import '../core/genre_stations.dart'
    show isStationSub, registerSavedTrack, stationSaveDir, stationSubOf;
import '../core/library_guard.dart' show lrcWriteFile;
import '../core/lyric_files.dart' show lrcPathForAudio;
import '../core/mode_session.dart' show sessionDir;
import '../core/radio_one_click.dart';
import '../services/smart_discovery_service.dart';
import '../ui/workspaces/yt_workspace.dart' show moveFile;
import 'automix_provider.dart';
import 'db_provider.dart';
import 'nlp_provider.dart';
import 'session_provider.dart';

/// 3.1.53 Curator Inbox: estado de la bandeja de revision y acciones del
/// usuario (agregar, descartar, buscar mas, ver despues).

/// Solo pruebas: servicio con buscador y descargador falsos.
@visibleForTesting
SmartDiscoveryService? debugCuratorService;

/// Solo pruebas: registro en la base local sin Isar.
@visibleForTesting
Future<void> Function(String path, String genre)? debugCuratorRegister;

/// Solo pruebas: no programar el worker diario.
@visibleForTesting
bool debugDisableCuratorWorker = false;

/// 3.1.87 Solo pruebas: JSON de descartes de la Radio en %TEMP%.
@visibleForTesting
String? debugDiscoveryDiscardPath;

/// 3.1.87: biblioteca en %TEMP% (pruebas): nada se lee ni escribe en las
/// carpetas reales del usuario.
bool _inTemp(String path) => path
    .replaceAll('\\', '/')
    .toLowerCase()
    .startsWith(Directory.systemTemp.path.replaceAll('\\', '/').toLowerCase());

/// 3.1.87: huellas descartadas (null con la biblioteca en %TEMP% y sin
/// ruta propia: solo en memoria, nunca la carpeta real de sesiones).
String? discoveryDiscardPath() {
  final String? o = debugDiscoveryDiscardPath;
  if (o != null) return o;
  if (_inTemp(vibeMusicRoot())) return null;
  return '${sessionDir()}${Platform.pathSeparator}difogo_discovery_discards.json';
}

/// 3.1.87: anti-duplicados de la Radio Descubrimiento (biblioteca local +
/// descartes, O(1)).
final discoveryDedupProvider = Provider<DiscoveryDedupController>(
  (ref) => DiscoveryDedupController(discardPath: discoveryDiscardPath()),
);

/// 3.1.87: arma una vez el indice de huellas de la biblioteca (listado
/// async y huellas en isolate; solo lectura) y de la carpeta de guardado de
/// la Radio.
Future<void> ensureDiscoveryLibrary(DiscoveryDedupController d) =>
    d.ensureLibrary(
      () => listLibraryAudioAsync(<String>[
        vibeMusicRoot(),
        if (!_inTemp(vibeMusicRoot()) || _inTemp(radioFallbackRoot()))
          radioFallbackRoot(),
      ]),
    );

class CuratorState {
  const CuratorState({
    this.entries = const <CuratorEntry>[],
    this.lastRun = const <String, String>{},
    this.busy = false,
    this.message,
  });

  final List<CuratorEntry> entries;
  final Map<String, String> lastRun;
  final bool busy;
  final String? message;

  List<CuratorEntry> get pending => <CuratorEntry>[
    for (final CuratorEntry e in entries)
      if (e.status == CuratorStatus.pending) e,
  ];

  CuratorState copyWith({
    List<CuratorEntry>? entries,
    Map<String, String>? lastRun,
    bool? busy,
    String? message,
  }) => CuratorState(
    entries: entries ?? this.entries,
    lastRun: lastRun ?? this.lastRun,
    busy: busy ?? this.busy,
    message: message,
  );
}

class CuratorNotifier extends Notifier<CuratorState> {
  late SmartDiscoveryService _service;
  late CuratorInboxStore _store;
  Timer? _daily;

  @override
  CuratorState build() {
    _service = debugCuratorService ?? SmartDiscoveryService();
    _store = CuratorInboxStore(_service.inboxDir);
    ref.onDispose(() => _daily?.cancel());
    final CuratorInboxData d = _store.load();
    // Un pendiente cuyo archivo ya no existe no se muestra.
    final List<CuratorEntry> entries = <CuratorEntry>[
      for (final CuratorEntry e in d.entries)
        if (e.status != CuratorStatus.pending || File(e.file).existsSync()) e,
    ];
    return CuratorState(entries: entries, lastRun: d.lastRun);
  }

  void _persist(CuratorState s) {
    state = s;
    try {
      _store.save(CuratorInboxData(entries: s.entries, lastRun: s.lastRun));
    } catch (e) {
      debugPrint('[CURATOR] no se pudo guardar: $e');
    }
  }

  String? get _vibe => ref.read(vibeProvider).active;

  /// 3.1.67: carpeta destino de [genre]; acepta rutas canonicas relativas
  /// `<Estacion>/<Sub>` (p. ej. `Tropical/Salsa`).
  String _dirOf(String genre) =>
      '${vibeMusicRoot()}${Platform.pathSeparator}'
      '${genre.replaceAll('/', Platform.pathSeparator)}';

  /// Corrida diaria tras [delay] (la app sigue arrancando mientras tanto).
  void startDailyWorker({Duration delay = const Duration(seconds: 90)}) {
    if (debugDisableCuratorWorker) return;
    _daily?.cancel();
    _daily = Timer(delay, () => unawaited(runDaily()));
  }

  /// Una vez por dia y por genero: baja hasta [kDiscoveryDailyCount] temas.
  Future<int> runDaily({DateTime? now}) async {
    final String? g = _vibe;
    if (g == null) return 0;
    final String today = discoveryDay(now ?? _service.now());
    if (state.lastRun[g] == today) return 0;
    final int added = await discover(count: kDiscoveryDailyCount);
    // Un fallo de red no gasta el dia: se reintenta en el proximo arranque.
    if (!(state.message ?? '').startsWith('No se pudo')) {
      _persist(
        state.copyWith(lastRun: <String, String>{...state.lastRun, g: today}),
      );
    }
    return added;
  }

  /// [Buscar Mas]: pide temas nuevos del genero activo ahora mismo.
  /// 3.1.61: [genre] (sub-genero de una estacion corta) sin tocar el candado.
  /// 3.1.64: [query] son los terminos canonicos del sub-genero; [genre]
  /// sigue siendo la carpeta destino al aceptar.
  /// 3.1.68: [stationId] y [subGenreId] viajan con cada tema a la bandeja
  /// para agruparlo por genero y guardarlo en su carpeta canonica.
  Future<int> discover({
    int count = 1,
    String? genre,
    String? query,
    String? stationId,
    String? subGenreId,
  }) async {
    final String? g = genre ?? _vibe;
    if (g == null) {
      state = state.copyWith(message: 'Elige un genero para buscar temas.');
      return 0;
    }
    if (state.busy) return 0;
    final int room =
        kDiscoveryMaxPending -
        state.pending.where((CuratorEntry e) => e.genre == g).length;
    if (room <= 0) {
      state = state.copyWith(message: 'La bandeja de $g ya esta llena.');
      return 0;
    }
    state = state.copyWith(busy: true);
    try {
      final DiscoveryDedupController dedup = ref.read(discoveryDedupProvider);
      await ensureDiscoveryLibrary(dedup);
      final List<CuratorEntry> got = await _service.discover(
        skipTitle: (String title) => dedup.blocksCandidate(filename: title),
        genre: g,
        count: count < room ? count : room,
        knownIds: <String>{for (final CuratorEntry e in state.entries) e.id},
        genreDir: _dirOf(g),
        query: query,
        stationId: stationId,
        subGenreId: subGenreId,
      );
      _persist(
        state.copyWith(
          entries: <CuratorEntry>[...state.entries, ...got],
          busy: false,
          message: got.isEmpty ? 'No hubo temas nuevos de $g.' : null,
        ),
      );
      return got.length;
    } catch (e) {
      debugPrint('[CURATOR] busqueda fallida: $e');
      state = state.copyWith(busy: false, message: 'No se pudo buscar: $e');
      return 0;
    }
  }

  CuratorEntry? _find(String id) {
    for (final CuratorEntry e in state.entries) {
      if (e.id == id && e.status == CuratorStatus.pending) return e;
    }
    return null;
  }

  void _replace(CuratorEntry next) {
    _persist(
      state.copyWith(
        entries: <CuratorEntry>[
          for (final CuratorEntry e in state.entries)
            e.id == next.id ? next : e,
        ],
      ),
    );
  }

  /// [Agregar]: mueve el MP3 a la carpeta del genero, lo registra en la base
  /// local y lo suma a la cola de Automix. Unica escritura en la biblioteca.
  Future<String?> accept(String id) async {
    final CuratorEntry? e = _find(id);
    if (e == null || !File(e.file).existsSync()) return null;
    final String dir = _destOf(e);
    Directory(dir).createSync(recursive: true);
    final String dst = discoveryFreePath(dir, discoverySafeName(e.title));
    moveFile(e.file, dst);
    try {
      final Future<void> Function(String, String)? reg = debugCuratorRegister;
      if (reg != null) {
        await reg(dst, e.genre);
      } else {
        await ref
            .read(dbServiceProvider)
            .saveTrackMetadata(path: dst, genre: e.genre);
      }
    } catch (err) {
      debugPrint('[CURATOR] base local: $err');
    }
    // 3.1.67: estacion y sub-genero al indice por cancion apenas se guarda.
    if (debugCuratorRegister == null || trackGenreIndexInTemp()) {
      try {
        await registerSavedTrack(
          trackGenreIndexPath(),
          vibeMusicRoot(),
          dst,
          stationId: e.stationId,
          subGenreId: e.subGenreId,
        );
      } catch (err) {
        debugPrint('[CURATOR] indice de generos: $err');
      }
    }
    ref.read(automixQueueProvider.notifier).addTrack(File(dst));
    _replace(e.copyWith(status: CuratorStatus.accepted, finalPath: dst));
    return dst;
  }

  /// 3.1.68: destino del tema: con estacion y sub-genero, la carpeta que ya
  /// alimenta ese sub-genero o la canonica `<Estacion>/<Sub>`
  /// ([stationSaveDir]); temas de antes, la carpeta de su genero.
  String _destOf(CuratorEntry e) {
    final String? st = e.stationId;
    final String? sub = e.subGenreId;
    if (st == null || sub == null || !isStationSub(st, sub)) {
      return _dirOf(e.genre);
    }
    final MapEntry<String, String>? m = stationSubOf(e.genre);
    final bool mine = m != null && m.key == st && m.value == sub;
    return stationSaveDir(
      vibeMusicRoot(),
      st,
      sub,
      library: mine ? <String, int>{e.genre: 1} : const <String, int>{},
    );
  }

  /// 3.1.68 [Aceptar todo este genero]: acepta [ids] en orden (mismo
  /// camino que [accept]). Devuelve las rutas guardadas.
  Future<List<String>> acceptAll(List<String> ids) async {
    final List<String> out = <String>[];
    for (final String id in ids) {
      final String? dst = await accept(id);
      if (dst != null) out.add(dst);
    }
    return out;
  }

  /// [Descartar]: borra el temporal; el id queda para no volver a bajarlo.
  /// 3.1.87: su huella queda en el anti-duplicados de la Radio.
  void reject(String id) {
    final CuratorEntry? e = _find(id);
    if (e == null) return;
    try {
      if (File(e.file).existsSync()) File(e.file).deleteSync();
    } catch (err) {
      debugPrint('[CURATOR] no se pudo borrar: $err');
    }
    _replace(e.copyWith(status: CuratorStatus.rejected));
    unawaited(
      ref
          .read(discoveryDedupProvider)
          .discard(title: e.title, filename: e.file)
          .catchError((Object _) => false),
    );
  }

  /// 3.1.87: tema pendiente de la bandeja que es [path] (pista temporal de
  /// la Radio Descubrimiento); null si [path] no es de la Radio.
  CuratorEntry? radioEntryFor(String? path) {
    if (path == null || path.isEmpty) return null;
    final String k = path.replaceAll('\\', '/').toLowerCase();
    for (final CuratorEntry e in state.entries) {
      if (e.status != CuratorStatus.pending) continue;
      if (e.file.replaceAll('\\', '/').toLowerCase() == k) return e;
    }
    return null;
  }

  /// 3.1.87 Solo pruebas: letra falsa (sin red).
  @visibleForTesting
  static RadioLyricFetcher? debugLyricFetcher;

  /// Letra de [audioPath] en 2do plano, junto al audio (o en el espejo si
  /// el audio estuviera en la biblioteca protegida).
  Future<void> _fetchLyricFor(String audioPath) async {
    final RadioLyricFetcher? hook = debugLyricFetcher;
    if (hook != null) return hook(audioPath);
    final choice = await ref.read(nlpWorkerProvider).lookupSafeLyric(audioPath);
    if (!choice.hasText) return;
    final String lrc = lrcPathForAudio(audioPath);
    await lrcWriteFile(audioPath, lrc).writeAsString(choice.fileText);
  }

  /// 3.1.87 [Guardar] en 1 clic: copia la pista de la Radio que suena a
  /// `<Biblioteca>/<Estacion>/<SubGenero>` (si esa carpeta es la biblioteca
  /// protegida, a `Musica/Descargas/<Estacion>/<SubGenero>`), la registra
  /// como de la biblioteca y baja su `.lrc` en 2do plano sin pausar.
  Future<String?> saveFromRadio(String id) async {
    final CuratorEntry? e = _find(id);
    if (e == null || !File(e.file).existsSync()) return null;
    final String? st = e.stationId;
    final String? sub = e.subGenreId;
    final String fallback = st != null && sub != null && isStationSub(st, sub)
        ? stationSaveDir(radioFallbackRoot(), st, sub)
        : '${radioFallbackRoot()}${Platform.pathSeparator}'
              '${e.genre.replaceAll('/', Platform.pathSeparator)}';
    final String dir = radioSaveDir(
      libraryDir: _destOf(e),
      fallbackDir: fallback,
    );
    final RadioSaveResult r = await radioSaveTrack(
      tempPath: e.file,
      targetDir: dir,
      stem: discoverySafeName(e.title),
      fetchLyrics: _fetchLyricFor,
    );
    ref.read(discoveryDedupProvider).addLibraryPath(r.path);
    try {
      final Future<void> Function(String, String)? reg = debugCuratorRegister;
      if (reg != null) {
        await reg(r.path, e.genre);
      } else {
        await ref
            .read(dbServiceProvider)
            .saveTrackMetadata(path: r.path, genre: e.genre);
      }
    } catch (err) {
      debugPrint('[CURATOR] base local: $err');
    }
    if (debugCuratorRegister == null || trackGenreIndexInTemp()) {
      try {
        await registerSavedTrack(
          trackGenreIndexPath(),
          vibeMusicRoot(),
          r.path,
          stationId: e.stationId,
          subGenreId: e.subGenreId,
        );
      } catch (err) {
        debugPrint('[CURATOR] indice de generos: $err');
      }
    }
    _replace(e.copyWith(status: CuratorStatus.accepted, finalPath: r.path));
    // El temporal sigue abierto en el deck: se borra cuando lo suelte.
    unawaited(radioDeleteTemp(e.file).catchError((Object _) => false));
    return r.path;
  }

  /// 3.1.87 [Descartar] en 1 clic: bloquea la huella, salta a la siguiente
  /// con [skip] (siguiente normal del motor, con cruce) y borra el temporal.
  Future<bool> discardFromRadio(
    String id, {
    required Future<void> Function() skip,
  }) async {
    final CuratorEntry? e = _find(id);
    if (e == null) return false;
    _replace(e.copyWith(status: CuratorStatus.rejected));
    return radioDiscardTrack(
      tempPath: e.file,
      title: e.title,
      dedup: ref.read(discoveryDedupProvider),
      skip: skip,
    );
  }
}

final curatorProvider = NotifierProvider<CuratorNotifier, CuratorState>(
  CuratorNotifier.new,
);

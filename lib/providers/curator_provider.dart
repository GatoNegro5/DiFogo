import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/genre_stations.dart'
    show isStationSub, registerSavedTrack, stationSaveDir, stationSubOf;
import '../services/smart_discovery_service.dart';
import '../ui/workspaces/yt_workspace.dart' show moveFile;
import 'automix_provider.dart';
import 'db_provider.dart';
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
      final List<CuratorEntry> got = await _service.discover(
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
  void reject(String id) {
    final CuratorEntry? e = _find(id);
    if (e == null) return;
    try {
      if (File(e.file).existsSync()) File(e.file).deleteSync();
    } catch (err) {
      debugPrint('[CURATOR] no se pudo borrar: $err');
    }
    _replace(e.copyWith(status: CuratorStatus.rejected));
  }
}

final curatorProvider = NotifierProvider<CuratorNotifier, CuratorState>(
  CuratorNotifier.new,
);

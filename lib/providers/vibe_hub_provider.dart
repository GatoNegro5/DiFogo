import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/discovery_dedup_controller.dart';
import '../core/genre_stations.dart';
import '../core/mode_session.dart';
import '../ui/mobile/music_picker_screen.dart'
    show musicPickerShowsFile, musicPickerTechFolder;
import '../services/smart_discovery_service.dart' show CuratorEntry;
import '../services/track_tags.dart' show TrackTags;
import 'curator_provider.dart';
import 'livedj_provider.dart';
import 'session_provider.dart';

/// 3.1.54 Super-Vibe Hub: categorias maestras (carpetas de genero de primer
/// nivel bajo vibeMusicRoot) con casillas. Es la vista por defecto de Live
/// DJ; el modo clasico vuelve al arbol de carpetas. Solo lectura de la
/// biblioteca: el Hub nunca escribe en ella.

/// Solo pruebas: escaneo de generos y reproduccion sin tocar Live DJ real.
@visibleForTesting
Future<List<VibeGenre>> Function(String root)? debugVibeHubScan;
@visibleForTesting
Future<void> Function(List<File> files)? debugVibeHubPlay;
@visibleForTesting
String? debugVibeHubStatePath;

/// 3.1.61 Solo pruebas: estaciones sin Live DJ real ni biblioteca.
@visibleForTesting
String? debugStationSessionsPath;
@visibleForTesting
Future<void> Function(StationPlan plan)? debugStationPlay;
@visibleForTesting
StationLive Function()? debugStationLive;
@visibleForTesting
Future<List<String>> Function(List<String> subGenres)? debugStationCollect;
@visibleForTesting
Random? debugStationRng;

/// 3.1.67 Solo pruebas: Auto-Curador falso (sin red). Devuelve las rutas de
/// los temas nuevos que llegaron para [feed].
@visibleForTesting
Future<List<String>> Function(String key, StationFeed feed, int count)?
debugStationFeed;

/// Estacion con menos pistas que esto: el curador busca temas nuevos.
const int kStationShortTracks = 25;

/// 3.1.72 Solo pruebas: pausa/reanuda falsa del boton Play de la estacion
/// (sin decks reales).
@visibleForTesting
Future<void> Function()? debugStationToggle;

/// 3.1.72 Radio Descubrimiento: 1 tema nuevo cada [kDiscoveryEvery] pistas
/// de la cola (2 locales y 1 nueva).
const int kDiscoveryEvery = 3;

String genreSessionsPath() =>
    debugStationSessionsPath ??
    '${sessionDir()}${Platform.pathSeparator}difogo_genre_sessions.json';

/// Lo que suena en Live DJ (pista, segundo y cola restante).
class StationLive {
  const StationLive(this.current, this.positionMs, this.queue);
  final String? current;
  final int positionMs;
  final List<String> queue;
}

/// Datos del modal de reingreso: "Estabas escuchando ...".
class StationResumeInfo {
  const StationResumeInfo(
    this.key,
    this.title,
    this.trackPath,
    this.positionMs,
  );
  final String key;
  final String title;
  final String trackPath;
  final int positionMs;

  String get trackTitle => stationTrackTitle(trackPath);
  String get clock => stationClock(positionMs);
}

/// isClassicFolderView: false (por defecto al abrir) = Hub Smart Vibe;
/// true = arbol de carpetas tradicional. No se guarda: cada arranque abre
/// en Smart Vibe.
final liveDjClassicFolderViewProvider = StateProvider<bool>((ref) => false);

class VibeHubState {
  const VibeHubState({
    this.genres = const <VibeGenre>[],
    this.stations = const <GenreStation>[],
    this.activeStation,
    this.checked = const <String>{},
    this.loading = false,
    this.busy = false,
    this.message,
    this.discoveryOn = false,
  });

  final List<VibeGenre> genres;

  /// 3.1.72: 🔥 RADIO DESCUBRIMIENTO (AUTO-NUEVAS). Apagada: solo la
  /// biblioteca local. Encendida: intercala en la cola de la estacion activa
  /// temas nuevos del curador, tocados desde su bandeja (fuera de la
  /// biblioteca); solo entran a la biblioteca con Aceptar.
  final bool discoveryOn;

  /// 3.1.61 Macro-generos (estaciones) armados desde [genres].
  final List<GenreStation> stations;

  /// Estacion que suena (clave del JSON de sesiones).
  final String? activeStation;

  /// Nombres de categoria marcados (se guardan en el estado de modo).
  final Set<String> checked;
  final bool loading;
  final bool busy;
  final String? message;

  VibeHubState copyWith({
    List<VibeGenre>? genres,
    List<GenreStation>? stations,
    String? activeStation,
    Set<String>? checked,
    bool? loading,
    bool? busy,
    String? message,
    bool clearMessage = false,
    bool? discoveryOn,
  }) => VibeHubState(
    genres: genres ?? this.genres,
    stations: stations ?? this.stations,
    activeStation: activeStation ?? this.activeStation,
    checked: checked ?? this.checked,
    loading: loading ?? this.loading,
    busy: busy ?? this.busy,
    message: clearMessage ? null : (message ?? this.message),
    discoveryOn: discoveryOn ?? this.discoveryOn,
  );
}

/// 3.1.70: cada cuantos segundos se guarda el segundo de la estacion.
const int kStationSaveEverySec = 5;

class VibeHubNotifier extends Notifier<VibeHubState> {
  String _path() => debugVibeHubStatePath ?? automixStatePath();

  @override
  VibeHubState build() {
    final Set<String> checked = <String>{};
    try {
      final Object? v = readModeDoc(_path())['vibeHub'];
      if (v is Map && v['checked'] is List) {
        for (final Object? g in v['checked'] as List) {
          if (g is String && g.isNotEmpty) checked.add(g);
        }
      }
    } catch (_) {}
    if (checked.isEmpty) {
      final String? a = ref.read(vibeProvider).active;
      if (a != null && a.isNotEmpty) checked.add(a);
    }
    return VibeHubState(checked: checked);
  }

  /// 3.1.67: canciones de carpetas genericas clasificadas una a una.
  TrackGenreBuckets _virtual = TrackGenreBuckets();

  /// 3.1.67: sube con cada estacion elegida; un auto-arranque del curador
  /// viejo no pisa una eleccion nueva.
  int _playEpoch = 0;

  /// Lee las categorias de la raiz (sin bloquear la UI: listado async).
  Future<void> refresh() async {
    if (state.loading) return;
    state = state.copyWith(loading: true, clearMessage: true);
    List<VibeGenre> genres = const <VibeGenre>[];
    try {
      genres = await (debugVibeHubScan ?? scanVibeGenres)(vibeMusicRoot());
    } catch (_) {}
    await _applyGenres(
      genres,
      vibeMusicRoot(),
      classify: debugVibeHubScan == null,
    );
  }

  /// 3.1.67: el arranque ya escaneo la biblioteca: el Hub la reusa y no
  /// vuelve a recorrer el disco antes de sonar.
  Future<void> adoptGenres(List<VibeGenre> genres, {String? root}) async {
    state = state.copyWith(loading: true, clearMessage: true);
    await _applyGenres(genres, root ?? vibeMusicRoot(), classify: true);
  }

  Future<void> _applyGenres(
    List<VibeGenre> genres,
    String root, {
    required bool classify,
  }) async {
    TrackGenreBuckets virt = TrackGenreBuckets();
    if (classify) {
      try {
        virt = await _classifyLoose(root, genres);
      } catch (_) {}
    }
    _virtual = virt;
    final Set<String> names = <String>{
      for (final VibeGenre g in genres) g.name.toLowerCase(),
    };
    state = state.copyWith(
      genres: genres,
      stations: groupStations(<MapEntry<String, int>>[
        for (final VibeGenre g in genres)
          MapEntry<String, int>(g.name, g.count),
      ], extra: virt.counts()),
      checked: <String>{
        for (final String c in state.checked)
          if (names.contains(c.toLowerCase())) c,
      },
      loading: false,
    );
  }

  /// 3.1.67: canciones de carpetas sin genero en el nombre (Descargas, Mix,
  /// raices canonicas `<Estacion>/`) y sueltas en la raiz, clasificadas una
  /// a una con el indice rapido (solo las nuevas pasan por la cascada).
  /// Solo lectura de la biblioteca: el indice vive en la carpeta de datos.
  Future<TrackGenreBuckets> _classifyLoose(
    String root,
    List<VibeGenre> genres,
  ) async {
    final String sep = Platform.pathSeparator;
    final List<String> paths = <String>[];
    Future<void> walk(Directory d, bool deep) async {
      if (!await d.exists()) return;
      try {
        await for (final FileSystemEntity f in d.list(
          recursive: deep,
          followLinks: false,
        )) {
          if (f is! File || !musicPickerShowsFile(f.path)) continue;
          if (musicPickerTechFolder(f.parent.path)) continue;
          paths.add(f.path);
        }
      } catch (_) {}
    }

    for (final VibeGenre g in genres) {
      if (stationSubOf(g.name) != null) continue;
      if (stationFold(g.name).contains('karaoke')) continue;
      await walk(Directory('$root$sep${g.name}'), true);
    }
    await walk(Directory(root), false);
    if (paths.isEmpty) return TrackGenreBuckets();
    paths.sort();
    final TrackGenreIndex idx = TrackGenreIndex.read(trackGenreIndexPath());
    final TrackGenreBuckets b = await classifyTracks(
      paths,
      root: root,
      index: idx,
      bpmOf: (String p) => TrackTags.peek(p)?.bpm ?? 0,
    );
    if (idx.dirty) {
      try {
        await idx.write();
      } catch (_) {}
    }
    return b;
  }

  Future<void> toggle(String genre) async {
    final Set<String> next = Set<String>.from(state.checked);
    if (!next.remove(genre)) next.add(genre);
    state = state.copyWith(checked: next, clearMessage: true);
    await _save();
  }

  Future<void> setAll(bool on) async {
    state = state.copyWith(
      checked: on
          ? <String>{for (final VibeGenre g in state.genres) g.name}
          : <String>{},
      clearMessage: true,
    );
    await _save();
  }

  Future<void> _save() async {
    try {
      await patchModeDoc(_path(), <String, dynamic>{
        'vibeHub': <String, dynamic>{
          'checked': (state.checked.toList()..sort()),
        },
      });
    } catch (_) {}
  }

  /// Pistas de las categorias marcadas, en orden de ruta. Solo lectura.
  Future<List<File>> collect() => _collectFrom(state.checked);

  Future<List<File>> _collectFrom(Iterable<String> genres) async {
    final String root = vibeMusicRoot();
    final List<File> out = <File>[];
    for (final String g in (genres.toList()..sort())) {
      final Directory d = Directory('$root${Platform.pathSeparator}$g');
      if (!await d.exists()) continue;
      try {
        await for (final FileSystemEntity f in d.list(
          recursive: true,
          followLinks: false,
        )) {
          if (f is! File || !musicPickerShowsFile(f.path)) continue;
          if (musicPickerTechFolder(f.parent.path)) continue;
          out.add(f);
        }
      } catch (_) {}
    }
    out.sort((File a, File b) => a.path.compareTo(b.path));
    return out;
  }

  /// Carga las categorias marcadas en la cola de Live DJ, aplica el Shuffle
  /// armonico existente y arranca si no habia nada sonando.
  Future<int> play() async {
    if (state.busy || state.checked.isEmpty) return 0;
    state = state.copyWith(busy: true, clearMessage: true);
    int n = 0;
    try {
      final List<File> files = await collect();
      n = files.length;
      if (files.isEmpty) {
        state = state.copyWith(message: 'Sin canciones en lo marcado');
        return 0;
      }
      final Future<void> Function(List<File>)? hook = debugVibeHubPlay;
      if (hook != null) {
        await hook(files);
      } else {
        final LiveDjNotifier dj = ref.read(liveDjProvider.notifier);
        dj.addAllTracks(files);
        // Primero arranca (si no sonaba nada) y luego el Shuffle armonico,
        // que ancla el orden a la pista que suena.
        if (ref.read(liveDjProvider).currentTrackPath == null) {
          await dj.togglePlayPause();
        }
        if (ref.read(liveDjProvider).mixStrategy ==
            LiveDjMixStrategy.sequential) {
          dj.shuffleQueue();
        }
      }
      state = state.copyWith(message: '$n canciones en la cola');
    } finally {
      state = state.copyWith(busy: false);
    }
    return n;
  }

  // ---- 3.1.61 Estaciones con sesion persistente por genero ----

  GenreSessionDoc? _doc;
  Future<void> _write = Future<void>.value();
  bool _tracking = false;
  bool _loading = false;

  GenreSessionDoc get _stationsDoc =>
      _doc ??= GenreSessionDoc.read(genreSessionsPath());

  Future<void> _saveStations() {
    final GenreSessionDoc d = _stationsDoc;
    final String path = genreSessionsPath();
    _write = _write.catchError((_) {}).then((_) => d.write(path));
    return _write;
  }

  @visibleForTesting
  Future<void> get stationsSettled => _write;

  StationLive _live() {
    final StationLive Function()? hook = debugStationLive;
    if (hook != null) return hook();
    final LiveDjState s = ref.read(liveDjProvider);
    return StationLive(s.currentTrackPath, s.position.inMilliseconds, <String>[
      for (final File f in s.queue) f.path,
    ]);
  }

  /// Congela en disco la estacion activa con lo que suena ahora.
  Future<void> freezeActive() async {
    final GenreSessionDoc d = _stationsDoc;
    final String? key = d.active;
    final GenreSession? s = key == null ? null : d.stations[key];
    if (key == null || s == null) return;
    final StationLive l = _live();
    if (l.current == null) return;
    d.stations[key] = s.copyWith(
      currentTrackPath: l.current,
      positionMs: l.positionMs,
      remainingQueuePaths: l.queue,
    );
    await _saveStations();
  }

  Future<List<String>> _stationTracks(List<String> subs) async {
    final Future<List<String>> Function(List<String>)? hook =
        debugStationCollect;
    if (hook != null) return hook(subs);
    return <String>[for (final File f in await _collectFrom(subs)) f.path];
  }

  /// Toca una estacion: arma la cola de los sub-generos en visto sin las
  /// sonadas, baraja, suena de una en Live DJ y, si ya tenia sesion, sigue
  /// en su pista y segundo. Devuelve las pistas de la estacion.
  Future<int> playStation(String key, List<String> subGenres) async {
    if (state.busy || subGenres.isEmpty) return 0;
    state = state.copyWith(busy: true, clearMessage: true);
    _loading = true;
    final int epoch = ++_playEpoch;
    try {
      // 3.1.67: congelar y guardar no frenan el arranque (la cadena de
      // escritura conserva el orden); se esperan despues de sonar.
      final Future<void> frozen = freezeActive();
      final List<String> all = await _stationPool(key, subGenres);
      if (all.isEmpty) {
        await frozen;
        // 3.1.87: 0 canciones locales: Radio Descubrimiento encendida para
        // este genero, sin error de carpeta vacia.
        await _autoDiscovery(key);
        _autoStartFromCurator(key, subGenres, epoch);
        return 0;
      }
      final GenreSessionDoc d = _stationsDoc;
      final StationPlan plan = planStation(
        all,
        d.stations[key],
        rng: debugStationRng,
        exists: debugStationCollect != null
            ? null
            : (String p) => File(p).existsSync(),
      );
      await _startPlan(key, subGenres, plan);
      await frozen;
      state = state.copyWith(
        activeStation: key,
        message: '${stationTitleOf(key)}: ${all.length} canciones',
      );
      if (all.length < kStationShortTracks) {
        _feedShortStation(key, subGenres);
      }
      if (state.discoveryOn) {
        unawaited(pumpDiscovery().catchError((Object _) => 0));
      }
      return all.length;
    } finally {
      _loading = false;
      state = state.copyWith(busy: false);
    }
  }

  /// Arma la sesion de [key] con [plan] y la hace sonar en Live DJ ya.
  Future<void> _startPlan(
    String key,
    List<String> subGenres,
    StationPlan plan,
  ) async {
    final GenreSessionDoc d = _stationsDoc;
    final List<String> queue = List<String>.from(plan.queue);
    final String? current =
        plan.currentTrackPath ?? (queue.isEmpty ? null : queue.removeAt(0));
    d.active = key;
    d.stations[key] = GenreSession(
      subGenresChecked: List<String>.from(subGenres),
      currentTrackPath: current,
      positionMs: plan.positionMs,
      remainingQueuePaths: queue,
      playedPaths: plan.played,
    ).copyWith();
    final Future<void> saved = _saveStations();
    final StationPlan run = StationPlan(
      currentTrackPath: current,
      positionMs: plan.positionMs,
      queue: queue,
      played: plan.played,
      resumed: plan.resumed,
    );
    final Future<void> Function(StationPlan)? hook = debugStationPlay;
    if (hook != null) {
      await hook(run);
    } else {
      await ref
          .read(liveDjProvider.notifier)
          .loadStation(
            currentPath: current,
            positionMs: plan.positionMs,
            queue: <File>[for (final String p in queue) File(p)],
          );
      _ensureTracker();
    }
    await saved;
  }

  /// 3.1.67: pistas de las carpetas de genero mas las clasificadas una a
  /// una (carpetas genericas), sin repetir.
  List<String> _withVirtual(
    List<String> fromFolders,
    String key,
    List<String> subs,
  ) {
    final List<String> extra = _virtual.tracksFor(key, subs);
    if (extra.isEmpty) return fromFolders;
    final Set<String> seen = <String>{
      for (final String p in fromFolders) stationPathKey(p),
    };
    return <String>[
      ...fromFolders,
      for (final String p in extra)
        if (seen.add(stationPathKey(p))) p,
    ];
  }

  /// 3.1.67: estacion con 0 canciones locales: el curador busca ya el
  /// sub-genero en visto mas corto y la primera pista que llega entra a la
  /// cola de Live DJ y suena sola. El tema queda en la bandeja: [Agregar]
  /// lo guarda en su carpeta canonica; nada se escribe en la biblioteca
  /// sin el usuario.
  void _autoStartFromCurator(String key, List<String> subs, int epoch) {
    Future<void> run() async {
      final List<String> first = await _dedupRadio(
        await _fetchFeed(key, subs, 1),
      );
      if (first.isEmpty || epoch != _playEpoch) return;
      _loading = true;
      try {
        await _startPlan(
          key,
          subs,
          StationPlan(
            currentTrackPath: first.first,
            positionMs: 0,
            queue: first.sublist(1),
            played: const <String>[],
            resumed: false,
          ),
        );
      } finally {
        _loading = false;
      }
      state = state.copyWith(
        activeStation: key,
        message: '${stationTitleOf(key)}: sonando lo nuevo del curador',
      );
      final List<String> more = await _dedupRadio(
        await _fetchFeed(key, subs, 2),
      );
      if (more.isEmpty || epoch != _playEpoch || debugStationPlay != null) {
        return;
      }
      ref.read(liveDjProvider.notifier).addAllTracks(<File>[
        for (final String p in more) File(p),
      ]);
    }

    unawaited(run().catchError((Object _) {}));
  }

  /// 3.1.87: genero sin canciones locales: enciende la Radio Descubrimiento
  /// para [key] (apaga la radio de generos vieja, como [setDiscovery]).
  Future<void> _autoDiscovery(String key) async {
    state = state.copyWith(
      discoveryOn: true,
      activeStation: key,
      message:
          '${stationTitleOf(key)}: sin canciones locales, Radio '
          'Descubrimiento busca temas nuevos',
    );
    if (debugStationPlay != null || debugStationFeed != null) return;
    try {
      if (ref.read(liveDjProvider).radioOn) {
        await ref.read(liveDjProvider.notifier).toggleRadio();
      }
    } catch (_) {}
  }

  /// 3.1.87: Mix con Letra con un genero sin canciones locales: Radio
  /// Descubrimiento de ese genero y sus primeros temas (rutas temporales de
  /// la bandeja, ya sin duplicados de la biblioteca ni descartes).
  Future<List<String>> startZeroLocalRadio(
    String key,
    List<String> subs,
  ) async {
    await _autoDiscovery(key);
    return _dedupRadio(await _fetchFeed(key, subs, 2));
  }

  /// 3.1.87: quita los temas que el usuario ya tiene o ya descarto (huella
  /// normalizada, O(1) por tema) antes de que entren a la cola.
  Future<List<String>> _dedupRadio(List<String> paths) async {
    if (paths.isEmpty) return paths;
    final DiscoveryDedupController d = ref.read(discoveryDedupProvider);
    try {
      await ensureDiscoveryLibrary(d);
    } catch (_) {}
    return <String>[
      for (final String p in paths)
        if (!d.blocksCandidate(filename: p)) p,
    ];
  }

  StationFeed? _feedFor(String key, List<String> subs) => stationFeedFor(
    key,
    subs,
    <String, int>{for (final VibeGenre g in state.genres) g.name: g.count},
    extra: _virtual.counts(),
  );

  /// Temas nuevos del curador para [key] (rutas en la bandeja).
  Future<List<String>> _fetchFeed(
    String key,
    List<String> subs,
    int count,
  ) async {
    final StationFeed? f = _feedFor(key, subs);
    if (f == null) return const <String>[];
    final Future<List<String>> Function(String, StationFeed, int)? hook =
        debugStationFeed;
    if (hook != null) return hook(key, f, count);
    if (debugStationPlay != null) return const <String>[];
    final Set<String> before = <String>{
      for (final CuratorEntry e in ref.read(curatorProvider).entries) e.id,
    };
    await ref
        .read(curatorProvider.notifier)
        .discover(
          count: count,
          genre: f.folder,
          query: f.query,
          stationId: key,
          subGenreId: f.sub,
        );
    return <String>[
      for (final CuratorEntry e in ref.read(curatorProvider).pending)
        if (!before.contains(e.id) && File(e.file).existsSync()) e.file,
    ];
  }

  /// 3.1.64: sub-generos canonicos a carpetas locales (solo interno).
  Future<List<String>> _stationFolders(String key, List<String> subs) async {
    if (state.genres.isEmpty &&
        _virtual.isEmpty &&
        subs.any((String s) => isStationSub(key, s))) {
      await refresh();
    }
    return stationFolders(key, subs, <String>[
      for (final VibeGenre g in state.genres) g.name,
    ]);
  }

  /// Estacion corta: el curador busca temas del sub-genero en visto con
  /// menos canciones, con sus terminos canonicos (llegan a la bandeja de
  /// revision; agregar sigue siendo del usuario).
  void _feedShortStation(String key, List<String> subs) {
    final Future<List<String>> Function(String, StationFeed, int)? hook =
        debugStationFeed;
    if (debugStationPlay != null && hook == null) return;
    final StationFeed? f = _feedFor(key, subs);
    if (f == null) return;
    if (hook != null) {
      unawaited(hook(key, f, 3).catchError((Object _) => <String>[]));
      return;
    }
    unawaited(
      ref
          .read(curatorProvider.notifier)
          .discover(
            count: 3,
            genre: f.folder,
            query: f.query,
            stationId: key,
            subGenreId: f.sub,
          )
          .catchError((Object _) => 0),
    );
  }

  /// Cambio de pista en Live DJ: la anterior queda como sonada.
  Future<void> noteTrackChange(
    String? previous,
    String? next,
    List<String> queue,
  ) async {
    final GenreSessionDoc d = _stationsDoc;
    final String? key = d.active;
    final GenreSession? s = key == null ? null : d.stations[key];
    if (key == null || s == null) return;
    d.stations[key] = stationTrackChanged(
      s,
      previous: previous,
      next: next,
      queue: queue,
    );
    await _saveStations();
  }

  int _lastTickSaveMs = -1;

  /// 3.1.70: guarda en la sesion activa la pista, el segundo y la cola que
  /// suenan (pausa, o cada [kStationSaveEverySec] segundos). Solo si la
  /// pista es de la estacion: otra musica en Live DJ no la pisa.
  Future<void> notePlaybackTick(
    String? current,
    int positionMs,
    List<String> queue, {
    bool force = false,
  }) async {
    if (_loading || current == null) return;
    final GenreSessionDoc d = _stationsDoc;
    final String? key = d.active;
    final GenreSession? s = key == null ? null : d.stations[key];
    if (key == null || s == null) return;
    final String k = stationPathKey(current);
    final bool mine =
        (s.currentTrackPath != null &&
            stationPathKey(s.currentTrackPath!) == k) ||
        s.remainingQueuePaths.any((String p) => stationPathKey(p) == k);
    if (!mine) return;
    final int now = DateTime.now().millisecondsSinceEpoch;
    if (!force &&
        _lastTickSaveMs >= 0 &&
        now - _lastTickSaveMs < kStationSaveEverySec * 1000) {
      return;
    }
    _lastTickSaveMs = now;
    d.stations[key] = s.copyWith(
      currentTrackPath: current,
      positionMs: positionMs < 0 ? 0 : positionMs,
      remainingQueuePaths: List<String>.from(queue),
    );
    await _saveStations();
  }

  void _ensureTracker() {
    if (_tracking) return;
    _tracking = true;
    ref.listen<String?>(
      liveDjProvider.select((LiveDjState s) => s.currentTrackPath),
      (String? prev, String? next) {
        if (_loading || prev == next || prev == null) return;
        unawaited(
          noteTrackChange(prev, next, <String>[
            for (final File f in ref.read(liveDjProvider).queue) f.path,
          ]),
        );
        if (state.discoveryOn && _discoveryDry()) {
          unawaited(pumpDiscovery().catchError((Object _) => 0));
        }
      },
    );
    // 3.1.70: pausa y segundo a disco (con limite), para volver al genero
    // o reabrir la app en la misma pista y segundo.
    void tick({required bool force}) {
      final LiveDjState s = ref.read(liveDjProvider);
      unawaited(
        notePlaybackTick(
          s.currentTrackPath,
          s.position.inMilliseconds,
          <String>[for (final File f in s.queue) f.path],
          force: force,
        ),
      );
    }

    ref.listen<bool>(liveDjProvider.select((LiveDjState s) => s.isPlaying), (
      bool? prev,
      bool next,
    ) {
      if (prev == true && !next) tick(force: true);
    });
    ref.listen<int>(
      liveDjProvider.select((LiveDjState s) => s.position.inSeconds),
      (int? prev, int next) {
        if (prev != next) tick(force: false);
      },
    );
  }

  /// Reingreso: estacion activa con su pista y segundo. Toma la posicion
  /// del ultimo guardado de Live DJ si es de esta estacion.
  StationResumeInfo? resumeInfo() {
    final GenreSessionDoc d = _stationsDoc;
    final String? key = d.active;
    GenreSession? s = key == null ? null : d.stations[key];
    if (key == null || s == null) return null;
    StationLive? l;
    if (debugStationLive != null) {
      l = debugStationLive!();
    } else {
      try {
        final Map<String, dynamic> doc = readModeDoc(liveDjStatePath());
        final Object? cur = doc['currentTrackPath'];
        final Object? pos = doc['positionMs'];
        l = StationLive(
          cur is String && cur.isNotEmpty ? cur : null,
          pos is int ? pos : 0,
          <String>[
            for (final Object? q
                in (doc['queue'] as List?) ?? const <Object?>[])
              if (q is String) q,
          ],
        );
      } catch (_) {}
    }
    final String? lc = l?.current;
    if (l != null && lc != null) {
      final String k = stationPathKey(lc);
      final bool mine =
          (s.currentTrackPath != null &&
              stationPathKey(s.currentTrackPath!) == k) ||
          s.remainingQueuePaths.any((String p) => stationPathKey(p) == k);
      if (mine) {
        s = s.copyWith(
          currentTrackPath: lc,
          positionMs: l.positionMs,
          remainingQueuePaths: l.queue,
        );
        d.stations[key] = s;
      }
    }
    final String? cur = s.currentTrackPath;
    if (cur == null) return null;
    return StationResumeInfo(key, stationTitleOf(key), cur, s.positionMs);
  }

  /// [Seguir escuchando]: misma pista, mismo segundo, misma cola.
  Future<int> resumeActive() async {
    final GenreSessionDoc d = _stationsDoc;
    final String? key = d.active;
    final GenreSession? s = key == null ? null : d.stations[key];
    if (key == null || s == null) return 0;
    final List<String> subs = s.subGenresChecked.isEmpty
        ? <String>[if (key.startsWith('g:')) key.substring(2)]
        : s.subGenresChecked;
    return playStation(key, subs);
  }

  /// 3.1.68: un tema aceptado en la bandeja entra ya a su estacion: queda
  /// entre las canciones clasificadas y, si esa estacion es la que suena
  /// con ese sub-genero en visto, va a la cola de Live DJ.
  void injectAccepted(String stationId, String subGenreId, String path) {
    _virtual.add(path, TrackGenre(stationId, subGenreId, 0));
    state = state.copyWith(
      stations: groupStations(<MapEntry<String, int>>[
        for (final VibeGenre g in state.genres)
          MapEntry<String, int>(g.name, g.count),
      ], extra: _virtual.counts()),
    );
    final String? active = state.activeStation ?? _stationsDoc.active;
    if (active != stationId) return;
    final List<String> subs =
        _stationsDoc.stations[stationId]?.subGenresChecked ?? const <String>[];
    if (subs.isNotEmpty && !subs.contains(subGenreId)) return;
    if (debugStationPlay != null) return;
    ref.read(liveDjProvider.notifier).addAllTracks(<File>[File(path)]);
  }

  /// 3.1.68 [Buscar Nueva Musica para mis Generos Activos]: el curador busca
  /// temas de los sub-generos en visto de la estacion activa (los mas cortos
  /// primero, hasta [maxSubs]); sin estacion, del genero bloqueado. Devuelve
  /// cuantos temas llegaron a la bandeja.
  Future<int> searchActiveGenres({int perSub = 2, int maxSubs = 3}) async {
    final String? key = state.activeStation ?? _stationsDoc.active;
    final List<String> subs = <String>[
      if (key != null)
        for (final String g
            in _stationsDoc.stations[key]?.subGenresChecked ?? const <String>[])
          if (isStationSub(key, g)) g,
    ];
    if (key == null || subs.isEmpty) {
      if (debugStationFeed != null || debugStationPlay != null) return 0;
      return ref.read(curatorProvider.notifier).discover(count: perSub);
    }
    Map<String, int> counts = const <String, int>{};
    for (final GenreStation s in state.stations) {
      if (s.key == key) counts = s.subCounts;
    }
    subs.sort(
      (String a, String b) => (counts[a] ?? 0).compareTo(counts[b] ?? 0),
    );
    int n = 0;
    for (final String sub in subs.take(maxSubs)) {
      n += (await _fetchFeed(key, <String>[sub], perSub)).length;
    }
    return n;
  }

  /// 3.1.86: pistas de [key] con [subs] (carpetas de genero mas las
  /// clasificadas), sin sonar nada. Mix con Letra arma con esto su cola por
  /// genero.
  Future<List<String>> stationTracksFor(String key, List<String> subs) async =>
      _stationPool(key, subs);

  /// 3.2.2: pistas de [key] con [subs]: carpetas de genero + clasificadas
  /// una a una y, si el filtro tiene sub-generos especificos sin "Todas",
  /// tambien las de carpetas generales (`Rock Mix/`, bucket Todas de
  /// `Rock/Todas`) cuyo sub-genero real por artista/diccionario esta en
  /// visto. Sin repetir. Con "Todas" en visto o sin filtro, como siempre.
  Future<List<String>> _stationPool(String key, List<String> subs) async {
    final List<String> base = _withVirtual(
      await _stationTracks(await _stationFolders(key, subs)),
      key,
      subs,
    );
    if (!stationFiltersSpecificSubs(key, subs)) return base;
    final List<String> folders = stationFallbackFolders(key, subs, <String>[
      for (final VibeGenre g in state.genres) g.name,
    ]);
    final List<String> loose = <String>[
      if (folders.isNotEmpty) ...await _stationTracks(folders),
      ...?_virtual.byStation[key]?[stationFallbackSub(key)],
    ];
    if (loose.isEmpty) return base;
    return mergeStationTracks(
      base,
      stationRefinedTracks(key, subs, loose, root: vibeMusicRoot()),
    );
  }

  /// Sesion guardada de [key] (sub-generos en visto, pista, segundo).
  GenreSession? stationSession(String key) => _stationsDoc.stations[key];

  /// 3.1.69: estacion de la ultima seleccion (la que suena o la guardada);
  /// null la primera vez.
  String? savedActiveStation() => state.activeStation ?? _stationsDoc.active;

  /// 3.1.72: boton Play redondo a la izquierda de cada estacion. Si [key] ya
  /// es la estacion activa con algo cargado, pausa o reanuda (-1); si no,
  /// suena esa estacion en Shuffle (playStation congela antes la anterior
  /// con su pista y segundo) y devuelve sus pistas.
  Future<int> tapStation(String key, List<String> subGenres) async {
    final bool loaded =
        debugStationToggle != null ||
        ref.read(liveDjProvider).currentTrackPath != null;
    if (key == state.activeStation && loaded) {
      await toggleStationPause();
      return -1;
    }
    return playStation(key, subGenres);
  }

  /// 3.1.72: pausa o reanuda la estacion que suena (Live DJ).
  Future<void> toggleStationPause() async {
    final Future<void> Function()? hook = debugStationToggle;
    if (hook != null) {
      await hook();
      return;
    }
    if (ref.read(liveDjProvider).currentTrackPath == null) return;
    await ref.read(liveDjProvider.notifier).togglePlayPause();
  }

  /// Rutas del curador ya intercaladas por la Radio Descubrimiento.
  final Set<String> _discoveryUsed = <String>{};

  @visibleForTesting
  Set<String> get discoveryUsed => _discoveryUsed;

  /// 3.1.72: enciende o apaga la Radio Descubrimiento. Encendida apaga la
  /// radio de generos vieja (no conviven) e intercala ya los temas nuevos.
  Future<int> setDiscovery(bool on) async {
    state = state.copyWith(
      discoveryOn: on,
      message: on
          ? 'Radio Descubrimiento: temas nuevos entre los tuyos'
          : 'Radio Descubrimiento apagada: solo tu biblioteca',
    );
    if (!on) return 0;
    if (debugStationPlay == null && ref.read(liveDjProvider).radioOn) {
      await ref.read(liveDjProvider.notifier).toggleRadio();
    }
    return pumpDiscovery();
  }

  Future<int> toggleDiscovery() => setDiscovery(!state.discoveryOn);

  /// Cierto si en las proximas pistas de la cola ya no hay tema nuevo.
  bool _discoveryDry() {
    final List<File> q = ref.read(liveDjProvider).queue;
    for (final File f in q.take(kDiscoveryEvery + 1)) {
      if (_discoveryUsed.contains(f.path)) return false;
    }
    return true;
  }

  /// 3.1.72: intercala en la cola de Live DJ los temas nuevos del curador de
  /// la estacion activa (los pendientes de su bandeja y, si faltan, pide
  /// mas). Los archivos siguen en la bandeja del curador, fuera de la
  /// biblioteca: nada se escribe en ReGenial sin Aceptar.
  Future<int> pumpDiscovery() async {
    if (!state.discoveryOn) return 0;
    final String? key = state.activeStation ?? _stationsDoc.active;
    if (key == null) return 0;
    final List<String> subs =
        _stationsDoc.stations[key]?.subGenresChecked ?? const <String>[];
    final List<String> ready = <String>[];
    if (debugStationFeed == null && debugStationPlay == null) {
      for (final CuratorEntry e in ref.read(curatorProvider).pending) {
        if (e.stationId != key || _discoveryUsed.contains(e.file)) continue;
        if (File(e.file).existsSync()) ready.add(e.file);
      }
    }
    if (ready.length < 2) {
      for (final String p in await _fetchFeed(key, subs, 2)) {
        if (!_discoveryUsed.contains(p) && !ready.contains(p)) ready.add(p);
      }
    }
    // 3.1.87: nada que el usuario ya tenga o ya descarto entra a la cola.
    final List<String> fresh = await _dedupRadio(ready);
    ready
      ..clear()
      ..addAll(fresh);
    if (ready.isEmpty || !state.discoveryOn) return 0;
    _discoveryUsed.addAll(ready);
    return ref.read(liveDjProvider.notifier).interleaveDiscovery(<File>[
      for (final String p in ready) File(p),
    ], every: kDiscoveryEvery);
  }
}

/// 3.1.72: Live DJ sonando (para el Play/Pausa de cada estacion). Sin
/// decks disponibles (p. ej. pruebas sin media_kit) es false.
final stationLivePlayingProvider = Provider<bool>((ref) {
  try {
    return ref.watch(liveDjProvider.select((LiveDjState s) => s.isPlaying));
  } catch (_) {
    return false;
  }
});

final vibeHubProvider = NotifierProvider<VibeHubNotifier, VibeHubState>(
  VibeHubNotifier.new,
);

/// 3.2.2: true si [subs] filtra sub-generos especificos de [key] sin su
/// bucket general ("Todas"): hay que buscar en las carpetas generales.
bool stationFiltersSpecificSubs(String key, List<String> subs) {
  final String? all = stationFallbackSub(key);
  if (all == null || subs.contains(all)) return false;
  return subs.any((String s) => isStationSub(key, s));
}

/// 3.2.2: carpetas de la biblioteca que caen en el bucket general de [key]
/// (p. ej. `Rock Mix` -> Rock > Todas). Vacio si no hace falta refinar.
List<String> stationFallbackFolders(
  String key,
  List<String> subs,
  Iterable<String> library,
) {
  if (!stationFiltersSpecificSubs(key, subs)) return const <String>[];
  final String? all = stationFallbackSub(key);
  return <String>[
    for (final String f in library)
      if (stationSubOf(f) case final MapEntry<String, String> m
          when m.key == key && m.value == all)
        f,
  ];
}

/// 3.2.2: de [tracks] (carpetas generales / bucket Todas), las que el
/// diccionario de artistas y palabras clave pone en uno de los
/// sub-generos especificos de [subs] (ver [stationTrackGenre]).
List<String> stationRefinedTracks(
  String key,
  List<String> subs,
  Iterable<String> tracks, {
  String? root,
}) {
  final Set<String> want = <String>{
    for (final String s in subs)
      if (isStationSub(key, s) && s != stationFallbackSub(key)) s,
  };
  if (want.isEmpty) return const <String>[];
  final List<String> out = <String>[];
  for (final String p in tracks) {
    final TrackGenre g = stationTrackGenre(p, root: root);
    if (g.stationId == key && want.contains(g.subGenreId)) out.add(p);
  }
  return out;
}

/// 3.2.2: [base] mas [extra] sin repetir (por [stationPathKey]).
List<String> mergeStationTracks(List<String> base, Iterable<String> extra) {
  final Set<String> seen = <String>{
    for (final String p in base) stationPathKey(p),
  };
  return <String>[
    ...base,
    for (final String p in extra)
      if (seen.add(stationPathKey(p))) p,
  ];
}

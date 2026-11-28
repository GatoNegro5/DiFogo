import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/dj_lyrics.dart';
import '../core/mode_session.dart' show sessionDir;
import '../core/session_store.dart';
import 'livedj_provider.dart';
import 'vibe_hub_provider.dart';

/// 3.2.30: modos de la cabecera de Dj. Excluyentes: Automix (la fuente
/// elegida), Radio (Radio Descubrimiento) y Fiesta (sets de 8 por genero).
enum DjMode { automix, radio, fiesta }

const String kDjUiFileName = '_dj_ui.json';
const int kDjUiSchema = 1;

/// Pruebas: archivo en %TEMP%. Bajo `flutter test` sin esto no hay disco.
String? debugDjUiPath;

/// `Music/DjPlaylists/_dj_ui.json` (null bajo `flutter test`).
String? djUiPath() {
  final String? dbg = debugDjUiPath;
  if (dbg != null) return dbg;
  if (Platform.environment['FLUTTER_TEST'] == 'true') return null;
  try {
    return '${sessionDir()}${Platform.pathSeparator}$kDjUiFileName';
  } catch (_) {
    return null;
  }
}

DjMode djModeFromName(Object? v) {
  for (final DjMode m in DjMode.values) {
    if (m.name == v) return m;
  }
  return DjMode.automix;
}

/// Modo que dice el motor (manda sobre el archivo).
DjMode djEngineMode({
  required bool fiesta,
  required bool discovery,
  required bool radioOn,
}) => fiesta
    ? DjMode.fiesta
    : (discovery || radioOn)
    ? DjMode.radio
    : DjMode.automix;

class DjUiState {
  const DjUiState({
    this.mode = DjMode.automix,
    this.lyrics = false,
    this.source = 'genero',
    this.lastGenre,
    this.lastFolder,
    this.lastFiesta,
  });

  final DjMode mode;

  /// Rueda de letras visible bajo la portada.
  final bool lyrics;

  /// `genero` o `carpeta`: de donde salio lo ultimo que se eligio.
  final String source;
  final String? lastGenre;
  final String? lastFolder;
  final String? lastFiesta;

  DjUiState copyWith({
    DjMode? mode,
    bool? lyrics,
    String? source,
    String? lastGenre,
    String? lastFolder,
    String? lastFiesta,
  }) => DjUiState(
    mode: mode ?? this.mode,
    lyrics: lyrics ?? this.lyrics,
    source: source ?? this.source,
    lastGenre: lastGenre ?? this.lastGenre,
    lastFolder: lastFolder ?? this.lastFolder,
    lastFiesta: lastFiesta ?? this.lastFiesta,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': kDjUiSchema,
    'mode': mode.name,
    'lyrics': lyrics,
    'source': source,
    'lastGenre': lastGenre,
    'lastFolder': lastFolder,
    'lastFiesta': lastFiesta,
  };

  static DjUiState fromJson(Object? raw) {
    if (raw is! Map) return const DjUiState();
    String? str(Object? v) => v is String && v.isNotEmpty ? v : null;
    return DjUiState(
      mode: djModeFromName(raw['mode']),
      lyrics: raw['lyrics'] == true,
      source: raw['source'] == 'carpeta' ? 'carpeta' : 'genero',
      lastGenre: str(raw['lastGenre']),
      lastFolder: str(raw['lastFolder']),
      lastFiesta: str(raw['lastFiesta']),
    );
  }
}

DjUiState readDjUi(String? path) {
  if (path == null) return const DjUiState();
  try {
    return DjUiState.fromJson(SessionStore.readJson(path));
  } catch (_) {
    return const DjUiState();
  }
}

bool writeDjUi(String? path, DjUiState s) {
  if (path == null) return false;
  try {
    SessionStore.writeJsonSync(path, s.toJson());
    return true;
  } catch (_) {
    return false;
  }
}

/// 3.2.30: estado de la cabecera de Dj. Al entrar o reabrir solo pinta: no
/// suena nada. Cambiar de modo con musica sonando nunca corta (solo la API
/// publica de 3.2.29: Fiesta y Radio Descubrimiento del Hub, radio de
/// Live DJ que se apaga sin tocar el deck).
class DjUiNotifier extends Notifier<DjUiState> {
  /// Solo la primera vez en el proceso se restaura la Radio del archivo
  /// (Radio Descubrimiento no se guarda en el motor).
  static bool _coldStart = true;

  @visibleForTesting
  static void debugResetColdStart() => _coldStart = true;

  bool _applying = false;

  /// 3.2.36: un toque mas nuevo invalida los pasos pendientes del anterior
  /// (Radio espera pumpDiscovery y, al terminar, no debe deshacer Fiesta).
  int _modeEpoch = 0;

  @override
  DjUiState build() {
    final DjUiState saved = readDjUi(djUiPath());
    final DjMode engine = _engineMode();
    final bool cold = _coldStart;
    _coldStart = false;
    DjUiState s = saved;
    if (engine != saved.mode) {
      if (cold &&
          engine == DjMode.automix &&
          saved.mode == DjMode.radio &&
          !ref.read(liveDjProvider).isPlaying) {
        // Arranque: Radio vuelve como bandera (sin bombear ni sonar).
        Future<void>.microtask(
          () => ref.read(vibeHubProvider.notifier).restoreDiscoveryFlag(true),
        );
      } else {
        // Manda el motor; el archivo se corrige.
        s = saved.copyWith(mode: engine);
        Future<void>.microtask(() => writeDjUi(djUiPath(), s));
      }
    }
    ref.listen<bool>(
      vibeHubProvider.select((VibeHubState h) => h.fiestaMode),
      (bool? p, bool n) => _onEngine(n && p != true ? DjMode.fiesta : null),
    );
    ref.listen<bool>(
      vibeHubProvider.select((VibeHubState h) => h.discoveryOn),
      (bool? p, bool n) => _onEngine(n && p != true ? DjMode.radio : null),
    );
    ref.listen<bool>(
      liveDjProvider.select((LiveDjState l) => l.radioOn),
      (bool? p, bool n) => _onEngine(n && p != true ? DjMode.radio : null),
    );
    ref.listen<String?>(
      vibeHubProvider.select((VibeHubState h) => h.activeStation),
      (String? p, String? n) {
        if (n == null || n == p) return;
        state = state.copyWith(
          source: 'genero',
          lastGenre: n,
          lastFiesta: state.mode == DjMode.fiesta ? n : null,
        );
        _write();
      },
    );
    return s;
  }

  DjMode _engineMode() {
    final VibeHubState h = ref.read(vibeHubProvider);
    return djEngineMode(
      fiesta: h.fiestaMode,
      discovery: h.discoveryOn,
      radioOn: ref.read(liveDjProvider).radioOn,
    );
  }

  /// Cambio del motor desde fuera (chip del Hub, etc.): lo que se encendio
  /// pasa a ser el modo (con su exclusion); si algo se apago, manda el motor.
  void _onEngine(DjMode? turnedOn) {
    if (_applying) return;
    if (turnedOn != null) {
      if (turnedOn != state.mode) unawaited(setMode(turnedOn));
      return;
    }
    final DjMode m = _engineMode();
    if (m == state.mode) return;
    state = state.copyWith(mode: m);
    _write();
  }

  void _write() => writeDjUi(djUiPath(), state);

  /// Guarda el estado (tambien desde los persistSession de salida).
  void persist() => _write();

  /// Cambia de modo sin cortar: nunca stop, pausa ni arranque en frio.
  /// 3.2.36: si llega otro toque mientras este espera (p. ej. Radio
  /// en pumpDiscovery), se abandonan los pasos que quedan y no se
  /// pisa el modo elegido despues.
  Future<void> setMode(DjMode mode) async {
    final int epoch = ++_modeEpoch;
    final String? station = ref.read(vibeHubProvider).activeStation;
    state = state.copyWith(
      mode: mode,
      lastFiesta: mode == DjMode.fiesta ? station : null,
    );
    _write();
    _applying = true;
    try {
      final VibeHubNotifier hub = ref.read(vibeHubProvider.notifier);
      final LiveDjNotifier dj = ref.read(liveDjProvider.notifier);
      if (epoch != _modeEpoch) return;
      if (mode != DjMode.fiesta && ref.read(vibeHubProvider).fiestaMode) {
        await hub.setFiestaMode(false);
      }
      if (epoch != _modeEpoch) return;
      if (mode != DjMode.radio && ref.read(vibeHubProvider).discoveryOn) {
        await hub.setDiscovery(false);
      }
      if (epoch != _modeEpoch) return;
      if (mode != DjMode.radio && ref.read(liveDjProvider).radioOn) {
        // Apagar la radio de Live DJ no toca el deck que suena.
        await dj.toggleRadio();
      }
      if (epoch != _modeEpoch) return;
      if (mode == DjMode.radio && !ref.read(vibeHubProvider).discoveryOn) {
        await hub.setDiscovery(true);
      }
      if (epoch != _modeEpoch) return;
      if (mode == DjMode.fiesta && !ref.read(vibeHubProvider).fiestaMode) {
        await hub.setFiestaMode(true);
      }
    } finally {
      if (epoch == _modeEpoch) _applying = false;
    }
  }

  void setLyrics(bool on) {
    if (state.lyrics == on) return;
    state = state.copyWith(lyrics: on);
    _write();
  }

  void toggleLyrics() => setLyrics(!state.lyrics);

  /// Carpeta elegida como fuente (Poner set / Mezclar todo).
  void noteFolder(String path) {
    if (path.isEmpty) return;
    state = state.copyWith(source: 'carpeta', lastFolder: path);
    _write();
  }
}

final djUiProvider = NotifierProvider<DjUiNotifier, DjUiState>(
  DjUiNotifier.new,
);

/// 3.2.30: letra de una pista (solo lectura de su `.lrc`).
final djLyricsProvider = FutureProvider.autoDispose
    .family<List<DjLyricLine>, String>(
      (ref, String path) => loadDjLyrics(path),
    );

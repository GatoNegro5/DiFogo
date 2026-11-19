import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart' show Media, Player;

import '../core/audio/dj_audio_handler.dart';
import '../core/mode_session.dart' show automixStatePath, liveDjStatePath;
import '../providers/automix_provider.dart';
import '../providers/livedj_provider.dart';

// Comportamiento de app profesional ante interrupciones del sistema
// (llamada telefónica, alarma, otra app de audio, auriculares fuera).
//
// * Al sonar pide el foco de audio (`setActive(true)`): sin él Android
//   mezcla la llamada con la música.
// * Interrupción temporal (llamada) → pausa y, al terminar, reanuda sola
//   solo si la pausa la causó el sistema.
// * Pérdida permanente (otra app de música) → pausa y NO reanuda.
// * Auriculares/Bluetooth desconectados → pausa y NO reanuda (salvo que
//   ya estemos en pausa por una llamada: 3.1.96).
// * "Duck" (navegación hablando): lo atenúa el sistema; no se toca el volumen
//   para no pelear con el motor de mezcla.
// * 3.1.96: cambio de salida (Bluetooth <-> parlante) → [onOutputDeviceChanged]
//   para que el siguiente Play recargue la salida de mpv.
//
// Un solo guardián para Automix y Live DJ en Android e iPhone (en
// Windows/macOS no hay llamadas ni foco que gestionar).

/// 3.1.96: lo que el guardian necesita de los motores (inyectable en pruebas).
abstract class FocusEngines {
  bool get anyPlaying;
  Future<bool> pauseAutomix();
  Future<bool> pauseLiveDj();
  Future<void> resumeAutomix();
  Future<void> resumeLiveDj();

  /// La pausa del sistema ya no se reanudara: suelta `_pausedByInterruption`.
  void dropInterruptionResume();

  /// La salida de audio cambio: el proximo Play recarga la salida de mpv.
  void outputDeviceChanged();

  /// Play del volante en frio: ultima sesion guardada (Automix o Live DJ).
  Future<void> coldPlay();

  void listenPlaying(void Function(bool playing) onChange);
  void close();
}

class _RefEngines implements FocusEngines {
  _RefEngines(this._ref);

  final WidgetRef _ref;
  final List<ProviderSubscription<dynamic>> _subs = [];

  @override
  bool get anyPlaying =>
      _ref.read(automixProvider).isPlaying ||
      _ref.read(liveDjProvider).isPlaying;

  @override
  Future<bool> pauseAutomix() =>
      _ref.read(automixProvider.notifier).pauseForInterruption();

  @override
  Future<bool> pauseLiveDj() =>
      _ref.read(liveDjProvider.notifier).pauseForInterruption();

  @override
  Future<void> resumeAutomix() =>
      _ref.read(automixProvider.notifier).resumeAfterInterruption();

  @override
  Future<void> resumeLiveDj() =>
      _ref.read(liveDjProvider.notifier).resumeAfterInterruption();

  @override
  void dropInterruptionResume() {
    try {
      _ref.read(automixProvider.notifier).dropInterruptionResume();
    } catch (_) {}
    try {
      _ref.read(liveDjProvider.notifier).dropInterruptionResume();
    } catch (_) {}
  }

  @override
  void outputDeviceChanged() {
    try {
      _ref.read(automixProvider.notifier).markOutputDirty();
    } catch (_) {}
    try {
      _ref.read(liveDjProvider.notifier).markOutputDirty();
    } catch (_) {}
  }

  @override
  Future<void> coldPlay() async {
    final bool liveFirst = liveDjSessionIsNewer();
    final List<Future<bool> Function()> order = <Future<bool> Function()>[
      if (liveFirst)
        () => _ref.read(liveDjProvider.notifier).coldPlayFromSession(),
      () => _ref.read(automixProvider.notifier).coldPlayFromSession(),
      if (!liveFirst)
        () => _ref.read(liveDjProvider.notifier).coldPlayFromSession(),
    ];
    for (final Future<bool> Function() play in order) {
      try {
        if (await play()) return;
      } catch (e) {
        debugPrint('🔴 [AUDIO FOCUS] cold play $e');
      }
    }
  }

  @override
  void listenPlaying(void Function(bool playing) onChange) {
    _subs.add(
      _ref.listenManual<bool>(
        automixProvider.select((s) => s.isPlaying),
        (prev, next) => onChange(next),
      ),
    );
    _subs.add(
      _ref.listenManual<bool>(
        liveDjProvider.select((s) => s.isPlaying),
        (prev, next) => onChange(next),
      ),
    );
  }

  @override
  void close() {
    for (final sub in _subs) {
      sub.close();
    }
    _subs.clear();
  }
}

/// 3.1.96: true si la sesion de Live DJ se guardo despues que la de Automix
/// (el ultimo modo usado). Sin archivos: Automix.
bool liveDjSessionIsNewer({String? automixPath, String? liveDjPath}) {
  try {
    final File a = File(automixPath ?? automixStatePath());
    final File l = File(liveDjPath ?? liveDjStatePath());
    if (!l.existsSync()) return false;
    if (!a.existsSync()) return true;
    return l.lastModifiedSync().isAfter(a.lastModifiedSync());
  } catch (_) {
    return false;
  }
}

/// true si el evento trae un dispositivo de SALIDA conectado o desconectado.
bool outputDevicesChanged(AudioDevicesChangedEvent event) =>
    event.devicesAdded.any((AudioDevice d) => d.isOutput) ||
    event.devicesRemoved.any((AudioDevice d) => d.isOutput);

class AudioInterruptionGuard {
  AudioInterruptionGuard(WidgetRef ref) : this.withEngines(_RefEngines(ref));

  /// 3.1.96: guardian con motores inyectados (pruebas sin Riverpod ni mpv).
  AudioInterruptionGuard.withEngines(this._engines) {
    onOutputDeviceChanged = _engines.outputDeviceChanged;
  }

  final FocusEngines _engines;

  /// 3.1.96: salida de audio conectada/desconectada (Bluetooth <-> parlante).
  void Function()? onOutputDeviceChanged;

  AudioSession? _session;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  StreamSubscription<void>? _noisySub;
  StreamSubscription<AudioDevicesChangedEvent>? _devicesSub;
  bool _resumeAutomix = false;
  bool _resumeLiveDj = false;
  // Pausa causada por el sistema: se conserva el foco para que Android nos
  // avise (GAIN) cuando termine la llamada y poder reanudar.
  bool _interrupted = false;
  bool _disposed = false;

  bool get _supported => Platform.isAndroid || Platform.isIOS;

  /// Hay una reanudacion pendiente al terminar la interrupcion.
  @visibleForTesting
  bool get resumePending => _resumeAutomix || _resumeLiveDj;

  /// En pausa por una perdida temporal del foco (llamada).
  @visibleForTesting
  bool get inTransientLoss => _interrupted;

  Future<void> start() async {
    if (!_supported) return;
    try {
      final session = await AudioSession.instance;
      if (_disposed) return;
      // 3.1.96: foco normal de reproductor de musica (AUDIOFOCUS_GAIN). Con
      // el transitorio Android no siempre devolvia el foco al colgar.
      await session.configure(const AudioSessionConfiguration.music());
      _session = session;
      _interruptionSub = session.interruptionEventStream.listen(
        (e) => unawaited(handleInterruption(e)),
      );
      _noisySub = session.becomingNoisyEventStream.listen((_) {
        unawaited(handleNoisy());
      });
      if (Platform.isAndroid) {
        _devicesSub = session.devicesChangedEventStream.listen(
          handleDevicesChanged,
        );
      }
      _engines.listenPlaying(_onPlayingChanged);
      // 3.1.96: Play del volante/Bluetooth antes de que suene nada.
      globalAudioHandler.onColdPlay = _engines.coldPlay;
    } catch (e) {
      debugPrint('🔴 [AUDIO FOCUS] init $e');
    }
  }

  void dispose() {
    _disposed = true;
    _interruptionSub?.cancel();
    _noisySub?.cancel();
    _devicesSub?.cancel();
    _engines.close();
  }

  void _onPlayingChanged(bool playing) {
    final session = _session;
    if (session == null) return;
    if (playing) {
      unawaited(_requestFocus(session));
    } else if (!_engines.anyPlaying && !_interrupted) {
      // Pausa o parada del usuario: soltar el foco para que otras apps
      // (llamada, navegación, otro reproductor) funcionen con normalidad.
      unawaited(session.setActive(false).catchError((_) => false));
    }
  }

  Future<void> _requestFocus(AudioSession session) async {
    try {
      final granted = await session.setActive(true);
      if (!granted && _engines.anyPlaying) {
        // El sistema nos niega el foco (p. ej. llamada en curso): no sonar encima.
        await _pauseAll(resumeLater: false);
      }
    } catch (e) {
      debugPrint('🔴 [AUDIO FOCUS] request $e');
    }
  }

  /// Evento de foco (llamada, alarma, otra app).
  @visibleForTesting
  Future<void> handleInterruption(AudioInterruptionEvent event) async {
    if (event.begin) {
      switch (event.type) {
        case AudioInterruptionType.duck:
          return;
        case AudioInterruptionType.pause:
          await _pauseAll(resumeLater: true);
          return;
        case AudioInterruptionType.unknown:
          await _pauseAll(resumeLater: false);
          return;
      }
    } else {
      switch (event.type) {
        case AudioInterruptionType.duck:
          return;
        case AudioInterruptionType.pause:
          await _resumeAll();
          return;
        case AudioInterruptionType.unknown:
          _resumeAutomix = false;
          _resumeLiveDj = false;
          _interrupted = false;
          _engines.dropInterruptionResume();
          return;
      }
    }
  }

  /// Auriculares/Bluetooth fuera (ACTION_AUDIO_BECOMING_NOISY).
  @visibleForTesting
  Future<void> handleNoisy() async {
    // La ruta de salida cambio: el proximo Play recarga la salida de mpv.
    onOutputDeviceChanged?.call();
    if (_interrupted) {
      // 3.1.96: en plena llamada (el auto pasa de A2DP a HFP) ya estamos en
      // pausa del sistema: se conserva la reanudacion al colgar.
      return;
    }
    await _pauseAll(resumeLater: false);
  }

  /// 3.1.96: salida conectada o desconectada (solo Android).
  @visibleForTesting
  void handleDevicesChanged(AudioDevicesChangedEvent event) {
    if (!outputDevicesChanged(event)) return;
    onOutputDeviceChanged?.call();
  }

  Future<void> _pauseAll({required bool resumeLater}) async {
    if (resumeLater) _interrupted = true;
    try {
      final paused = await _engines.pauseAutomix();
      if (paused && resumeLater) _resumeAutomix = true;
    } catch (e) {
      debugPrint('🔴 [AUDIO FOCUS] pause automix $e');
    }
    try {
      final paused = await _engines.pauseLiveDj();
      if (paused && resumeLater) _resumeLiveDj = true;
    } catch (e) {
      debugPrint('🔴 [AUDIO FOCUS] pause livedj $e');
    }
    if (!resumeLater) {
      _resumeAutomix = false;
      _resumeLiveDj = false;
      _interrupted = false;
      // 3.1.96: sin reanudacion: no dejar `_pausedByInterruption` colgada.
      _engines.dropInterruptionResume();
    } else if (!_resumeAutomix && !_resumeLiveDj) {
      // Nada sonaba: no hay nada que reanudar ni foco que retener.
      _interrupted = false;
    }
  }

  Future<void> _resumeAll() async {
    final wantAutomix = _resumeAutomix;
    final wantLive = _resumeLiveDj;
    _resumeAutomix = false;
    _resumeLiveDj = false;
    _interrupted = false;
    if (!wantAutomix && !wantLive) return;
    final session = _session;
    if (session != null) {
      try {
        final granted = await session.setActive(true);
        if (!granted) {
          _engines.dropInterruptionResume();
          return;
        }
      } catch (_) {}
    }
    if (wantAutomix) {
      try {
        await _engines.resumeAutomix();
      } catch (e) {
        debugPrint('🔴 [AUDIO FOCUS] resume automix $e');
      }
    }
    if (wantLive) {
      try {
        await _engines.resumeLiveDj();
      } catch (e) {
        debugPrint('🔴 [AUDIO FOCUS] resume livedj $e');
      }
    }
  }
}

// ---------------------------------------------------------------------------
// 3.1.96: salida de mpv trabada tras un cambio de dispositivo (Android).
// ---------------------------------------------------------------------------

/// Espera tras Play antes de mirar si la posicion avanza.
const int kOutputProbeMs = 180;

/// Avance minimo (ms) en [kOutputProbeMs] para dar la salida por viva.
const int kOutputMinAdvanceMs = 40;

/// true si el deck dice sonar pero su posicion no avanzo.
bool outputStalled({
  required bool playing,
  required int beforeMs,
  required int afterMs,
}) => playing && afterMs - beforeMs < kOutputMinAdvanceMs;

enum OutputFix { none, reload, reopen }

/// `ao-reload` de mpv: cierra y vuelve a abrir la salida de audio del deck en
/// el dispositivo actual (parlante si el Bluetooth se fue).
Future<void> mpvAoReload(Player deck) async {
  try {
    await (deck.platform as dynamic)?.command(<String>['ao-reload']);
  } catch (e) {
    debugPrint('🔴 [AUDIO OUT] ao-reload $e');
  }
}

/// Reabre [path] en el deck en [at] y suena (ultimo recurso).
Future<void> mpvReopenDeck(Player deck, String path, Duration at) async {
  try {
    await deck.open(Media(path), play: false);
    try {
      await deck.stream.duration
          .firstWhere((Duration d) => d.inMilliseconds > 0)
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
    if (at > Duration.zero) await deck.seek(at);
    await deck.play();
  } catch (e) {
    debugPrint('🔴 [AUDIO OUT] reopen $e');
  }
}

/// 3.1.96 (solo Android): tras Play o reanudar. Con [dirty] (cambio de
/// salida) hace `ao-reload` de una; luego, si a los [kOutputProbeMs] el deck
/// suena pero la posicion no avanza, `ao-reload`; si sigue igual y hay
/// [reopenPath], reabre la pista en la misma posicion.
Future<OutputFix> ensureDeckOutput(
  Player deck, {
  required bool dirty,
  String? reopenPath,
  bool? android,
}) async {
  if (!(android ?? Platform.isAndroid)) return OutputFix.none;
  int posMs() {
    try {
      return deck.state.position.inMilliseconds;
    } catch (_) {
      return 0;
    }
  }

  bool playing() {
    try {
      return deck.state.playing;
    } catch (_) {
      return false;
    }
  }

  const Duration probe = Duration(milliseconds: kOutputProbeMs);
  OutputFix fix = OutputFix.none;
  if (dirty) {
    await mpvAoReload(deck);
    fix = OutputFix.reload;
  }
  int before = posMs();
  await Future<void>.delayed(probe);
  if (!outputStalled(playing: playing(), beforeMs: before, afterMs: posMs())) {
    return fix;
  }
  if (fix == OutputFix.none) {
    await mpvAoReload(deck);
    fix = OutputFix.reload;
    before = posMs();
    await Future<void>.delayed(probe);
    if (!outputStalled(
      playing: playing(),
      beforeMs: before,
      afterMs: posMs(),
    )) {
      return fix;
    }
  }
  if (reopenPath == null) return fix;
  await mpvReopenDeck(deck, reopenPath, Duration(milliseconds: before));
  return OutputFix.reopen;
}

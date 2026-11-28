import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio_path.dart' show sameAudioPath;
import '../../core/genre_mix_fx.dart';
import '../../core/genre_stations.dart' show stationTitleOf;
import '../../core/net/artist_info.dart';
import '../../core/track_name_clean.dart' show cleanTrackTitle;
import '../../providers/livedj_provider.dart';
import '../../providers/mix_formula.dart';
import '../../providers/theme_provider.dart';
import 'livedj_mix_marker.dart';
import 'livedj_layout.dart';
import '../../providers/vibe_hub_provider.dart';
import '../widgets/radio_track_actions.dart';

/// 3.1.70: AutomixDj abre en Modo Spotify (portada grande, artista, barra
/// de progreso y controles limpios). false = vista clasica de consola.
final liveDjSpotifyModeProvider = StateProvider<bool>((ref) => true);

/// Titulo y artista de `Artista - Titulo.ext` (sin artista si no viene).
/// 3.1.84: sin `.mp3` ni `(91 BPM)`.
({String title, String artist}) spotifyTrackLabels(String? path) {
  if (path == null || path.isEmpty) {
    return (title: 'SISTEMA EN ESPERA', artist: 'Elige una estación o carpeta');
  }
  // 3.1.84: sin extension ni etiqueta de BPM (pantalla limpia).
  final String name = cleanTrackTitle(path);
  final int i = name.indexOf(' - ');
  if (i <= 0) return (title: name.trim(), artist: '');
  return (
    title: name.substring(i + 3).trim(),
    artist: name.substring(0, i).trim(),
  );
}

String spotifyMixLabel(MixFormula f) {
  switch (f) {
    case MixFormula.dnaEnergy:
      return 'ACTIVE BEATMATCHING';
    case MixFormula.phraseGrid:
      return 'PHRASE 8';
    case MixFormula.stealthGap:
      return 'STEALTH';
  }
}

/// 3.1.72: badge de la estacion (o genero) que suena.
String spotifyStationBadge(String? stationKey) => stationKey == null
    ? 'BIBLIOTECA LOCAL'
    : stationTitleOf(stationKey).toUpperCase();

/// 3.1.72: NEXT MIX: la proxima pista y la cuenta regresiva al punto de
/// mezcla (customMixOutMs) de la que suena.
String spotifyNextMixLabel(LiveDjState s) {
  String? next;
  for (final File f in s.queue) {
    if (s.currentTrackPath != null &&
        sameAudioPath(f.path, s.currentTrackPath)) {
      continue;
    }
    next = f.path;
    break;
  }
  if (next == null) return 'NEXT MIX · sin siguiente';
  final String title = spotifyTrackLabels(next).title;
  final int mixOut = s.customMixOutMs;
  final int left = mixOut > 0 ? mixOut - s.position.inMilliseconds : -1;
  if (s.currentTrackPath == null || left < 0) return 'NEXT MIX · $title';
  return 'NEXT MIX en ${_clock(Duration(milliseconds: left))} · $title';
}

/// 3.1.84: indicador compacto de la siguiente sin extension ni BPM:
/// `Siguiente: Daddy Yankee · Ghosting`.
String spotifyCleanNextLabel(LiveDjState s) {
  for (final File f in s.queue) {
    if (s.currentTrackPath != null &&
        sameAudioPath(f.path, s.currentTrackPath)) {
      continue;
    }
    final labels = spotifyTrackLabels(f.path);
    return labels.artist.isEmpty
        ? 'Siguiente: ${labels.title}'
        : 'Siguiente: ${labels.artist} · ${labels.title}';
  }
  return '';
}

/// 3.1.73: plan (curva + FX) del proximo cruce, el mismo que usara el motor.
GenreMixPlan spotifyMixFxPlan(
  LiveDjState s,
  MixFormula formula,
  String? stationKey, {
  bool locked = false,
}) {
  String? next;
  for (final File f in s.queue) {
    if (s.currentTrackPath != null &&
        sameAudioPath(f.path, s.currentTrackPath)) {
      continue;
    }
    next = f.path;
    break;
  }
  return genrePlanForPaths(
    current: formula,
    stationKey: stationKey,
    outPath: s.currentTrackPath,
    inPath: next,
    locked: locked,
  );
}

String _clock(Duration d) {
  final Duration v = d.isNegative ? Duration.zero : d;
  return '${v.inMinutes.toString().padLeft(2, '0')}:'
      '${(v.inSeconds % 60).toString().padLeft(2, '0')}';
}

/// 3.1.74: badge interactivo `FX · <MEZCLA> + <EFECTO> · AUTO|FIJO`. El
/// mismo widget va en Spotify Pro y en la cabecera de la vista clasica y
/// comparte `mixFormulaLockedProvider`: un toque alterna AUTO/FIJO en las dos.
class MixFxBadge extends ConsumerWidget {
  const MixFxBadge({super.key, required this.badgeKey});

  /// Llave del area tocable (`spotify-fx-badge` / `classic-fx-badge`).
  final Key badgeKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final LiveDjState s = ref.watch(liveDjProvider);
    final MixFormula formula = ref.watch(mixFormulaProvider);
    final bool locked = ref.watch(mixFormulaLockedProvider);
    final String? station = ref.watch(
      vibeHubProvider.select((VibeHubState h) => h.activeStation),
    );
    final GenreMixPlan plan = spotifyMixFxPlan(
      s,
      formula,
      station,
      locked: locked,
    );
    return GestureDetector(
      key: badgeKey,
      onTap: () => ref.read(mixFormulaLockedProvider.notifier).state = !locked,
      child: Tooltip(
        message:
            'Mix Effect del proximo cruce segun genero y BPM. '
            'AUTO elige curva y efecto; FIJO respeta tu tipo de '
            'mezcla. Toca para cambiar.',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: const Color(0x2200E5FF),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: GatoMixTheme.cyanAccent),
          ),
          child: Text(
            genreMixBadge(plan, spotifyMixLabel(plan.formula)),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: GatoMixTheme.cyanAccent,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0,
            ),
          ),
        ),
      ),
    );
  }
}

/// Cuerpo del reproductor de AutomixDj en Modo Spotify.
class LiveDjSpotifyPanel extends ConsumerStatefulWidget {
  final bool compact;

  const LiveDjSpotifyPanel({super.key, required this.compact});

  @override
  ConsumerState<LiveDjSpotifyPanel> createState() => _LiveDjSpotifyPanelState();
}

class _LiveDjSpotifyPanelState extends ConsumerState<LiveDjSpotifyPanel> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final LiveDjState s = ref.watch(liveDjProvider);
    final String? path =
        s.currentTrackPath ?? (s.queue.isNotEmpty ? s.queue.first.path : null);
    final labels = spotifyTrackLabels(path);
    final bool canToggle = s.currentTrackPath != null || s.queue.isNotEmpty;
    final bool shuffle = s.mixStrategy == LiveDjMixStrategy.random;
    final Duration pos = s.position;
    final Duration dur = s.duration;
    final double maxMs = dur.inMilliseconds > 0
        ? dur.inMilliseconds.toDouble()
        : 1.0;
    final double value =
        _drag ?? pos.inMilliseconds.toDouble().clamp(0.0, maxMs);
    final LiveDjNotifier dj = ref.read(liveDjProvider.notifier);

    Widget info(double width) => SizedBox(
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // 3.1.72 Spotify Pro: tarjeta NOW PLAYING.
          const Text(
            'NOW PLAYING',
            key: Key('spotify-now-playing'),
            style: TextStyle(
              color: Color(0xFFFF5722),
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            labels.title,
            key: const Key('spotify-title'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            labels.artist.isEmpty ? 'Artista desconocido' : labels.artist,
            key: const Key('spotify-artist'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white60, fontSize: 15),
          ),
          // 3.1.87: Guardar / Descartar en 1 clic (solo pista de la Radio).
          RadioTrackActions(
            path: s.currentTrackPath,
            onSkip: () => dj.forceNext(),
          ),
          // 3.1.84 Consumer Clean Mode: sin chips de mezcla ni FX bajo el
          // titulo (viven en la hoja Modo DJ de la cabecera).
          const SizedBox(height: 10),
          SizedBox(
            key: const Key('livedj-progress-slider'),
            height: kLiveDjProgressHeight,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                activeTrackColor: GatoMixTheme.syncActive,
                inactiveTrackColor: Colors.white12,
                thumbColor: Colors.white,
                overlayShape: SliderComponentShape.noOverlay,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              // 3.1.83: la misma linea roja del punto de mezcla que la consola
              // clasica y la vista de la carpeta (customMixOutMs).
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  Slider(
                    key: const Key('spotify-progress'),
                    value: value,
                    min: 0.0,
                    max: maxMs,
                    onChangeStart: (double v) => setState(() => _drag = v),
                    onChanged: (double v) => setState(() => _drag = v),
                    onChangeEnd: (double v) {
                      if (dur.inMilliseconds > 0) {
                        dj.seek(Duration(milliseconds: v.round()));
                      }
                      setState(() => _drag = null);
                    },
                  ),
                  liveDjMixMarker(6, s.customMixOutMs, dur.inMilliseconds),
                ],
              ),
            ),
          ),
          Row(
            children: <Widget>[
              Text(
                _clock(Duration(milliseconds: value.round())),
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
              const Spacer(),
              Text(
                '-${_clock(dur - Duration(milliseconds: value.round()))}',
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: <Widget>[
              IconButton(
                key: const Key('spotify-shuffle'),
                tooltip: shuffle ? 'Shuffle activo' : 'Orden de la cola',
                onPressed: dj.toggleMixStrategy,
                icon: Icon(
                  Icons.shuffle_rounded,
                  size: 26,
                  color: shuffle ? GatoMixTheme.syncActive : Colors.white38,
                ),
              ),
              IconButton(
                key: const Key('spotify-play'),
                iconSize: 68,
                onPressed: canToggle ? dj.togglePlayPause : null,
                icon: Icon(
                  s.isPlaying
                      ? Icons.pause_circle_filled_rounded
                      : Icons.play_circle_fill_rounded,
                  color: Colors.white.withValues(alpha: canToggle ? 1 : 0.3),
                ),
              ),
              IconButton(
                key: const Key('spotify-next'),
                onPressed: s.queue.isEmpty ? null : () => dj.forceNext(),
                icon: Icon(
                  Icons.skip_next_rounded,
                  size: 32,
                  color: s.queue.isEmpty ? Colors.white24 : Colors.white,
                ),
              ),
            ],
          ),
        ],
      ),
    );

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double w = c.maxWidth.isFinite ? c.maxWidth : 400;
        final double h = c.maxHeight.isFinite ? c.maxHeight : 400;
        // 3.1.84: sin chips ni NEXT MIX la ficha es mas baja.
        const double infoH = 236;
        final bool wide = w >= 520;
        final double colSide = (h - infoH - 24).clamp(0.0, w - 48);
        // Telefono con poco alto: portada al lado en vez de encima.
        final bool row = wide || colSide < 120;
        final Widget body;
        if (row) {
          final double narrowSide = (h - 24) < w * 0.35 ? h - 24 : w * 0.35;
          final double side = wide
              ? (h - 24).clamp(0.0, 360.0)
              : narrowSide.clamp(0.0, 200.0);
          final double infoW = (w - side - (wide ? 56 : 44)).clamp(
            160.0,
            560.0,
          );
          body = Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (side >= 64) ...<Widget>[
                _SpotifyCover(artist: labels.artist, side: side),
                SizedBox(width: wide ? 24 : 12),
              ],
              info(infoW),
            ],
          );
        } else {
          final double side = colSide;
          body = Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (side >= 64) ...<Widget>[
                _SpotifyCover(artist: labels.artist, side: side),
                const SizedBox(height: 12),
              ],
              info((w - 32).clamp(160.0, 560.0)),
            ],
          );
        }
        return ColoredBox(
          key: const Key('livedj-spotify-panel'),
          color: GatoMixTheme.bgDark,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Center(
              child: FittedBox(fit: BoxFit.scaleDown, child: body),
            ),
          ),
        );
      },
    );
  }
}

/// Portada grande: foto del artista (cache local) o una nota de respaldo.
class _SpotifyCover extends StatefulWidget {
  final String artist;
  final double side;

  const _SpotifyCover({required this.artist, required this.side});

  @override
  State<_SpotifyCover> createState() => _SpotifyCoverState();
}

class _SpotifyCoverState extends State<_SpotifyCover> {
  Future<ArtistInfo?>? _info;
  String _for = '';

  Future<ArtistInfo?>? _future() {
    if (widget.artist.isEmpty) return null;
    if (_info == null || _for != widget.artist) {
      _for = widget.artist;
      _info = loadArtistInfo(widget.artist);
    }
    return _info;
  }

  @override
  Widget build(BuildContext context) {
    final double side = widget.side;
    final Widget fallback = DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFF1B4F72), Color(0xFF0B1A2A)],
        ),
      ),
      child: Center(
        child: Icon(Icons.music_note, color: Colors.white38, size: side * 0.4),
      ),
    );
    final Future<ArtistInfo?>? f = _future();
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        key: const Key('spotify-cover'),
        width: side,
        height: side,
        child: f == null
            ? fallback
            : FutureBuilder<ArtistInfo?>(
                future: f,
                builder:
                    (BuildContext context, AsyncSnapshot<ArtistInfo?> snap) {
                      final String? photo = snap.data?.photoPath;
                      if (photo != null && File(photo).existsSync()) {
                        final int px =
                            (side * MediaQuery.devicePixelRatioOf(context))
                                .round()
                                .clamp(64, 1600);
                        return Image.file(
                          File(photo),
                          fit: BoxFit.cover,
                          cacheWidth: px,
                          cacheHeight: px,
                          errorBuilder: (_, _, _) => fallback,
                        );
                      }
                      return fallback;
                    },
              ),
      ),
    );
  }
}

/// Boton de la cabecera: Modo Spotify o vista clasica de consola.
class LiveDjSpotifyToggle extends ConsumerWidget {
  const LiveDjSpotifyToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool on = ref.watch(liveDjSpotifyModeProvider);
    return Tooltip(
      message: on ? 'Vista lista' : 'Modo Spotify',
      child: GestureDetector(
        key: const Key('livedj-spotify-toggle'),
        onTap: () => ref.read(liveDjSpotifyModeProvider.notifier).state = !on,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Icon(
            // 3.1.84: los sliders (tune) son ahora el boton Modo DJ.
            on ? Icons.view_list_rounded : Icons.library_music_rounded,
            size: 22,
            color: on ? Colors.white70 : GatoMixTheme.syncActive,
          ),
        ),
      ),
    );
  }
}

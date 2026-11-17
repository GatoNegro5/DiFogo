import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/genre_stations.dart';
import '../providers/session_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/vibe_hub_provider.dart';
import 'vibe_hub_view.dart';

/// Solo pruebas: no abrir el flujo de inicio.
@visibleForTesting
bool debugSkipStartupVibe = false;
bool _vibeShown = false;

const Color _vibeNeon = GatoMixTheme.syncActive;

/// 3.1.61: al arrancar, si habia una estacion sonando ofrece seguir donde
/// quedo; si no (o si elige otro genero), abre las estaciones estilo
/// Spotify con sus sub-generos en visto. Todo suena en Live DJ.
/// [onStation] se llama antes de sonar (p. ej. para abrir Live DJ).
Future<void> showStartupVibeFlow(
  BuildContext context,
  WidgetRef ref, {
  String? root,
  Future<List<VibeGenre>> Function(String root)? scan,
  VoidCallback? onStation,
}) async {
  if (debugSkipStartupVibe || _vibeShown) return;
  _vibeShown = true;
  final VibeHubNotifier hub = ref.read(vibeHubProvider.notifier);
  final StationResumeInfo? info = hub.resumeInfo();
  if (info != null) {
    final bool? keep = await showDialog<bool>(
      context: context,
      builder: (_) => StationResumeDialog(info: info),
    );
    if (keep == null) return;
    if (keep) {
      onStation?.call();
      await hub.resumeActive();
      return;
    }
    await hub.freezeActive();
  }
  if (!context.mounted) return;
  final String r = root ?? vibeMusicRoot();
  final List<VibeGenre> genres = await (scan ?? scanVibeGenres)(r);
  if (!context.mounted) return;
  // 3.1.67: el Hub reusa este escaneo (sin otro recorrido antes de sonar) y
  // clasifica cancion por cancion las carpetas genericas.
  await hub.adoptGenres(genres, root: r);
  if (!context.mounted) return;
  final List<GenreStation> stations = ref.read(vibeHubProvider).stations;
  if (genres.isEmpty && stations.every((GenreStation s) => s.count == 0)) {
    return;
  }
  StationPick? last;
  final StationPick? chosen = await showDialog<StationPick>(
    context: context,
    builder: (_) => StationPickerDialog(
      stations: stations,
      savedChecked: (String k) => hub.stationSession(k)?.subGenresChecked,
      initialStation: hub.savedActiveStation(),
      onChanged: (StationPick? p) => last = p,
      activeStation: ref.read(vibeHubProvider).activeStation,
      playing: ref.read(stationLivePlayingProvider),
      onTogglePause: hub.toggleStationPause,
    ),
  );
  // 3.1.67: salir del selector (fuera del cuadro o Atras) tras tocar una
  // estacion tambien la hace sonar; solo [Ahora no] la descarta.
  final StationPick? pick = chosen ?? last;
  if (pick == null || pick.subGenres.isEmpty) return;
  onStation?.call();
  await hub.playStation(pick.key, pick.subGenres);
}

/// Reingreso: "Estabas escuchando [Genero] — [Cancion] (mm:ss)".
class StationResumeDialog extends StatelessWidget {
  const StationResumeDialog({super.key, required this.info});
  final StationResumeInfo info;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: GatoMixTheme.bgPanel,
      title: Text(
        'Estabas escuchando ${info.title} — ${info.trackTitle} (${info.clock})',
        style: const TextStyle(color: Colors.white, fontSize: 17),
      ),
      content: const Text(
        'Sigue en la misma canción y segundo, sin repetir lo que ya sonó.',
        style: TextStyle(color: Colors.white70),
      ),
      actionsOverflowButtonSpacing: 8,
      actions: [
        TextButton(
          key: const Key('station-other'),
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Elegir otro género'),
        ),
        FilledButton.icon(
          key: const Key('station-resume'),
          style: FilledButton.styleFrom(
            backgroundColor: _vibeNeon,
            foregroundColor: Colors.black,
            minimumSize: const Size(48, 48),
          ),
          onPressed: () => Navigator.pop(context, true),
          icon: const Icon(Icons.play_arrow),
          label: const Text('Seguir escuchando donde quedó'),
        ),
      ],
    );
  }
}

class StationPick {
  const StationPick(this.key, this.subGenres);
  final String key;
  final List<String> subGenres;

  /// 3.1.67: [Ahora no]: cierra sin sonar.
  static const StationPick none = StationPick('', <String>[]);
}

/// Estaciones estilo Spotify (3.1.69: "Escoge Tus Generos Preferidos" con
/// Play al lado del titulo, visto maestro por estacion en cascada, flecha que
/// despliega o minimiza sin tocar los vistos y aviso si no hay nada marcado).
class StationPickerDialog extends StatefulWidget {
  const StationPickerDialog({
    super.key,
    required this.stations,
    this.savedChecked,
    this.initialStation,
    this.onChanged,
    this.activeStation,
    this.playing = false,
    this.onTogglePause,
  });

  final List<GenreStation> stations;

  /// 3.1.72: estacion que suena (su Play muestra ⏸) y si esta sonando.
  final String? activeStation;
  final bool playing;

  /// 3.1.72: ⏸/▶ de la estacion que suena sin cerrar el selector.
  final Future<void> Function()? onTogglePause;

  /// Sub-generos que el usuario dejo en visto la ultima vez (si hay).
  final List<String>? Function(String key)? savedChecked;

  /// 3.1.69: estacion de la ultima seleccion guardada; null la primera vez
  /// (entonces Musica del Momento abre con todo en visto).
  final String? initialStation;

  /// 3.1.67: estacion y sub-generos elegidos en cada toque (null si no hay
  /// nada para sonar); el flujo la usa si el usuario sale sin confirmar.
  final ValueChanged<StationPick?>? onChanged;

  @override
  State<StationPickerDialog> createState() => _StationPickerDialogState();
}

class _StationPickerDialogState extends State<StationPickerDialog> {
  // 3.1.69: la estacion desplegada solo cambia la vista; los vistos viven
  // en _checks y no se tocan al minimizar.
  String? _open;
  bool _empty = false;
  late bool _playing = widget.playing;
  late final StationChecks _checks = StationChecks(widget.stations)
    ..seed(
      key: widget.initialStation,
      saved: widget.initialStation == null
          ? null
          : widget.savedChecked?.call(widget.initialStation!),
    );

  void _toggleOpen(GenreStation s) {
    setState(() => _open = _open == s.key ? null : s.key);
  }

  void _change(VoidCallback f) {
    setState(() {
      f();
      if (_checks.any) _empty = false;
    });
    widget.onChanged?.call(_pick());
  }

  StationPick? _pick() {
    final MapEntry<String, List<String>>? p = _checks.pick();
    return p == null ? null : StationPick(p.key, p.value);
  }

  /// 3.1.72: Play redondo de una estacion: la que suena se pausa o
  /// reanuda aqui; otra suena ya en Shuffle con sus vistos (o su ultima
  /// sesion, o todo) y la anterior queda guardada donde iba.
  Future<void> _tapStation(GenreStation s) async {
    final Future<void> Function()? toggle = widget.onTogglePause;
    if (s.key == widget.activeStation && toggle != null) {
      await toggle();
      if (mounted) setState(() => _playing = !_playing);
      return;
    }
    final List<String> subs = stationTapSubs(s, <String>[
      for (final String g in s.subGenres)
        if (_checks.isOn(s.key, g)) g,
    ], widget.savedChecked?.call(s.key));
    if (subs.isEmpty) return;
    Navigator.pop(context, StationPick(s.key, subs));
  }

  /// Play de arriba y de abajo: suena lo marcado (o retoma su cola); sin
  /// nada en visto no cierra y avisa.
  void _play() {
    final StationPick? p = _pick();
    if (p == null) {
      setState(() => _empty = true);
      return;
    }
    Navigator.pop(context, p);
  }

  @override
  Widget build(BuildContext context) {
    final double maxH = MediaQuery.of(context).size.height * 0.62;
    return AlertDialog(
      backgroundColor: GatoMixTheme.bgPanel,
      title: Row(
        children: [
          const Flexible(
            child: Text(
              'Escoge Tus Géneros Preferidos',
              style: TextStyle(color: Colors.white, fontSize: 18),
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            key: const Key('station-play-top'),
            tooltip: 'Reproducir',
            onPressed: _play,
            style: IconButton.styleFrom(
              backgroundColor: const Color(0x33FF5722),
              side: const BorderSide(color: GatoMixTheme.fire),
              minimumSize: const Size(44, 44),
            ),
            icon: const Icon(
              Icons.play_arrow_rounded,
              color: GatoMixTheme.fire,
              size: 30,
            ),
          ),
        ],
      ),
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      content: SizedBox(
        width: 420,
        height: maxH < 460 ? maxH : 460,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                key: const ValueKey('station-list'),
                children: [
                  for (final GenreStation s in widget.stations) ...[
                    ListTile(
                      key: Key('station-${s.key}'),
                      minTileHeight: 52,
                      contentPadding: const EdgeInsets.only(left: 16, right: 4),
                      selected: s.key == _open,
                      selectedTileColor: GatoMixTheme.surfaceHover,
                      // 3.1.72: Play/Pausa dinamico (antes, icono de radio).
                      leading: StationPlayButton(
                        key: Key('station-play-${s.key}'),
                        playing: s.key == widget.activeStation && _playing,
                        label: s.title,
                        onTap: () => _tapStation(s),
                      ),
                      title: Text(
                        s.title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      subtitle: Text(
                        '${s.count} canciones · ${s.subGenres.length} '
                        '${s.subGenres.length == 1 ? 'género' : 'géneros'}',
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          StationMasterCheck(
                            key: Key('station-master-${s.key}'),
                            on: _checks.master(s.key),
                            label: s.title,
                            onTap: () =>
                                _change(() => _checks.toggleMaster(s.key)),
                          ),
                          IconButton(
                            key: Key('station-chevron-${s.key}'),
                            tooltip: s.key == _open ? 'Minimizar' : 'Desplegar',
                            onPressed: () => _toggleOpen(s),
                            icon: Icon(
                              s.key == _open
                                  ? Icons.expand_less
                                  : Icons.expand_more,
                              color: Colors.white54,
                            ),
                          ),
                        ],
                      ),
                      onTap: () => _toggleOpen(s),
                    ),
                    if (s.key == _open)
                      for (final String g in s.subGenres)
                        StationSubTile(
                          key: Key('station-sub-$g'),
                          label: g,
                          indent: 40,
                          fontSize: 13,
                          on: _checks.isOn(s.key, g),
                          onTap: () =>
                              _change(() => _checks.toggleSub(s.key, g)),
                        ),
                  ],
                ],
              ),
            ),
            if (_empty) const GenreEmptyNotice(key: Key('station-empty-msg')),
          ],
        ),
      ),
      actionsOverflowButtonSpacing: 8,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, StationPick.none),
          child: const Text('Ahora no'),
        ),
        FilledButton.icon(
          key: const Key('station-play'),
          style: FilledButton.styleFrom(
            backgroundColor: _vibeNeon,
            foregroundColor: Colors.black,
            minimumSize: const Size(48, 48),
          ),
          onPressed: _play,
          icon: const Icon(Icons.play_arrow),
          label: const Text('Reproducir Estación en Shuffle'),
        ),
      ],
    );
  }
}

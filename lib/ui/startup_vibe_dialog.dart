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
      onChanged: (StationPick? p) => last = p,
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

/// Estaciones estilo Spotify: al tocar una se despliegan sus sub-generos
/// marcados con visto por defecto y el boton de reproducir en Shuffle.
class StationPickerDialog extends StatefulWidget {
  const StationPickerDialog({
    super.key,
    required this.stations,
    this.savedChecked,
    this.onChanged,
  });

  final List<GenreStation> stations;

  /// Sub-generos que el usuario dejo en visto la ultima vez (si hay).
  final List<String>? Function(String key)? savedChecked;

  /// 3.1.67: estacion y sub-generos elegidos en cada toque (null si no hay
  /// nada para sonar); el flujo la usa si el usuario sale sin confirmar.
  final ValueChanged<StationPick?>? onChanged;

  @override
  State<StationPickerDialog> createState() => _StationPickerDialogState();
}

class _StationPickerDialogState extends State<StationPickerDialog> {
  String? _open;
  final Set<String> _checked = <String>{};

  void _select(GenreStation s) {
    final List<String>? saved = widget.savedChecked?.call(s.key);
    final Set<String> keep = <String>{
      for (final String g in saved ?? const <String>[])
        if (s.subGenres.contains(g)) g,
    };
    setState(() {
      _open = s.key;
      _checked
        ..clear()
        ..addAll(keep.isEmpty ? s.subGenres : keep);
    });
    _notify();
  }

  void _notify() {
    final ValueChanged<StationPick?>? cb = widget.onChanged;
    if (cb == null) return;
    for (final GenreStation s in widget.stations) {
      if (s.key != _open) continue;
      final List<String> subs = <String>[
        for (final String g in s.subGenres)
          if (_checked.contains(g)) g,
      ];
      cb(subs.isEmpty ? null : StationPick(s.key, subs));
      return;
    }
    cb(null);
  }

  @override
  Widget build(BuildContext context) {
    final double maxH = MediaQuery.of(context).size.height * 0.62;
    GenreStation? open;
    for (final GenreStation s in widget.stations) {
      if (s.key == _open) open = s;
    }
    return AlertDialog(
      backgroundColor: GatoMixTheme.bgPanel,
      title: const Text(
        '¿Qué estación suena hoy?',
        style: TextStyle(color: Colors.white, fontSize: 18),
      ),
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      content: SizedBox(
        width: 420,
        height: maxH < 460 ? maxH : 460,
        child: ListView(
          key: const ValueKey('station-list'),
          children: [
            for (final GenreStation s in widget.stations) ...[
              ListTile(
                key: Key('station-${s.key}'),
                minTileHeight: 52,
                selected: s.key == _open,
                selectedTileColor: GatoMixTheme.surfaceHover,
                leading: const Icon(Icons.radio, color: _vibeNeon),
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
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                trailing: Icon(
                  s.key == _open ? Icons.expand_less : Icons.expand_more,
                  color: Colors.white54,
                ),
                onTap: () => _select(s),
              ),
              if (s.key == _open)
                for (final String g in s.subGenres)
                  StationSubTile(
                    key: Key('station-sub-$g'),
                    label: g,
                    indent: 40,
                    fontSize: 13,
                    on: _checked.contains(g),
                    onTap: () {
                      setState(() {
                        if (!_checked.remove(g)) _checked.add(g);
                      });
                      _notify();
                    },
                  ),
            ],
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
          onPressed: open == null || _checked.isEmpty
              ? null
              : () => Navigator.pop(
                  context,
                  StationPick(open!.key, <String>[
                    for (final String g in open.subGenres)
                      if (_checked.contains(g)) g,
                  ]),
                ),
          icon: const Icon(Icons.play_arrow),
          label: const Text('Reproducir Estación en Shuffle'),
        ),
      ],
    );
  }
}

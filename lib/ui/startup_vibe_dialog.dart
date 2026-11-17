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
  final List<VibeGenre> genres = await (scan ?? scanVibeGenres)(
    root ?? vibeMusicRoot(),
  );
  if (genres.isEmpty || !context.mounted) return;
  final List<GenreStation> stations = groupStations(<MapEntry<String, int>>[
    for (final VibeGenre g in genres) MapEntry<String, int>(g.name, g.count),
  ]);
  final StationPick? pick = await showDialog<StationPick>(
    context: context,
    builder: (_) => StationPickerDialog(
      stations: stations,
      savedChecked: (String k) => hub.stationSession(k)?.subGenresChecked,
    ),
  );
  if (pick == null) return;
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
}

/// Estaciones estilo Spotify: al tocar una se despliegan sus sub-generos
/// marcados con visto por defecto y el boton de reproducir en Shuffle.
class StationPickerDialog extends StatefulWidget {
  const StationPickerDialog({
    super.key,
    required this.stations,
    this.savedChecked,
  });

  final List<GenreStation> stations;

  /// Sub-generos que el usuario dejo en visto la ultima vez (si hay).
  final List<String>? Function(String key)? savedChecked;

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
                    onTap: () => setState(() {
                      if (!_checked.remove(g)) _checked.add(g);
                    }),
                  ),
            ],
          ],
        ),
      ),
      actionsOverflowButtonSpacing: 8,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
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

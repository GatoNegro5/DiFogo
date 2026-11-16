import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/automix_provider.dart';
import '../providers/session_provider.dart';
import '../providers/theme_provider.dart';

/// Solo pruebas: no abrir el flujo de inicio.
@visibleForTesting
bool debugSkipStartupVibe = false;
bool _vibeShown = false;

const Color _vibeNeon = GatoMixTheme.syncActive;

/// 3.1.52: al arrancar pregunta si se mantiene el genero anterior o se elige
/// uno de la carpeta unica; aplica el candado a la cola de Automix.
Future<void> showStartupVibeFlow(
  BuildContext context,
  WidgetRef ref, {
  String? root,
  Future<List<VibeGenre>> Function(String root)? scan,
}) async {
  if (debugSkipStartupVibe || _vibeShown) return;
  _vibeShown = true;
  final VibeState s = ref.read(vibeProvider);
  final String r = root ?? vibeMusicRoot();
  final String? last = s.lastVibe;
  if (s.sessionActive && last != null) {
    final bool? keep = await showDialog<bool>(
      context: context,
      builder: (_) => VibeKeepDialog(genre: last),
    );
    if (keep == true) {
      await _apply(ref, last);
      return;
    }
    if (keep == null) return;
  }
  if (!context.mounted) return;
  final List<VibeGenre> genres = await (scan ?? scanVibeGenres)(r);
  if (genres.isEmpty || !context.mounted) return;
  final String? pick = await showDialog<String>(
    context: context,
    builder: (_) => VibePickerDialog(genres: genres),
  );
  if (pick == null) return;
  await _apply(ref, pick == VibePickerDialog.all ? null : pick);
}

Future<void> _apply(WidgetRef ref, String? genre) async {
  await ref.read(vibeProvider.notifier).choose(genre);
  try {
    ref.read(automixQueueProvider.notifier).applyVibe();
  } catch (_) {}
}

class VibeKeepDialog extends StatelessWidget {
  const VibeKeepDialog({super.key, required this.genre});
  final String genre;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF121212),
      title: Text(
        '¿Mantenemos el género $genre?',
        style: const TextStyle(color: Colors.white, fontSize: 18),
      ),
      content: const Text(
        'Solo sonarán pistas de esa carpeta durante la sesión.',
        style: TextStyle(color: Colors.white70),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('No, elegir otro'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: _vibeNeon,
            foregroundColor: Colors.black,
            minimumSize: const Size(48, 48),
          ),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Sí, mantener'),
        ),
      ],
    );
  }
}

class VibePickerDialog extends StatelessWidget {
  const VibePickerDialog({super.key, required this.genres});
  final List<VibeGenre> genres;

  /// Valor devuelto por la opcion sin candado.
  static const String all = '\u0000todo';

  @override
  Widget build(BuildContext context) {
    final double maxH = MediaQuery.of(context).size.height * 0.6;
    return AlertDialog(
      backgroundColor: const Color(0xFF121212),
      title: const Text(
        '¿Qué género suena hoy?',
        style: TextStyle(color: Colors.white, fontSize: 18),
      ),
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      content: SizedBox(
        width: 360,
        height: maxH < 420 ? maxH : 420,
        child: ListView(
          key: const ValueKey('vibe-genres'),
          children: [
            for (final VibeGenre g in genres)
              ListTile(
                minTileHeight: 48,
                leading: const Icon(Icons.folder, color: _vibeNeon),
                title: Text(
                  g.name,
                  style: const TextStyle(color: Colors.white),
                ),
                trailing: Text(
                  '${g.count} canciones',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                onTap: () => Navigator.pop(context, g.name),
              ),
            ListTile(
              minTileHeight: 48,
              leading: const Icon(Icons.all_inclusive, color: Colors.white54),
              title: const Text(
                'Todo (sin filtro)',
                style: TextStyle(color: Colors.white70),
              ),
              onTap: () => Navigator.pop(context, all),
            ),
          ],
        ),
      ),
    );
  }
}

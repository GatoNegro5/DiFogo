import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import '../core/genre_stations.dart';
import '../providers/curator_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/vibe_hub_provider.dart';
import '../services/smart_discovery_service.dart';

/// 3.1.53 Curator Inbox: tarjetas de los temas pendientes con vista previa.
/// 3.1.68: "Acepta Nueva Musica": temas agrupados por estacion y
/// sub-genero, Aceptar / Aceptar todo este genero / Descartar, y busqueda
/// sobre los generos en visto cuando la bandeja esta vacia.

const Color _curFire = GatoMixTheme.fire;
const Color _curBg = Color(0xFF121212);
const Color _curCard = Color(0xFF1C1C1C);

/// Texto del boton protagonista (con el conteo de pendientes si hay).
// 3.1.84 Consumer Clean Mode: badge compacto junto a "+ Agregar".
// 3.1.85: sin emoji; el destello es un Icon vectorial en el boton.
String acceptNewMusicLabel(int pending) =>
    pending > 0 ? 'Nuevas ($pending)' : 'Nuevas';

Future<void> showCuratorInbox(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const CuratorInboxDialog(),
);

/// 3.1.68: boton pildora "Acepta Nueva Musica" con el conteo de pendientes
/// (antes: icono chico con numerito rojo). Barra de Live DJ y cabecera del
/// panel de estaciones.
class CuratorInboxButton extends ConsumerWidget {
  const CuratorInboxButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final int n = ref.watch(curatorProvider.select((s) => s.pending.length));
    return Tooltip(
      message: 'Revisa y acepta los temas nuevos del curador',
      child: OutlinedButton(
        key: const ValueKey<String>('curator-inbox-button'),
        onPressed: () => showCuratorInbox(context),
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          backgroundColor: _curFire.withValues(alpha: n > 0 ? 0.22 : 0.10),
          side: BorderSide(color: _curFire, width: n > 0 ? 2 : 1.2),
          shape: const StadiumBorder(),
          minimumSize: const Size(0, 26),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.auto_awesome_rounded, size: 14),
              const SizedBox(width: 3),
              Text(
                acceptNewMusicLabel(n),
                maxLines: 1,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Grupo de la caja: estacion + sub-genero (null = "Otros").
class CuratorGroup {
  CuratorGroup(this.stationId, this.subGenreId);
  final String? stationId;
  final String? subGenreId;
  final List<CuratorEntry> items = <CuratorEntry>[];

  String get id => '${stationId ?? 'otros'}-${subGenreId ?? 'otros'}';

  String get header {
    final String n =
        '${items.length} '
        '${items.length == 1 ? 'canción' : 'canciones'}';
    if (stationId == null) return 'OTROS ($n)';
    return '${stationTitleOf(stationId!).toUpperCase()} • $subGenreId ($n)';
  }
}

/// Pendientes agrupados en el orden del catalogo de estaciones.
List<CuratorGroup> groupCuratorEntries(List<CuratorEntry> items) {
  final Map<String, CuratorGroup> by = <String, CuratorGroup>{};
  for (final CuratorEntry e in items) {
    final MapEntry<String, String>? m = stationSubOfCurator(
      stationId: e.stationId,
      subGenreId: e.subGenreId,
      genre: e.genre,
      title: e.title,
    );
    final CuratorGroup g = by.putIfAbsent(
      '${m?.key}|${m?.value}',
      () => CuratorGroup(m?.key, m?.value),
    );
    g.items.add(e);
  }
  int rank(CuratorGroup g) {
    for (int i = 0; i < kUniversalStations.length; i++) {
      final UniversalStation u = kUniversalStations[i];
      if (u.key != g.stationId) continue;
      final int j = u.subs.indexWhere(
        (StationSub s) => s.label == g.subGenreId,
      );
      return i * 100 + (j < 0 ? 99 : j);
    }
    return 1 << 20;
  }

  return by.values.toList()
    ..sort((CuratorGroup a, CuratorGroup b) => rank(a).compareTo(rank(b)));
}

String _clock(int ms) {
  final int t = ms ~/ 1000;
  return '${t ~/ 60}:${(t % 60).toString().padLeft(2, '0')}';
}

class CuratorInboxDialog extends ConsumerStatefulWidget {
  const CuratorInboxDialog({super.key});

  @override
  ConsumerState<CuratorInboxDialog> createState() => _CuratorInboxDialogState();
}

class _CuratorInboxDialogState extends ConsumerState<CuratorInboxDialog> {
  Player? _player;
  String? _playing;
  bool _searching = false;

  @override
  void dispose() {
    unawaited(_player?.dispose());
    super.dispose();
  }

  Future<void> _togglePreview(CuratorEntry e) async {
    try {
      final Player p = _player ??= Player();
      if (_playing == e.id) {
        await p.stop();
        if (mounted) setState(() => _playing = null);
        return;
      }
      await p.open(Media(e.file));
      if (mounted) setState(() => _playing = e.id);
    } catch (err) {
      debugPrint('[CURATOR] vista previa: $err');
    }
  }

  Future<void> _stopIf(String id) async {
    if (_playing != id) return;
    try {
      await _player?.stop();
    } catch (_) {}
    if (mounted) setState(() => _playing = null);
  }

  /// Aceptar: mismo camino del curador (mueve a la carpeta canonica e
  /// indexa) y el tema entra a la cola de su estacion.
  Future<int> _accept(CuratorGroup g, List<CuratorEntry> items) async {
    int n = 0;
    String? last;
    for (final CuratorEntry e in items) {
      await _stopIf(e.id);
      final String? dst = await ref.read(curatorProvider.notifier).accept(e.id);
      if (dst == null) continue;
      n++;
      last = dst;
      final String? st = g.stationId;
      final String? sub = g.subGenreId;
      if (st != null && sub != null) {
        ref.read(vibeHubProvider.notifier).injectAccepted(st, sub, dst);
      }
    }
    if (mounted && last != null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            n == 1
                ? 'Agregado: ${last.split(Platform.pathSeparator).last}'
                : '$n temas agregados',
          ),
        ),
      );
    }
    return n;
  }

  Future<void> _searchActive() async {
    if (_searching) return;
    setState(() => _searching = true);
    try {
      await ref.read(vibeHubProvider.notifier).searchActiveGenres();
    } catch (err) {
      debugPrint('[CURATOR] buscar generos activos: $err');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final CuratorState s = ref.watch(curatorProvider);
    final List<CuratorEntry> items = s.pending;
    final List<CuratorGroup> groups = groupCuratorEntries(items);
    final bool busy = s.busy || _searching;
    return Dialog(
      backgroundColor: _curBg,
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: _curFire, width: 1),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                acceptNewMusicLabel(items.length),
                key: const ValueKey<String>('curator-title'),
                style: const TextStyle(
                  color: _curFire,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              const Text(
                'Temas sugeridos por el curador, agrupados por estación y '
                'género. Lo que aceptes se guarda en su carpeta y entra a la '
                'cola de su estación.',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 8),
              if (s.message != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    s.message!,
                    style: const TextStyle(color: Colors.orangeAccent),
                  ),
                ),
              Flexible(
                child: items.isEmpty
                    ? _empty(busy)
                    : ListView(
                        key: const ValueKey<String>('curator-list'),
                        shrinkWrap: true,
                        children: <Widget>[
                          for (final CuratorGroup g in groups) ...<Widget>[
                            _groupHeader(g),
                            for (final CuratorEntry e in g.items) _card(g, e),
                            const SizedBox(height: 8),
                          ],
                        ],
                      ),
              ),
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  if (items.isNotEmpty) ...<Widget>[
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const ValueKey<String>('curator-more'),
                        onPressed: busy
                            ? null
                            : () => unawaited(_searchActive()),
                        icon: busy
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.refresh),
                        label: const Text(
                          'Buscar más',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _curFire,
                          minimumSize: const Size(0, 48),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: TextButton(
                      key: const ValueKey<String>('curator-later'),
                      onPressed: () => Navigator.of(context).pop(),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white70,
                        minimumSize: const Size(0, 48),
                      ),
                      child: const Text(
                        'Ver después',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _empty(bool busy) {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text(
              'No hay temas pendientes.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54),
            ),
            const SizedBox(height: 14),
            FilledButton(
              key: const ValueKey<String>('curator-search-active'),
              onPressed: busy ? null : () => unawaited(_searchActive()),
              style: FilledButton.styleFrom(
                backgroundColor: _curFire,
                foregroundColor: Colors.black,
                minimumSize: const Size(0, 48),
                shape: const StadiumBorder(),
              ),
              child: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        '🔍 Buscar Nueva Música para mis Géneros Activos',
                        maxLines: 1,
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _groupHeader(CuratorGroup g) {
    return Padding(
      key: ValueKey<String>('curator-group-${g.id}'),
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.radio, color: _curFire, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  g.header,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: ValueKey<String>('curator-accept-all-${g.id}'),
              onPressed: () => unawaited(_accept(g, List.of(g.items))),
              icon: const Icon(Icons.done_all, size: 16),
              label: const Text('Aceptar todo este género'),
              style: TextButton.styleFrom(
                foregroundColor: _curFire,
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
          const Divider(height: 1, color: Colors.white10),
        ],
      ),
    );
  }

  Widget _card(CuratorGroup g, CuratorEntry e) {
    final bool on = _playing == e.id;
    final int? ms = e.durationMs;
    return Card(
      key: ValueKey<String>('curator-card-${e.id}'),
      color: _curCard,
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                IconButton(
                  tooltip: on ? 'Detener' : 'Escuchar',
                  icon: Icon(
                    on ? Icons.stop_circle : Icons.play_circle,
                    color: Colors.cyanAccent,
                  ),
                  onPressed: () => unawaited(_togglePreview(e)),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        e.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white),
                      ),
                      Text(
                        ms == null ? e.genre : '${_clock(ms)} · ${e.genre}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 6,
              runSpacing: 4,
              children: <Widget>[
                _CuratorTextButton(
                  key: ValueKey<String>('curator-accept-${e.id}'),
                  label: '✓ Aceptar',
                  tooltip: 'Guardar en ${g.header}',
                  color: _curFire,
                  onPressed: () => unawaited(_accept(g, <CuratorEntry>[e])),
                ),
                _CuratorTextButton(
                  key: ValueKey<String>('curator-reject-${e.id}'),
                  label: '✕ Descartar',
                  tooltip: 'Descartar',
                  color: Colors.white70,
                  onPressed: () async {
                    await _stopIf(e.id);
                    ref.read(curatorProvider.notifier).reject(e.id);
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 3.1.55: boton de texto compacto de la tarjeta (Aceptar / Descartar).
class _CuratorTextButton extends StatelessWidget {
  const _CuratorTextButton({
    super.key,
    required this.label,
    required this.tooltip,
    required this.color,
    required this.onPressed,
  });

  final String label;
  final String tooltip;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: color,
          side: BorderSide(color: color.withValues(alpha: 0.7)),
          minimumSize: const Size(0, 34),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(label, style: const TextStyle(fontSize: 12)),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/genre_stations.dart';
import '../providers/theme_provider.dart';
import '../providers/vibe_hub_provider.dart';
import 'curator_inbox_dialog.dart';

const Color _hubNeon = GatoMixTheme.syncActive;

/// 3.1.54 Super-Vibe Hub (3.1.62: estaciones con sub-generos en visto; 3.1.64:
/// 7 estaciones universales y descartado con X). En escritorio
/// ocupa la columna izquierda de Live DJ; en movil se abre como hoja.
class VibeHubView extends ConsumerStatefulWidget {
  const VibeHubView({super.key, this.onPlayed});

  /// Movil: cierra la hoja despues de cargar la cola.
  final VoidCallback? onPlayed;

  @override
  ConsumerState<VibeHubView> createState() => _VibeHubViewState();
}

class _VibeHubViewState extends ConsumerState<VibeHubView> {
  // 3.1.62: estacion desplegada y sus sub-generos en visto.
  String? _open;
  final Set<String> _checked = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(vibeHubProvider.notifier).refresh();
    });
  }

  void _select(GenreStation st) {
    if (_open == st.key) {
      setState(() => _open = null);
      return;
    }
    final List<String>? saved = ref
        .read(vibeHubProvider.notifier)
        .stationSession(st.key)
        ?.subGenresChecked;
    final Set<String> keep = <String>{
      for (final String g in saved ?? const <String>[])
        if (st.subGenres.contains(g)) g,
    };
    setState(() {
      _open = st.key;
      _checked
        ..clear()
        ..addAll(keep.isEmpty ? st.subGenres : keep);
    });
  }

  @override
  Widget build(BuildContext context) {
    final VibeHubState s = ref.watch(vibeHubProvider);
    final VibeHubNotifier n = ref.read(vibeHubProvider.notifier);
    GenreStation? open;
    for (final GenreStation st in s.stations) {
      if (st.key == _open) open = st;
    }
    final List<String> picked = <String>[
      for (final String g in open?.subGenres ?? const <String>[])
        if (_checked.contains(g)) g,
    ];
    return Material(
      color: GatoMixTheme.bgPanel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 6, 6),
            child: Row(
              children: <Widget>[
                const Icon(Icons.auto_awesome, color: _hubNeon, size: 16),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    'SMART VIBE',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _hubNeon,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
                // 3.1.62: columna de escritorio: conmutador y curador aqui,
                // porque el Cartridge se oculta mientras la cola esta vacia.
                if (widget.onPlayed == null) ...const <Widget>[
                  LiveDjViewToggleButton(mobile: false),
                  CuratorInboxButton(),
                ],
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white10),
          Expanded(
            child: s.loading && s.stations.isEmpty
                ? const Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : s.stations.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: Text(
                        'Sin estaciones en la carpeta de musica',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white38, fontSize: 11),
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    children: <Widget>[
                      for (final GenreStation st in s.stations) ...<Widget>[
                        _StationCard(
                          station: st,
                          open: st.key == _open,
                          active: st.key == s.activeStation,
                          onTap: () => _select(st),
                        ),
                        if (st.key == _open)
                          for (final String g in st.subGenres)
                            StationSubTile(
                              key: Key('vibe-hub-cat-$g'),
                              label: g,
                              on: _checked.contains(g),
                              onTap: () => setState(() {
                                if (!_checked.remove(g)) _checked.add(g);
                              }),
                            ),
                      ],
                    ],
                  ),
          ),
          if (s.message != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
              child: Text(
                s.message!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white54, fontSize: 10),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: SizedBox(
              height: 48,
              child: ElevatedButton.icon(
                key: const Key('vibe-hub-play'),
                onPressed: open == null || picked.isEmpty || s.busy
                    ? null
                    : () async {
                        final int got = await n.playStation(open!.key, picked);
                        if (got > 0) widget.onPlayed?.call();
                      },
                icon: s.busy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow, size: 20),
                // Ventana angosta: se achica en vez de recortarse.
                label: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    open == null
                        ? 'Elige una estación'
                        : 'Reproducir Estación en Shuffle',
                    maxLines: 1,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: open == null ? Colors.white10 : _hubNeon,
                  foregroundColor: open == null ? _hubNeon : Colors.black,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Tarjeta de estacion (macro-genero o carpeta suelta).
class _StationCard extends StatelessWidget {
  const _StationCard({
    required this.station,
    required this.open,
    required this.active,
    required this.onTap,
  });

  final GenreStation station;
  final bool open;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final int subs = station.subGenres.length;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      child: Material(
        color: open ? GatoMixTheme.surfaceHover : Colors.white10,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color: active ? GatoMixTheme.fire : Colors.transparent,
          ),
        ),
        child: InkWell(
          key: Key('vibe-hub-st-${station.key}'),
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: <Widget>[
                  Icon(
                    active ? Icons.graphic_eq : Icons.radio,
                    color: _hubNeon,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          station.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          '${station.count} canciones · $subs '
                          '${subs == 1 ? 'género' : 'géneros'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    open ? Icons.expand_less : Icons.expand_more,
                    color: Colors.white54,
                    size: 18,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Movil: el Hub en una hoja inferior.
Future<void> showVibeHubSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: GatoMixTheme.bgPanel,
    builder: (BuildContext ctx) => SafeArea(
      child: SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.7,
        child: VibeHubView(onPlayed: () => Navigator.of(ctx).maybePop()),
      ),
    ),
  );
}

/// 3.1.54: conmutador del header de Live DJ. Escritorio: alterna
/// isClassicFolderView (Hub Smart Vibe <-> arbol de carpetas). Movil (sin
/// columna izquierda): abre el Hub en una hoja.
class LiveDjViewToggleButton extends ConsumerWidget {
  const LiveDjViewToggleButton({super.key, required this.mobile});

  final bool mobile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool classic = ref.watch(liveDjClassicFolderViewProvider);
    final bool showSmartIcon = mobile || classic;
    return IconButton(
      key: const Key('livedj-view-toggle'),
      icon: Icon(
        showSmartIcon ? Icons.auto_awesome : Icons.account_tree,
        color: showSmartIcon ? _hubNeon : Colors.white70,
        size: 18,
      ),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 28, height: 28),
      visualDensity: VisualDensity.compact,
      tooltip: mobile
          ? 'Smart Vibe'
          : (classic ? 'Modo Smart Vibe' : 'Modo Clasico'),
      onPressed: () {
        if (mobile) {
          showVibeHubSheet(context);
          return;
        }
        final StateController<bool> c = ref.read(
          liveDjClassicFolderViewProvider.notifier,
        );
        c.state = !c.state;
      },
    );
  }
}

/// 3.1.64: sub-genero en visto (check fuego) o descartado (X sobre recuadro
/// gris/rojo tenue). Tocar alterna entre los dos estados.
class StationSubTile extends StatelessWidget {
  const StationSubTile({
    super.key,
    required this.label,
    required this.on,
    required this.onTap,
    this.indent = 22,
    this.fontSize = 12,
  });

  final String label;
  final bool on;
  final VoidCallback onTap;
  final double indent;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      checked: on,
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Padding(
            padding: EdgeInsets.only(left: indent, right: 8),
            child: Row(
              children: <Widget>[
                if (on)
                  const Icon(
                    Icons.check_box,
                    color: GatoMixTheme.fire,
                    size: 22,
                  )
                else
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: const Color(0x33FF5252),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: const Icon(
                      Icons.close,
                      color: Color(0xFFFF8A80),
                      size: 16,
                    ),
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: on ? Colors.white : Colors.white38,
                      fontSize: fontSize,
                      decoration: on ? null : TextDecoration.lineThrough,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

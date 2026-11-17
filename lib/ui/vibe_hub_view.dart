import 'dart:async';

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
  // 3.1.62: estacion desplegada (3.1.69: solo la vista; los vistos de cada
  // estacion y su visto maestro viven en _checks).
  String? _open;
  StationChecks? _checks;
  bool _empty = false;

  // 3.1.67: movil: cerrar la hoja tras tocar los vistos la hace sonar.
  VibeHubNotifier? _hub;
  bool _touched = false;
  bool _played = false;

  @override
  void dispose() {
    final VibeHubNotifier? hub = _hub;
    final MapEntry<String, List<String>>? p = _checks?.pick();
    if (widget.onPlayed != null &&
        !_played &&
        _touched &&
        hub != null &&
        p != null) {
      unawaited(hub.playStation(p.key, p.value));
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(vibeHubProvider.notifier).refresh();
    });
  }

  void _select(GenreStation st) {
    setState(() => _open = _open == st.key ? null : st.key);
  }

  /// 3.1.69: la estacion que suena (o la guardada) con sus vistos; la
  /// primera vez, Musica del Momento con todo en visto.
  StationChecks _checksFor(VibeHubState s, VibeHubNotifier n) {
    final StationChecks? c = _checks;
    if (c != null) return c..updateStations(s.stations);
    final String? key = n.savedActiveStation();
    final StationChecks fresh = StationChecks(s.stations)
      ..seed(
        key: key,
        saved: key == null ? null : n.stationSession(key)?.subGenresChecked,
      );
    if (s.stations.isNotEmpty) _checks = fresh;
    return fresh;
  }

  void _change(VoidCallback f) {
    setState(() {
      f();
      _touched = true;
      if (_checks?.any ?? false) _empty = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final VibeHubState s = ref.watch(vibeHubProvider);
    final VibeHubNotifier n = ref.read(vibeHubProvider.notifier);
    final StationChecks checks = _checksFor(s, n);
    final MapEntry<String, List<String>>? pick = checks.pick();
    _hub = n;
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
                // 3.1.68: titulo claro para cualquier usuario; en columnas
                // angostas se achica en vez de cortarse.
                const Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'ESTACIONES & GÉNEROS',
                      maxLines: 1,
                      style: TextStyle(
                        color: _hubNeon,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                ),
                // 3.1.62: columna de escritorio: conmutador aqui, porque el
                // Cartridge se oculta mientras la cola esta vacia.
                if (widget.onPlayed == null)
                  const LiveDjViewToggleButton(mobile: false),
              ],
            ),
          ),
          // 3.1.68: boton protagonista "Acepta Nueva Musica" arriba de las
          // estaciones (escritorio y hoja movil).
          const Padding(
            padding: EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: CuratorInboxButton(),
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
                          master: checks.master(st.key),
                          onTap: () => _select(st),
                          onMaster: () =>
                              _change(() => checks.toggleMaster(st.key)),
                        ),
                        if (st.key == _open)
                          for (final String g in st.subGenres)
                            StationSubTile(
                              key: Key('vibe-hub-cat-$g'),
                              label: g,
                              on: checks.isOn(st.key, g),
                              onTap: () =>
                                  _change(() => checks.toggleSub(st.key, g)),
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
          if (_empty)
            const Padding(
              padding: EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: GenreEmptyNotice(key: Key('vibe-hub-empty-msg')),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: SizedBox(
              height: 48,
              child: ElevatedButton.icon(
                key: const Key('vibe-hub-play'),
                onPressed: s.busy
                    ? null
                    : () async {
                        // 3.1.69: sin nada en visto no suena y avisa.
                        if (pick == null) {
                          setState(() => _empty = true);
                          return;
                        }
                        _played = true;
                        final int got = await n.playStation(
                          pick.key,
                          pick.value,
                        );
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
                  child: const Text(
                    'Reproducir Estación en Shuffle',
                    maxLines: 1,
                    style: TextStyle(fontSize: 12),
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: pick == null ? Colors.white10 : _hubNeon,
                  foregroundColor: pick == null ? _hubNeon : Colors.black,
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
    required this.master,
    required this.onTap,
    required this.onMaster,
  });

  final GenreStation station;
  final bool open;
  final bool active;
  final bool master;
  final VoidCallback onTap;
  final VoidCallback onMaster;

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
                  // 3.1.69: visto maestro junto al chevron; tocar la tarjeta
                  // o el chevron despliega o minimiza.
                  StationMasterCheck(
                    key: Key('vibe-hub-master-${station.key}'),
                    on: master,
                    label: station.title,
                    onTap: onMaster,
                  ),
                  Icon(
                    open ? Icons.expand_less : Icons.expand_more,
                    key: Key('vibe-hub-chevron-${station.key}'),
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

/// 3.1.69: aviso cuando se da Play sin ningun genero en visto.
const String kGenreEmptyMessage = 'Tiene que escoger su Género Favorito...';

class GenreEmptyNotice extends StatelessWidget {
  const GenreEmptyNotice({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0x33FF5722),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: GatoMixTheme.fire),
      ),
      child: const Row(
        children: <Widget>[
          Icon(Icons.info_outline, color: GatoMixTheme.fire, size: 18),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              kGenreEmptyMessage,
              style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 3.1.69: visto maestro de una estacion: check fuego si tiene sub-generos
/// en visto, X si esta deshabilitada. Area de toque de 40 px.
class StationMasterCheck extends StatelessWidget {
  const StationMasterCheck({
    super.key,
    required this.on,
    required this.onTap,
    this.label = '',
  });

  final bool on;
  final VoidCallback onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      checked: on,
      button: true,
      label: label,
      child: InkResponse(
        onTap: onTap,
        radius: 22,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Center(
            child: on
                ? const Icon(
                    Icons.check_box,
                    color: GatoMixTheme.fire,
                    size: 24,
                  )
                : Container(
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
          ),
        ),
      ),
    );
  }
}

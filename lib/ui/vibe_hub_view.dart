import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/session_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/vibe_hub_provider.dart';

const Color _hubNeon = GatoMixTheme.syncActive;

/// 3.1.54 Super-Vibe Hub: categorias maestras con casillas. En escritorio
/// ocupa la columna izquierda de Live DJ; en movil se abre como hoja.
class VibeHubView extends ConsumerStatefulWidget {
  const VibeHubView({super.key, this.onPlayed});

  /// Movil: cierra la hoja despues de cargar la cola.
  final VoidCallback? onPlayed;

  @override
  ConsumerState<VibeHubView> createState() => _VibeHubViewState();
}

class _VibeHubViewState extends ConsumerState<VibeHubView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(vibeHubProvider.notifier).refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final VibeHubState s = ref.watch(vibeHubProvider);
    final VibeHubNotifier n = ref.read(vibeHubProvider.notifier);
    final bool all = s.genres.isNotEmpty && s.checked.length >= s.genres.length;
    return Material(
      color: GatoMixTheme.bgPanel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 4, 4),
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
                TextButton(
                  key: const Key('vibe-hub-all'),
                  onPressed: s.genres.isEmpty ? null : () => n.setAll(!all),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white70,
                    minimumSize: const Size(0, 28),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                  ),
                  child: Text(
                    all ? 'Ninguno' : 'Todo',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white10),
          Expanded(
            child: s.loading && s.genres.isEmpty
                ? const Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : s.genres.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: Text(
                        'Sin categorias en la carpeta de musica',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white38, fontSize: 11),
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: s.genres.length,
                    itemBuilder: (BuildContext context, int i) {
                      final VibeGenre g = s.genres[i];
                      final bool on = s.checked.any(
                        (String c) => c.toLowerCase() == g.name.toLowerCase(),
                      );
                      return CheckboxListTile(
                        key: Key('vibe-hub-cat-${g.name}'),
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        controlAffinity: ListTileControlAffinity.leading,
                        activeColor: _hubNeon,
                        checkColor: Colors.black,
                        value: on,
                        onChanged: (_) => n.toggle(
                          s.checked.firstWhere(
                            (String c) =>
                                c.toLowerCase() == g.name.toLowerCase(),
                            orElse: () => g.name,
                          ),
                        ),
                        title: Text(
                          g.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: on ? Colors.white : Colors.white70,
                            fontSize: 12,
                            fontWeight: on
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                        secondary: Text(
                          '${g.count}',
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 10,
                          ),
                        ),
                      );
                    },
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
              height: 40,
              child: ElevatedButton.icon(
                key: const Key('vibe-hub-play'),
                onPressed: s.checked.isEmpty || s.busy
                    ? null
                    : () async {
                        final int got = await n.play();
                        if (got > 0) widget.onPlayed?.call();
                      },
                icon: s.busy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.shuffle, size: 16),
                label: Text(
                  s.checked.isEmpty
                      ? 'Marca una categoria'
                      : 'Mezclar (${s.checked.length})',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white10,
                  foregroundColor: _hubNeon,
                ),
              ),
            ),
          ),
        ],
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

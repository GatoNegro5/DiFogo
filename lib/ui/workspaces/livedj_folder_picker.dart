import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/discovery_dedup_controller.dart' show listLibraryAudioAsync;
import '../../core/folder_cards.dart';
import '../../core/audio_path.dart';
import '../../providers/dj_ui_provider.dart';
import '../../providers/livedj_provider.dart';
import '../../providers/theme_provider.dart';
import '../../providers/vibe_hub_provider.dart';
import '../mobile/music_picker_screen.dart' show gatomixMusicRoot;

/// Carpetas marcadas para "Poner set".
final liveDjPickedFoldersProvider = StateProvider<Set<String>>((ref) => {});

final liveDjFolderCardsProvider = FutureProvider<List<FolderCardInfo>>((
  ref,
) async {
  return loadRegenialFolderCards(musicRoot: gatomixMusicRoot());
});

/// 3.2.38: cards de ReGenial (conteo y energia media), multi-seleccion
/// y Poner set hacia la cola. El selector Secuencial/Shuffle solo se
/// muestra en Automix y Fiesta al escuchar por Carpetas.
class LiveDjFolderPicker extends ConsumerWidget {
  const LiveDjFolderPicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<FolderCardInfo>> async = ref.watch(
      liveDjFolderCardsProvider,
    );
    final Set<String> picked = ref.watch(liveDjPickedFoldersProvider);
    final DjMode mode = ref.watch(djUiProvider.select((s) => s.mode));
    final bool classic = ref.watch(liveDjClassicFolderViewProvider);
    final bool showMix = showFolderMixSelector(
      classicFolders: classic,
      radio: mode == DjMode.radio,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'CARPETAS',
                  style: TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    letterSpacing: 1.4,
                  ),
                ),
              ),
              if (showMix) const LiveDjFolderMixSelector(),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
          child: Align(
            alignment: Alignment.centerRight,
            child: ElevatedButton.icon(
              key: const Key('livedj-poner-set'),
              onPressed: picked.isEmpty ? null : () => _ponerSet(ref, picked),
              icon: const Icon(Icons.playlist_add_check, size: 16),
              label: Text(
                picked.isEmpty
                    ? 'Poner set (8)'
                    : 'Poner set (8) · ${picked.length}',
                style: const TextStyle(fontSize: 11),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white10,
                foregroundColor: GatoMixTheme.cyanAccent,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 30),
              ),
            ),
          ),
        ),
        Expanded(
          child: async.when(
            loading: () => const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
            error: (Object e, StackTrace st) => const Center(
              child: Text(
                'No se pudieron leer las carpetas.',
                style: TextStyle(color: Colors.white38),
              ),
            ),
            data: (List<FolderCardInfo> cards) {
              if (cards.isEmpty) {
                return const Center(
                  child: Text(
                    'No hay carpetas con audio en ReGenial.',
                    style: TextStyle(color: Colors.white38),
                    textAlign: TextAlign.center,
                  ),
                );
              }
              return ListView(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final FolderCardInfo c in cards)
                        _FolderChip(
                          info: c,
                          selected: picked.contains(c.path),
                          onTap: () {
                            final Set<String> next = <String>{...picked};
                            if (!next.add(c.path)) next.remove(c.path);
                            ref
                                    .read(liveDjPickedFoldersProvider.notifier)
                                    .state =
                                next;
                          },
                        ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _ponerSet(WidgetRef ref, Set<String> picked) async {
    final List<File> files = <File>[];
    final Set<String> seen = <String>{};
    for (final String dir in picked) {
      final List<String> paths = await listLibraryAudioAsync(<String>[dir]);
      for (final String p in paths) {
        if (isKaraokeAudioPath(p) || !seen.add(p)) continue;
        files.add(File(p));
      }
    }
    if (files.isEmpty) return;
    final String owner = picked.length == 1 ? picked.first : picked.join('|');
    ref.read(djUiProvider.notifier).noteFolder(owner);
    await ref.read(liveDjProvider.notifier).playFolderList(owner, files);
  }
}

class LiveDjFolderMixSelector extends ConsumerWidget {
  const LiveDjFolderMixSelector({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool shuffle = ref.watch(
      liveDjProvider.select((s) => s.mixStrategy == LiveDjMixStrategy.random),
    );
    return Container(
      key: const Key('livedj-folder-mix-selector'),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _seg(
            label: 'Secuencial',
            selected: !shuffle,
            onTap: shuffle
                ? () => ref.read(liveDjProvider.notifier).toggleMixStrategy()
                : null,
          ),
          _seg(
            label: 'Shuffle',
            selected: shuffle,
            onTap: shuffle
                ? null
                : () => ref.read(liveDjProvider.notifier).toggleMixStrategy(),
          ),
        ],
      ),
    );
  }

  Widget _seg({
    required String label,
    required bool selected,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? const Color(0x3300E5FF) : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? GatoMixTheme.cyanAccent : Colors.transparent,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? GatoMixTheme.cyanAccent : Colors.white54,
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

class _FolderChip extends StatelessWidget {
  const _FolderChip({
    required this.info,
    required this.selected,
    required this.onTap,
  });

  final FolderCardInfo info;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final String energy = info.meanEnergy == null
        ? 'E —'
        : 'E ${info.meanEnergy!.toStringAsFixed(1)}';
    return Material(
      color: selected ? const Color(0x221A222D) : GatoMixTheme.bgPanel,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        key: Key('folder-chip-${info.name}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 150,
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? GatoMixTheme.cyanAccent : Colors.white10,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                info.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${info.count} temas · $energy',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 10,
                  fontFamily: 'Consolas',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

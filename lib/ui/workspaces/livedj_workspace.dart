import 'dart:async';
import 'dart:io';
import '../widgets/approx_lyric_icon.dart';
import '../widgets/hover_marquee_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio_path.dart';
import '../../core/display_bpm.dart';
import '../../providers/theme_provider.dart';
import '../../providers/directory_provider.dart';
import '../../providers/livedj_provider.dart';
import 'livedj_sort_button.dart';
import 'automix_workspace.dart';
import '../mobile/music_picker_screen.dart';
import 'livedj_bpm_badge.dart';
import 'livedj_dj_sheet.dart';
import 'livedj_artist_card.dart';
import 'livedj_folder_playlist.dart';
import 'livedj_mix_marker.dart';
import 'livedj_spotify_panel.dart';
import '../../core/audio/cue_preview.dart';
import '../../core/livedj_next.dart';
import '../../core/track_name_clean.dart';
import '../curator_inbox_dialog.dart';
import '../vibe_hub_view.dart';
import '../../providers/vibe_hub_provider.dart';

/// Texto del buscador de la cola (solo filtra la vista; la cola real no cambia).
final liveDjQueueSearchProvider = StateProvider<String>((ref) => '');

/// Vista grande de la carpeta. Apagada: Explorador + carpeta + Cartridge.
final liveDjPlaylistViewProvider = StateProvider<bool>((ref) => false);

/// Solo pruebas: fuerza el layout móvil (null = según plataforma).
@visibleForTesting
bool? debugLiveDjForceMobile;

bool liveDjIsMobile() =>
    debugLiveDjForceMobile ?? (Platform.isAndroid || Platform.isIOS);

class LiveDjWorkspace extends ConsumerWidget {
  const LiveDjWorkspace({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final compact = liveDjIsMobile();
    final bool playlist = ref.watch(liveDjPlaylistViewProvider);
    // 3.1.48: la vista de la cancion (disco) vuelve tambien al celular.
    if (playlist) {
      return Scaffold(
        backgroundColor: GatoMixTheme.bgDark,
        body: Stack(
          children: [
            const Positioned.fill(child: LiveDjFolderPlaylist()),
            // 3.1.84: el mismo boton Modo DJ en la vista del disco.
            const Positioned(
              top: 10,
              right: 98,
              child: LiveDjModeDjButton(compact: true),
            ),
            Positioned(
              top: 8,
              right: 56,
              child: Tooltip(
                message: 'Volver a DiFogo',
                child: GestureDetector(
                  onTap: () =>
                      ref.read(liveDjPlaylistViewProvider.notifier).state =
                          false,
                  child: const Padding(
                    padding: EdgeInsets.all(6),
                    child: Icon(
                      Icons.album,
                      size: 28,
                      color: GatoMixTheme.syncActive,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }
    final bool classic = ref.watch(liveDjClassicFolderViewProvider);
    // 3.1.70: en Modo Spotify el reproductor gana alto en el telefono.
    final bool spotify = ref.watch(liveDjSpotifyModeProvider);
    final bool hasQueue = ref.watch(
      liveDjProvider.select((s) => s.queue.isNotEmpty),
    );
    return Scaffold(
      backgroundColor: GatoMixTheme.bgDark,
      body: Row(
        children: [
          // Escritorio: explorador a la izquierda. En móvil esa columna no va;
          // las canciones se agregan desde la hoja del Cartridge.
          if (!compact) ...<Widget>[
            Expanded(
              // 3.1.62: las tarjetas de estacion piden algo mas de ancho.
              flex: classic ? 5 : 6,
              // 3.1.54: Smart Vibe (Hub) por defecto; el modo clasico vuelve
              // al arbol de carpetas.
              child: classic
                  ? Material(
                      color: GatoMixTheme.bgPanel,
                      child: LibraryTreePanel(
                        provider: liveDjDirectoryProvider,
                      ),
                    )
                  : const VibeHubView(),
            ),
            const VerticalDivider(width: 1, color: Colors.white10),
          ],
          Expanded(
            flex: compact ? 1 : (classic ? 19 : 18),
            child: Column(
              children: [
                // 3.1.85: Lista en telefono: el reproductor sin alto fijo.
                if (compact && !spotify)
                  const LiveDjPlayerPanel()
                else
                  Expanded(
                    flex: compact ? (spotify ? 7 : 5) : 5,
                    child: const LiveDjPlayerPanel(),
                  ),
                const Divider(height: 1, color: Colors.white10),
                // 3.1.62: en modo estaciones (escritorio) no va "Cargar
                // Carpeta" ni el Cartridge vacio; la cola aparece al sonar.
                if (compact || classic || hasQueue)
                  Expanded(
                    flex: compact ? (spotify ? 5 : 6) : 5,
                    child: !compact && !classic
                        ? const LiveDjCartridgePanel()
                        : compact
                        // 3.0.48: en móvil (acostado o parado) no va la columna
                        // de carpeta; se agrega con "+ Agregar canciones".
                        ? const LiveDjCartridgePanel()
                        : const Row(
                            children: [
                              Expanded(flex: 4, child: LiveDjFolderPanel()),
                              VerticalDivider(width: 1, color: Colors.white10),
                              Expanded(flex: 5, child: LiveDjCartridgePanel()),
                            ],
                          ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class LiveDjMobileLibrary extends ConsumerWidget {
  final VoidCallback? onClose;

  const LiveDjMobileLibrary({super.key, this.onClose});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<File> queue = ref.watch(liveDjProvider.select((s) => s.queue));
    return MusicPickerScreen(
      rootPath: gatomixMusicRoot(),
      onClose: onClose,
      queuePaths: <String>[for (final File file in queue) file.path],
      onEnqueue: (File file) {
        ref.read(liveDjProvider.notifier).addTrack(file);
      },
      onUndo: (File file) {
        ref.read(liveDjProvider.notifier).removeTrack(file.path);
      },
      onPlayNext: (File file) => _liveDjPlayNext(ref, file),
      onMixFolder: (List<File> files) => _liveDjMix(ref, files),
    );
  }
}

void _liveDjPlayNext(WidgetRef ref, File file) {
  final notifier = ref.read(liveDjProvider.notifier);
  final state = ref.read(liveDjProvider);
  if (state.currentTrackPath != null &&
      sameAudioPath(state.currentTrackPath!, file.path)) {
    return;
  }
  if (state.mixStrategy == LiveDjMixStrategy.random) {
    notifier.addTrack(file);
    return;
  }
  final List<File> queue = List<File>.from(state.queue);
  var insertAt = queue.length;
  if (state.currentTrackPath != null) {
    final int i = queue.indexWhere(
      (File item) => sameAudioPath(item.path, state.currentTrackPath),
    );
    if (i >= 0) insertAt = i + 1;
  }
  final List<File> tail = queue
      .sublist(insertAt)
      .where((File item) => !sameAudioPath(item.path, file.path))
      .toList();
  for (final File item in tail) {
    notifier.removeTrack(item.path);
  }
  notifier.removeTrack(file.path);
  notifier.addTrack(file);
  if (tail.isNotEmpty) notifier.addAllTracks(tail);
}

Future<void> _liveDjMix(WidgetRef ref, List<File> files) async {
  if (files.isEmpty) return;
  final notifier = ref.read(liveDjProvider.notifier);
  notifier.addAllTracks(files);
  final List<File> queue = ref.read(liveDjProvider).queue;
  final int index = queue.indexWhere(
    (File item) => sameAudioPath(item.path, files.first.path),
  );
  if (index >= 0) {
    await notifier.playTrackFromQueue(index);
  } else if (ref.read(liveDjProvider).currentTrackPath == null) {
    await notifier.togglePlayPause();
  }
}

class LiveDjFolderPanel extends ConsumerWidget {
  const LiveDjFolderPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dirState = ref.watch(liveDjDirectoryProvider);
    // 3.1.43: BPM en memoria (cache, TrackTags, nombre); se repinta al medir.
    // 3.1.44: cache propia de Live DJ (su carpeta y la de su cola).
    final bpmCache = ref.watch(liveDjBpmCacheProvider);
    // 3.1.40: los `_K` (karaoke, solo TV) no se listan en la carpeta.
    final folderFiles = dirState.files
        .where((f) => !isKaraokeAudioPath(f.path))
        .toList();
    final bool isMobile = MediaQuery.of(context).size.width < 800;

    return Column(
      children: [
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: 10,
            vertical: isMobile ? 4 : 8,
          ),
          color: GatoMixTheme.bgPanel,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  dirState.currentPath.isEmpty
                      ? "Selecciona carpeta..."
                      : dirState.currentPath
                            .replaceAll('\\', '/')
                            .split('/')
                            .last,
                  style: TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.bold,
                    fontSize: isMobile ? 11 : 13,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              ElevatedButton.icon(
                onPressed: folderFiles.isEmpty
                    ? null
                    : () async {
                        final rawFiles = folderFiles.whereType<File>().toList();
                        final notifier = ref.read(liveDjProvider.notifier);
                        notifier.addAllTracks(rawFiles);
                        if (ref.read(liveDjProvider).currentTrackPath == null) {
                          await notifier.togglePlayPause();
                        }
                      },
                icon: Icon(Icons.playlist_add_check, size: isMobile ? 14 : 16),
                label: Text(
                  "Cargar Carpeta",
                  style: TextStyle(fontSize: isMobile ? 10 : 11),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white10,
                  foregroundColor: GatoMixTheme.cyanAccent,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  minimumSize: Size(0, isMobile ? 24 : 30),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: folderFiles.isEmpty
              ? const Center(
                  child: Text(
                    "Carpeta vacía o sin MP3.",
                    style: TextStyle(color: Colors.white38),
                  ),
                )
              : ListView.builder(
                  physics: const BouncingScrollPhysics(),
                  itemCount: folderFiles.length,
                  itemBuilder: (context, index) {
                    final file = folderFiles[index];

                    return Material(
                      color: Colors.transparent,
                      child: ListTile(
                        dense: true,
                        visualDensity: const VisualDensity(vertical: -4),
                        shape: const Border(
                          bottom: BorderSide(color: Colors.white10),
                        ),
                        leading: const Icon(
                          Icons.audio_file,
                          color: Colors.white24,
                          size: 18,
                        ),
                        title: Row(
                          children: [
                            ApproxLyricIcon(path: file.path, size: 16),
                            const SizedBox(width: 4),
                            Expanded(
                              child: HoverMarqueeText(
                                formatTrackTitle(
                                  file.path,
                                  bpm: displayBpmFor(file.path, bpmCache),
                                ),
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                        onTap: () async {
                          final notifier = ref.read(liveDjProvider.notifier);
                          notifier.addTrack(file);
                          if (ref.read(liveDjProvider).currentTrackPath ==
                              null) {
                            await notifier.togglePlayPause();
                          }
                        },
                        trailing: IconButton(
                          icon: const Icon(
                            Icons.add_circle_outline,
                            color: GatoMixTheme.cyanAccent,
                            size: 20,
                          ),
                          onPressed: () =>
                              ref.read(liveDjProvider.notifier).addTrack(file),
                          tooltip: "Añadir a la Cola",
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class LiveDjPlayerPanel extends ConsumerStatefulWidget {
  /// Solo pruebas: fuerza el acomodo de teléfono o de escritorio.
  final bool? compactOverride;

  const LiveDjPlayerPanel({super.key, this.compactOverride});

  @override
  ConsumerState<LiveDjPlayerPanel> createState() => _LiveDjPlayerPanelState();
}

class _LiveDjPlayerPanelState extends ConsumerState<LiveDjPlayerPanel> {
  double? _dragPosition;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(liveDjProvider);
    final pos = state.position;
    final dur = state.duration;
    final currentName =
        (state.currentTrackPath ??
                (state.queue.isNotEmpty ? state.queue.first.path : null))
            ?.replaceAll('\\', '/')
            .split('/')
            .last ??
        "SISTEMA EN ESPERA";
    final isPlayingNow = state.isPlaying;
    final canToggle = state.currentTrackPath != null || state.queue.isNotEmpty;

    // 3.1.70: Modo Spotify por defecto (las pruebas con compactOverride
    // siguen viendo la consola clasica).
    final bool spotify =
        widget.compactOverride == null && ref.watch(liveDjSpotifyModeProvider);

    final isShuffle = state.mixStrategy == LiveDjMixStrategy.random;
    final compact = widget.compactOverride ?? liveDjIsMobile();
    final bool playlistOn = ref.watch(liveDjPlaylistViewProvider);
    final bool menuOpen = compact ? ref.watch(mobileNavOpenProvider) : false;
    final gap = compact ? 4.0 : 10.0;
    final titleSize = compact ? 13.0 : 16.0;
    final timeSize = compact ? 14.0 : 18.0;

    final bool radioOn = state.radioOn;
    // 3.1.84: la Radio Descubrimiento va como chip en la cabecera de la cola.

    // Controlador de GÉNERO: visible solo con la Radio encendida.
    // Ningún chip marcado = Todo.
    Widget genreChip(
      String label,
      bool selected,
      VoidCallback onTap, {
      bool enabled = true,
    }) {
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Opacity(
          opacity: enabled ? 1.0 : 0.3,
          child: GestureDetector(
            onTap: enabled ? onTap : null,
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 8 : 10,
                vertical: compact ? 2 : 4,
              ),
              decoration: BoxDecoration(
                color: selected
                    ? GatoMixTheme.syncActive.withValues(alpha: 0.18)
                    : Colors.transparent,
                border: Border.all(
                  color: selected ? GatoMixTheme.syncActive : Colors.white24,
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                label,
                style: TextStyle(
                  color: selected ? GatoMixTheme.syncActive : Colors.white54,
                  fontWeight: FontWeight.bold,
                  fontSize: compact ? 10 : 11,
                ),
                maxLines: 1,
              ),
            ),
          ),
        ),
      );
    }

    final Widget radioChips = radioOn
        ? Padding(
            padding: EdgeInsets.only(top: compact ? 3 : 8),
            child: SizedBox(
              height: compact ? 24 : 28,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    genreChip(
                      'Todo',
                      state.radioGenres.isEmpty,
                      () =>
                          ref.read(liveDjProvider.notifier).clearRadioGenres(),
                    ),
                    for (final id in kRadioGenreIds)
                      genreChip(
                        kRadioGenreLabels[id]!,
                        state.radioGenres.contains(id),
                        () => ref
                            .read(liveDjProvider.notifier)
                            .toggleRadioGenre(id),
                        enabled: state.radioGenresAvailable.contains(id),
                      ),
                  ],
                ),
              ),
            ),
          )
        : const SizedBox.shrink();

    final nowPlayingBody = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "NOW PLAYING",
                    style: TextStyle(
                      color: GatoMixTheme.syncActive,
                      fontWeight: FontWeight.bold,
                      fontSize: 9,
                    ),
                  ),
                  SizedBox(height: compact ? 2 : 5),
                  // 3.1.84: titulo limpio (sin .mp3 ni BPM; el BPM esta en
                  // la hoja Modo DJ).
                  HoverMarqueeText(
                    cleanTrackTitle(currentName),
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: titleSize,
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: LiveDjArtistCard(
                path:
                    state.currentTrackPath ??
                    (state.queue.isNotEmpty ? state.queue.first.path : null),
                compact: compact,
              ),
            ),
            if (!compact) ...[
              const SizedBox(width: 6),
              if (!compact)
                Tooltip(
                  message: playlistOn
                      ? 'Volver a Explorador y Cartridge'
                      : 'Vista de la carpeta',
                  child: GestureDetector(
                    onTap: () {
                      ref.read(liveDjPlaylistViewProvider.notifier).state =
                          !playlistOn;
                    },
                    child: Icon(
                      Icons.album,
                      size: 28,
                      color: playlistOn
                          ? GatoMixTheme.syncActive
                          : Colors.white70,
                    ),
                  ),
                ),
            ],
          ],
        ),
        radioChips,
        SizedBox(height: compact ? 4 : gap),
        if (compact)
          Row(
            children: [
              Text(
                "${pos.inMinutes.toString().padLeft(2, '0')}:${(pos.inSeconds % 60).toString().padLeft(2, '0')}",
                style: const TextStyle(
                  color: GatoMixTheme.cyanAccent,
                  fontFamily: 'Consolas',
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Expanded(
                child: SliderTheme(
                  data: const SliderThemeData(
                    trackHeight: 3,
                    thumbShape: RoundSliderThumbShape(enabledThumbRadius: 5),
                    overlayShape: RoundSliderOverlayShape(overlayRadius: 8),
                    activeTrackColor: GatoMixTheme.syncActive,
                    inactiveTrackColor: Colors.white10,
                    thumbColor: Colors.white,
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Slider(
                        value:
                            _dragPosition ??
                            (dur.inMilliseconds > 0
                                ? pos.inMilliseconds.toDouble().clamp(
                                    0.0,
                                    dur.inMilliseconds.toDouble(),
                                  )
                                : 0.0),
                        min: 0.0,
                        max: dur.inMilliseconds > 0
                            ? dur.inMilliseconds.toDouble()
                            : 1.0,
                        onChangeStart: (val) {
                          setState(() {
                            _dragPosition = val;
                          });
                        },
                        onChanged: (val) {
                          setState(() {
                            _dragPosition = val;
                          });
                        },
                        onChangeEnd: (val) {
                          if (dur.inMilliseconds > 0) {
                            ref
                                .read(liveDjProvider.notifier)
                                .seek(Duration(milliseconds: val.toInt()));
                          }
                          setState(() {
                            _dragPosition = null;
                          });
                        },
                      ),
                      liveDjMixMarker(
                        8,
                        state.customMixOutMs,
                        dur.inMilliseconds,
                      ),
                    ],
                  ),
                ),
              ),
              Text(
                "-${(dur - pos).inMinutes.toString().padLeft(2, '0')}:${((dur - pos).inSeconds % 60).toString().padLeft(2, '0')}",
                style: const TextStyle(
                  color: Colors.white54,
                  fontFamily: 'Consolas',
                  fontSize: 11,
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                style: IconButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                tooltip: isShuffle
                    ? 'Modo: Aleatorio (Shuffle)'
                    : 'Modo: Secuencial',
                onPressed: () {
                  ref.read(liveDjProvider.notifier).toggleMixStrategy();
                },
                icon: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color:
                        (isShuffle
                                ? const Color(0xFFFF007F)
                                : const Color(0xFF00FFFF))
                            .withValues(alpha: 0.18),
                    border: Border.all(
                      color: isShuffle
                          ? const Color(0xFFFF007F)
                          : const Color(0xFF00FFFF),
                      width: 2,
                    ),
                  ),
                  child: Icon(
                    isShuffle
                        ? Icons.shuffle_rounded
                        : Icons.format_list_numbered,
                    size: 16,
                    color: isShuffle
                        ? const Color(0xFFFF007F)
                        : const Color(0xFF00FFFF),
                  ),
                ),
              ),
              LiveDjSortButton(size: 16),
              const SizedBox(width: 12),
              IconButton(
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                style: IconButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                constraints: const BoxConstraints.tightFor(
                  width: 48,
                  height: 48,
                ),
                onPressed: canToggle
                    ? () => ref.read(liveDjProvider.notifier).togglePlayPause()
                    : null,
                icon: Icon(
                  isPlayingNow
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_fill,
                  color: const Color(
                    0xFF39FF14,
                  ).withValues(alpha: canToggle ? 1 : 0.28),
                  size: 42,
                ),
              ),
              const SizedBox(width: 8),
              InkWell(
                onTap: state.queue.isEmpty
                    ? null
                    : () => ref.read(liveDjProvider.notifier).forceNext(),
                child: Icon(
                  Icons.skip_next,
                  size: 22,
                  color: state.queue.isEmpty ? Colors.white24 : Colors.white70,
                ),
              ),
            ],
          )
        else ...[
          Row(
            children: [
              Text(
                "${pos.inMinutes.toString().padLeft(2, '0')}:${(pos.inSeconds % 60).toString().padLeft(2, '0')}",
                style: TextStyle(
                  color: GatoMixTheme.cyanAccent,
                  fontFamily: 'Consolas',
                  fontSize: timeSize,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              Text(
                "-${(dur - pos).inMinutes.toString().padLeft(2, '0')}:${((dur - pos).inSeconds % 60).toString().padLeft(2, '0')}",
                style: const TextStyle(
                  color: Colors.white54,
                  fontFamily: 'Consolas',
                  fontSize: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 15,
            child: SliderTheme(
              data: const SliderThemeData(
                trackHeight: 3,
                thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
                activeTrackColor: GatoMixTheme.syncActive,
                inactiveTrackColor: Colors.white10,
                thumbColor: Colors.white,
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Slider(
                    value:
                        _dragPosition ??
                        (dur.inMilliseconds > 0
                            ? pos.inMilliseconds.toDouble().clamp(
                                0.0,
                                dur.inMilliseconds.toDouble(),
                              )
                            : 0.0),
                    min: 0.0,
                    max: dur.inMilliseconds > 0
                        ? dur.inMilliseconds.toDouble()
                        : 1.0,
                    onChangeStart: (val) {
                      setState(() {
                        _dragPosition = val;
                      });
                    },
                    onChanged: (val) {
                      setState(() {
                        _dragPosition = val;
                      });
                    },
                    onChangeEnd: (val) {
                      if (dur.inMilliseconds > 0) {
                        ref
                            .read(liveDjProvider.notifier)
                            .seek(Duration(milliseconds: val.toInt()));
                      }
                      setState(() {
                        _dragPosition = null;
                      });
                    },
                  ),
                  liveDjMixMarker(12, state.customMixOutMs, dur.inMilliseconds),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                style: IconButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                constraints: const BoxConstraints.tightFor(
                  width: 52,
                  height: 52,
                ),
                tooltip: isShuffle
                    ? 'Modo: Aleatorio (Shuffle)'
                    : 'Modo: Secuencial',
                onPressed: () {
                  ref.read(liveDjProvider.notifier).toggleMixStrategy();
                },
                icon: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color:
                        (isShuffle
                                ? const Color(0xFFFF007F)
                                : const Color(0xFF00FFFF))
                            .withValues(alpha: 0.18),
                    border: Border.all(
                      color: isShuffle
                          ? const Color(0xFFFF007F)
                          : const Color(0xFF00FFFF),
                      width: 2,
                    ),
                  ),
                  child: Icon(
                    isShuffle
                        ? Icons.shuffle_rounded
                        : Icons.format_list_numbered,
                    size: 26,
                    color: isShuffle
                        ? const Color(0xFFFF007F)
                        : const Color(0xFF00FFFF),
                  ),
                ),
              ),
              LiveDjSortButton(size: 24),
              const SizedBox(width: 12),
              IconButton(
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                style: IconButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                constraints: const BoxConstraints.tightFor(
                  width: 48,
                  height: 48,
                ),
                onPressed: canToggle
                    ? () => ref.read(liveDjProvider.notifier).togglePlayPause()
                    : null,
                icon: Icon(
                  isPlayingNow
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_fill,
                  color: const Color(
                    0xFF39FF14,
                  ).withValues(alpha: canToggle ? 1 : 0.28),
                  size: 45,
                ),
              ),
              const SizedBox(width: 12),
              IconButton(
                icon: Icon(
                  Icons.skip_next,
                  color: (state.queue.isEmpty && !state.radioOn)
                      ? Colors.white24
                      : Colors.white70,
                  size: 30,
                ),
                onPressed: (state.queue.isEmpty && !state.radioOn)
                    ? null
                    : () => ref.read(liveDjProvider.notifier).forceNext(),
              ),
            ],
          ),
        ],
      ],
    );

    final songCard = Container(
      margin: EdgeInsets.all(compact ? 6 : 15),
      padding: EdgeInsets.all(compact ? 8 : 15),
      decoration: BoxDecoration(
        color: GatoMixTheme.bgPanel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: nowPlayingBody,
    );

    // 3.1.84: el selector "TIPO DE MEZCLA" paso a la hoja Modo DJ; aqui
    // solo queda el buscador de la cola.
    final routingBar = Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 15,
        vertical: compact ? 4 : 12,
      ),
      color: GatoMixTheme.bgDark,
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: SizedBox(
              height: compact ? 26 : 30,
              child: TextField(
                onChanged: (v) =>
                    ref.read(liveDjQueueSearchProvider.notifier).state = v,
                style: const TextStyle(color: Colors.white, fontSize: 11),
                decoration: InputDecoration(
                  hintText: 'Buscar en la cola',
                  hintStyle: const TextStyle(
                    color: Colors.white38,
                    fontSize: 11,
                  ),
                  prefixIcon: const Icon(
                    Icons.search,
                    size: 14,
                    color: Colors.white38,
                  ),
                  prefixIconConstraints: const BoxConstraints(
                    minWidth: 26,
                    minHeight: 20,
                  ),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 6),
                  filled: true,
                  fillColor: GatoMixTheme.bgDark,
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: const BorderSide(color: Colors.white24),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: const BorderSide(
                      color: GatoMixTheme.syncActive,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    // 3.1.85: Lista en telefono: la tarjeta mide solo lo que ocupa (sin
    // Expanded ni hueco bajo la barra y los controles); la cola gana el resto.
    final Widget compactListCard = Padding(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: GatoMixTheme.bgPanel,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white10),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 12, 4, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, c) {
                    return FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        width: c.maxWidth,
                        child: nowPlayingBody,
                      ),
                    );
                  },
                ),
              ),
              if (!compact)
                Tooltip(
                  message: playlistOn
                      ? 'Volver a Explorador y Cartridge'
                      : 'Vista de la carpeta',
                  child: GestureDetector(
                    onTap: () {
                      ref
                              .read(
                                liveDjPlaylistViewProvider.notifier,
                              )
                              .state =
                          !playlistOn;
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(
                        Icons.album,
                        size: 26,
                        color: playlistOn
                            ? GatoMixTheme.syncActive
                            : Colors.white70,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    final bool tightList = compact && !spotify;
    return Column(
      mainAxisSize: tightList ? MainAxisSize.min : MainAxisSize.max,
      children: [
        if (compact)
          ColoredBox(
            color: GatoMixTheme.bgDark,
            child: Row(
              children: [
                GatoMixMobileModeBar(
                  title: 'AutomixDj',
                  accent: GatoMixTheme.syncActive,
                  open: menuOpen,
                  expand: false,
                  onTap: () => ref.read(mobileNavOpenProvider.notifier).state =
                      !menuOpen,
                ),
                // 3.1.48: disco en la barra movil, como en 3.0.17.
                Tooltip(
                  message: playlistOn
                      ? 'Volver a DiFogo'
                      : 'Vista de la carpeta',
                  child: GestureDetector(
                    onTap: () {
                      ref.read(liveDjPlaylistViewProvider.notifier).state =
                          !playlistOn;
                    },
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Icon(
                        Icons.album,
                        size: 26,
                        color: GatoMixTheme.syncActive,
                      ),
                    ),
                  ),
                ),
                const LiveDjModeDjButton(compact: true),
                const LiveDjSpotifyToggle(),
                Expanded(child: routingBar),
              ],
            ),
          )
        else
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
            decoration: const BoxDecoration(
              color: GatoMixTheme.bgDark,
              border: Border(bottom: BorderSide(color: Colors.white10)),
            ),
            child: Row(
              children: [
                // 3.1.84 Consumer Clean Mode: titulo y un solo boton Modo DJ
                // (tipo de mezcla, FX AUTO/FIJO y BPM en la hoja).
                const Expanded(
                  child: Text(
                    'AutomixDj',
                    key: Key('livedj-clean-title'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),
                const LiveDjModeDjButton(),
                const SizedBox(width: 6),
                const LiveDjSpotifyToggle(),
              ],
            ),
          ),
        if (tightList)
          compactListCard
        else
          Expanded(
          child: spotify
              ? LiveDjSpotifyPanel(compact: compact)
              : compact
              ? compactListCard
              : SingleChildScrollView(child: songCard),
        ),
        // 3.1.84: sin franja con el nombre de archivo de la siguiente (la
        // cola ya la muestra en primer lugar).
        if (!compact) routingBar,
      ],
    );
  }
}

/// Una linea. Si el nombre cabe, se queda (con puntos suspensivos de
/// respaldo). Si no cabe, se desplaza dentro del recorte.
/// 3.1.22 (Pendiente 22e): ida, pausa 2,5 s, vuelta, pausa 2,5 s; tope de 3
/// ciclos y queda quieto al inicio. Las pausas son Timer (0 cuadros).
class NextTrackLine extends StatefulWidget {
  final String label;
  final TextStyle style;

  const NextTrackLine({super.key, required this.label, required this.style});

  static const Duration endPause = Duration(milliseconds: 2500);
  static const int maxCycles = 3;

  /// Duracion de una pasada segun el exceso de ancho.
  static int legMs(double travel) => (travel * 18).round().clamp(4000, 14000);

  @override
  State<NextTrackLine> createState() => _NextTrackLineState();
}

class _NextTrackLineState extends State<NextTrackLine>
    with SingleTickerProviderStateMixin {
  late final AnimationController _move;
  Timer? _pause;
  int _cycles = 0;
  bool _nextForward = true;
  bool _tickersOn = true;
  bool _overflow = false;
  double _travel = 0;

  @override
  void initState() {
    super.initState();
    _move = AnimationController(vsync: this)..addStatusListener(_onStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool on = TickerMode.valuesOf(context).enabled;
    if (on == _tickersOn) return;
    _tickersOn = on;
    if (on) _resume();
  }

  @override
  void didUpdateWidget(covariant NextTrackLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.label != widget.label || oldWidget.style != widget.style) {
      _restart();
      WidgetsBinding.instance.addPostFrameCallback((_) => _resume());
    }
  }

  @override
  void dispose() {
    _pause?.cancel();
    _move.dispose();
    super.dispose();
  }

  void _onStatus(AnimationStatus s) {
    if (!mounted) return;
    if (s == AnimationStatus.completed) {
      _nextForward = false;
      _schedulePause();
    } else if (s == AnimationStatus.dismissed && !_nextForward) {
      _cycles++;
      _nextForward = true;
      if (_cycles < NextTrackLine.maxCycles) _schedulePause();
    }
  }

  void _schedulePause() {
    _pause?.cancel();
    _pause = Timer(NextTrackLine.endPause, () {
      _pause = null;
      if (!mounted) return;
      _resume();
    });
  }

  /// Arranca la pasada pendiente si hace falta y se puede.
  void _resume() {
    if (!mounted || !_tickersOn || !_overflow) return;
    if (_pause != null || _move.isAnimating) return;
    if (_cycles >= NextTrackLine.maxCycles) return;
    _move.duration = Duration(milliseconds: NextTrackLine.legMs(_travel));
    if (_nextForward) {
      _move.forward(from: 0);
    } else {
      _move.reverse(from: 1);
    }
  }

  /// Texto o ancho nuevo: corta la pausa, vuelve al inicio y cuenta de 0.
  void _restart() {
    _pause?.cancel();
    _pause = null;
    _move.stop();
    _move.value = 0;
    _cycles = 0;
    _nextForward = true;
  }

  void _syncLayout(bool overflow, double travel) {
    if (overflow == _overflow && (travel - _travel).abs() < 0.5) return;
    final bool wasOverflow = _overflow;
    _overflow = overflow;
    _travel = travel;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (wasOverflow || !_overflow) _restart();
      _resume();
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double maxW = constraints.maxWidth;
        final TextPainter painter = TextPainter(
          text: TextSpan(text: widget.label, style: widget.style),
          maxLines: 1,
          textDirection: Directionality.of(context),
        )..layout();
        final double textW = painter.width;
        final double textH = painter.height;
        painter.dispose();
        final bool overflow = maxW.isFinite && textW > maxW + 1;
        _syncLayout(overflow, overflow ? textW - maxW : 0);
        if (!overflow) {
          return Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: widget.style,
          );
        }
        final double travel = textW - maxW;
        // El texto mide su ancho real y se desliza; el recorte impide
        // que pinte encima de la barra de mezcla. RepaintBoundary: cada
        // cuadro repinta solo esta linea, no la franja.
        return SizedBox(
          width: maxW,
          height: textH,
          child: RepaintBoundary(
            child: ClipRect(
              child: AnimatedBuilder(
                animation: _move,
                builder: (context, _) {
                  final double t = Curves.easeInOut.transform(_move.value);
                  return Transform.translate(
                    offset: Offset(-travel * t, 0),
                    child: OverflowBox(
                      alignment: Alignment.centerLeft,
                      minWidth: textW,
                      maxWidth: textW,
                      minHeight: textH,
                      maxHeight: textH,
                      child: Text(
                        widget.label,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.visible,
                        style: widget.style,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

class LiveDjCartridgePanel extends ConsumerWidget {
  const LiveDjCartridgePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool radioOn = ref.watch(liveDjProvider.select((s) => s.radioOn));
    final bool spotifyQueue = ref.watch(liveDjSpotifyModeProvider);
    final List<String> radioUpcoming = ref.watch(
      liveDjProvider.select((s) => s.radioUpcoming),
    );
    final queue = ref.watch(liveDjProvider.select((s) => s.queue));
    final List<String> shown = liveDjSidePaths(
      radioOn: radioOn,
      queuePaths: <String>[for (final File f in queue) f.path],
      radioUpcoming: radioUpcoming,
    );
    final query = ref.watch(liveDjQueueSearchProvider).trim().toLowerCase();
    final visible = <int>[
      for (int i = 0; i < shown.length; i++)
        if (query.isEmpty ||
            shown[i]
                .replaceAll('\\', '/')
                .split('/')
                .last
                .toLowerCase()
                .contains(query))
          i,
    ];
    // Pre-escucha (flecha roja): solo Windows; activa solo con audífono.
    final cue = CuePreviewNotifier.supported
        ? ref.watch(cuePreviewProvider)
        : const CueState();

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: const BoxDecoration(
            color: GatoMixTheme.bgPanel,
            border: Border(
              top: BorderSide(color: Colors.white10),
              bottom: BorderSide(color: Colors.white10),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 3.1.84: telefono: "+ Agregar" con los chips compactos
              // Radio y Nuevas en su propia fila (antes boton largo y barra
              // de ancho completo); asi el titulo de la cola no se recorta.
              if (liveDjIsMobile()) ...<Widget>[
                Row(
                  children: [
                    // 3.1.25: "+ Agregar canciones" de 48 px dentro de la fila.
                    // Flexible: en anchos chicos se recorta con elipsis.
                    Flexible(
                      child: MusicPickerAddButton(
                        onPressed: () {
                          showMusicPickerPanel(
                            context,
                            child: (VoidCallback close) =>
                                LiveDjMobileLibrary(onClose: close),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 6),
                    const RadioDiscoveryButton(compact: true),
                    const SizedBox(width: 4),
                    const CuratorInboxButton(),
                  ],
                ),
                const SizedBox(height: 4),
              ],
              Row(
                children: [
                  if (!liveDjIsMobile()) ...<Widget>[
                    const RadioDiscoveryButton(compact: true),
                    const SizedBox(width: 4),
                    if (ref.watch(liveDjClassicFolderViewProvider)) ...<Widget>[
                      const CuratorInboxButton(),
                      const SizedBox(width: 4),
                    ],
                  ],
                  const Icon(
                    Icons.queue_music_rounded,
                    color: Colors.pinkAccent,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      liveDjIsMobile()
                          ? "COLA (${shown.length})"
                          : "COLA DE REPRODUCCIÓN (${shown.length})",
                      style: const TextStyle(
                        color: Colors.pinkAccent,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        letterSpacing: 1.5,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // 3.1.54: conmutador Smart Vibe / Modo Clasico. 3.1.62: en
                  // escritorio con estaciones viven en la cabecera del Hub.
                  if (liveDjIsMobile() ||
                      ref.watch(liveDjClassicFolderViewProvider)) ...<Widget>[
                    LiveDjViewToggleButton(mobile: liveDjIsMobile()),
                  ],
                  IconButton(
                    icon: const Icon(
                      Icons.delete_sweep,
                      color: Colors.redAccent,
                      size: 18,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 28,
                      height: 28,
                    ),
                    visualDensity: VisualDensity.compact,
                    onPressed: radioOn || queue.isEmpty
                        ? null
                        : () => ref.read(liveDjProvider.notifier).clearQueue(),
                    tooltip: "Borrar Cola",
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.save,
                      color: Colors.cyanAccent,
                      size: 18,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 28,
                      height: 28,
                    ),
                    visualDensity: VisualDensity.compact,
                    onPressed: queue.isEmpty
                        ? null
                        : () =>
                              ref.read(liveDjProvider.notifier).savePlaylist(),
                    tooltip: "Guardar Playlist",
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.folder_open,
                      color: Colors.greenAccent,
                      size: 18,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 28,
                      height: 28,
                    ),
                    visualDensity: VisualDensity.compact,
                    onPressed: () =>
                        ref.read(liveDjProvider.notifier).loadPlaylist(),
                    tooltip: "Cargar Playlist",
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? Center(
                  child: Text(
                    radioOn
                        ? "RADIO ▸ eligiendo…"
                        : "COLA DE REPRODUCCIÓN VACÍA\nElige una estación o agrega canciones.",
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white24, fontSize: 12),
                  ),
                )
              : ListView.builder(
                  physics: const BouncingScrollPhysics(),
                  itemCount: visible.length,
                  itemBuilder: (context, vi) {
                    final index = visible[vi];
                    final String path = shown[index];
                    final File file = File(path);

                    return Material(
                      color: Colors.transparent,
                      child: ListTile(
                        dense: true,
                        visualDensity: const VisualDensity(vertical: -4),
                        shape: const Border(
                          bottom: BorderSide(color: Colors.white10),
                        ),
                        leading: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // 3.1.72: Modo Spotify: indicador de play en
                            // cada fila de la cola (toca la fila para sonar).
                            if (spotifyQueue)
                              Icon(
                                Icons.play_circle_outline_rounded,
                                key: Key('livedj-queue-play-$index'),
                                color: const Color(0xFFFF5722),
                                size: 16,
                              )
                            else
                              const Icon(
                                Icons.drag_handle,
                                color: Colors.white24,
                                size: 16,
                              ),
                            const SizedBox(width: 6),
                            LiveDjBpmBadge(path: file.path),
                          ],
                        ),
                        // 3.1.84: cola limpia, sin .mp3 ni BPM en el titulo.
                        title: HoverMarqueeText(
                          cleanTrackTitle(path),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                        onTap: radioOn
                            ? null
                            : () => ref
                                  .read(liveDjProvider.notifier)
                                  .playTrackFromQueue(index),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ApproxLyricIcon(path: file.path),
                            if (CuePreviewNotifier.supported)
                              IconButton(
                                icon: Icon(
                                  cue.playingPath == file.path
                                      ? Icons.stop
                                      : Icons.play_arrow,
                                  color: cue.available
                                      ? Colors.redAccent
                                      : Colors.white24,
                                  size: 18,
                                ),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints.tightFor(
                                  width: 28,
                                  height: 28,
                                ),
                                visualDensity: VisualDensity.compact,
                                tooltip: cue.available
                                    ? "Pre-escucha (solo audífono)"
                                    : "Conecta un audífono para pre-escuchar",
                                onPressed: cue.available
                                    ? () => ref
                                          .read(cuePreviewProvider.notifier)
                                          .toggle(file.path)
                                    : null,
                              ),
                            IconButton(
                              icon: const Icon(
                                Icons.play_arrow,
                                color: Color(0xFF39FF14),
                                size: 18,
                              ),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                width: 28,
                                height: 28,
                              ),
                              visualDensity: VisualDensity.compact,
                              tooltip: "Play",
                              onPressed: radioOn
                                  ? null
                                  : () {
                                      if (CuePreviewNotifier.supported) {
                                        ref
                                            .read(cuePreviewProvider.notifier)
                                            .stop();
                                      }
                                      ref
                                          .read(liveDjProvider.notifier)
                                          .playTrackFromQueue(index);
                                    },
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.close,
                                color: Colors.redAccent,
                                size: 16,
                              ),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                width: 28,
                                height: 28,
                              ),
                              visualDensity: VisualDensity.compact,
                              onPressed: radioOn
                                  ? null
                                  : () => ref
                                        .read(liveDjProvider.notifier)
                                        .removeTrack(file.path),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

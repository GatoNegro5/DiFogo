import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/mode_session.dart';
import '../ui/mobile/music_picker_screen.dart'
    show musicPickerShowsFile, musicPickerTechFolder;
import 'livedj_provider.dart';
import 'session_provider.dart';

/// 3.1.54 Super-Vibe Hub: categorias maestras (carpetas de genero de primer
/// nivel bajo vibeMusicRoot) con casillas. Es la vista por defecto de Live
/// DJ; el modo clasico vuelve al arbol de carpetas. Solo lectura de la
/// biblioteca: el Hub nunca escribe en ella.

/// Solo pruebas: escaneo de generos y reproduccion sin tocar Live DJ real.
@visibleForTesting
Future<List<VibeGenre>> Function(String root)? debugVibeHubScan;
@visibleForTesting
Future<void> Function(List<File> files)? debugVibeHubPlay;
@visibleForTesting
String? debugVibeHubStatePath;

/// isClassicFolderView: false (por defecto al abrir) = Hub Smart Vibe;
/// true = arbol de carpetas tradicional. No se guarda: cada arranque abre
/// en Smart Vibe.
final liveDjClassicFolderViewProvider = StateProvider<bool>((ref) => false);

class VibeHubState {
  const VibeHubState({
    this.genres = const <VibeGenre>[],
    this.checked = const <String>{},
    this.loading = false,
    this.busy = false,
    this.message,
  });

  final List<VibeGenre> genres;

  /// Nombres de categoria marcados (se guardan en el estado de modo).
  final Set<String> checked;
  final bool loading;
  final bool busy;
  final String? message;

  VibeHubState copyWith({
    List<VibeGenre>? genres,
    Set<String>? checked,
    bool? loading,
    bool? busy,
    String? message,
    bool clearMessage = false,
  }) => VibeHubState(
    genres: genres ?? this.genres,
    checked: checked ?? this.checked,
    loading: loading ?? this.loading,
    busy: busy ?? this.busy,
    message: clearMessage ? null : (message ?? this.message),
  );
}

class VibeHubNotifier extends Notifier<VibeHubState> {
  String _path() => debugVibeHubStatePath ?? automixStatePath();

  @override
  VibeHubState build() {
    final Set<String> checked = <String>{};
    try {
      final Object? v = readModeDoc(_path())['vibeHub'];
      if (v is Map && v['checked'] is List) {
        for (final Object? g in v['checked'] as List) {
          if (g is String && g.isNotEmpty) checked.add(g);
        }
      }
    } catch (_) {}
    if (checked.isEmpty) {
      final String? a = ref.read(vibeProvider).active;
      if (a != null && a.isNotEmpty) checked.add(a);
    }
    return VibeHubState(checked: checked);
  }

  /// Lee las categorias de la raiz (sin bloquear la UI: listado async).
  Future<void> refresh() async {
    if (state.loading) return;
    state = state.copyWith(loading: true, clearMessage: true);
    List<VibeGenre> genres = const <VibeGenre>[];
    try {
      genres = await (debugVibeHubScan ?? scanVibeGenres)(vibeMusicRoot());
    } catch (_) {}
    final Set<String> names = <String>{
      for (final VibeGenre g in genres) g.name.toLowerCase(),
    };
    state = state.copyWith(
      genres: genres,
      checked: <String>{
        for (final String c in state.checked)
          if (names.contains(c.toLowerCase())) c,
      },
      loading: false,
    );
  }

  Future<void> toggle(String genre) async {
    final Set<String> next = Set<String>.from(state.checked);
    if (!next.remove(genre)) next.add(genre);
    state = state.copyWith(checked: next, clearMessage: true);
    await _save();
  }

  Future<void> setAll(bool on) async {
    state = state.copyWith(
      checked: on
          ? <String>{for (final VibeGenre g in state.genres) g.name}
          : <String>{},
      clearMessage: true,
    );
    await _save();
  }

  Future<void> _save() async {
    try {
      await patchModeDoc(_path(), <String, dynamic>{
        'vibeHub': <String, dynamic>{
          'checked': (state.checked.toList()..sort()),
        },
      });
    } catch (_) {}
  }

  /// Pistas de las categorias marcadas, en orden de ruta. Solo lectura.
  Future<List<File>> collect() async {
    final String root = vibeMusicRoot();
    final List<File> out = <File>[];
    for (final String g in (state.checked.toList()..sort())) {
      final Directory d = Directory('$root${Platform.pathSeparator}$g');
      if (!await d.exists()) continue;
      try {
        await for (final FileSystemEntity f in d.list(
          recursive: true,
          followLinks: false,
        )) {
          if (f is! File || !musicPickerShowsFile(f.path)) continue;
          if (musicPickerTechFolder(f.parent.path)) continue;
          out.add(f);
        }
      } catch (_) {}
    }
    out.sort((File a, File b) => a.path.compareTo(b.path));
    return out;
  }

  /// Carga las categorias marcadas en la cola de Live DJ, aplica el Shuffle
  /// armonico existente y arranca si no habia nada sonando.
  Future<int> play() async {
    if (state.busy || state.checked.isEmpty) return 0;
    state = state.copyWith(busy: true, clearMessage: true);
    int n = 0;
    try {
      final List<File> files = await collect();
      n = files.length;
      if (files.isEmpty) {
        state = state.copyWith(message: 'Sin canciones en lo marcado');
        return 0;
      }
      final Future<void> Function(List<File>)? hook = debugVibeHubPlay;
      if (hook != null) {
        await hook(files);
      } else {
        final LiveDjNotifier dj = ref.read(liveDjProvider.notifier);
        dj.addAllTracks(files);
        // Primero arranca (si no sonaba nada) y luego el Shuffle armonico,
        // que ancla el orden a la pista que suena.
        if (ref.read(liveDjProvider).currentTrackPath == null) {
          await dj.togglePlayPause();
        }
        if (ref.read(liveDjProvider).mixStrategy ==
            LiveDjMixStrategy.sequential) {
          dj.shuffleQueue();
        }
      }
      state = state.copyWith(message: '$n canciones en la cola');
    } finally {
      state = state.copyWith(busy: false);
    }
    return n;
  }
}

final vibeHubProvider = NotifierProvider<VibeHubNotifier, VibeHubState>(
  VibeHubNotifier.new,
);

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/mode_session.dart';
import '../ui/mobile/music_picker_screen.dart'
    show gatomixMusicRoot, musicPickerShowsFile, musicPickerTechFolder;

/// 3.1.52 Smart Vibe & Strict Genre Lock: el genero es la carpeta de primer
/// nivel dentro de la carpeta unica de musica (Musica/ReGenial, o Musica).

/// Solo pruebas: raiz de musica y archivo de estado en %TEMP%.
@visibleForTesting
String? debugVibeRootOverride;
@visibleForTesting
String? debugVibeStatePath;

/// 3.1.67 Solo pruebas: indice de generos por cancion en %TEMP%.
@visibleForTesting
String? debugTrackGenreIndexPath;

/// 3.1.67 `difogo_track_genre_index.json` en la carpeta de datos de la app
/// (junto a `difogo_genre_sessions.json`), nunca en la biblioteca.
String trackGenreIndexPath() =>
    debugTrackGenreIndexPath ??
    '${sessionDir()}${Platform.pathSeparator}difogo_track_genre_index.json';

/// true si las pruebas apuntan el indice a %TEMP%.
bool trackGenreIndexInTemp() => debugTrackGenreIndexPath != null;

String vibeMusicRoot() {
  final String? o = debugVibeRootOverride;
  if (o != null) return o;
  final String base = gatomixMusicRoot();
  final Directory reg = Directory('$base${Platform.pathSeparator}ReGenial');
  return reg.existsSync() ? reg.path : base;
}

String _norm(String p) =>
    p.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');

/// Genero de [path]: nombre de la carpeta de primer nivel bajo [root];
/// null si esta fuera de la raiz o suelto en ella.
String? vibeGenreOf(String root, String path) {
  final String r = _norm(root).toLowerCase();
  final String p = _norm(path);
  if (r.isEmpty || !p.toLowerCase().startsWith('$r/')) return null;
  final String rel = p.substring(r.length + 1);
  final int cut = rel.indexOf('/');
  if (cut <= 0) return null;
  return rel.substring(0, cut);
}

/// Candado estricto: sin genero activo pasa todo; con genero, solo las
/// pistas que viven dentro de esa carpeta (nombre exacto, sin mayusculas).
bool vibeAllows(String? vibe, String root, String path) {
  if (vibe == null || vibe.isEmpty) return true;
  final String? g = vibeGenreOf(root, path);
  return g != null && g.toLowerCase() == vibe.toLowerCase();
}

/// Filtra [paths] con el candado (una sola lectura de la raiz).
List<String> vibeKeep(List<String> paths, String? vibe, String root) {
  if (vibe == null || vibe.isEmpty) return List<String>.from(paths);
  return <String>[
    for (final String p in paths)
      if (vibeAllows(vibe, root, p)) p,
  ];
}

class VibeGenre {
  const VibeGenre(this.name, this.count);
  final String name;
  final int count;
}

/// Generos disponibles: subcarpetas de [root] con audio (sin _K, ocultas ni
/// tecnicas), en orden alfabetico. Solo lectura.
Future<List<VibeGenre>> scanVibeGenres(String root) async {
  final List<VibeGenre> out = <VibeGenre>[];
  final Directory dir = Directory(root);
  if (!dir.existsSync()) return out;
  try {
    await for (final FileSystemEntity e in dir.list(followLinks: false)) {
      if (e is! Directory) continue;
      final String name = _norm(e.path).split('/').last;
      final String low = name.toLowerCase();
      if (low.startsWith('.') || low.contains('_k')) continue;
      if (musicPickerTechFolder(e.path)) continue;
      int n = 0;
      try {
        await for (final FileSystemEntity f in e.list(
          recursive: true,
          followLinks: false,
        )) {
          if (f is File && musicPickerShowsFile(f.path)) n++;
        }
      } catch (_) {}
      if (n > 0) out.add(VibeGenre(name, n));
    }
  } catch (_) {}
  out.sort(
    (VibeGenre a, VibeGenre b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase()),
  );
  return out;
}

class VibeState {
  const VibeState({this.active, this.lastVibe, this.sessionActive = false});

  /// Genero bloqueado en esta sesion (null = sin candado).
  final String? active;

  /// Ultimo genero guardado y si el usuario quiere mantenerlo.
  final String? lastVibe;
  final bool sessionActive;
}

class VibeNotifier extends Notifier<VibeState> {
  String _path() => debugVibeStatePath ?? automixStatePath();

  @override
  VibeState build() {
    try {
      final Object? v = readModeDoc(_path())['vibe'];
      if (v is Map) {
        final Object? g = v['lastVibe'];
        return VibeState(
          lastVibe: g is String && g.isNotEmpty ? g : null,
          sessionActive: v['sessionActive'] == true,
        );
      }
    } catch (_) {}
    return const VibeState();
  }

  /// Fija el genero de la sesion (null = Todo) y lo guarda para el proximo
  /// arranque.
  Future<void> choose(String? genre) async {
    final String? g = (genre == null || genre.isEmpty) ? null : genre;
    state = VibeState(
      active: g,
      lastVibe: g ?? state.lastVibe,
      sessionActive: g != null,
    );
    try {
      await patchModeDoc(_path(), <String, dynamic>{
        'vibe': <String, dynamic>{
          'sessionActive': g != null,
          'lastVibe': g ?? state.lastVibe,
        },
      });
    } catch (_) {}
  }
}

final vibeProvider = NotifierProvider<VibeNotifier, VibeState>(
  VibeNotifier.new,
);

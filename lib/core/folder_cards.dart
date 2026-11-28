import 'dart:io';

import 'audio_path.dart';
import 'discovery_dedup_controller.dart' show listLibraryAudioAsync;
import 'gatomix_store.dart';

/// 3.2.38: cards de carpetas de ReGenial (conteo y energia media).
/// Solo lectura del audio; el promedio sale del espejo (peekTrackDna).

/// Solo pruebas: raiz de biblioteca falsa.
String? debugFolderCardsRoot;

class FolderCardInfo {
  const FolderCardInfo({
    required this.path,
    required this.name,
    required this.count,
    this.meanEnergy,
  });

  final String path;
  final String name;
  final int count;
  final double? meanEnergy;
}

String regenialRoot({String? musicRoot}) {
  final String base = debugFolderCardsRoot ?? musicRoot ?? '';
  if (base.isEmpty) return '';
  return '$base${Platform.pathSeparator}ReGenial';
}

/// Cierto si Automix o Fiesta estan en vista por Carpetas.
bool showFolderMixSelector({
  required bool classicFolders,
  required bool radio,
}) => classicFolders && !radio;

/// Subcarpetas inmediatas de ReGenial con al menos un audio.
Future<List<FolderCardInfo>> loadRegenialFolderCards({
  required String musicRoot,
}) async {
  final String root = regenialRoot(musicRoot: musicRoot);
  if (root.isEmpty) return const <FolderCardInfo>[];
  final Directory dir = Directory(root);
  if (!await dir.exists()) return const <FolderCardInfo>[];
  final List<Directory> subs = <Directory>[];
  try {
    await for (final FileSystemEntity e in dir.list(followLinks: false)) {
      if (e is Directory) {
        final String name = e.path.replaceAll('\\', '/').split('/').last;
        if (name.startsWith('.')) continue;
        subs.add(e);
      }
    }
  } catch (_) {
    return const <FolderCardInfo>[];
  }
  subs.sort(
    (Directory a, Directory b) =>
        a.path.toLowerCase().compareTo(b.path.toLowerCase()),
  );
  final List<FolderCardInfo> out = <FolderCardInfo>[];
  for (final Directory d in subs) {
    final List<String> files = await listLibraryAudioAsync(<String>[d.path]);
    final List<String> audio = <String>[
      for (final String p in files)
        if (!isKaraokeAudioPath(p)) p,
    ];
    if (audio.isEmpty) continue;
    final Set<String> dirs = <String>{};
    for (final String p in audio) {
      dirs.add(File(p).parent.path);
    }
    for (final String folder in dirs) {
      await warmTrackDnaDir(folder);
    }
    var sum = 0;
    var n = 0;
    for (final String p in audio) {
      final int? lv = peekTrackDna(p)?.energyLevel;
      if (lv != null) {
        sum += lv;
        n++;
      }
    }
    final String name = d.path.replaceAll('\\', '/').split('/').last;
    out.add(
      FolderCardInfo(
        path: d.path,
        name: name,
        count: audio.length,
        meanEnergy: n == 0 ? null : sum / n,
      ),
    );
  }
  return out;
}

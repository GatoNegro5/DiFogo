import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../core/net/safe_download.dart';
import '../core/pipeline_controller.dart' show ytDlpAbrDownloadArgs;
import '../core/track_name_clean.dart' show ytTitleToStem;
import '../core/yt_chunked_download.dart';
import '../djiphone/iphone_library.dart';
import '../src/rust/api/core_dsp.dart' as rust_dsp;
import '../ui/workspaces/yt_workspace.dart'
    show mp3KbpsForSource, moveFile, ytNewPipeChannel, ytNewPipeDownload;

/// 3.1.53 Smart Discovery & Curator Inbox: busca temas del genero activo,
/// los baja como MP3 a una bandeja de revision (fuera de la biblioteca) y
/// guarda los pendientes en `curator_inbox.json`. Nada entra a la carpeta
/// del genero sin la aprobacion explicita del usuario.

/// Solo pruebas: carpeta de la bandeja en %TEMP%.
@visibleForTesting
String? debugCuratorInboxDir;

/// Temas por corrida diaria y tope de pendientes por genero.
const int kDiscoveryDailyCount = 2;
const int kDiscoveryMaxPending = 6;

/// Duracion aceptada de una sugerencia: fuera quedan mixes y cortos.
const Duration kDiscoveryMinDuration = Duration(minutes: 2);
const Duration kDiscoveryMaxDuration = Duration(minutes: 8);

String discoveryInboxDir() {
  final String? o = debugCuratorInboxDir;
  if (o != null) return o;
  final String sep = Platform.pathSeparator;
  if (Platform.isAndroid) return '/storage/emulated/0/Download/GatoMix_Inbox';
  if (Platform.isIOS) {
    return '${Directory(IphoneLibrary.musicRoot).parent.path}${sep}GatoMix_Inbox';
  }
  if (Platform.isWindows) {
    final String? up = Platform.environment['USERPROFILE'];
    return '${up ?? 'C:'}\\Downloads\\GatoMix_Inbox';
  }
  final String? home = Platform.environment['HOME'];
  return '${home ?? ''}/Downloads/GatoMix_Inbox';
}

String discoveryQuery(String genre, int year) =>
    '$genre exitos $year official audio';

String discoveryDay(DateTime t) =>
    '${t.year.toString().padLeft(4, '0')}-'
    '${t.month.toString().padLeft(2, '0')}-'
    '${t.day.toString().padLeft(2, '0')}';

/// Nombre de archivo seguro (sin caracteres prohibidos en Windows/Android).
String discoverySafeName(String stem) {
  final String s = stem.replaceAll(RegExp(r'[\\/:*?"<>|]'), '').trim();
  return s.isEmpty ? 'tema' : s;
}

/// Ruta libre en [dir]: si `nombre.mp3` existe prueba `nombre (2).mp3`...
String discoveryFreePath(String dir, String stem) {
  final String sep = Platform.pathSeparator;
  String p = '$dir$sep$stem.mp3';
  int n = 2;
  while (File(p).existsSync()) {
    p = '$dir$sep$stem ($n).mp3';
    n++;
  }
  return p;
}

class DiscoveryCandidate {
  const DiscoveryCandidate({
    required this.id,
    required this.title,
    this.duration,
  });
  final String id;
  final String title;
  final Duration? duration;
}

typedef DiscoverySearch =
    Future<List<DiscoveryCandidate>> Function(String query);
typedef DiscoveryDownload =
    Future<void> Function(DiscoveryCandidate c, String mp3Path);

enum CuratorStatus { pending, accepted, rejected }

class CuratorEntry {
  const CuratorEntry({
    required this.id,
    required this.title,
    required this.genre,
    required this.file,
    required this.status,
    required this.addedAt,
    this.finalPath,
    this.stationId,
    this.subGenreId,
    this.durationMs,
  });

  final String id;
  final String title;
  final String genre;
  final String file;
  final CuratorStatus status;
  final String addedAt;
  final String? finalPath;

  /// 3.1.68: estacion y sub-genero canonicos que pidieron el tema (null en
  /// temas de antes: se deducen de [genre] o del titulo al agrupar).
  final String? stationId;
  final String? subGenreId;

  /// 3.1.68: duracion del video de origen (null si no se conocia).
  final int? durationMs;

  CuratorEntry copyWith({CuratorStatus? status, String? finalPath}) =>
      CuratorEntry(
        id: id,
        title: title,
        genre: genre,
        file: file,
        status: status ?? this.status,
        addedAt: addedAt,
        finalPath: finalPath ?? this.finalPath,
        stationId: stationId,
        subGenreId: subGenreId,
        durationMs: durationMs,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'title': title,
    'genre': genre,
    'file': file,
    'status': status.name,
    'addedAt': addedAt,
    if (finalPath != null) 'finalPath': finalPath,
    if (stationId != null) 'stationId': stationId,
    if (subGenreId != null) 'subGenreId': subGenreId,
    if (durationMs != null) 'durationMs': durationMs,
  };

  static CuratorEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    final Object? file = raw['file'];
    if (id is! String || file is! String) return null;
    final CuratorStatus st = CuratorStatus.values.firstWhere(
      (CuratorStatus s) => s.name == raw['status'],
      orElse: () => CuratorStatus.pending,
    );
    return CuratorEntry(
      id: id,
      title: raw['title'] is String ? raw['title'] as String : id,
      genre: raw['genre'] is String ? raw['genre'] as String : '',
      file: file,
      status: st,
      addedAt: raw['addedAt'] is String ? raw['addedAt'] as String : '',
      finalPath: raw['finalPath'] is String ? raw['finalPath'] as String : null,
      stationId: raw['stationId'] is String ? raw['stationId'] as String : null,
      subGenreId: raw['subGenreId'] is String
          ? raw['subGenreId'] as String
          : null,
      durationMs: raw['durationMs'] is int ? raw['durationMs'] as int : null,
    );
  }
}

class CuratorInboxData {
  const CuratorInboxData({required this.entries, required this.lastRun});
  final List<CuratorEntry> entries;

  /// Genero -> dia (yyyy-MM-dd) de la ultima corrida diaria.
  final Map<String, String> lastRun;

  static const CuratorInboxData empty = CuratorInboxData(
    entries: <CuratorEntry>[],
    lastRun: <String, String>{},
  );
}

/// `curator_inbox.json` dentro de la bandeja. Escritura atomica (.tmp).
class CuratorInboxStore {
  CuratorInboxStore(this.dir);
  final String dir;

  String get path => '$dir${Platform.pathSeparator}curator_inbox.json';

  CuratorInboxData load() {
    try {
      final File f = File(path);
      if (!f.existsSync()) return CuratorInboxData.empty;
      final Object? raw = jsonDecode(f.readAsStringSync());
      if (raw is! Map) return CuratorInboxData.empty;
      final List<CuratorEntry> entries = <CuratorEntry>[
        if (raw['entries'] is List)
          for (final Object? e in raw['entries'] as List)
            ?CuratorEntry.fromJson(e),
      ];
      final Map<String, String> last = <String, String>{};
      final Object? lr = raw['lastRun'];
      if (lr is Map) {
        lr.forEach((Object? k, Object? v) {
          if (k is String && v is String) last[k] = v;
        });
      }
      return CuratorInboxData(entries: entries, lastRun: last);
    } catch (e) {
      debugPrint('[CURATOR] json ilegible: $e');
      return CuratorInboxData.empty;
    }
  }

  void save(CuratorInboxData d) {
    Directory(dir).createSync(recursive: true);
    final File tmp = File('$path.tmp');
    tmp.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
        'version': 1,
        'lastRun': d.lastRun,
        'entries': <Map<String, dynamic>>[
          for (final CuratorEntry e in d.entries) e.toJson(),
        ],
      }),
    );
    if (File(path).existsSync()) File(path).deleteSync();
    tmp.renameSync(path);
  }
}

class SmartDiscoveryService {
  SmartDiscoveryService({
    DiscoverySearch? search,
    DiscoveryDownload? download,
    String? inboxDir,
    DateTime Function()? now,
  }) : search = search ?? ytDiscoverySearch,
       download = download ?? ytDiscoveryDownload,
       inboxDir = inboxDir ?? discoveryInboxDir(),
       now = now ?? DateTime.now;

  final DiscoverySearch search;
  final DiscoveryDownload download;
  final String inboxDir;
  final DateTime Function() now;

  /// Busca y baja hasta [count] temas nuevos de [genre] a la bandeja.
  /// Salta ids ya vistos (pendientes, aceptados o descartados) y temas cuyo
  /// nombre ya existe en [genreDir]. Un fallo de descarga no corta el resto.
  Future<List<CuratorEntry>> discover({
    required String genre,
    required int count,
    required Set<String> knownIds,
    String? genreDir,
    String? query,
    String? stationId,
    String? subGenreId,
  }) async {
    if (count <= 0) return const <CuratorEntry>[];
    final List<DiscoveryCandidate> found = await search(
      discoveryQuery(query ?? genre, now().year),
    );
    Directory(inboxDir).createSync(recursive: true);
    final List<CuratorEntry> out = <CuratorEntry>[];
    for (final DiscoveryCandidate c in found) {
      if (out.length >= count) break;
      if (knownIds.contains(c.id)) continue;
      final Duration? d = c.duration;
      if (d != null &&
          (d < kDiscoveryMinDuration || d > kDiscoveryMaxDuration)) {
        continue;
      }
      final String stem = discoverySafeName(ytTitleToStem(c.title));
      if (genreDir != null &&
          File('$genreDir${Platform.pathSeparator}$stem.mp3').existsSync()) {
        continue;
      }
      final String target = discoveryFreePath(inboxDir, stem);
      try {
        await download(c, target);
        if (!File(target).existsSync() || File(target).lengthSync() == 0) {
          throw Exception('archivo vacio');
        }
      } catch (e) {
        debugPrint('[CURATOR] fallo al bajar ${c.id}: $e');
        try {
          if (File(target).existsSync()) File(target).deleteSync();
        } catch (_) {}
        continue;
      }
      out.add(
        CuratorEntry(
          id: c.id,
          title: stem,
          genre: genre,
          file: target,
          status: CuratorStatus.pending,
          addedAt: now().toIso8601String(),
          stationId: stationId,
          subGenreId: subGenreId,
          durationMs: d?.inMilliseconds,
        ),
      );
    }
    return out;
  }
}

/// Busqueda real en YouTube (misma libreria que el modulo YT).
Future<List<DiscoveryCandidate>> ytDiscoverySearch(String query) async {
  final YoutubeExplode yt = YoutubeExplode();
  try {
    final VideoSearchList list = await yt.search.search(query);
    return <DiscoveryCandidate>[
      for (final Video v in list.take(15))
        DiscoveryCandidate(
          id: v.id.value,
          title: v.title,
          duration: v.duration,
        ),
    ];
  } finally {
    yt.close();
  }
}

Future<String> _ytDlpBinary() async {
  if (Platform.isMacOS || Platform.isLinux) {
    for (final String p in <String>[
      '/opt/homebrew/bin/yt-dlp',
      '/usr/local/bin/yt-dlp',
    ]) {
      if (File(p).existsSync()) return p;
    }
    return 'yt-dlp';
  }
  final String tempDir = Directory.systemTemp.path;
  for (final String p in <String>[
    '${Directory.current.path}\\yt-dlp.exe',
    '${File(Platform.resolvedExecutable).parent.path}\\yt-dlp.exe',
    '${Directory.current.path}\\windows\\yt-dlp.exe',
    '$tempDir\\yt-dlp.exe',
  ]) {
    if (File(p).existsSync()) return p;
  }
  final String target = '$tempDir\\yt-dlp.exe';
  await downloadFileRobust(
    'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe',
    target,
  );
  return target;
}

/// Descarga real sin pantalla: mismo camino por plataforma que el modulo YT
/// (NewPipe en Android, trozos en iOS, yt-dlp en escritorio) y MP3 con el
/// codificador Rust/LAME, sin masterizar.
Future<void> ytDiscoveryDownload(DiscoveryCandidate c, String mp3Path) async {
  final String sep = Platform.pathSeparator;
  final String raw =
      '${Directory.systemTemp.path}${sep}gmx_discovery_${c.id}.m4a';
  final String tmpMp3 = '$raw.mp3';
  if (File(raw).existsSync()) File(raw).deleteSync();
  int kbps = 0;
  try {
    if (Platform.isAndroid) {
      final Object? info = await ytNewPipeChannel.invokeMethod(
        'getAudioUrl',
        <String, Object?>{'videoId': c.id},
      );
      if (info is Map && info['averageBitrate'] is num) {
        kbps = (info['averageBitrate'] as num).round();
      }
      await ytNewPipeDownload(videoId: c.id, destPath: raw);
    } else if (Platform.isIOS) {
      final YoutubeExplode yt = YoutubeExplode();
      try {
        final StreamManifest m = await yt.videos.streamsClient.getManifest(
          VideoId(c.id),
        );
        final List<AudioOnlyStreamInfo> m4a = m.audioOnly
            .where(
              (AudioOnlyStreamInfo s) => s.container == StreamContainer.mp4,
            )
            .toList();
        if (m4a.isEmpty) throw Exception('sin stream AAC/M4A');
        m4a.sort(
          (AudioOnlyStreamInfo a, AudioOnlyStreamInfo b) =>
              b.bitrate.compareTo(a.bitrate),
        );
        kbps = (m4a.first.bitrate.bitsPerSecond / 1000).round();
        await ytChunkedDownload(
          url: m4a.first.url,
          totalBytes: m4a.first.size.totalBytes,
          outPath: raw,
        );
      } finally {
        yt.close();
      }
    } else {
      final ProcessResult r = await Process.run(
        await _ytDlpBinary(),
        ytDlpAbrDownloadArgs(
          output: raw,
          url: 'https://www.youtube.com/watch?v=${c.id}',
        ),
      );
      if (r.exitCode != 0 || !File(raw).existsSync()) {
        throw Exception('yt-dlp: ${r.stderr}');
      }
      final List<String> words = '${r.stdout}'
          .split(RegExp(r'\s+'))
          .where((String s) => s.trim().isNotEmpty)
          .toList();
      if (words.isNotEmpty) kbps = double.tryParse(words.last)?.round() ?? 0;
    }
    if (!File(raw).existsSync() || File(raw).lengthSync() == 0) {
      throw Exception('audio vacio');
    }
    await rust_dsp.encodeToMp3(
      inputPath: raw,
      outputPath: tmpMp3,
      bitrateKbps: mp3KbpsForSource(kbps),
      master: false,
    );
    moveFile(tmpMp3, mp3Path);
  } on PlatformException catch (e) {
    throw Exception(e.message ?? e.code);
  } finally {
    for (final String p in <String>[raw, tmpMp3]) {
      try {
        if (File(p).existsSync()) File(p).deleteSync();
      } catch (_) {}
    }
  }
}

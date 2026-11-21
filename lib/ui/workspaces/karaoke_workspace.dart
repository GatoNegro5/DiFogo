import 'dart:io';
import '../widgets/approx_lyric_icon.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/lyric_files.dart';
import '../../core/library_guard.dart' show lrcReadFile;
import '../../services/tv_sync_server.dart';
import '../../services/tv_adb_deployment_service.dart';
import '../../services/tv_apk_cache.dart';
import 'lan_sync_workspace.dart' show pickLanIpv4;

/// 3.2.24: `.lrc` de Karaoke con la misma cascada que Mix con Letra
/// ([lrcReadFile]): espejo local de letras, espejo heredado y por ultimo
/// el `.lrc` junto al audio.
File karaokeLrcFile(String audioPath) => lrcReadFile(
  audioPath,
  audioPath.replaceAll(RegExp(r'\.mp3$', caseSensitive: false), '.lrc'),
);

/// 3.2.24: eleccion `_K` vs original con I/O asincrono (antes existsSync y
/// lengthSync en el hilo de UI). Mismas reglas: `_K` de al menos 256 KB y
/// no menor al 45 por ciento del original; si no, el original.
Future<String> resolveKaraokeAudio(String originalPath) async {
  final String karaokePath = originalPath.replaceAll(
    RegExp(r'\.mp3$', caseSensitive: false),
    '_K.mp3',
  );
  try {
    final File instrumental = File(karaokePath);
    if (!await instrumental.exists()) return originalPath;
    final int karaokeBytes = await instrumental.length();
    if (karaokeBytes < 256 * 1024) return originalPath;
    final File original = File(originalPath);
    if (await original.exists()) {
      final int originalBytes = await original.length();
      if (originalBytes > 0 && karaokeBytes < (originalBytes * 0.45).round()) {
        return originalPath;
      }
    }
    return karaokePath;
  } catch (_) {
    return originalPath;
  }
}

// ----------------------------------------------------------------------
// 1. SINGLETON (Puente de Memoria RAM entre el Servidor REST y la UI)
// ----------------------------------------------------------------------
class KaraokeCore {
  static final KaraokeCore _instance = KaraokeCore._internal();
  factory KaraokeCore() => _instance;
  KaraokeCore._internal();

  final ValueNotifier<List<Map<String, dynamic>>> queueNotifier = ValueNotifier(
    [],
  );
  final ValueNotifier<Map<String, int>> votesNotifier = ValueNotifier({
    '🔥': 0,
    '💩': 0,
    '👏': 0,
  });
  final ValueNotifier<Map<String, String>> currentSingerNotifier =
      ValueNotifier({});
  final ValueNotifier<bool> sessionActive = ValueNotifier(false);
  final ValueNotifier<Map<String, dynamic>> scoreboardNotifier = ValueNotifier(
    {},
  );
  final ValueNotifier<bool> pausedNotifier = ValueNotifier(false);
  DateTime? voteDeadline;

  Map<String, dynamic> publicState() {
    final current = currentSingerNotifier.value;
    final board = scoreboardNotifier.value;
    final now = DateTime.now();
    final voting = voteDeadline != null && now.isBefore(voteDeadline!);
    final phase = voting
        ? 'voting'
        : (sessionActive.value && current.isNotEmpty ? 'playing' : 'idle');
    final singer = voting ? '${board['user'] ?? ''}' : current['user'] ?? '';
    final song = voting ? '${board['song'] ?? ''}' : current['song'] ?? '';
    final votes = voting
        ? Map<String, int>.from(board['votes'] as Map? ?? {})
        : Map<String, int>.from(votesNotifier.value);
    final left = voting
        ? voteDeadline!.difference(now).inSeconds.clamp(0, 10)
        : 0;
    return {
      'phase': phase,
      'singer': singer,
      'track': song
          .replaceAll('\\', '/')
          .split('/')
          .last
          .replaceAll(RegExp(r'(_K)?\.mp3$', caseSensitive: false), ''),
      'votes': votes,
      'seconds_left': left,
    };
  }

  void addToQueue(String user, String songPath) {
    final currentQueue = List<Map<String, dynamic>>.from(queueNotifier.value);
    currentQueue.add({'user': user, 'song': songPath});
    queueNotifier.value = currentQueue;
  }

  void addVote(String type) {
    if (votesNotifier.value.containsKey(type)) {
      final currentVotes = Map<String, int>.from(votesNotifier.value);
      currentVotes[type] = currentVotes[type]! + 1;
      votesNotifier.value = currentVotes;
      if (voteDeadline != null && scoreboardNotifier.value.isNotEmpty) {
        final board = Map<String, dynamic>.from(scoreboardNotifier.value);
        board['votes'] = currentVotes;
        scoreboardNotifier.value = board;
      }
    }
  }

  Map<String, dynamic>? peekNext() {
    if (queueNotifier.value.isEmpty) return null;
    return Map<String, dynamic>.from(queueNotifier.value.first);
  }

  void removeAt(int index) {
    final currentQueue = List<Map<String, dynamic>>.from(queueNotifier.value);
    if (index < 0 || index >= currentQueue.length) return;
    currentQueue.removeAt(index);
    queueNotifier.value = currentQueue;
  }

  void startSession() {
    sessionActive.value = true;
    pausedNotifier.value = false;
    voteDeadline = null;
    popNextSong();
  }

  void popNextSong() {
    final currentQueue = List<Map<String, dynamic>>.from(queueNotifier.value);
    voteDeadline = null;
    scoreboardNotifier.value = {};
    if (currentQueue.isNotEmpty) {
      final next = currentQueue.removeAt(0);
      currentSingerNotifier.value = {
        'user': next['user'],
        'song': next['song'],
      };
      queueNotifier.value = currentQueue;
      votesNotifier.value = {'🔥': 0, '💩': 0, '👏': 0};
    } else {
      currentSingerNotifier.value = {};
    }
  }

  Map<String, dynamic> freezeScoreboard() {
    final current = currentSingerNotifier.value;
    final board = <String, dynamic>{
      'user': current['user'] ?? '',
      'song': current['song'] ?? '',
      'votes': Map<String, int>.from(votesNotifier.value),
    };
    scoreboardNotifier.value = board;
    voteDeadline = DateTime.now().add(const Duration(seconds: 8));
    return board;
  }

  void endSession() {
    sessionActive.value = false;
    pausedNotifier.value = false;
    voteDeadline = null;
    queueNotifier.value = [];
    currentSingerNotifier.value = {};
    votesNotifier.value = {'🔥': 0, '💩': 0, '👏': 0};
    scoreboardNotifier.value = {};
  }
}

// ----------------------------------------------------------------------
// 2. MÓDULO UI: KARAOKE WORKSPACE (Inyectado con Telemetría TV)
// ----------------------------------------------------------------------
class KaraokeWorkspace extends ConsumerStatefulWidget {
  const KaraokeWorkspace({super.key});

  @override
  ConsumerState<KaraokeWorkspace> createState() => _KaraokeWorkspaceState();
}

class _KaraokeWorkspaceState extends ConsumerState<KaraokeWorkspace> {
  final ScrollController _lrcScrollController = ScrollController();
  final TvAdbDeploymentService _tvDeploymentService = TvAdbDeploymentService();
  Map<Duration, String> _currentLyrics = {};
  int _countdown = 0;

  String _tvSyncUrl = "Escaneando red...";
  String _hostIp = '127.0.0.1';
  Timer? _scoreboardTimer;
  Timer? _lyricClock;
  Timer? _preloadTimer;
  bool _advancing = false;
  bool _showLaptopStage = false;
  int _lastUiPosMs = 0;
  int _activeLyricIndex = 0;
  List<Duration> _lyricKeys = const [];

  /// 3.2.26: ultima posicion real de la TV (TV_POS) y aviso de senal.
  StreamSubscription<TvPosition>? _tvPosSub;
  TvPosition? _tvPos;
  bool _tvSignalLost = false;

  @override
  void initState() {
    super.initState();
    // El nodo WS :55056 es lazy. Sin esta lectura la TV no tiene a quién
    // conectarse hasta que suene la primera pista.
    ref.read(tvSyncProvider);
    unawaited(_ensureTvFirewallRule());
    _fetchTvSyncUrl();

    KaraokeCore().currentSingerNotifier.addListener(_onSingerChanged);
    _lrcSub = lrcChanges.listen(_onLrcChanged);
    KaraokeCore().queueNotifier.addListener(_onQueueChanged);
    KaraokeCore().votesNotifier.addListener(_pushStageState);
    ref.read(tvSyncProvider).onTvMessage = _onTvMessage;
    ref.read(tvSyncProvider).onTvJoined = _pushStageState;
    _tvPosSub = ref.read(tvSyncProvider).positions.listen(_onTvPosition);
  }

  /// Abre el puerto del nodo TV en Windows Defender. La regla de LAN Sync solo
  /// cubre :55055; sin esta, la Google TV no completa el upgrade WebSocket.
  Future<void> _ensureTvFirewallRule() async {
    if (!Platform.isWindows) return;
    // 3.1.76: regla DiFogo; las viejas (marca anterior y GatoMix) se borran.
    // La regla es por puerto, no por exe: el cambio a difogo.exe no la rompe.
    const oldRules = <String>[
      'DJ'
          'Studio'
          ' TV Sync',
      'GatoMix TV Sync',
    ];
    const ruleName = 'DiFogo TV Sync';
    try {
      final List<String> hadOld = <String>[];
      for (final String oldRule in oldRules) {
        final probeOld = await Process.run('powershell', [
          '-Command',
          'Get-NetFirewallRule -DisplayName "$oldRule" '
              '-ErrorAction SilentlyContinue',
        ]);
        if (probeOld.stdout.toString().contains(oldRule)) hadOld.add(oldRule);
      }
      final probe = await Process.run('powershell', [
        '-Command',
        'Get-NetFirewallRule -DisplayName "$ruleName" '
            '-ErrorAction SilentlyContinue',
      ]);
      final hasNew = probe.stdout.toString().contains(ruleName);
      if (hadOld.isEmpty && hasNew) return;

      final script = StringBuffer();
      for (final String oldRule in hadOld) {
        script.write(
          "Remove-NetFirewallRule -DisplayName '$oldRule' -ErrorAction SilentlyContinue; ",
        );
      }
      if (!hasNew) {
        script.write(
          "New-NetFirewallRule -DisplayName '$ruleName' -Direction Inbound "
          '-LocalPort 55056 -Protocol TCP -Action Allow',
        );
      }
      await Process.run('powershell', [
        '-Command',
        'Start-Process powershell -Verb runAs -WindowStyle Hidden '
            '-ArgumentList "-Command ${script.toString().trim()}"',
      ]);
    } catch (e) {
      debugPrint('🔴 [KARAOKE TV] Firewall :55056 $e');
    }
  }

  Future<void> _fetchTvSyncUrl() async {
    String hostIp = '127.0.0.1';
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      if (interfaces.isNotEmpty) {
        hostIp = interfaces.first.addresses.first.address;
      }
    } catch (e) {
      debugPrint("🔴 Error obteniendo IP para TV Sync: $e");
    }
    if (mounted) {
      setState(() {
        _hostIp = hostIp;
        _tvSyncUrl = 'ws://$hostIp:55056';
      });
      _pushStageState();
    }
  }

  void _onPlaybackTick(Duration position) {
    if (!mounted || _currentLyrics.isEmpty) return;
    final posMs = position.inMilliseconds;
    if ((posMs - _lastUiPosMs).abs() < 90) return;
    _lastUiPosMs = posMs;

    final keys = _lyricKeys;
    if (keys.isEmpty) return;
    final nextIdx = keys.indexWhere((k) => k > position);
    var newIndex = nextIdx == -1 ? keys.length - 1 : nextIdx - 1;
    if (newIndex < 0) newIndex = 0;

    var newCountdown = 0;
    if (nextIdx != -1) {
      final nextTime = keys[nextIdx];
      final diff = nextTime - position;
      var isLargeGap = nextIdx == 0;
      if (!isLargeGap && nextIdx > 0) {
        final prevTime = keys[nextIdx - 1];
        if ((nextTime - prevTime).inSeconds > 5 &&
            (position - prevTime).inSeconds > 1) {
          isLargeGap = true;
        }
      }
      if (isLargeGap && diff.inSeconds <= 4 && diff.inSeconds > 0) {
        newCountdown = diff.inSeconds;
      }
    }

    if (newIndex == _activeLyricIndex && newCountdown == _countdown) return;
    final scroll = newIndex != _activeLyricIndex;
    setState(() {
      _activeLyricIndex = newIndex;
      _countdown = newCountdown;
    });
    if (scroll) _syncLyricsScroll();
  }

  void _stopLyricClock() {
    _lyricClock?.cancel();
    _lyricClock = null;
  }

  /// 3.2.26: la letra de la laptop sigue la posicion REAL de la TV (TV_POS
  /// cada 500 ms) e interpola cada 100 ms mientras suena. Antes un reloj
  /// propio avanzaba aunque la TV no sonara; ahora sin TV_POS (o sin senal
  /// en [kTvPosTimeout]) la letra se congela con aviso 'Sin señal de TV'.
  void _onTvPosition(TvPosition position) {
    if (!mounted) return;
    _tvPos = position;
    if (_tvSignalLost) setState(() => _tvSignalLost = false);
    _driveLyrics();
  }

  void _driveLyrics() {
    final TvPosition? p = _tvPos;
    if (p == null || !_showLaptopStage || _lyricKeys.isEmpty) {
      _stopLyricClock();
      return;
    }
    _onPlaybackTick(Duration(milliseconds: p.positionMs));
    if (!p.playing) {
      _stopLyricClock();
      return;
    }
    _lyricClock ??= Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _interpolateLyrics(),
    );
  }

  void _interpolateLyrics() {
    final TvPosition? p = _tvPos;
    final int? ms = p?.estimateMs(DateTime.now());
    if (ms == null) {
      _stopLyricClock();
      if (mounted && p != null) setState(() => _tvSignalLost = true);
      return;
    }
    _onPlaybackTick(Duration(milliseconds: ms));
  }

  /// 3.2.26: PIN que la TV debe escribir (---- si el nodo no levanto).
  String get _tvPin {
    try {
      final String pin = ref.read(tvSyncProvider).sessionPin;
      return pin.isEmpty ? '----' : pin;
    } catch (_) {
      return '----';
    }
  }

  String get _qrUrl => 'http://$_hostIp:55055/karaoke';

  void _pushStageState() {
    try {
      final current = KaraokeCore().currentSingerNotifier.value;
      ref
          .read(tvSyncProvider)
          .broadcastStageState(
            queue: KaraokeCore().queueNotifier.value
                .map(
                  (item) => {
                    'user': '${item['user'] ?? ''}',
                    'song': _displayName('${item['song']}'),
                  },
                )
                .toList(),
            current: {
              'user': current['user'] ?? '',
              'song': current.isEmpty ? '' : _displayName('${current['song']}'),
            },
            votes: Map<String, int>.from(KaraokeCore().votesNotifier.value),
            sessionActive: KaraokeCore().sessionActive.value,
            paused: KaraokeCore().pausedNotifier.value,
            qrUrl: _qrUrl,
          );
    } catch (_) {}
  }

  void _setPaused(bool paused) {
    KaraokeCore().pausedNotifier.value = paused;
    // 3.2.26: la letra se reanuda con el TV_POS real de la TV.
    if (paused) {
      _stopLyricClock();
      try {
        ref.read(tvSyncProvider).broadcastEdgePause();
      } catch (_) {}
    } else {
      try {
        ref.read(tvSyncProvider).broadcastEdgeResume();
      } catch (_) {}
    }
    _pushStageState();
  }

  String _displayName(String path) {
    return path
        .replaceAll('\\', '/')
        .split('/')
        .last
        .replaceAll(RegExp(r'(_K)?\.mp3$', caseSensitive: false), '');
  }

  Map<String, String> _edgeUrls(String audioPath, String originalPath) {
    // 3.2.24: la TV pide el .lrc resuelto (espejo de letras o junto al mp3).
    final lrcPath = karaokeLrcFile(originalPath).path;
    return {
      'mp3':
          'http://$_hostIp:55056/karaoke/audio?p=${Uri.encodeQueryComponent(audioPath)}',
      'lrc':
          'http://$_hostIp:55056/karaoke/lrc?p=${Uri.encodeQueryComponent(lrcPath)}',
      'track': originalPath.replaceAll('\\', '/').split('/').last,
    };
  }

  void _dispatchEdgeExecute({
    required String audioPath,
    required String originalPath,
    required String singer,
  }) {
    try {
      final urls = _edgeUrls(audioPath, originalPath);
      ref
          .read(tvSyncProvider)
          .broadcastEdgeExecute(
            mp3Url: urls['mp3']!,
            lrcUrl: urls['lrc']!,
            trackName: urls['track']!,
            singer: singer,
          );
    } catch (e) {
      debugPrint('🔴 [KARAOKE TV] EDGE_EXECUTE: $e');
    }
  }

  void _preloadNext() {
    _preloadTimer?.cancel();
    final next = KaraokeCore().peekNext();
    if (next == null) return;
    _preloadTimer = Timer(const Duration(seconds: 15), () async {
      if (!mounted || !KaraokeCore().sessionActive.value) return;
      final queued = KaraokeCore().peekNext();
      if (queued == null) return;
      final originalPath = '${queued['song']}';
      final String audioPath = await resolveKaraokeAudio(originalPath);
      if (!mounted || !KaraokeCore().sessionActive.value) return;
      final urls = _edgeUrls(audioPath, originalPath);
      try {
        ref
            .read(tvSyncProvider)
            .broadcastEdgePreload(
              mp3Url: urls['mp3']!,
              lrcUrl: urls['lrc']!,
              trackName: urls['track']!,
              singer: '${queued['user'] ?? ''}',
            );
      } catch (e) {
        debugPrint('🔴 [KARAOKE TV] EDGE_PRELOAD: $e');
      }
    });
  }

  void _onQueueChanged() {
    _pushStageState();
    if (!mounted || !KaraokeCore().sessionActive.value || _advancing) return;
    if (KaraokeCore().currentSingerNotifier.value.isEmpty) {
      if (KaraokeCore().peekNext() != null) KaraokeCore().popNextSong();
      return;
    }
    _preloadNext();
  }

  void _onTvMessage(Map<String, dynamic> message) {
    switch (message['type']) {
      case 'TV_TRACK_ENDED':
        unawaited(_onTrackFinished());
      case 'TV_SESSION_END':
        unawaited(_endSession());
      case 'TV_PAUSE':
        KaraokeCore().pausedNotifier.value = true;
        _stopLyricClock();
        _pushStageState();
      case 'TV_RESUME':
        KaraokeCore().pausedNotifier.value = false;
        _pushStageState();
      case 'TV_SKIP':
        unawaited(_skipTrack());
      case 'TV_REMOVE':
        final index = int.tryParse('${message['index']}') ?? -1;
        KaraokeCore().removeAt(index);
    }
  }

  Future<void> _skipTrack() async {
    if (!mounted || !KaraokeCore().sessionActive.value) return;
    if (_advancing) {
      _scoreboardTimer?.cancel();
      _advancing = false;
      if (KaraokeCore().peekNext() != null) {
        KaraokeCore().popNextSong();
        return;
      }
      KaraokeCore().currentSingerNotifier.value = {};
      KaraokeCore().scoreboardNotifier.value = {};
      try {
        ref.read(tvSyncProvider).broadcastEdgeStop();
      } catch (_) {}
      _pushStageState();
      return;
    }
    await _onTrackFinished();
  }

  Future<void> _onTrackFinished() async {
    if (!mounted || _advancing) return;
    if (KaraokeCore().currentSingerNotifier.value.isEmpty) return;
    if (!KaraokeCore().sessionActive.value) return;

    _advancing = true;
    _stopLyricClock();
    _preloadTimer?.cancel();
    _tvPos = null;
    final board = KaraokeCore().freezeScoreboard();
    final next = KaraokeCore().peekNext();
    try {
      ref
          .read(tvSyncProvider)
          .broadcastScoreboard(
            singer: '${board['user']}',
            trackName: _displayName('${board['song']}'),
            votes: Map<String, int>.from(board['votes'] as Map),
            nextSinger: next == null ? null : '${next['user']}',
            nextTrack: next == null ? null : _displayName('${next['song']}'),
          );
    } catch (_) {}

    if (mounted) {
      setState(() {
        _currentLyrics = {};
        _lyricKeys = const [];
        _countdown = 0;
      });
    }

    _scoreboardTimer?.cancel();
    _scoreboardTimer = Timer(const Duration(seconds: 8), () {
      _advancing = false;
      if (!mounted || !KaraokeCore().sessionActive.value) return;
      if (KaraokeCore().peekNext() != null) {
        KaraokeCore().popNextSong();
        return;
      }
      KaraokeCore().currentSingerNotifier.value = {};
      KaraokeCore().scoreboardNotifier.value = {};
      try {
        ref.read(tvSyncProvider).broadcastEdgeStop();
      } catch (_) {}
      _pushStageState();
    });
  }

  Future<void> _endSession() async {
    _scoreboardTimer?.cancel();
    _preloadTimer?.cancel();
    _stopLyricClock();
    _tvPos = null;
    _advancing = false;
    KaraokeCore().endSession();
    try {
      ref.read(tvSyncProvider).broadcastSessionEnd();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _currentLyrics = {};
      _lyricKeys = const [];
      _countdown = 0;
    });
  }

  @override
  void dispose() {
    _scoreboardTimer?.cancel();
    _lrcSub?.cancel();
    _lyricClock?.cancel();
    _tvPosSub?.cancel();
    _preloadTimer?.cancel();
    KaraokeCore().currentSingerNotifier.removeListener(_onSingerChanged);
    KaraokeCore().queueNotifier.removeListener(_onQueueChanged);
    KaraokeCore().votesNotifier.removeListener(_pushStageState);
    try {
      ref.read(tvSyncProvider).onTvMessage = null;
      ref.read(tvSyncProvider).onTvJoined = null;
    } catch (_) {}
    _lrcScrollController.dispose();
    super.dispose();
  }

  StreamSubscription<String>? _lrcSub;

  /// 3.2.24: turno del ultimo cambio de cantante; un despacho viejo que
  /// termina tarde no pisa al nuevo.
  int _dispatchSeq = 0;

  Future<void> _dispatchResolved({
    required int seq,
    required String originalPath,
    required String singer,
  }) async {
    final String audioPath = await resolveKaraokeAudio(originalPath);
    if (!mounted || seq != _dispatchSeq) return;
    _dispatchEdgeExecute(
      audioPath: audioPath,
      originalPath: originalPath,
      singer: singer,
    );
  }

  /// Buscar letra / Deshacer / Restaurar cambiaron el `.lrc`: si es el tema
  /// abierto, se relee.
  void _onLrcChanged(String audioPath) {
    if (!mounted) return;
    final String? song = KaraokeCore().currentSingerNotifier.value['song'];
    if (sameAudioPath(song, audioPath)) _loadLrc(song!);
  }

  void _onSingerChanged() {
    final songData = KaraokeCore().currentSingerNotifier.value;
    if (songData.containsKey('song')) {
      final originalPath = songData['song']!;
      _loadLrc(originalPath);

      // 3.2.24: _K vs original se resuelve sin I/O sincrono en la UI.
      unawaited(
        _dispatchResolved(
          seq: ++_dispatchSeq,
          originalPath: originalPath,
          singer: songData['user'] ?? '',
        ),
      );

      _tvPos = null;
      KaraokeCore().pausedNotifier.value = false;
      // 3.2.26: la letra espera el TV_POS de la pista nueva.
      _stopLyricClock();
      _preloadNext();
      _pushStageState();
    } else {
      // 3.2.24: sin cantante, un despacho pendiente ya no sale.
      _dispatchSeq++;
      try {
        ref.read(tvSyncProvider).broadcastEdgeStop();
      } catch (_) {}
      _stopLyricClock();
      _preloadTimer?.cancel();
      _tvPos = null;
      setState(() {
        _currentLyrics = {};
        _lyricKeys = const [];
        _countdown = 0;
      });
      _pushStageState();
    }
  }

  void _loadLrc(String mp3Path) {
    // 3.2.24: misma cascada que Mix con Letra (espejo, heredado, junto).
    final file = karaokeLrcFile(mp3Path);

    if (file.existsSync()) {
      final rawLrcContent = file.readAsStringSync();
      final Map<Duration, String> lyrics = {};
      final RegExp timeRegex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');

      for (var line in rawLrcContent.split('\n')) {
        final match = timeRegex.firstMatch(line);
        if (match != null) {
          final int min = int.parse(match.group(1)!);
          final int sec = int.parse(match.group(2)!);
          final String msStr = match.group(3)!;
          final int ms = msStr.length == 2
              ? int.parse(msStr) * 10
              : int.parse(msStr);
          final text = match.group(4)!.trim();
          if (text.isNotEmpty) {
            lyrics[Duration(minutes: min, seconds: sec, milliseconds: ms)] =
                text;
          }
        }
      }
      setState(() {
        _currentLyrics = lyrics;
        _lyricKeys = lyrics.keys.toList();
        _activeLyricIndex = 0;
        _lastUiPosMs = 0;
      });
    } else {
      setState(() {
        _currentLyrics = {
          Duration.zero: "No hay letra (.lrc) disponible para esta pista.",
        };
        _lyricKeys = const [Duration.zero];
        _activeLyricIndex = 0;
        _lastUiPosMs = 0;
      });
    }
  }

  void _syncLyricsScroll() {
    if (_currentLyrics.isEmpty || !_lrcScrollController.hasClients) return;
    const itemHeight = 80.0;
    double targetOffset = 0.0;
    try {
      final viewportHeight = _lrcScrollController.position.viewportDimension;
      targetOffset =
          (_activeLyricIndex * itemHeight) -
          (viewportHeight / 2) +
          (itemHeight / 2);
      if (targetOffset < 0) targetOffset = 0;
      final maxScroll = _lrcScrollController.position.maxScrollExtent;
      if (targetOffset > maxScroll) targetOffset = maxScroll;
    } catch (_) {
      targetOffset = _activeLyricIndex * itemHeight;
    }

    _lrcScrollController.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  Future<void> _showQrModal(BuildContext context) async {
    String hostIp = '127.0.0.1';
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      if (interfaces.isNotEmpty) {
        hostIp = interfaces.first.addresses.first.address;
      }
    } catch (_) {}
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final String karaokeUrl = 'http://$hostIp:55055/karaoke?v=$timestamp';
    if (!context.mounted) return;

    showDialog(
      context: context,
      builder: (BuildContext ctx) {
        return Dialog(
          backgroundColor: const Color(0xFF101010),
          shape: RoundedRectangleBorder(
            side: const BorderSide(color: Color(0xFF00FFFF), width: 2),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Padding(
            padding: const EdgeInsets.all(25.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  "🎤 ESCANEA PARA CANTAR",
                  style: TextStyle(
                    color: Color(0xFF39FF14),
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 20),
                Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(10),
                  height: 250,
                  width: 250,
                  child: QrImageView(
                    data: karaokeUrl,
                    version: QrVersions.auto,
                    size: 230.0,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  karaokeUrl,
                  style: const TextStyle(
                    color: Color(0xFF00FFFF),
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF39FF14),
                    foregroundColor: Colors.black,
                  ),
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text(
                    "CERRAR",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showTvInstaller() async {
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) return;
    // 3.2.25: asistente sin ADB (recomendado); el flujo ADB queda adentro
    // como opcion avanzada.
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => TvInstallWizardDialog(
        server: ref.read(tvSyncProvider),
        adbService: _tvDeploymentService,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: Row(
        children: [
          if (_showLaptopStage) ...[
            Expanded(flex: 5, child: _buildLaptopStage()),
            const VerticalDivider(width: 1, color: Colors.white10),
          ],
          Expanded(
            flex: 3,
            child: Container(
              color: const Color(0xFF101010),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(15),
                    color: const Color(0xFF1A1A1A),
                    width: double.infinity,
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Text(
                              "📺 NODO TV (WEBSOCKET)",
                              style: TextStyle(
                                color: Color(0xFFB026FF),
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 2,
                              ),
                            ),
                            const SizedBox(width: 12),
                            IconButton(
                              onPressed: _showTvInstaller,
                              icon: const Icon(
                                Icons.search,
                                color: Color(0xFF39FF14),
                              ),
                              tooltip: 'Instalar GatoMix TV',
                            ),
                            IconButton(
                              onPressed: () {
                                setState(
                                  () => _showLaptopStage = !_showLaptopStage,
                                );
                                _driveLyrics();
                              },
                              icon: Icon(
                                _showLaptopStage
                                    ? Icons.tv
                                    : Icons.monitor_outlined,
                                color: _showLaptopStage
                                    ? const Color(0xFF00FFFF)
                                    : Colors.white38,
                              ),
                              tooltip: _showLaptopStage
                                  ? 'Ocultar letra en laptop'
                                  : 'Ver escenario en laptop',
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _showLaptopStage
                              ? 'Escenario opcional en laptop. El audio solo sale en la TV.'
                              : 'Mesa de control. Audio, letra y QR viven en la TV.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _tvSyncUrl,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontFamily: 'Consolas',
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'PIN TV  $_tvPin',
                          style: const TextStyle(
                            color: Color(0xFF39FF14),
                            fontSize: 15,
                            fontFamily: 'Consolas',
                            fontWeight: FontWeight.w900,
                            letterSpacing: 3,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: Colors.white10),
                  Container(
                    padding: const EdgeInsets.all(20),
                    color: Colors.black,
                    child: Column(
                      children: [
                        const Text(
                          "REACCIÓN DEL PÚBLICO",
                          style: TextStyle(
                            color: Colors.white54,
                            fontSize: 14,
                            letterSpacing: 2,
                          ),
                        ),
                        const SizedBox(height: 20),
                        ValueListenableBuilder<Map<String, int>>(
                          valueListenable: KaraokeCore().votesNotifier,
                          builder: (context, votes, _) {
                            return Row(
                              mainAxisAlignment: MainAxisAlignment.spaceAround,
                              children: [
                                _buildStatBadge(
                                  '👏',
                                  votes['👏'] ?? 0,
                                  const Color(0xFF00FFFF),
                                ),
                                _buildStatBadge(
                                  '🔥',
                                  votes['🔥'] ?? 0,
                                  const Color(0xFFFF3366),
                                ),
                                _buildStatBadge(
                                  '💩',
                                  votes['💩'] ?? 0,
                                  const Color(0xFFFFAA00),
                                ),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: Colors.white10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(15),
                    color: const Color(0xFF1A1A1A),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          "SIGUIENTES EN LA COLA",
                          style: TextStyle(
                            color: Color(0xFF39FF14),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.qr_code_2,
                            color: Color(0xFF00FFFF),
                            size: 30,
                          ),
                          onPressed: () => _showQrModal(context),
                          tooltip: 'Mostrar Código QR',
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ValueListenableBuilder<List<Map<String, dynamic>>>(
                      valueListenable: KaraokeCore().queueNotifier,
                      builder: (context, queue, _) {
                        return ListView.builder(
                          itemCount: queue.length,
                          itemBuilder: (context, index) {
                            final req = queue[index];
                            final songName = req['song']
                                .toString()
                                .replaceAll('\\', '/')
                                .split('/')
                                .last
                                .replaceAll(
                                  RegExp(r'\.mp3$', caseSensitive: false),
                                  '',
                                );
                            return ListTile(
                              leading: CircleAvatar(
                                backgroundColor: const Color(
                                  0xFF39FF14,
                                ).withAlpha(50),
                                child: const Icon(
                                  Icons.person,
                                  color: Color(0xFF39FF14),
                                ),
                              ),
                              title: Text(
                                req['user'],
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              subtitle: Text(
                                songName,
                                style: const TextStyle(color: Colors.white70),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ApproxLyricIcon(path: req['song'].toString()),
                                  const SizedBox(width: 6),
                                  Text(
                                    "#${index + 1}",
                                    style: const TextStyle(
                                      color: Colors.white38,
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Quitar de la cola',
                                    onPressed: () =>
                                        KaraokeCore().removeAt(index),
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      color: Color(0xFFFF3366),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(20),
                    color: Colors.black,
                    width: double.infinity,
                    child: ValueListenableBuilder<bool>(
                      valueListenable: KaraokeCore().sessionActive,
                      builder: (context, session, _) {
                        return ValueListenableBuilder<Map<String, String>>(
                          valueListenable: KaraokeCore().currentSingerNotifier,
                          builder: (context, current, _) {
                            if (!session) {
                              return ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF00FFFF),
                                  foregroundColor: Colors.black,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 20,
                                  ),
                                ),
                                onPressed: () => KaraokeCore().startSession(),
                                child: const Text(
                                  "INICIAR KARAOKE ⏭️",
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              );
                            }
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (current.isNotEmpty)
                                  ValueListenableBuilder<bool>(
                                    valueListenable:
                                        KaraokeCore().pausedNotifier,
                                    builder: (context, paused, _) {
                                      return OutlinedButton.icon(
                                        onPressed: () => _setPaused(!paused),
                                        icon: Icon(
                                          paused
                                              ? Icons.play_arrow
                                              : Icons.pause,
                                        ),
                                        label: Text(
                                          paused ? 'REANUDAR TV' : 'PAUSA TV',
                                        ),
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: const Color(
                                            0xFF00FFFF,
                                          ),
                                          side: const BorderSide(
                                            color: Color(0xFF00FFFF),
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 14,
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                if (current.isNotEmpty)
                                  const SizedBox(height: 8),
                                if (current.isNotEmpty)
                                  OutlinedButton(
                                    onPressed: () => unawaited(_skipTrack()),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: const Color(0xFF39FF14),
                                      side: const BorderSide(
                                        color: Color(0xFF39FF14),
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 14,
                                      ),
                                    ),
                                    child: const Text(
                                      "SIGUIENTE PISTA",
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                if (current.isNotEmpty)
                                  const SizedBox(height: 8),
                                ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFFFF3366),
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 18,
                                    ),
                                  ),
                                  onPressed: () => unawaited(_endSession()),
                                  child: const Text(
                                    "FINALIZAR KARAOKE",
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLaptopStage() {
    return Container(
      padding: const EdgeInsets.all(28),
      child: Column(
        children: [
          ValueListenableBuilder<Map<String, String>>(
            valueListenable: KaraokeCore().currentSingerNotifier,
            builder: (context, currentSinger, _) {
              if (currentSinger.isEmpty) {
                return const Text(
                  'ESCENARIO EN TV',
                  style: TextStyle(color: Colors.white38, letterSpacing: 2),
                );
              }
              return Row(
                children: [
                  Flexible(
                    child: Text(
                      'MONITOR: ${currentSinger['user']} — ${_displayName('${currentSinger['song']}')}',
                      style: const TextStyle(
                        color: Color(0xFF00FFFF),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ApproxLyricIcon(path: '${currentSinger['song']}'),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          if (_currentLyrics.isNotEmpty && (_tvPos == null || _tvSignalLost))
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'Sin señal de TV: la letra se mueve con la posición real de la TV.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFFFFAA00), fontSize: 13),
              ),
            ),
          Expanded(
            child: _currentLyrics.isEmpty
                ? ValueListenableBuilder<Map<String, dynamic>>(
                    valueListenable: KaraokeCore().scoreboardNotifier,
                    builder: (context, board, _) {
                      if (board.isEmpty) {
                        return const Center(
                          child: Text(
                            'La letra vive en la TV.',
                            style: TextStyle(
                              color: Colors.white38,
                              fontSize: 22,
                            ),
                          ),
                        );
                      }
                      return _buildScoreboard(board);
                    },
                  )
                : ListView.builder(
                    controller: _lrcScrollController,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _currentLyrics.length,
                    itemBuilder: (context, index) {
                      final entry = _currentLyrics.entries.elementAt(index);
                      final isActive = index == _activeLyricIndex;
                      return SizedBox(
                        height: 72,
                        child: Center(
                          child: Text(
                            entry.value,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: isActive
                                  ? const Color(0xFF39FF14)
                                  : Colors.white54,
                              fontSize: isActive ? 28 : 20,
                              fontWeight: isActive
                                  ? FontWeight.w900
                                  : FontWeight.normal,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildScoreboard(Map<String, dynamic> board) {
    final votes = Map<String, int>.from(board['votes'] as Map? ?? {});
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${board['user']} — ${_displayName('${board['song']}')}',
            style: const TextStyle(
              color: Color(0xFF00FFFF),
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          const Text(
            'CALIFICACIÓN',
            style: TextStyle(color: Colors.white54, letterSpacing: 3),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildStatBadge('👏', votes['👏'] ?? 0, const Color(0xFF00FFFF)),
              _buildStatBadge('🔥', votes['🔥'] ?? 0, const Color(0xFFFF3366)),
              _buildStatBadge('💩', votes['💩'] ?? 0, const Color(0xFFFFAA00)),
            ],
          ),
          const SizedBox(height: 28),
          const Text(
            'Siguiente pista en 8 s',
            style: TextStyle(color: Color(0xFF39FF14), fontSize: 16),
          ),
        ],
      ),
    );
  }

  Widget _buildStatBadge(String emoji, int count, Color color) {
    return Column(
      children: [
        Text(emoji, style: const TextStyle(fontSize: 32)),
        const SizedBox(height: 5),
        Text(
          count.toString(),
          style: TextStyle(
            color: color,
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}

/// 3.2.25: IP LAN para la URL de /apk (misma eleccion que LAN Sync:
/// prefiere Wi-Fi, salta virtuales y 169.254). null si no hay red.
Future<String?> karaokeLanIp() async {
  try {
    final List<NetworkInterface> interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    return pickLanIpv4(<({String name, List<String> addresses})>[
      for (final NetworkInterface i in interfaces)
        (
          name: i.name,
          addresses: <String>[
            for (final InternetAddress a in i.addresses) a.address,
          ],
        ),
    ], preferWlan: true);
  } catch (_) {
    return null;
  }
}

/// 3.2.25: direccion que se escribe en Downloader.
String tvApkUrl(String ip, int port) => 'http://$ip:$port/apk';

/// 3.2.25: asistente de instalacion de GatoMix TV. Recomendado: sin cables
/// ni Modo Desarrollador (Downloader + /apk del nodo TV). Avanzado: el
/// flujo ADB de siempre ([TvDeploymentDialog]) sin cambios.
class TvInstallWizardDialog extends StatefulWidget {
  final TvSyncServer server;
  final TvAdbDeploymentService adbService;
  final TvApkCache? cache;

  const TvInstallWizardDialog({
    super.key,
    required this.server,
    required this.adbService,
    this.cache,
  });

  @override
  State<TvInstallWizardDialog> createState() => _TvInstallWizardDialogState();
}

class _TvInstallWizardDialogState extends State<TvInstallWizardDialog> {
  static const Color _neon = Color(0xFF39FF14);
  static const Color _cyan = Color(0xFF00FFFF);

  late final TvApkCache _cache = widget.cache ?? TvApkCache();
  String? _ip;
  bool _serverUp = false;
  bool _apkReady = false;
  bool _busy = false;
  double? _progress;
  String _status = 'Revisando la red y el APK…';

  String? get _url =>
      _ip == null ? null : tvApkUrl(_ip!, widget.server.boundPort);

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  Future<void> _boot() async {
    final bool up = await widget.server.ensureStarted();
    final String? ip = await karaokeLanIp();
    final bool ready = await _cache.isValid();
    if (!mounted) return;
    setState(() {
      _serverUp = up;
      _ip = ip;
      _apkReady = ready;
      _status = !up
          ? 'No se pudo abrir el puerto ${widget.server.port}. Cierra otra '
                'copia de GatoMix y vuelve a abrir este asistente.'
          : ip == null
          ? 'Sin red local: conecta la laptop al mismo Wi-Fi que la TV.'
          : ready
          ? 'APK listo. Sigue los 3 pasos en la TV.'
          : 'Primero prepara el APK (se baja una sola vez, unos 90 MB).';
    });
  }

  Future<void> _prepare({required bool force}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _progress = null;
      _status = force ? 'Actualizando APK…' : 'Preparando APK…';
    });
    try {
      await _cache.ensure(
        force: force,
        onProgress: (int got, int? total) {
          if (!mounted || total == null || total <= 0) return;
          final double p = got / total;
          final double? last = _progress;
          if (last != null && p < 1 && (p - last).abs() < 0.01) return;
          setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      setState(() {
        _apkReady = true;
        _status = _ip == null
            ? 'APK listo, pero falta red local en la laptop.'
            : 'APK listo. Sigue los 3 pasos en la TV.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'No se pudo preparar el APK: $e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _copy() async {
    final String? url = _url;
    if (url == null) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    setState(() => _status = 'Dirección copiada: $url');
  }

  Future<void> _openAdb() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => TvDeploymentDialog(service: widget.adbService),
    );
  }

  Widget _step(String n, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 11,
            backgroundColor: _neon,
            child: Text(
              n,
              style: const TextStyle(
                color: Colors.black,
                fontSize: 12,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Colors.white70, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final String? url = _url;
    final bool showQr = _serverUp && _apkReady && url != null;
    return Dialog(
      backgroundColor: const Color(0xFF0B0D10),
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: _neon),
        borderRadius: BorderRadius.circular(14),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 700),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.live_tv, color: _neon, size: 32),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'INSTALAR GATOMIX TV',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                            fontSize: 18,
                            letterSpacing: 2,
                          ),
                        ),
                        Text(
                          'Karaoke en tu Google TV o Android TV',
                          style: TextStyle(color: Colors.white54),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    tooltip: 'Cerrar',
                    icon: const Icon(Icons.close, color: Colors.white54),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.pin, color: _cyan, size: 20),
                  const SizedBox(width: 8),
                  const Text(
                    'PIN para la TV:',
                    style: TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    widget.server.sessionPin.isEmpty
                        ? '----'
                        : widget.server.sessionPin,
                    style: const TextStyle(
                      color: _neon,
                      fontSize: 24,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 6,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF12161B),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _neon.withValues(alpha: 0.6)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Instalar sin cables ni Modo Desarrollador (Recomendado)',
                      style: TextStyle(
                        color: _neon,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 176,
                          height: 176,
                          padding: const EdgeInsets.all(8),
                          color: Colors.white,
                          child: showQr
                              ? QrImageView(
                                  data: url,
                                  version: QrVersions.auto,
                                  size: 160,
                                )
                              : Center(
                                  child: _busy
                                      ? CircularProgressIndicator(
                                          value: _progress,
                                          color: Colors.black54,
                                        )
                                      : const Icon(
                                          Icons.qr_code_2,
                                          color: Colors.black26,
                                          size: 96,
                                        ),
                                ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SelectableText(
                                url ?? 'Buscando la IP de la laptop…',
                                style: const TextStyle(
                                  color: _cyan,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 17,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  OutlinedButton.icon(
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: _cyan,
                                      side: const BorderSide(color: _cyan),
                                    ),
                                    onPressed: url == null ? null : _copy,
                                    icon: const Icon(Icons.copy, size: 16),
                                    label: const Text('COPIAR'),
                                  ),
                                  ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: _neon,
                                      foregroundColor: Colors.black,
                                    ),
                                    onPressed: _busy || !_serverUp
                                        ? null
                                        : () => _prepare(force: _apkReady),
                                    icon: Icon(
                                      _apkReady
                                          ? Icons.refresh
                                          : Icons.download,
                                      size: 18,
                                    ),
                                    label: Text(
                                      _apkReady
                                          ? 'ACTUALIZAR APK'
                                          : 'PREPARAR APK',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 14),
                              _step(
                                '1',
                                'En la TV abre la app Downloader (gratis en '
                                    'Google Play).',
                              ),
                              _step(
                                '2',
                                'Escribe la dirección de arriba o escanea el '
                                    'QR con el celular.',
                              ),
                              _step(
                                '3',
                                'Instala y abre GatoMix TV y escribe el PIN. Si la TV lo pide, '
                                    'permite instalar apps desde Downloader.',
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (_busy) ...[
                      const SizedBox(height: 12),
                      LinearProgressIndicator(
                        value: _progress,
                        color: _neon,
                        backgroundColor: Colors.white10,
                      ),
                    ],
                    const SizedBox(height: 10),
                    Text(
                      _status,
                      style: const TextStyle(
                        color: Colors.white70,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white70,
                  side: const BorderSide(color: Colors.white24),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: _openAdb,
                icon: const Icon(Icons.developer_mode),
                label: const Text('Instalación automática por ADB (Avanzado)'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class TvDeploymentDialog extends StatefulWidget {
  final TvAdbDeploymentService service;

  const TvDeploymentDialog({super.key, required this.service});

  @override
  State<TvDeploymentDialog> createState() => _TvDeploymentDialogState();
}

class _TvDeploymentDialogState extends State<TvDeploymentDialog> {
  List<TvAdbTarget> _targets = const [];
  bool _busy = false;
  String _status = 'Activa Depuración inalámbrica en Google TV.';

  @override
  void initState() {
    super.initState();
    widget.service.onStatus = (m) {
      if (mounted) setState(() => _status = m);
    };
    unawaited(_scan());
  }

  Future<void> _scan() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = 'Buscando Google TV por ADB/mDNS…';
    });
    try {
      final targets = await widget.service.discover();
      if (!mounted) return;
      setState(() {
        _targets = targets;
        _status = targets.isEmpty
            ? 'No se encontró TV. Activa Opciones de desarrollador → '
                  'Depuración inalámbrica.'
            : '${targets.length} destino(s) detectado(s).';
      });
    } catch (e) {
      if (mounted) setState(() => _status = 'Error de radar: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _pair(TvAdbTarget target, {bool manageBusy = true}) async {
    final discovered = await widget.service.resolvePairingEndpoint(target.host);
    final pairingEndpoint = discovered ?? target.pairingEndpoint ?? target.host;
    final endpointController = TextEditingController(text: pairingEndpoint);
    final codeController = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF121212),
        title: const Text(
          'Emparejar Google TV',
          style: TextStyle(color: Color(0xFF39FF14)),
        ),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'En la TV entra en Depuración inalámbrica → Emparejar '
                'dispositivo. Copia el IP:PUERTO y el código de 6 dígitos que '
                'muestra esa pantalla; ese puerto es distinto al de conexión.',
                style: TextStyle(color: Colors.white70, height: 1.4),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: endpointController,
                style: const TextStyle(
                  color: Colors.white,
                  fontFamily: 'Consolas',
                ),
                decoration: const InputDecoration(
                  labelText: 'IP:puerto de emparejamiento',
                  hintText: '192.168.1.9:38791',
                  labelStyle: TextStyle(color: Colors.white54),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: codeController,
                autofocus: true,
                keyboardType: TextInputType.number,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  letterSpacing: 5,
                ),
                decoration: const InputDecoration(
                  labelText: 'Código de vinculación',
                  labelStyle: TextStyle(color: Colors.white54),
                ),
                onSubmitted: (_) => Navigator.pop(dialogContext, true),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('CANCELAR'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('EMPAREJAR'),
          ),
        ],
      ),
    );

    var endpoint = endpointController.text.trim();
    final code = codeController.text.trim();
    endpointController.dispose();
    codeController.dispose();

    if (confirmed != true || code.isEmpty) return false;
    if (RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}:?$').hasMatch(endpoint)) {
      final resolved = discovered ?? target.pairingEndpoint;
      if (resolved != null && resolved.contains(':')) {
        endpoint = resolved;
      }
    }
    if (!RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}:\d+$').hasMatch(endpoint)) {
      setState(
        () => _status =
            'Falta el puerto de emparejamiento. En la TV, bajo el código, '
            'copia “Dirección IP y puerto” completo (ej. 192.168.1.9:34339).',
      );
      return false;
    }

    if (manageBusy) {
      setState(() {
        _busy = true;
        _status = 'Emparejando $endpoint…';
      });
    } else {
      setState(() => _status = 'Emparejando $endpoint…');
    }
    try {
      await widget.service.pair(endpoint: endpoint, code: code);
      if (!mounted) return false;
      if (manageBusy) {
        setState(() {
          _busy = false;
          _status = 'TV emparejada. Actualizando radar…';
        });
        await _scan();
      } else {
        setState(() => _status = 'TV emparejada. Continuando instalación…');
      }
      return true;
    } catch (e) {
      if (!mounted) return false;
      setState(() {
        if (manageBusy) _busy = false;
        _status = 'Emparejamiento fallido: $e';
      });
      return false;
    }
  }

  Future<void> _addManualEndpoint() async {
    final controller = TextEditingController(text: '192.168.1.');
    final endpoint = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF121212),
        title: const Text(
          'Conexión ADB manual',
          style: TextStyle(color: Color(0xFF00FFFF)),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white, fontFamily: 'Consolas'),
          decoration: const InputDecoration(
            labelText: 'IP:puerto que muestra la TV',
            hintText: '192.168.1.40:5555',
          ),
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('AÑADIR'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (endpoint == null || endpoint.trim().isEmpty) return;
    // Sin puerto se asume 5555 (el que usa la TV en depuración por red).
    final String full = endpoint.contains(':')
        ? endpoint.trim()
        : '${endpoint.trim()}:5555';
    setState(() {
      _busy = true;
      _status = 'Conectando con $full…';
    });
    bool connected = false;
    try {
      final String result = await widget.service.connectManual(full);
      connected =
          result.toLowerCase().contains('connected to') &&
          !result.toLowerCase().contains('failed');
      if (!mounted) return;
      setState(() {
        _targets = [
          ..._targets.where((t) => t.endpoint != full),
          TvAdbTarget(
            endpoint: full,
            name: 'Google TV manual',
            state: TvAdbTargetState.discoverable,
          ),
        ];
        _status = result.isEmpty ? 'Añadida $full.' : result;
      });
    } catch (e) {
      if (mounted) setState(() => _status = 'No se pudo conectar: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && connected) await _scan();
  }

  Future<void> _install(TvAdbTarget target) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = 'Preparando instalación…';
    });
    try {
      await widget.service.buildInstallAndLaunch(
        target: target,
        onProgress: (message) {
          if (mounted) setState(() => _status = message);
        },
      );
    } on TvAdbPairingRequiredException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = e.message;
      });
      final paired = await _pair(e.target, manageBusy: false);
      if (!paired || !mounted) return;
      await _install(e.target.copyWith(state: TvAdbTargetState.discoverable));
    } catch (e) {
      if (mounted) setState(() => _status = 'Instalación fallida: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
      if (mounted) await _scan();
    }
  }

  Widget _actionLamp({
    required String label,
    required bool needsAction,
    required VoidCallback? onPressed,
  }) {
    final color = needsAction ? const Color(0xFFFFAA00) : Colors.white24;
    return InkWell(
      onTap: needsAction ? onPressed : null,
      child: SizedBox(
        width: 118,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: needsAction ? color : Colors.transparent,
                border: Border.all(color: color, width: 2),
                boxShadow: needsAction
                    ? [
                        BoxShadow(
                          color: color.withValues(alpha: 0.7),
                          blurRadius: 10,
                        ),
                      ]
                    : const [],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF0B0D10),
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: Color(0xFF39FF14)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 620),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.live_tv, color: Color(0xFF39FF14), size: 32),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'DEPLOY GOOGLE TV',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                            fontSize: 18,
                            letterSpacing: 2,
                          ),
                        ),
                        Text(
                          'Compila, instala y abre GatoMix Karaoke',
                          style: TextStyle(color: Colors.white54),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: _busy ? null : _scan,
                    tooltip: 'Buscar TV',
                    icon: const Icon(Icons.search, color: Color(0xFF39FF14)),
                  ),
                  IconButton(
                    onPressed: _busy ? null : _addManualEndpoint,
                    tooltip: 'IP manual',
                    icon: const Icon(Icons.add_link, color: Color(0xFF00FFFF)),
                  ),
                  IconButton(
                    onPressed: _busy ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close, color: Colors.white54),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white12),
                ),
                child: const Text(
                  'TV: Ajustes → Sistema → Información → pulsa “Compilación” '
                  '7 veces → Opciones de desarrollador → Depuración '
                  'inalámbrica → Emparejar dispositivo.\n'
                  'Lámpara ENCENDIDA = falta acción. Apagada = ya está hecho.\n'
                  'Emparejado: enciende si aún no hay IP+clave. '
                  'Instalado: enciende si la APK no está en la TV. '
                  'No se vuelve a emparejar ni a reinstalar si ya está listo.',
                  style: TextStyle(color: Colors.white70, height: 1.4),
                ),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: _targets.isEmpty
                    ? Center(
                        child: _busy
                            ? const CircularProgressIndicator(
                                color: Color(0xFF39FF14),
                              )
                            : const Icon(
                                Icons.tv_off,
                                color: Colors.white24,
                                size: 72,
                              ),
                      )
                    : ListView.separated(
                        itemCount: _targets.length,
                        separatorBuilder: (_, _) =>
                            const Divider(color: Colors.white10),
                        itemBuilder: (context, index) {
                          final target = _targets[index];
                          final needsPairing =
                              target.state == TvAdbTargetState.pairingRequired;
                          return ListTile(
                            leading: Icon(
                              needsPairing ? Icons.lock : Icons.tv,
                              color: needsPairing
                                  ? const Color(0xFFFFAA00)
                                  : const Color(0xFF39FF14),
                            ),
                            title: Text(
                              target.name,
                              style: const TextStyle(color: Colors.white),
                            ),
                            subtitle: Text(
                              target.endpoint,
                              style: const TextStyle(
                                color: Colors.white54,
                                fontFamily: 'Consolas',
                              ),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _actionLamp(
                                  label: 'Conectado/Emparejado',
                                  needsAction: !target.paired,
                                  onPressed: _busy ? null : () => _pair(target),
                                ),
                                const SizedBox(width: 16),
                                _actionLamp(
                                  label: 'Instalado',
                                  needsAction: !target.installed,
                                  onPressed: _busy
                                      ? null
                                      : () => _install(target),
                                ),
                                if (target.installed) ...[
                                  const SizedBox(width: 10),
                                  TextButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _install(target),
                                    child: const Text(
                                      'ABRIR',
                                      style: TextStyle(
                                        color: Color(0xFF00FFFF),
                                        fontSize: 11,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                color: const Color(0xFF111820),
                child: Row(
                  children: [
                    if (_busy) ...[
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF00FFFF),
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: Text(
                        _status,
                        style: const TextStyle(
                          color: Color(0xFF00FFFF),
                          fontFamily: 'Consolas',
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

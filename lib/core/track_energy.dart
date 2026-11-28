import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:difogo/src/rust/api/core_dsp.dart' show decodeMonoPcm;

import 'audio_path.dart';
import 'bpm_backfill_worker.dart' show fillTrackDnaIfStale;
import 'discovery_dedup_controller.dart' show listLibraryAudioAsync;
import 'gatomix_store.dart';
import 'library_guard.dart';
import 'queue_bpm.dart';

/// 3.2.37: energia 1-10 (compuesto) y Camelot en Dart, sin tocar el FFI.
/// El espejo (folder_cache) es el unico destino de escritura.

const double kEnergyBpmMin = 70;
const double kEnergyBpmSpan = 90;
const int kCamelotPcmRate = 11025;
const double kCamelotStartFrac = 0.30;
const int kCamelotSecs = 18;

/// Peso al menos igual al bonus de ola BPM (+36).
const double kEnergyWaveBonus = 36;
const double kEnergyJumpPenalty = 200;

/// Perfiles Krumhansl-Kessler (C, C#, ..., B).
const List<double> kKrumhanslMajor = <double>[
  6.35,
  2.23,
  3.48,
  2.33,
  4.38,
  4.09,
  2.52,
  5.19,
  2.39,
  3.66,
  2.29,
  2.88,
];
const List<double> kKrumhanslMinor = <double>[
  6.33,
  2.68,
  3.52,
  5.38,
  2.60,
  3.53,
  2.54,
  4.75,
  3.98,
  2.69,
  3.34,
  3.17,
];

/// Indice 0 = C. Mayor: 8B = C. Menor: 8A = Am.
const List<String> kCamelotMajor = <String>[
  '8B',
  '3B',
  '10B',
  '5B',
  '12B',
  '7B',
  '2B',
  '9B',
  '4B',
  '11B',
  '6B',
  '1B',
];
const List<String> kCamelotMinor = <String>[
  '5A',
  '12A',
  '7A',
  '2A',
  '9A',
  '4A',
  '11A',
  '6A',
  '1A',
  '8A',
  '3A',
  '10A',
];

double bpmNormForEnergy(double bpm) {
  if (bpm <= 0) return 0.5;
  return ((bpm - kEnergyBpmMin) / kEnergyBpmSpan).clamp(0.0, 1.0);
}

/// 40% densidad de beat, 15% BPM, 20% brillo, 25% RMS (energy de TrackDna).
int compositeEnergyLevel({
  required double rmsEnergy,
  required double beatDensity,
  required double brightness,
  required double bpm,
}) {
  final double e = rmsEnergy.clamp(0.0, 1.0);
  final double d = beatDensity.clamp(0.0, 1.0);
  final double b = brightness.clamp(0.0, 1.0);
  final double c =
      0.40 * d + 0.15 * bpmNormForEnergy(bpm) + 0.20 * b + 0.25 * e;
  return (c * 9.0).round().clamp(0, 9) + 1;
}

/// Salto de energia entre dos temas. Subir 1 hacia el pico vale tanto
/// como quedarse; un salto de mas de 2 niveles se penaliza fuerte.
double harmonicEnergyScore(
  int? fromLevel,
  int? toLevel, {
  required bool waveUp,
}) {
  if (fromLevel == null || toLevel == null) return 0;
  final int delta = toLevel - fromLevel;
  final int ad = delta.abs();
  if (ad > 2) return -kEnergyJumpPenalty;
  if (ad == 0) return kEnergyWaveBonus;
  final bool along = waveUp ? delta > 0 : delta < 0;
  if (ad == 1) return along ? kEnergyWaveBonus : 12;
  return along ? 6 : 0;
}

/// Cierto si el salto es legal (falta un nivel, o hay a lo sumo 2 de diferencia).
bool energyJumpOk(int? fromLevel, int? toLevel) {
  if (fromLevel == null || toLevel == null) return true;
  return (toLevel - fromLevel).abs() <= 2;
}

bool isCamelotKey(String? s) {
  if (s == null) return false;
  final String t = s.trim().toUpperCase();
  return RegExp(r'^(?:[1-9]|1[0-2])[AB]$').hasMatch(t);
}

String? normalizeCamelot(String? s) {
  if (!isCamelotKey(s)) return null;
  return s!.trim().toUpperCase();
}

/// Tokens "8A" / "11b" en el nombre del archivo, si existen.
String? camelotFromFileName(String path) {
  final RegExp re = RegExp(
    r'(?:^|[^0-9A-Za-z])((?:[1-9]|1[0-2])[ABab])(?![0-9A-Za-z])',
  );
  final String name = path.replaceAll(r'\', '/').split('/').last;
  final Iterable<RegExpMatch> all = re.allMatches(name);
  if (all.isEmpty) return null;
  return all.last.group(1)!.toUpperCase();
}

/// Necesita relleno si falta el nivel o el mtime no coincide.
/// Marca de "se intento y no se pudo": no rehacer el decode.
const String kCamelotUnknown = '-';

bool trackEnergyNeedsFill(TrackDnaEntry? cur, int mtimeMs) {
  if (cur == null || cur.energyLevel == null) return true;
  if (mtimeMs > 0 && cur.mtimeMs != null && cur.mtimeMs != mtimeMs) {
    return true;
  }
  return false;
}

bool trackCamelotNeedsFill(TrackDnaEntry? cur) {
  if (cur == null) return true;
  if (isCamelotKey(cur.camelot)) return false;
  if (cur.camelot == kCamelotUnknown) return false;
  return true;
}

int? levelFromStored(TrackDnaEntry? cur, double bpm) {
  if (cur == null) return null;
  if (cur.energy == null || cur.beatDensity == null || cur.brightness == null) {
    return null;
  }
  return compositeEnergyLevel(
    rmsEnergy: cur.energy!,
    beatDensity: cur.beatDensity!,
    brightness: cur.brightness!,
    bpm: bpm,
  );
}

/// PCM s16le mono -> 12 bins de clase de altura (C..B).
List<double> chromaFromPcm(Uint8List pcm, int sampleRate) {
  final int nSamp = pcm.length ~/ 2;
  final List<double> chroma = List<double>.filled(12, 0);
  if (nSamp < 2048 || sampleRate <= 0) return chroma;
  const int win = 4096;
  const int hop = 2048;
  final int use = math.min(nSamp, sampleRate * 22);
  final List<double> frame = List<double>.filled(win, 0);
  for (int start = 0; start + win <= use; start += hop) {
    for (int i = 0; i < win; i++) {
      final int o = (start + i) * 2;
      final int lo = pcm[o];
      final int hi = pcm[o + 1];
      int s = lo | (hi << 8);
      if (s >= 0x8000) s -= 0x10000;
      final double w = 0.5 - 0.5 * math.cos(2 * math.pi * i / (win - 1));
      frame[i] = s / 32768.0 * w;
    }
    // MIDI 36 (C2) a 84 (C6): 4 octavas.
    for (int midi = 36; midi <= 84; midi++) {
      final double freq = 440.0 * math.pow(2.0, (midi - 69) / 12.0);
      final double mag = _goertzel(frame, freq, sampleRate);
      chroma[midi % 12] += mag;
    }
  }
  double peak = 0;
  for (final double v in chroma) {
    if (v > peak) peak = v;
  }
  if (peak > 0) {
    for (int i = 0; i < 12; i++) {
      chroma[i] /= peak;
    }
  }
  return chroma;
}

double _goertzel(List<double> x, double freq, int rate) {
  final double w = 2 * math.pi * freq / rate;
  final double coeff = 2 * math.cos(w);
  double s1 = 0;
  double s2 = 0;
  for (final double v in x) {
    final double s0 = v + coeff * s1 - s2;
    s2 = s1;
    s1 = s0;
  }
  return s1 * s1 + s2 * s2 - coeff * s1 * s2;
}

double _corrShift(List<double> chroma, List<double> profile, int shift) {
  double s = 0;
  for (int i = 0; i < 12; i++) {
    s += chroma[i] * profile[(i - shift) % 12];
  }
  return s;
}

/// Mejor Camelot a partir de un cromagrama.
String? camelotFromChroma(List<double> chroma) {
  if (chroma.length != 12) return null;
  double best = double.negativeInfinity;
  String? key;
  for (int k = 0; k < 12; k++) {
    final double maj = _corrShift(chroma, kKrumhanslMajor, k);
    if (maj > best) {
      best = maj;
      key = kCamelotMajor[k];
    }
    final double minv = _corrShift(chroma, kKrumhanslMinor, k);
    if (minv > best) {
      best = minv;
      key = kCamelotMinor[k];
    }
  }
  return key;
}

String? camelotFromPcm(Uint8List pcm, int sampleRate) {
  final List<double> ch = chromaFromPcm(pcm, sampleRate);
  double sum = 0;
  for (final double v in ch) {
    sum += v;
  }
  if (sum <= 0) return null;
  return camelotFromChroma(ch);
}

Future<String?> detectCamelotFromAudio(
  String path, {
  double durationSec = 0,
}) async {
  try {
    final int start = durationSec > 60
        ? (durationSec * kCamelotStartFrac).round()
        : 0;
    final Uint8List pcm = await decodeMonoPcm(
      inputPath: path,
      startSecs: start,
      lengthSecs: kCamelotSecs,
      targetRate: kCamelotPcmRate,
    );
    return camelotFromPcm(pcm, kCamelotPcmRate);
  } catch (_) {
    return null;
  }
}

/// Rellena energyLevel y camelot en el espejo. Nunca escribe junto al audio.
/// Si las metricas Rust ya estan frescas, no vuelve a llamar track_dna.
Future<TrackDnaEntry?> fillTrackEnergyIfStale(String path) async {
  if (path.isEmpty || isKaraokeAudioPath(path)) return peekTrackDna(path);
  if (!isLibraryPath(path)) return peekTrackDna(path);
  try {
    final FileStat st = await File(path).stat();
    if (st.type != FileSystemEntityType.file) return peekTrackDna(path);
    final int mtimeMs = st.modified.millisecondsSinceEpoch;
    await warmTrackDnaDir(File(path).parent.path);
    TrackDnaEntry? cur = peekTrackDna(path);
    final bool needLevel = trackEnergyNeedsFill(cur, mtimeMs);
    final bool needKey = trackCamelotNeedsFill(cur);
    if (!needLevel && !needKey) return cur;

    if (needLevel &&
        (cur == null ||
            cur.energy == null ||
            cur.beatDensity == null ||
            cur.brightness == null ||
            (mtimeMs > 0 && cur.mtimeMs != null && cur.mtimeMs != mtimeMs))) {
      await fillTrackDnaIfStale(path);
      cur = peekTrackDna(path);
    }

    final double bpm = memoryBpm(path);
    final int? level = needLevel ? levelFromStored(cur, bpm) : cur?.energyLevel;

    String? camelot = normalizeCamelot(cur?.camelot);
    camelot ??= normalizeCamelot(camelotFromFileName(path));
    if (camelot == null && needKey) {
      camelot = await detectCamelotFromAudio(path);
      camelot = normalizeCamelot(camelot);
    }
    // Si se intento y no hay clave, sellar para no re-decodear.
    final String? camelotStamp =
        camelot ?? (needKey ? kCamelotUnknown : cur?.camelot);

    if (level == null && camelotStamp == null) return cur;

    final TrackDnaEntry next = (cur ?? const TrackDnaEntry()).mergedWith(
      TrackDnaEntry(
        energyLevel: level,
        camelot: camelotStamp,
        mtimeMs: mtimeMs > 0 ? mtimeMs : cur?.mtimeMs,
      ),
    );
    await saveTrackDna(path, next);
    return peekTrackDna(path);
  } catch (_) {
    return peekTrackDna(path);
  }
}

class EnergyBackfillReport {
  int scanned = 0;
  int skipped = 0;
  int filled = 0;
  int failed = 0;
  int withLevel = 0;
  int withCamelot = 0;

  @override
  String toString() =>
      'scanned=$scanned skipped=$skipped filled=$filled failed=$failed '
      'withLevel=$withLevel withCamelot=$withCamelot';
}

/// Recorre [root] (ReGenial), escribe solo el espejo, y se puede retomar:
/// lo que ya tiene nivel + mtime fresco se salta. Camelot ausente se
/// intenta una vez (nombre o decode); si falla, no se reintenta el decode
/// en la siguiente pasada si el nivel ya esta sellado.
Future<EnergyBackfillReport> backfillLibraryEnergy({
  required String root,
  required void Function(String line) log,
  int blockSize = 40,
  bool Function()? shouldStop,
}) async {
  final EnergyBackfillReport r = EnergyBackfillReport();
  if (root.isEmpty) return r;
  final List<String> paths = await listLibraryAudioAsync(<String>[root]);
  paths.sort();
  log('backfill: ${paths.length} audios bajo $root');
  int inBlock = 0;
  for (final String path in paths) {
    if (shouldStop != null && shouldStop()) break;
    if (isKaraokeAudioPath(path) || !isLibraryPath(path)) continue;
    r.scanned++;
    try {
      final FileStat st = await File(path).stat();
      final int mtimeMs = st.modified.millisecondsSinceEpoch;
      await warmTrackDnaDir(File(path).parent.path);
      final TrackDnaEntry? before = peekTrackDna(path);
      final bool need =
          trackEnergyNeedsFill(before, mtimeMs) ||
          trackCamelotNeedsFill(before);
      if (!need) {
        r.skipped++;
        if (before?.energyLevel != null) r.withLevel++;
        if (isCamelotKey(before?.camelot)) r.withCamelot++;
        continue;
      }
      final TrackDnaEntry? after = await fillTrackEnergyIfStale(path);
      if (after?.energyLevel != null || isCamelotKey(after?.camelot)) {
        r.filled++;
        if (after?.energyLevel != null) r.withLevel++;
        if (isCamelotKey(after?.camelot)) r.withCamelot++;
      } else {
        r.failed++;
      }
    } catch (e) {
      r.failed++;
      log('fail: $path $e');
    }
    inBlock++;
    if (inBlock >= blockSize) {
      inBlock = 0;
      log('progreso: ${r.toString()}');
    }
  }
  log('listo: ${r.toString()}');
  return r;
}

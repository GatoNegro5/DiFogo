// 3.1.96: foco de audio en llamadas, Bluetooth fuera y cambio de salida.
// AudioDeviceType de audio_session esta marcado experimental.
// ignore_for_file: experimental_member_use
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:difogo/services/audio_interruption.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeEngines implements FocusEngines {
  bool playing = true;
  int pauses = 0;
  int resumes = 0;
  int drops = 0;
  int outputChanges = 0;
  int coldPlays = 0;

  @override
  bool get anyPlaying => playing;

  @override
  Future<bool> pauseAutomix() async {
    final bool was = playing;
    pauses++;
    playing = false;
    return was;
  }

  @override
  Future<bool> pauseLiveDj() async => false;

  @override
  Future<void> resumeAutomix() async {
    resumes++;
    playing = true;
  }

  @override
  Future<void> resumeLiveDj() async {}

  @override
  void dropInterruptionResume() => drops++;

  @override
  void outputDeviceChanged() => outputChanges++;

  @override
  Future<void> coldPlay() async => coldPlays++;

  @override
  void listenPlaying(void Function(bool playing) onChange) {}

  @override
  void close() {}
}

AudioDevice _dev(String id, AudioDeviceType type, {bool output = true}) =>
    AudioDevice(
      id: id,
      name: id,
      isInput: !output,
      isOutput: output,
      type: type,
    );

void main() {
  late _FakeEngines engines;
  late AudioInterruptionGuard guard;

  setUp(() {
    engines = _FakeEngines();
    guard = AudioInterruptionGuard.withEngines(engines);
  });

  test('(a) NOISY durante la llamada no borra la reanudacion', () async {
    await guard.handleInterruption(
      AudioInterruptionEvent(true, AudioInterruptionType.pause),
    );
    expect(guard.inTransientLoss, isTrue);
    expect(guard.resumePending, isTrue);

    await guard.handleNoisy();
    expect(guard.resumePending, isTrue);
    expect(guard.inTransientLoss, isTrue);
    expect(engines.drops, 0);
    expect(engines.pauses, 1);
    expect(engines.outputChanges, 1);

    await guard.handleInterruption(
      AudioInterruptionEvent(false, AudioInterruptionType.pause),
    );
    expect(engines.resumes, 1);
    expect(guard.resumePending, isFalse);
    expect(guard.inTransientLoss, isFalse);
  });

  test('(b) NOISY fuera de llamada pausa y no reanuda', () async {
    await guard.handleNoisy();
    expect(engines.pauses, 1);
    expect(engines.playing, isFalse);
    expect(guard.resumePending, isFalse);
    expect(guard.inTransientLoss, isFalse);
    expect(engines.drops, 1);

    await guard.handleInterruption(
      AudioInterruptionEvent(false, AudioInterruptionType.pause),
    );
    expect(engines.resumes, 0);
  });

  test('perdida permanente: sin reanudacion y marca soltada', () async {
    await guard.handleInterruption(
      AudioInterruptionEvent(true, AudioInterruptionType.unknown),
    );
    expect(guard.resumePending, isFalse);
    expect(engines.drops, 1);
    await guard.handleInterruption(
      AudioInterruptionEvent(false, AudioInterruptionType.pause),
    );
    expect(engines.resumes, 0);
  });

  test('(c) onOutputDeviceChanged al cambiar la salida', () {
    final List<String> seen = <String>[];
    guard.onOutputDeviceChanged = () => seen.add('out');

    guard.handleDevicesChanged(
      AudioDevicesChangedEvent(
        devicesAdded: <AudioDevice>{},
        devicesRemoved: <AudioDevice>{
          _dev('bt', AudioDeviceType.bluetoothA2dp),
        },
      ),
    );
    expect(seen, <String>['out']);

    guard.handleDevicesChanged(
      AudioDevicesChangedEvent(
        devicesAdded: <AudioDevice>{
          _dev('spk', AudioDeviceType.builtInSpeaker),
        },
        devicesRemoved: <AudioDevice>{},
      ),
    );
    expect(seen.length, 2);

    // Solo entradas (microfono): no es cambio de salida.
    guard.handleDevicesChanged(
      AudioDevicesChangedEvent(
        devicesAdded: <AudioDevice>{
          _dev('mic', AudioDeviceType.builtInMic, output: false),
        },
        devicesRemoved: <AudioDevice>{},
      ),
    );
    expect(seen.length, 2);
  });

  test('por defecto el callback marca la salida en los motores', () {
    guard.handleDevicesChanged(
      AudioDevicesChangedEvent(
        devicesAdded: <AudioDevice>{},
        devicesRemoved: <AudioDevice>{
          _dev('bt', AudioDeviceType.bluetoothA2dp),
        },
      ),
    );
    expect(engines.outputChanges, 1);
  });

  test('salida trabada: posicion que no avanza estando en play', () {
    expect(outputStalled(playing: true, beforeMs: 1000, afterMs: 1010), isTrue);
    expect(
      outputStalled(playing: true, beforeMs: 1000, afterMs: 1170),
      isFalse,
    );
    expect(
      outputStalled(playing: false, beforeMs: 1000, afterMs: 1000),
      isFalse,
    );
    expect(kOutputProbeMs, 180);
  });

  test('Play en frio: el ultimo modo guardado manda', () {
    final Directory dir = Directory.systemTemp.createTempSync('difogo_3196_');
    try {
      final String a = '${dir.path}${Platform.pathSeparator}automix.json';
      final String l = '${dir.path}${Platform.pathSeparator}liveDj.json';
      expect(liveDjSessionIsNewer(automixPath: a, liveDjPath: l), isFalse);
      File(l).writeAsStringSync('{}');
      expect(liveDjSessionIsNewer(automixPath: a, liveDjPath: l), isTrue);
      File(a).writeAsStringSync('{}');
      File(a).setLastModifiedSync(DateTime(2026, 1, 2));
      File(l).setLastModifiedSync(DateTime(2026, 1, 1));
      expect(liveDjSessionIsNewer(automixPath: a, liveDjPath: l), isFalse);
      File(l).setLastModifiedSync(DateTime(2026, 1, 3));
      expect(liveDjSessionIsNewer(automixPath: a, liveDjPath: l), isTrue);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('fuente: foco normal, sin gainTransient, NOISY y dispositivos', () {
    final String s = File(
      'lib/services/audio_interruption.dart',
    ).readAsStringSync();
    expect(s.contains('gainTransient'), isFalse);
    expect(s.contains('AudioSessionConfiguration.music()'), isTrue);
    expect(s.contains('devicesChangedEventStream'), isTrue);
    expect(s.contains("'ao-reload'"), isTrue);
    final String h = File(
      'lib/core/audio/dj_audio_handler.dart',
    ).readAsStringSync();
    expect(h.contains('onColdPlay'), isTrue);
  });
}

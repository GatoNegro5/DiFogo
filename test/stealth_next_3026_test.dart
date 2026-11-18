import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/gatomix_store.dart';
import 'package:difogo/core/livedj_next.dart';
import 'package:difogo/providers/livedj_provider.dart';
import 'package:difogo/providers/mix_formula.dart';
import 'package:difogo/services/track_tags.dart';

// 3.1.84: Stealth ya no elige por cercania de BPM (salto fantasma de Deck B).
// Con cualquier tecnica entra la cabeza de la cola; barra = deck = cola.

const String _rose = '/m/Rose 100bpm.mp3';
const String _toto = '/m/Toto 170bpm.mp3';
const String _lipps = '/m/Lipps 104bpm.mp3';
const String _holmes = '/m/Holmes.mp3';
const List<String> _queue = <String>[_toto, _lipps, _holmes];

class _Harness extends LiveDjNotifier {
  @override
  LiveDjState build() => LiveDjState();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Stealth, DNA y Phrase 8: siempre la cabeza de la cola', () {
    for (final MixFormula formula in MixFormula.values) {
      final ProviderContainer box = ProviderContainer(
        overrides: <Override>[liveDjProvider.overrideWith(_Harness.new)],
      );
      addTearDown(box.dispose);
      box.read(mixFormulaProvider.notifier).state = formula;
      final LiveDjNotifier dj = box.read(liveDjProvider.notifier);
      dj.seedOffAirQueue(queue: _queue, playing: _rose);
      expect(dj.debugNextQueueIndex(), 0, reason: formula.name);
      expect(_queue[dj.debugNextQueueIndex()], _toto);
      expect(
        LiveDjNextLabel().text(
          radioOn: false,
          radioNextPath: _lipps,
          queuePaths: _queue,
          currentPath: _rose,
        ),
        'Toto 170bpm.mp3',
      );
    }
  });

  test('no elige la que suena y no salta las sin BPM', () {
    const List<String> queue = <String>[
      _rose,
      '/m/none-a.mp3',
      _toto,
      '/m/none-b.mp3',
      _lipps,
    ];
    expect(offAirNextIndex(paths: queue, currentPath: _rose), 1);
    expect(
      liveDjFollowingLabel(
        radioOn: false,
        radioNextPath: null,
        queuePaths: queue,
        currentPath: _rose,
      ),
      'none-a.mp3',
    );
  });

  test('con la radio encendida muestra la lista de la radio', () {
    const String cars = '/m/The Cars - Shake It Up.mp3';
    const String lime = '/m/Lime - Your Love.mp3';
    const List<String> upcoming = <String>[cars, lime];
    final String? bar = LiveDjNextLabel().text(
      radioOn: true,
      radioNextPath: cars,
      queuePaths: _queue,
      currentPath: _rose,
    );
    expect(bar, 'RADIO ▸ The Cars - Shake It Up.mp3');
    expect(
      liveDjSidePaths(
        radioOn: true,
        queuePaths: _queue,
        radioUpcoming: upcoming,
      ),
      upcoming,
    );
    expect(
      liveDjSidePaths(
        radioOn: false,
        queuePaths: _queue,
        radioUpcoming: upcoming,
      ),
      _queue,
    );
  });

  test('el reloj no relee el JSON para elegir la siguiente', () {
    final Directory dir = Directory.systemTemp.createTempSync('gmx_stealth26_');
    final String sep = Platform.pathSeparator;
    final String playing = '${dir.path}${sep}Rose.mp3';
    final String far = '${dir.path}${sep}Toto.mp3';
    final String near = '${dir.path}${sep}Lipps.mp3';
    final List<String> queue = <String>[far, near];
    TrackTags.clear();
    File('${dir.path}$sep.gatomix.json').writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'schema': 1,
        'djMetadata': <String, dynamic>{playing: 100, far: 170, near: 104},
      }),
    );
    final int reads = GatomixStore.debugDiskReads;
    final LiveDjNextLabel label = LiveDjNextLabel();
    for (var n = 0; n < 30; n++) {
      expect(offAirNextIndex(paths: queue, currentPath: playing), 0);
      expect(
        label.text(
          radioOn: false,
          radioNextPath: null,
          queuePaths: queue,
          currentPath: playing,
        ),
        'Toto.mp3',
      );
    }
    expect(GatomixStore.debugDiskReads, reads);
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });
}

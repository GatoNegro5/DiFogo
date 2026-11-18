import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/genre_mix_fx.dart';
import 'package:difogo/core/livedj_next.dart';
import 'package:difogo/providers/livedj_provider.dart';
import 'package:difogo/providers/mix_formula.dart';

// 3.1.84: salto fantasma de Deck B. Con la cola anunciada, ninguna tecnica
// (AUTO-FX, Stealth fijo o elegido a mano) sustituye ni reordena la pista
// que entra: Stealth solo cambia la curva, la ventana y el filtro.

const String _teddy = '/m/Teddy - Fuego (125 BPM).mp3';
const String _daddy = '/m/Daddy Yankee - Ghosting (91 BPM).mp3';
const String _otra = '/m/Otra - Puente (100 BPM).mp3';
const String _shakira = '/m/Shakira - Loca (122 BPM).mp3';
const List<String> _queue = <String>[_daddy, _otra, _shakira];

class _Harness extends LiveDjNotifier {
  @override
  LiveDjState build() => LiveDjState();
}

String _read(String p) =>
    File(p).readAsStringSync().replaceAll('\r\n', '\n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('125 -> 91 BPM: AUTO-FX pasa a Stealth', () {
    final GenreMixPlan plan = pickGenreMix(
      current: MixFormula.dnaEnergy,
      outPath: _teddy,
      inPath: _daddy,
      outBpm: 125,
      inBpm: 91,
    );
    expect((125 - 91).abs(), greaterThan(kGenreFxBpmJump));
    expect(plan.formula, MixFormula.stealthGap);
    expect(plan.fx, GenreMixFx.filterDropEcho);
  });

  test('Stealth (AUTO o fijo) deja la cola #1 intacta: entra Daddy Yankee', () {
    for (final bool locked in <bool>[false, true]) {
      for (final MixFormula f in MixFormula.values) {
        final ProviderContainer box = ProviderContainer(
          overrides: <Override>[liveDjProvider.overrideWith(_Harness.new)],
        );
        addTearDown(box.dispose);
        box.read(mixFormulaLockedProvider.notifier).state = locked;
        box.read(mixFormulaProvider.notifier).state = f;
        final LiveDjNotifier dj = box.read(liveDjProvider.notifier);
        dj.seedOffAirQueue(queue: _queue, playing: _teddy);
        final int i = dj.debugNextQueueIndex();
        expect(i, 0, reason: '${f.name} locked=$locked');
        expect(dj.state.queue[i].path, _daddy);
        // La cola no se toca: sin tercera pista intermedia.
        expect(<String>[
          for (final File x in dj.state.queue) x.path,
        ], _queue);
      }
    }
  });

  test('la barra y el motor dicen la misma: Daddy Yankee', () {
    expect(offAirNextIndex(paths: _queue, currentPath: _teddy), 0);
    expect(offAirNextIndex(paths: const <String>[], currentPath: _teddy), -1);
    final String? bar = LiveDjNextLabel().text(
      radioOn: false,
      radioNextPath: null,
      queuePaths: _queue,
      currentPath: _teddy,
    );
    expect(bar, 'Daddy Yankee - Ghosting (91 BPM).mp3');
    expect(bar, isNot(contains('Otra')));
  });

  test('sin segundo re-disparo: el recalculo AUTO deja 30 s de juego', () {
    // Punto recalculado 1,5 s por delante: se conserva el del cruce.
    expect(
      autoCurveMixOutMs(
        recalculatedMs: 21500,
        positionMs: 20000,
        currentMixOutMs: 180000,
      ),
      180000,
    );
    // Punto recalculado en el pasado: igual.
    expect(
      autoCurveMixOutMs(
        recalculatedMs: 15000,
        positionMs: 20000,
        currentMixOutMs: 180000,
      ),
      180000,
    );
    // Con juego suficiente se acepta.
    expect(
      autoCurveMixOutMs(
        recalculatedMs: 170000,
        positionMs: 20000,
        currentMixOutMs: 180000,
      ),
      170000,
    );
    expect(kAutoCurveMinLeadMs, 30000);
  });

  test('blindaje de fuente: sin seleccion por cercania de BPM', () {
    final String ld = _read('lib/providers/livedj_provider.dart');
    final String mf = _read('lib/providers/mix_formula.dart');
    final String nx = _read('lib/core/livedj_next.dart');
    expect(ld.contains('pickStealthNextIndex'), isFalse);
    expect(mf.contains('pickStealthNextIndex'), isFalse);
    expect(nx.contains('pickStealthNextIndex'), isFalse);
    // 3.1.88: _nextQueueIndex es de una linea y delega en liveDjHeadIndex.
    final int a = ld.indexOf('int _nextQueueIndex() =>');
    expect(a, greaterThanOrEqualTo(0));
    final String body = ld.substring(a, ld.indexOf(';', a));
    expect(body.contains('stealth'), isFalse);
    expect(body.contains('mixFormula'), isFalse);
    expect(body.contains('liveDjHeadIndex('), isTrue);
    final int h = ld.indexOf('int liveDjHeadIndex(');
    expect(h, greaterThanOrEqualTo(0));
    final String head = ld.substring(h, ld.indexOf(');', h));
    expect(head.contains('offAirNextIndex('), isTrue);
    expect(head.contains('stealth'), isFalse);
    expect(head.contains('mixFormula'), isFalse);
    expect(head.toLowerCase().contains('bpm'), isFalse);
    final int b = ld.indexOf('void _applyAutoCurve() {');
    final String auto = ld.substring(b, ld.indexOf('\n  }\n', b));
    expect(auto.contains('autoCurveMixOutMs('), isTrue);
  });
}

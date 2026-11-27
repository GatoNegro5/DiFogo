// 3.2.31: estacion "fantasma" (Gabriel: sonando Rock salio Gipsy King y el
// Hub mostro Tropical marcado). El motor no cambio de estacion: Solituda es
// de Rock (carpeta Espanola -> Rock Clasico Espanol) y los vistos del Hub
// quedaban sembrados con la estacion anterior. Ahora los vistos siguen a la
// estacion activa y cada cambio de estacion deja traza con su origen.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/genre_stations.dart';
import 'package:difogo/providers/vibe_hub_provider.dart';

GenreStation _st(String key, List<String> subs) =>
    GenreStation(key, key, subs, 10);

void main() {
  final List<GenreStation> stations = <GenreStation>[
    _st('tropical', <String>['Merengue', 'Salsa', 'Cumbia']),
    _st('rock', <String>['Rock Clásico Español', 'Heavy Metal', 'Grunge']),
  ];

  test('los vistos siguen a la estacion activa (Tropical -> Rock)', () {
    final StationChecks c = StationChecks(stations)
      ..seed(key: 'tropical', saved: <String>['Merengue']);
    expect(c.master('tropical'), isTrue);
    expect(c.master('rock'), isFalse);
    final bool moved = c.follow('rock', saved: <String>['Heavy Metal']);
    expect(moved, isTrue);
    expect(c.master('rock'), isTrue);
    expect(c.master('tropical'), isFalse);
    expect(c.pick()!.key, 'rock');
    expect(c.pick()!.value, <String>['Heavy Metal']);
  });

  test('seguir la misma estacion no pisa los vistos del usuario', () {
    final StationChecks c = StationChecks(stations)
      ..seed(key: 'rock', saved: <String>['Heavy Metal', 'Grunge']);
    c.toggleSub('rock', 'Grunge');
    expect(c.follow('rock', saved: <String>['Heavy Metal', 'Grunge']), isFalse);
    expect(c.picked('rock'), <String>['Heavy Metal']);
    expect(c.follow('no-existe'), isFalse);
    expect(c.master('rock'), isTrue);
  });

  test('origen del cambio: llamadores fuera del provider', () {
    final StackTrace st = StackTrace.fromString(
      '#0      VibeHubNotifier.playStation (package:difogo/providers/vibe_hub_provider.dart:605:5)\n'
      '#1      _VibeHubViewState._tapPlay (package:difogo/ui/vibe_hub_view.dart:80:31)\n'
      '#2      _rootRun (dart:async/zone.dart:1399:13)\n'
      '#3      main (file:///C:/GatoMix/test/x_test.dart:10:3)\n',
    );
    expect(stationCallers(st), 'vibe_hub_view.dart:80<x_test.dart:10');
    expect(stationCallers(StackTrace.fromString('')), '?');
  });

  test('fuente: Hub sigue la activa y playStation/_startPlan trazan', () {
    final String view = File('lib/ui/vibe_hub_view.dart').readAsStringSync();
    expect(view, contains('c.follow(act'));
    final String hub = File(
      'lib/providers/vibe_hub_provider.dart',
    ).readAsStringSync();
    expect(hub, contains("'ESTACION play \$key desde="));
    expect(hub, contains("'ESTACION activa "));
    // La traza va a la bitacora de Live DJ.
    expect(hub, contains("import '../core/dj_trace.dart' show djTrace;"));
  });

  test('Espanola sigue en Rock (decision de producto pendiente)', () {
    expect(stationSubOf('Española'), isNotNull);
  });
}

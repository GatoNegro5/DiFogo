import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/genre_stations.dart';
import 'package:difogo/core/persistent_lists.dart';
import 'package:difogo/providers/vibe_hub_provider.dart';
import 'package:difogo/ui/vibe_hub_view.dart';
import 'package:difogo/ui/workspaces/automix_workspace.dart'
    show mixFolderPathOf;

// 3.2.7: "Mezclar todo" / "Cargar" de carpeta -> lista persistente
// folder:<ruta> en Automix y Live DJ, y boton "Reiniciar lista" con
// confirmacion. Todo en %TEMP%; nunca la biblioteca real.

String get _sep => Platform.pathSeparator;

/// Fuente sin espacios ni saltos (independiente del formato).
String _flat(String rel) =>
    File(rel).readAsStringSync().replaceAll(RegExp(r'\s+'), '');

String _body(String src, String from, String to) {
  final int a = src.indexOf(from);
  expect(a, greaterThanOrEqualTo(0), reason: from);
  final int b = src.indexOf(to, a + from.length);
  expect(b, greaterThan(a), reason: to);
  return src.substring(a, b);
}

List<String> _tracks(String dir, int n) => <String>[
  for (int i = 0; i < n; i++)
    '$dir${_sep}Tema ${i.toString().padLeft(2, '0')}.mp3',
];

void main() {
  test('Automix: Mezclar todo y Cargar Todo usan loadFolderList', () {
    final String aw = _flat('lib/ui/workspaces/automix_workspace.dart');
    final String mix = _body(
      aw,
      'onMixFolder:(List<File>files)async{',
      'StringmixFolderPathOf(',
    );
    expect(mix.contains('.loadFolderList(mixFolderPathOf(files),'), isTrue);
    expect(mix.contains('play:true'), isTrue);
    // Ya no se mezcla dentro del genero activo.
    expect(mix.contains('syncDynamicPlaylist('), isFalse);
    expect(mix.contains('jumpToTrack('), isFalse);
    expect(mix.contains('.addAll(files)'), isFalse);
    final String load = _body(
      aw,
      'onPressed:folderFiles.isEmpty',
      'Icons.playlist_add',
    );
    expect(load.contains('.loadFolderList(dirState.currentPath,'), isTrue);
    expect(load.contains('.addAll(folderFiles)'), isFalse);
    // Boton en la barra de la cola, solo con lista activa.
    final int sweep = aw.indexOf('Icons.delete_sweep');
    final int reset = aw.indexOf(
      '.activePersistentListKey!=null)PersistentListResetButton(',
    );
    expect(sweep, greaterThan(0));
    expect(reset, greaterThan(sweep));
    expect(aw.contains('.restartActivePersistentList(),'), isTrue);
  });

  test('Live DJ: Mezclar todo y Cargar Carpeta usan playFolderList', () {
    final String lw = _flat('lib/ui/workspaces/livedj_workspace.dart');
    final String mix = _body(
      lw,
      'Future<void>_liveDjMix(WidgetRefref,List<File>files)async{',
      'classLiveDjFolderPanel',
    );
    expect(
      mix.contains('.playFolderList(mixFolderPathOf(files),files)'),
      isTrue,
    );
    expect(mix.contains('addAllTracks('), isFalse);
    expect(mix.contains('playTrackFromQueue('), isFalse);
    final String load = _body(
      lw,
      'onPressed:folderFiles.isEmpty',
      // 3.2.29: el boton ahora dice lo que hace.
      '"Ponerset(8)"',
    );
    expect(load.contains('.playFolderList(dirState.currentPath,'), isTrue);
    expect(load.contains('addAllTracks('), isFalse);
    final int borrar = lw.indexOf('tooltip:"BorrarCola"');
    final int reset = lw.indexOf(
      '.activePersistentListKey!=null)PersistentListResetButton(',
    );
    expect(borrar, greaterThan(0));
    expect(reset, greaterThan(borrar));
    expect(lw.contains('.restartActivePersistentList(),'), isTrue);
  });

  test('Hub y providers: reinicio con confirmacion y recarga', () {
    final String hv = _flat('lib/ui/vibe_hub_view.dart');
    expect(hv.contains('n.hasStationProgress(pick.key)'), isTrue);
    expect(hv.contains('()=>n.resetStationList(pick.key)'), isTrue);
    expect(hv.contains('runPersistentListReset('), isTrue);
    expect(hv.contains('confirmPersistentListReset(context)'), isTrue);

    final String am = _flat('lib/providers/automix_provider.dart');
    final String sw = _body(
      am,
      'Future<bool>_switchPersistentQueue(',
      'Future<void>_loadPersistentQueue(',
    );
    expect(sw.contains('_isCrossfading||_drift.preRollActive'), isTrue);
    final String ar = _body(
      am,
      'Future<bool>restartActivePersistentList()async{',
      'Future<void>applyManualLyrics(',
    );
    expect(ar.contains('_isCrossfading||_drift.preRollActive'), isTrue);
    expect(ar.indexOf('lists.reset(key);'), greaterThan(0));
    expect(
      ar.indexOf('return_switchPersistentQueue('),
      greaterThan(ar.indexOf('lists.reset(key);')),
    );

    final String dj = _flat('lib/providers/livedj_provider.dart');
    final String pf = _body(
      dj,
      'Future<int>playFolderList(',
      'Future<bool>resetActivePersistentList()',
    );
    expect(
      pf.indexOf('lists.activeKey=key;'),
      lessThan(pf.indexOf('awaitloadStation(')),
    );
    final String dr = _body(
      dj,
      'Future<bool>restartActivePersistentList()async{',
      'voidshuffleQueue(){',
    );
    expect(dr.contains('hub.resetStationList(st,replay:true)'), isTrue);
    expect(dr.contains('playFolderList(key.substring('), isTrue);
  });

  test('mixFolderPathOf: carpeta comun estable de las pistas', () {
    expect(
      mixFolderPathOf(<File>[
        File('C:/Music/Salsa/a.mp3'),
        File('C:/Music/Salsa/Sub/b.mp3'),
        File('C:/Music/Salsa/Otra/c.mp3'),
      ]),
      'C:/Music/Salsa',
    );
    expect(
      mixFolderPathOf(<File>[
        File('/storage/emulated/0/Music/Cumbia/a.mp3'),
        File('/storage/emulated/0/Music/cumbia/b.mp3'),
      ]),
      '/storage/emulated/0/Music/Cumbia',
    );
    expect(
      persistentFolderKey(
        mixFolderPathOf(<File>[File(r'C:\Music\Rock\x.mp3')]),
      ),
      persistentFolderKey(r'C:\Music\Rock\'),
    );
  });

  testWidgets('dialogo Reiniciar lista: Cancelar no toca, Reiniciar llama', (
    WidgetTester t,
  ) async {
    int calls = 0;
    bool result = true;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: PersistentListResetButton(
              onRestart: () async {
                calls++;
                return result;
              },
            ),
          ),
        ),
      ),
    );
    expect(kPersistentListResetLabel, 'Reiniciar lista');
    expect(
      kPersistentListResetQuestion,
      '¿Reiniciar esta lista y barajar desde cero?',
    );
    await t.tap(find.byKey(const Key('persistent-list-reset')));
    await t.pumpAndSettle();
    expect(find.text(kPersistentListResetQuestion), findsOneWidget);
    await t.tap(find.text('Cancelar'));
    await t.pumpAndSettle();
    expect(calls, 0);
    expect(find.byKey(const Key('persistent-list-reset-dialog')), findsNothing);

    await t.tap(find.byKey(const Key('persistent-list-reset')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('persistent-list-reset-ok')));
    await t.pumpAndSettle();
    expect(calls, 1);
    expect(find.byType(SnackBar), findsNothing);

    // No se pudo (mezcla en curso): aviso corto.
    result = false;
    await t.tap(find.byKey(const Key('persistent-list-reset')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('persistent-list-reset-ok')));
    await t.pump();
    expect(calls, 2);
    expect(find.byType(SnackBar), findsOneWidget);
    await t.pump(const Duration(seconds: 3));
    await t.pumpAndSettle();
  });

  test(
    'Hub: resetStationList borra solo esa estacion y rearma desde cero',
    () async {
      final Directory tmp = Directory.systemTemp.createTempSync('gmx_ui_3207_');
      PersistentListsStore.debugForgetAll();
      int clock = 1000;
      debugPersistentNow = () => clock += 10;
      debugStationSessionsPath =
          '${tmp.path}${_sep}sessions${_sep}difogo_genre_sessions.json';
      debugStationRng = Random(11);
      final List<String> lib = _tracks('${tmp.path}${_sep}Cumbias', 6);
      debugStationCollect = (List<String> subs) async => lib;
      final List<StationPlan> plays = <StationPlan>[];
      debugStationPlay = (StationPlan s) async => plays.add(s);
      debugStationLive = () => const StationLive(null, 0, <String>[]);
      addTearDown(() {
        debugPersistentNow = null;
        debugStationSessionsPath = null;
        debugStationRng = null;
        debugStationCollect = null;
        debugStationPlay = null;
        debugStationLive = null;
        PersistentListsStore.debugForgetAll();
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {}
      });

      ProviderContainer c = ProviderContainer();
      VibeHubNotifier hub = c.read(vibeHubProvider.notifier);
      expect(hub.hasStationProgress('tropical'), isFalse);
      expect(await hub.playStation('tropical', <String>['Cumbias']), 6);
      final StationPlan t1 = plays.last;
      await hub.noteTrackChange(
        t1.currentTrackPath,
        t1.queue.first,
        t1.queue.sublist(1),
      );
      expect(await hub.playStation('rock', <String>['Rock']), 6);
      await hub.stationsSettled;
      expect(hub.hasStationProgress('tropical'), isTrue);
      expect(hub.hasStationProgress('rock'), isTrue);
      expect(hub.activePersistentListKey, 'genre:rock');

      // No suena: solo borra (el siguiente Play arma el orden nuevo).
      final int before = plays.length;
      expect(await hub.resetStationList('tropical'), isTrue);
      expect(plays.length, before);
      expect(hub.hasStationProgress('tropical'), isFalse);
      expect(hub.hasStationProgress('rock'), isTrue);
      expect(hub.stationSession('tropical')!.subGenresChecked, <String>[
        'Cumbias',
      ]);
      expect(c.read(vibeHubProvider).message, contains('lista reiniciada'));
      c.dispose();

      // Persistido: un contenedor nuevo ve el reinicio.
      PersistentListsStore.debugForgetAll();
      c = ProviderContainer();
      addTearDown(c.dispose);
      hub = c.read(vibeHubProvider.notifier);
      expect(hub.hasStationProgress('tropical'), isFalse);
      expect(hub.hasStationProgress('rock'), isTrue);

      // Con replay (boton de la cola de Live DJ): vuelve a sonar desde cero.
      expect(await hub.resetStationList('rock', replay: true), isTrue);
      final StationPlan fresh = plays.last;
      expect(plays.length, before + 1);
      expect(fresh.resumed, isFalse);
      expect(fresh.played, isEmpty);
      expect(
        <String>{fresh.currentTrackPath!, ...fresh.queue}.length,
        lib.length,
      );
      expect(hub.activePersistentListKey, 'genre:rock');
      await hub.stationsSettled;
    },
  );
}

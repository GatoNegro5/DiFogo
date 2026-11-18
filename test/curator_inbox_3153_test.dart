import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/providers/automix_provider.dart';
import 'package:difogo/providers/curator_provider.dart';
import 'package:difogo/providers/session_provider.dart';
import 'package:difogo/services/smart_discovery_service.dart';
import 'package:difogo/ui/curator_inbox_dialog.dart';

/// Cola falsa: no lee ni escribe el estado real de Automix.
class _FakeQueue extends AutomixQueueNotifier {
  @override
  List<File> build() => <File>[];

  @override
  void addTrack(File file) => state = <File>[...state, file];
}

void main() {
  final String sep = Platform.pathSeparator;
  late Directory tmp;
  late String root;
  late String inbox;
  final List<String> queries = <String>[];
  final List<String> registered = <String>[];

  Future<List<DiscoveryCandidate>> fakeSearch(String q) async {
    queries.add(q);
    return const <DiscoveryCandidate>[
      DiscoveryCandidate(
        id: 'mix',
        title: 'Salsa Mix 1 hora',
        duration: Duration(minutes: 60),
      ),
      DiscoveryCandidate(
        id: 'dup',
        title: 'Ya Esta',
        duration: Duration(minutes: 4),
      ),
      DiscoveryCandidate(
        id: 'v1',
        title: 'Tema Uno (Official Audio)',
        duration: Duration(minutes: 4),
      ),
      DiscoveryCandidate(
        id: 'v2',
        title: 'Tema Dos',
        duration: Duration(minutes: 5),
      ),
      DiscoveryCandidate(
        id: 'v3',
        title: 'Tema Tres',
        duration: Duration(minutes: 3),
      ),
    ];
  }

  Future<void> fakeDownload(DiscoveryCandidate c, String mp3) async {
    File(mp3).writeAsStringSync('mp3:${c.id}');
  }

  ProviderContainer make() {
    debugCuratorService = SmartDiscoveryService(
      search: fakeSearch,
      download: fakeDownload,
      inboxDir: inbox,
      now: () => DateTime(2026, 11, 16, 10),
    );
    return ProviderContainer(
      overrides: [automixQueueProvider.overrideWith(_FakeQueue.new)],
    );
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('gmx_curator_3153_');
    root = '${tmp.path}${sep}Musica';
    inbox = '${tmp.path}${sep}Downloads${sep}GatoMix_Inbox';
    File('$root${sep}Salsa${sep}Ya Esta.mp3')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('x');
    debugVibeRootOverride = root;
    debugVibeStatePath = '${tmp.path}${sep}state.json';
    debugDisableCuratorWorker = true;
    debugCuratorRegister = (String p, String g) async =>
        registered.add('$g|$p');
    queries.clear();
    registered.clear();
  });

  tearDown(() {
    debugVibeRootOverride = null;
    debugVibeStatePath = null;
    debugCuratorService = null;
    debugCuratorRegister = null;
    tmp.deleteSync(recursive: true);
  });

  test('sin genero activo no busca nada', () async {
    final c = make();
    expect(await c.read(curatorProvider.notifier).discover(), 0);
    expect(queries, isEmpty);
    c.dispose();
  });

  test('descubre solo temas nuevos del genero y persiste el json', () async {
    final c = make();
    await c.read(vibeProvider.notifier).choose('Salsa');
    expect(await c.read(curatorProvider.notifier).runDaily(), 2);
    expect(queries.single, 'Salsa exitos 2026 official audio');
    final pend = c.read(curatorProvider).pending;
    expect(pend.map((e) => e.id), <String>['v1', 'v2']);
    expect(pend.first.title, 'Tema Uno');
    expect(File(pend.first.file).parent.path, inbox);
    // La misma corrida diaria no se repite el mismo dia.
    expect(await c.read(curatorProvider.notifier).runDaily(), 0);
    expect(queries.length, 1);
    // Buscar mas trae el siguiente.
    expect(await c.read(curatorProvider.notifier).discover(), 1);
    c.dispose();

    final Map json =
        jsonDecode(File('$inbox${sep}curator_inbox.json').readAsStringSync())
            as Map;
    expect(json['lastRun'], <String, dynamic>{'Salsa': '2026-11-16'});
    final c2 = make();
    expect(c2.read(curatorProvider).pending.map((e) => e.id), <String>[
      'v1',
      'v2',
      'v3',
    ]);
    c2.dispose();
  });

  test('agregar mueve a la carpeta del genero y descartar borra', () async {
    final c = make();
    await c.read(vibeProvider.notifier).choose('Salsa');
    await c.read(curatorProvider.notifier).discover(count: 2);
    final pend = c.read(curatorProvider).pending;
    final String? dst = await c.read(curatorProvider.notifier).accept('v1');
    expect(dst, '$root${sep}Salsa${sep}Tema Uno.mp3');
    expect(File(dst!).readAsStringSync(), 'mp3:v1');
    expect(File(pend.first.file).existsSync(), isFalse);
    expect(registered, <String>['Salsa|$dst']);
    expect(c.read(automixQueueProvider).map((f) => f.path), <String>[dst]);

    c.read(curatorProvider.notifier).reject('v2');
    expect(File(pend[1].file).existsSync(), isFalse);
    expect(c.read(curatorProvider).pending, isEmpty);
    // Un descartado no se vuelve a bajar.
    await c.read(curatorProvider.notifier).discover(count: 3);
    expect(c.read(curatorProvider).pending.map((e) => e.id), <String>['v3']);
    c.dispose();
  });

  testWidgets('la bandeja muestra tarjetas, descarta y se cierra', (t) async {
    final c = make();
    await t.runAsync(() async {
      await c.read(vibeProvider.notifier).choose('Salsa');
      await c.read(curatorProvider.notifier).discover(count: 2);
    });
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => Column(
                children: <Widget>[
                  const CuratorInboxButton(),
                  TextButton(
                    onPressed: () => showCuratorInbox(ctx),
                    child: const Text('abrir'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('✨ Acepta Nueva Música (2)'), findsOneWidget);
    await t.tap(find.text('abrir'));
    await t.pumpAndSettle();
    // 3.1.68: caja agrupada por estacion y sub-genero.
    expect(find.text('TROPICAL • Salsa (2 canciones)'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('curator-card-v1')),
      findsOneWidget,
    );
    // 3.1.55: botones de texto claros, sin pulgares.
    expect(find.text('✓ Aceptar'), findsNWidgets(2));
    expect(find.text('✕ Descartar'), findsNWidgets(2));
    expect(find.byIcon(Icons.thumb_up), findsNothing);
    expect(find.byIcon(Icons.thumb_down), findsNothing);
    expect(t.takeException(), isNull);
    await t.tap(find.byKey(const ValueKey<String>('curator-reject-v1')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('curator-card-v1')), findsNothing);
    expect(find.text('Buscar más'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey<String>('curator-later')));
    await t.pumpAndSettle();
    expect(find.byType(CuratorInboxDialog), findsNothing);
    expect(c.read(curatorProvider).pending.map((e) => e.id), <String>['v2']);
    c.dispose();
  });
}

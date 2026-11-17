import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/providers/session_provider.dart';
import 'package:gatomix/providers/vibe_hub_provider.dart';
import 'package:gatomix/ui/startup_vibe_dialog.dart';

void main() {
  late Directory tmp;
  late String root;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('gmx_vibe_3152_');
    root = '${tmp.path}${Platform.pathSeparator}Musica';
    void touch(String rel) {
      final f = File('$root${Platform.pathSeparator}$rel');
      f.parent.createSync(recursive: true);
      f.writeAsStringSync('x');
    }

    touch('Salsa/a (100) - Uno.mp3');
    touch('Salsa/sub/b.mp3');
    touch('Salsa/c.lrc');
    touch('Merengue/d.m4a');
    touch('Salsa_K/e_K.mp3');
    touch('suelta.mp3');
    Directory('$root${Platform.pathSeparator}Vacia').createSync();
  });

  tearDownAll(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('3152 genero = carpeta de primer nivel (Windows y posix)', () {
    expect(
      vibeGenreOf(r'C:\M\ReGenial', r'C:\M\ReGenial\Salsa\x.mp3'),
      'Salsa',
    );
    expect(
      vibeGenreOf(r'C:\M\ReGenial', r'c:\m\regenial\Salsa\s\x.mp3'),
      'Salsa',
    );
    expect(vibeGenreOf('/m/R', '/m/R/Baladas/x.mp3'), 'Baladas');
    expect(vibeGenreOf('/m/R', '/m/R/x.mp3'), isNull);
    expect(vibeGenreOf('/m/R', '/otra/Salsa/x.mp3'), isNull);
  });

  test('3152 candado estricto: solo el genero exacto', () {
    const r = '/m/R';
    expect(vibeAllows(null, r, '/m/R/Rock/x.mp3'), isTrue);
    expect(vibeAllows('Salsa', r, '/m/R/salsa/x.mp3'), isTrue);
    expect(vibeAllows('Salsa', r, '/m/R/Salsa Romantica/x.mp3'), isFalse);
    expect(vibeAllows('Salsa', r, '/m/R/x.mp3'), isFalse);
    expect(
      vibeKeep(
        ['/m/R/Salsa/a.mp3', '/m/R/Rock/b.mp3', '/m/R/Salsa/s/c.mp3'],
        'Salsa',
        r,
      ),
      ['/m/R/Salsa/a.mp3', '/m/R/Salsa/s/c.mp3'],
    );
  });

  test('3152 generos de la carpeta unica en %TEMP%', () async {
    final g = await scanVibeGenres(root);
    expect(g.map((e) => '${e.name}:${e.count}').toList(), [
      'Merengue:1',
      'Salsa:2',
    ]);
  });

  test('3152 la eleccion persiste para el proximo arranque', () async {
    debugVibeStatePath = '${tmp.path}${Platform.pathSeparator}state.json';
    final c1 = ProviderContainer();
    expect(c1.read(vibeProvider).sessionActive, isFalse);
    await c1.read(vibeProvider.notifier).choose('Salsa');
    expect(c1.read(vibeProvider).active, 'Salsa');
    c1.dispose();
    final c2 = ProviderContainer();
    final s = c2.read(vibeProvider);
    expect(s.sessionActive, isTrue);
    expect(s.lastVibe, 'Salsa');
    expect(s.active, isNull);
    await c2.read(vibeProvider.notifier).choose(null);
    c2.dispose();
    final c3 = ProviderContainer();
    expect(c3.read(vibeProvider).sessionActive, isFalse);
    c3.dispose();
    debugVibeStatePath = null;
  });

  // 3.1.61: el modal "mantener genero" paso a "Estabas escuchando ...".
  testWidgets('3152/3161 dialogo de reingreso de estacion', (tester) async {
    Object? got;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => TextButton(
            onPressed: () async {
              got = await showDialog<bool>(
                context: ctx,
                builder: (_) => const StationResumeDialog(
                  info: StationResumeInfo(
                    'tropical',
                    'Tropical & Fiesta',
                    '/m/R/Salsa/a (100) - Uno.mp3',
                    65000,
                  ),
                ),
              );
            },
            child: const Text('abrir'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    expect(
      find.text('Estabas escuchando Tropical & Fiesta — a (100) - Uno (1:05)'),
      findsOneWidget,
    );
    await tester.tap(find.text('Seguir escuchando donde quedó'));
    await tester.pumpAndSettle();
    expect(got, isTrue);
  });
}

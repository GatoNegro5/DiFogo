import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/gatomix_store.dart';
import 'package:difogo/core/lan_sync_plan.dart';
import 'package:difogo/core/library_guard.dart';

// 3.1.81: el documento por carpeta (fuera de la biblioteca) se escribe como
// .difogo.json; el .gatomix.json heredado se sigue leyendo y nunca se borra
// ni se reescribe. Todo en %TEMP%: nada toca ReGenial.

final String _s = Platform.pathSeparator;

void main() {
  late Directory tmp;
  List<String>? roots;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('dfg_3181_');
    roots = debugLibraryRoots;
    // Biblioteca falsa en otra carpeta: tmp queda fuera de la biblioteca.
    debugLibraryRoots = <String>['${tmp.path}${_s}NoEsBiblioteca'];
  });

  tearDown(() {
    debugLibraryRoots = roots;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('3181 nombres: escribe .difogo.json, lee .gatomix.json heredado', () {
    expect(gatomixStoreName, '.difogo.json');
    expect(gatomixOldStoreName, '.gatomix.json');
    final String dir = '${tmp.path}${_s}Salsa';
    Directory(dir).createSync();
    expect(isLibraryPath(dir), isFalse);
    expect(GatomixStore.fileOf(dir).path, '$dir$_s.difogo.json');
    expect(GatomixStore.legacyFileOf(dir).path, '$dir$_s.gatomix.json');
    // Carpeta vacia: sin documento; la lectura apunta al nuevo.
    expect(GatomixStore.hasDocument(dir), isFalse);
    expect(GatomixStore.readFileOf(dir).path, '$dir$_s.difogo.json');
  });

  test('3181 heredado: se lee, la escritura va a .difogo.json y lo viejo '
      'queda intacto', () {
    final String dir = '${tmp.path}${_s}Rock';
    Directory(dir).createSync();
    final File old = File('$dir$_s.gatomix.json')
      ..writeAsStringSync(
        jsonEncode(<String, dynamic>{
          'schema': 1,
          'djMetadata': <String, dynamic>{'viejo.mp3': 101},
        }),
      );
    final String oldText = old.readAsStringSync();
    GatomixStore.forget(<String>[dir]);
    expect(GatomixStore.hasDocument(dir), isTrue);
    expect(GatomixStore.readFileOf(dir).path, old.path);
    expect(GatomixStore.readMap(dir, 'djMetadata')['viejo.mp3'], 101);

    GatomixStore.putSection(dir, 'probe3181', <String, int>{'v': 1});
    final File neu = File('$dir$_s.difogo.json');
    expect(neu.existsSync(), isTrue);
    final Map<String, dynamic> doc =
        jsonDecode(neu.readAsStringSync()) as Map<String, dynamic>;
    // Lo heredado viaja al nuevo: no se pierde nada.
    expect((doc['djMetadata'] as Map)['viejo.mp3'], 101);
    expect(doc['probe3181'], <String, dynamic>{'v': 1});
    // El viejo ni se borra ni se reescribe.
    expect(old.existsSync(), isTrue);
    expect(old.readAsStringSync(), oldText);
    // Desde ahora manda el nuevo.
    GatomixStore.forget(<String>[dir]);
    expect(GatomixStore.readFileOf(dir).path, neu.path);
    expect(GatomixStore.section(dir, 'probe3181'), <String, dynamic>{'v': 1});
    expect(File('$dir$_s.difogo.json.tmp').existsSync(), isFalse);
  });

  test('3181 carpeta nueva: solo .difogo.json; LAN no lo envia ni borra', () {
    final String dir = '${tmp.path}${_s}Nueva';
    Directory(dir).createSync();
    GatomixStore.putSection(dir, 'probe3181', <String, int>{'v': 2});
    expect(File('$dir$_s.difogo.json').existsSync(), isTrue);
    expect(File('$dir$_s.gatomix.json').existsSync(), isFalse);
    expect(lanSyncable('.difogo.json'), isFalse);
    expect(lanSyncable('.gatomix.json'), isFalse);
    expect(lanWipeTarget('.difogo.json'), isNull);
  });
}

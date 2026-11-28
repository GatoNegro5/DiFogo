import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:difogo/core/track_energy.dart';
import 'package:difogo/src/rust/frb_generated.dart';

/// Job de una sola pasada, no entra en la bateria de 30s.
/// Corre solo con GMX_ENERGY_BACKFILL=1 (laptop, biblioteca real).
/// Escribe unicamente en el espejo folder_cache. Nunca en ReGenial.

String _rustLib() {
  final String name = Platform.isWindows
      ? 'rust_lib_gatomix_player.dll'
      : (Platform.isMacOS
            ? 'librust_lib_gatomix_player.dylib'
            : 'librust_lib_gatomix_player.so');
  final File release = File('rust/target/release/$name');
  if (release.existsSync()) return release.path;
  return 'rust/target/debug/$name';
}

void main() {
  final bool run = Platform.environment['GMX_ENERGY_BACKFILL'] == '1';
  final String lib = _rustLib();
  final bool hasLib = File(lib).existsSync();

  test(
    'backfill energia y Camelot de ReGenial (espejo)',
    () async {
      if (!run) return;
      if (!hasLib) {
        fail('sin libreria Rust compilada: $lib');
      }
      if (!RustLib.instance.initialized) {
        await RustLib.init(externalLibrary: ExternalLibrary.open(lib));
      }
      final String? up = Platform.environment['USERPROFILE'];
      final String home = Platform.environment['HOME'] ?? '';
      final String root = Platform.isWindows
          ? '${up ?? 'C:\\\\Users'}\\Music\\ReGenial'
          : '$home/Music/ReGenial';
      if (!Directory(root).existsSync()) {
        fail('no esta ReGenial en $root');
      }
      final File logFile = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}gmx_energy_backfill.log',
      );
      final IOSink sink = logFile.openWrite(mode: FileMode.write);
      void log(String line) {
        // ignore: avoid_print
        print(line);
        sink.writeln(line);
      }

      log('inicio ${DateTime.now().toIso8601String()} root=$root');
      final EnergyBackfillReport r = await backfillLibraryEnergy(
        root: root,
        log: log,
        blockSize: 25,
      );
      log('reporte ${r.toString()}');
      final EnergyRelevelReport rel = await relevelLibraryEnergy(
        root: root,
        log: log,
      );
      log('relevel ${rel.toString()}');
      await sink.flush();
      await sink.close();
      expect(r.scanned, greaterThan(0));
      // Al menos una parte de la biblioteca queda con nivel.
      expect(r.withLevel + rel.withRaw, greaterThan(0));
    },
    skip: run ? false : 'job: export GMX_ENERGY_BACKFILL=1',
    timeout: const Timeout(Duration(minutes: 60)),
  );

  final bool relevelOnly = Platform.environment['GMX_ENERGY_RELEVEL'] == '1';
  test(
    'relevel deciles del espejo (sin decode)',
    () async {
      if (!relevelOnly) return;
      final String? up = Platform.environment['USERPROFILE'];
      final String home = Platform.environment['HOME'] ?? '';
      final String root = Platform.isWindows
          ? '${up ?? 'C:\\Users'}\\Music\\ReGenial'
          : '$home/Music/ReGenial';
      if (!Directory(root).existsSync()) {
        fail('no esta ReGenial en $root');
      }
      final File logFile = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}gmx_energy_backfill.log',
      );
      final IOSink sink = logFile.openWrite(mode: FileMode.append);
      void log(String line) {
        // ignore: avoid_print
        print(line);
        sink.writeln(line);
      }

      log('relevel-only ${DateTime.now().toIso8601String()} root=$root');
      final EnergyRelevelReport rel = await relevelLibraryEnergy(
        root: root,
        log: log,
      );
      await sink.flush();
      await sink.close();
      expect(rel.withRaw, greaterThan(0));
      log('relevel ${rel.toString()}');
    },
    skip: relevelOnly ? false : 'job: export GMX_ENERGY_RELEVEL=1',
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

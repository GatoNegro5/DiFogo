// 3.2.33 (DIF-30): arreglo automatico de empalmes. Rust rechaza el temporal
// con "Empalme evitado" (duracion contra la fuente o detector); aqui se
// descarta, se rehace desde la fuente hasta 2 veces y, si sigue, no se
// instala y queda una linea en <temp>/difogo_empalmes.log. Sin dialogos.
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// Reintentos ademas del primer intento (igual que Rust SPLICE_RETRIES).
const int kSpliceRetries = 2;

bool isSpliceError(Object e) => e.toString().contains('Empalme evitado');

/// La fuente ya viene empalmada: rehacer no sirve.
bool isSpliceNoRetry(Object e) => e.toString().contains('sin reintento');

@visibleForTesting
String? spliceLogOverride;

String spliceLogPath() =>
    spliceLogOverride ??
    '${Directory.systemTemp.path}${Platform.pathSeparator}difogo_empalmes.log';

/// Una linea por caso agotado (se recorta sola al pasar 200 KB).
void logSpliceEvent(String what, Object e) {
  try {
    final File f = File(spliceLogPath());
    if (f.existsSync() && f.lengthSync() > 200000) f.writeAsStringSync('');
    final String msg = e.toString().replaceAll('\n', ' ');
    f.writeAsStringSync(
      '${DateTime.now().toIso8601String()}\t$what\t$msg\n',
      mode: FileMode.append,
    );
  } catch (_) {}
}

/// Corre `run`; si falla por empalme, `redo(n)` rehace la fuente (n = 1..)
/// y se vuelve a correr, hasta `retries` veces. Otros errores y los de
/// "sin reintento" salen tal cual.
Future<T> retryOnSplice<T>({
  required Future<T> Function() run,
  required Future<void> Function(int attempt) redo,
  int retries = kSpliceRetries,
}) async {
  int attempt = 0;
  while (true) {
    try {
      return await run();
    } catch (e) {
      if (!isSpliceError(e) || isSpliceNoRetry(e) || attempt >= retries) {
        rethrow;
      }
      attempt++;
      await redo(attempt);
    }
  }
}

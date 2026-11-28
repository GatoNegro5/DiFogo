import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'brand_paths.dart' show migrateBrandFile, kLivedjTraceName, kOldLivedjTraceName;

/// Las pruebas apuntan la bitácora a una carpeta temporal propia.
@visibleForTesting
String? djTraceFileOverride;

/// Bitacora de decisiones del mezclador (solo diagnostico, no toca el audio).
/// Archivo: `<temp>/gatomix_livedj_trace.txt` (3.2.35; si solo esta el
/// `difogo_livedj_trace.txt` se copia y no se borra; se recorta al pasar
/// 300 KB).
void djTrace(String msg) {
  try {
    final File f = File(
      djTraceFileOverride ??
          migrateBrandFile(
            Directory.systemTemp.path,
            kOldLivedjTraceName,
            kLivedjTraceName,
          ),
    );
    if (f.existsSync() && f.lengthSync() > 300000) f.writeAsStringSync('');
    f.writeAsStringSync(
      '${DateTime.now().toIso8601String()} $msg\n',
      mode: FileMode.append,
    );
  } catch (_) {}
}

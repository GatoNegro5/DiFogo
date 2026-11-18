import 'package:flutter/material.dart';

/// 3.1.83: linea roja del punto de mezcla en toda barra de progreso de
/// AutomixDj (Modo Spotify, consola clasica y vista de la carpeta).
/// `mixMs` = `customMixOutMs` de `liveDjProvider` (el mismo valor que
/// dispara el cruce); `inset` = margen horizontal del riel del Slider.
Widget liveDjMixMarker(double inset, int mixMs, int durMs) {
  if (mixMs <= 0 || durMs <= 0 || mixMs >= durMs) {
    return const SizedBox.shrink();
  }
  return Positioned.fill(
    child: IgnorePointer(
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints c) {
          final double w = c.maxWidth - inset * 2;
          final double x = inset + w * (mixMs / durMs).clamp(0.0, 1.0);
          return Stack(
            children: <Widget>[
              Positioned(
                key: const Key('livedj-mix-marker'),
                left: x - 1,
                top: 0,
                bottom: 0,
                child: Container(width: 2, color: Colors.redAccent),
              ),
            ],
          );
        },
      ),
    ),
  );
}

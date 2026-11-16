import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/providers/theme_provider.dart';

void main() {
  test('3.1.55 DiFogo Theme: negro profundo y acentos fuego', () {
    expect(GatoMixTheme.bgDark, const Color(0xFF0A0A0A));
    expect(GatoMixTheme.fire, const Color(0xFFFF5722));
    expect(GatoMixTheme.syncActive, GatoMixTheme.fire);
    final ThemeData t = GatoMixTheme.darkTheme;
    expect(t.scaffoldBackgroundColor, const Color(0xFF0A0A0A));
    expect(t.colorScheme.primary, const Color(0xFFFF5722));
    expect(t.sliderTheme.activeTrackColor, const Color(0xFFFF5722));
    expect(t.progressIndicatorTheme.color, const Color(0xFFFF5722));
    expect(
      t.checkboxTheme.fillColor!.resolve(<WidgetState>{WidgetState.selected}),
      const Color(0xFFFF5722),
    );
  });
}

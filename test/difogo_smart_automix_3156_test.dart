import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/providers/theme_provider.dart';

// 3.1.56 DiFogo Smart AutoMix: paleta mate y AutoMix sin neon fijo.
void main() {
  test('constantes nuevas y existentes del tema', () {
    expect(GatoMixTheme.bgDark, const Color(0xFF0F1115));
    expect(GatoMixTheme.bgPanel, const Color(0xFF181B21));
    expect(GatoMixTheme.surfaceHover, const Color(0xFF22262F));
    expect(GatoMixTheme.techCyan, const Color(0xFF00E5FF));
    expect(GatoMixTheme.statusReady, const Color(0xFF10B981));
    expect(GatoMixTheme.borderSubtle, const Color(0xFF2A2F38));
    expect(GatoMixTheme.cyanAccent, GatoMixTheme.techCyan);
    expect(GatoMixTheme.fire, const Color(0xFFFF5722));
    expect(GatoMixTheme.syncActive, GatoMixTheme.fire);
    expect(GatoMixTheme.deckB, GatoMixTheme.fire);
    expect(GatoMixTheme.deckA, const Color(0xFF2E9BFF));
  });

  test('ColorScheme, tarjetas, dialogos y hover', () {
    final ThemeData t = GatoMixTheme.darkTheme;
    expect(t.colorScheme.primary, GatoMixTheme.fire);
    expect(t.colorScheme.secondary, GatoMixTheme.techCyan);
    expect(t.colorScheme.surface, GatoMixTheme.bgPanel);
    expect(t.scaffoldBackgroundColor, GatoMixTheme.bgDark);
    expect(t.hoverColor, GatoMixTheme.surfaceHover);
    expect(t.cardTheme.color, GatoMixTheme.surfaceHover);
    expect(t.dialogTheme.backgroundColor, GatoMixTheme.surfaceHover);
    expect(
      (t.cardTheme.shape! as RoundedRectangleBorder).side.color,
      GatoMixTheme.borderSubtle,
    );
    expect(t.textTheme.bodyMedium!.fontFamily, 'Consolas');
  });

  test('automix_workspace sin literales neon de GatoMix', () {
    final String src = File(
      'lib/ui/workspaces/automix_workspace.dart',
    ).readAsStringSync().toUpperCase();
    for (final String hex in <String>[
      '0XFFFF007F',
      '0XFF39FF14',
      '0XFF00FFFF',
      '0XFF121212',
    ]) {
      expect(src.contains(hex), isFalse, reason: hex);
    }
    expect(src.contains('GATOMIXTHEME.STATUSREADY'), isTrue);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class GatoMixTheme {
  // 3.1.55 DiFogo Theme: negro profundo, grises carbon y acentos fuego.
  static const Color fire = Color(0xFFFF5722); // Rojo brasa (marca DiFogo)
  static const Color ember = Color(0xFFFF7A1A); // Naranja intenso
  static const Color bgDark = Color(0xFF0F1115); // 3.1.56 base mate
  static const Color bgPanel = Color(0xFF181B21); // 3.1.56 tarjetas
  static const Color surfaceHover = Color(0xFF22262F); // 3.1.56 hover/elevado
  static const Color techCyan = Color(0xFF00E5FF); // 3.1.56 cian tecnico
  static const Color statusReady = Color(0xFF10B981); // 3.1.56 OK/Listo
  static const Color borderSubtle = Color(0xFF2A2F38); // 3.1.56 bordes

  static const Color deckA = Color(0xFF2E9BFF); // Deck A azul Traktor
  static const Color deckB = fire; // Deck B fuego
  static const Color cyanAccent = techCyan; // 3.1.56 cian tecnico

  // Estados Críticos del Sistema
  // 3.1.55: el verde neon pasa a fuego (Sync, botones activos, sliders).
  static const Color syncActive = fire;
  static const Color masterPeak = Color(
    0xFFFFC400,
  ); // Ámbar/Oro (Alertas/Master)
  static const Color alertCritical = Color(
    0xFFFF1744,
  ); // Rojo Escarlata (On Air/Errores)

  // Tipografía con tintes profesionales (Cero transparencias sucias)
  static const Color textMain = Color(0xFFF8F9FA); // Blanco Ártico puro
  static const Color textMuted = Color(
    0xFF8A93A2,
  ); // Gris Técnico (Mejor contraste que white54)
  static const Color textHidden = Color(
    0xFF3E4551,
  ); // Gris Oscuro para elementos deshabilitados

  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bgDark,
      fontFamily: 'Consolas',
      colorScheme: const ColorScheme.dark(
        primary: syncActive,
        secondary: cyanAccent,
        surface: bgPanel,
        error: alertCritical,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: bgPanel,
          foregroundColor: textMain,
          side: const BorderSide(color: borderSubtle),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          elevation: 0,
        ),
      ),
      sliderTheme: const SliderThemeData(
        trackHeight: 3,
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
        activeTrackColor: syncActive,
        inactiveTrackColor: borderSubtle,
        thumbColor: ember,
        overlayColor: Color(0x33FF5722),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: fire,
        linearTrackColor: borderSubtle,
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (Set<WidgetState> s) =>
              s.contains(WidgetState.selected) ? fire : null,
        ),
        checkColor: const WidgetStatePropertyAll<Color>(Colors.black),
        side: const BorderSide(color: textMuted),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (Set<WidgetState> s) =>
              s.contains(WidgetState.selected) ? ember : null,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (Set<WidgetState> s) =>
              s.contains(WidgetState.selected) ? const Color(0x80FF5722) : null,
        ),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: textMuted,
        textColor: textMain,
      ),
      iconTheme: const IconThemeData(color: textMuted),
      // 3.1.56 DiFogo Smart AutoMix: tarjetas, dialogos y hover elevados.
      hoverColor: surfaceHover,
      cardTheme: CardThemeData(
        color: surfaceHover,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: borderSubtle),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surfaceHover,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: borderSubtle),
        ),
      ),
    );
  }
}

final themeProvider = Provider<ThemeData>((ref) => GatoMixTheme.darkTheme);

final mobileNavOpenProvider = StateProvider<bool>((ref) => false);

class GatoMixMobileModeBar extends StatelessWidget {
  final String title;
  final Color accent;
  final bool open;
  final VoidCallback onTap;
  final bool expand;

  const GatoMixMobileModeBar({
    super.key,
    required this.title,
    required this.accent,
    required this.open,
    required this.onTap,
    this.expand = true,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: GatoMixTheme.bgDark,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 36,
          width: expand ? double.infinity : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
              children: [
                Icon(open ? Icons.close : Icons.menu, size: 18, color: accent),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: TextStyle(
                    color: accent,
                    fontFamily: 'Consolas',
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  open ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: GatoMixTheme.textMuted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

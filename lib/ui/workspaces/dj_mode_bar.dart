import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/dj_lyrics.dart';
import '../../providers/dj_ui_provider.dart';
import '../../providers/livedj_provider.dart';
import '../../providers/theme_provider.dart';
import '../widgets/theater_lyrics_view.dart';

/// 3.2.30: etiquetas del segmentado de Dj.
const Map<DjMode, String> kDjModeLabels = <DjMode, String>{
  DjMode.automix: 'Automix',
  DjMode.radio: 'Radio',
  DjMode.fiesta: 'Fiesta',
};

const Map<DjMode, String> kDjModeHelp = <DjMode, String>{
  DjMode.automix:
      'AUTOMIX: suena lo que elegiste (género o carpeta) con mezcla normal.',
  DjMode.radio:
      'RADIO: tu género con temas nuevos del curador (Radio Descubrimiento).',
  DjMode.fiesta:
      'FIESTA: sets de 8 por género y rotación automática, sin repetir.',
};

const String kDjLyricsLabel = 'Letras';
const String kDjNoLyrics = 'Sin letra';

/// 3.2.30: segmentado [Automix | Radio | Fiesta] de la cabecera de Dj.
/// Cambiar de modo nunca corta la pista que suena.
class DjModeBar extends ConsumerWidget {
  const DjModeBar({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DjMode mode = ref.watch(djUiProvider.select((DjUiState s) => s.mode));
    final double h = compact ? 30 : 32;
    return Container(
      key: const Key('dj-mode-bar'),
      height: h,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: GatoMixTheme.bgPanel,
        border: Border.all(color: Colors.white24),
        borderRadius: BorderRadius.circular(h / 2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final DjMode m in DjMode.values)
            _segment(ref, m, selected: m == mode, height: h - 6),
        ],
      ),
    );
  }

  Widget _segment(
    WidgetRef ref,
    DjMode m, {
    required bool selected,
    required double height,
  }) {
    return Tooltip(
      message: kDjModeHelp[m]!,
      child: GestureDetector(
        key: Key('dj-mode-${m.name}'),
        behavior: HitTestBehavior.opaque,
        onTap: () => ref.read(djUiProvider.notifier).setMode(m),
        child: Container(
          height: height,
          constraints: BoxConstraints(minWidth: compact ? 58 : 68),
          padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? GatoMixTheme.fire : Colors.transparent,
            borderRadius: BorderRadius.circular(height / 2),
          ),
          child: Text(
            kDjModeLabels[m]!,
            maxLines: 1,
            style: TextStyle(
              color: selected ? Colors.black : Colors.white70,
              fontWeight: selected ? FontWeight.bold : FontWeight.w600,
              fontSize: compact ? 11 : 12,
            ),
          ),
        ),
      ),
    );
  }
}

/// 3.2.30: boton Letras: muestra u oculta la letra sincronizada de la pista
/// que suena (se recuerda al salir).
class DjLyricsButton extends ConsumerWidget {
  const DjLyricsButton({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool on = ref.watch(djUiProvider.select((DjUiState s) => s.lyrics));
    final Color color = on ? GatoMixTheme.syncActive : Colors.white54;
    return Tooltip(
      message: on
          ? 'LETRAS VISIBLES: la letra de la canción que suena. Toca para ocultar.'
          : 'Toca para ver la letra sincronizada de la canción que suena.',
      child: GestureDetector(
        key: const Key('dj-lyrics-toggle'),
        onTap: () => ref.read(djUiProvider.notifier).toggleLyrics(),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 8 : 10,
            vertical: compact ? 3 : 4,
          ),
          decoration: BoxDecoration(
            color: color.withValues(alpha: on ? 0.14 : 0.04),
            border: Border.all(color: on ? color : Colors.white24),
            borderRadius: BorderRadius.circular(12),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: compact ? 80 : 110),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.lyrics_outlined, size: 14, color: color),
                  const SizedBox(width: 3),
                  Text(
                    kDjLyricsLabel,
                    maxLines: 1,
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 3.2.30: letra de la pista actual de Live DJ bajo la portada. Reusa
/// [TheaterLyricsView] de Mix con Letra sin cambiarlo; al entrar la pista
/// nueva en la mezcla cambia a su letra. Sin letra: "Sin letra" (el audio
/// no se entera).
class DjLyricsPanel extends ConsumerWidget {
  const DjLyricsPanel({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String? path = ref.watch(
      liveDjProvider.select((LiveDjState s) => s.currentTrackPath),
    );
    final Widget body;
    if (path == null) {
      body = _empty();
    } else {
      final AsyncValue<List<DjLyricLine>> lines = ref.watch(
        djLyricsProvider(path),
      );
      body = lines.when(
        data: (List<DjLyricLine> l) =>
            l.isEmpty ? _empty() : _DjLyricsWheel(lines: l, compact: compact),
        loading: () => const SizedBox.shrink(),
        error: (Object _, StackTrace _) => _empty(),
      );
    }
    return Container(
      key: const Key('dj-lyrics-panel'),
      height: compact ? 104 : 140,
      margin: EdgeInsets.fromLTRB(compact ? 6 : 15, 4, compact ? 6 : 15, 4),
      decoration: BoxDecoration(
        color: GatoMixTheme.bgPanel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: ClipRect(child: body),
    );
  }

  Widget _empty() => const Center(
    child: Text(
      kDjNoLyrics,
      key: Key('dj-lyrics-empty'),
      style: TextStyle(color: Colors.white38, fontSize: 13),
    ),
  );
}

class _DjLyricsWheel extends ConsumerWidget {
  const _DjLyricsWheel({required this.lines, required this.compact});

  final List<DjLyricLine> lines;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final int idx = ref.watch(
      liveDjProvider.select(
        (LiveDjState s) => djLyricIndexAt(lines, s.position.inMilliseconds),
      ),
    );
    return TheaterLyricsView(
      lines: <String>[for (final DjLyricLine l in lines) l.text],
      activeIndex: idx,
      compact: compact,
    );
  }
}

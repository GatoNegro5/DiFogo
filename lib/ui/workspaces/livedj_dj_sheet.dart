import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/genre_mix_fx.dart' show mixFormulaLockedProvider;
import '../../providers/livedj_provider.dart';
import '../../providers/mix_formula.dart';
import '../../providers/theme_provider.dart';
import '../../providers/vibe_hub_provider.dart';
import 'livedj_bpm_badge.dart';
import 'livedj_spotify_panel.dart';

/// 3.1.84 Consumer Clean Mode: la jerga de DJ (tipo de mezcla, FX AUTO/FIJO,
/// BPM y cuenta regresiva al punto de mezcla) vive en una sola hoja
/// "Modo DJ" que se abre desde el boton de sliders de la cabecera de
/// AutomixDj. Reusa los mismos providers: no hay estado duplicado.

// 3.1.85: sin emoji; el icono de sliders va como Icon vectorial.
const String kModoDjLabel = 'Modo DJ';

/// Texto del tipo de mezcla (antes en la barra "TIPO DE MEZCLA").
String liveDjMixTypeLabel(MixFormula f, {bool bypass = false}) {
  if (bypass) return 'BYPASS (MEZCLA PROTEGIDA)';
  switch (f) {
    case MixFormula.stealthGap:
      return 'STEALTH 60% (SIN VOZ)';
    case MixFormula.phraseGrid:
      return 'PHRASE 8 (GRID 4/4)';
    case MixFormula.dnaEnergy:
      return 'ACTIVE BEATMATCHING (DNA DJ 60-80%)';
  }
}

Color liveDjMixTypeColor(MixFormula f, {bool bypass = false}) {
  if (bypass) return GatoMixTheme.cyanAccent;
  switch (f) {
    case MixFormula.stealthGap:
      return GatoMixTheme.deckB;
    case MixFormula.phraseGrid:
      return GatoMixTheme.deckA;
    case MixFormula.dnaEnergy:
      return GatoMixTheme.syncActive;
  }
}

Future<void> showLiveDjModeDjSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: GatoMixTheme.bgPanel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (BuildContext _) => const SafeArea(child: LiveDjModeDjPanel()),
    );

/// Boton de sliders de la cabecera (escritorio con texto, movil solo icono).
class LiveDjModeDjButton extends StatelessWidget {
  const LiveDjModeDjButton({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '$kModoDjLabel: tipo de mezcla, FX y BPM',
      child: InkWell(
        key: const Key('livedj-mode-dj-button'),
        borderRadius: BorderRadius.circular(18),
        onTap: () => showLiveDjModeDjSheet(context),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 6 : 10,
            vertical: 4,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.tune_rounded, size: 22, color: Colors.white70),
              if (!compact) ...<Widget>[
                const SizedBox(width: 6),
                const Text(
                  'Modo DJ',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Contenido de la hoja Modo DJ.
class LiveDjModeDjPanel extends ConsumerWidget {
  const LiveDjModeDjPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final LiveDjState s = ref.watch(liveDjProvider);
    final MixFormula formula = ref.watch(mixFormulaProvider);
    final bool bypass = s.currentMixMode == LiveDjMixMode.longBypass;
    final String? station = ref.watch(
      vibeHubProvider.select((VibeHubState h) => h.activeStation),
    );
    final Color mixColor = liveDjMixTypeColor(formula, bypass: bypass);
    final String? path =
        s.currentTrackPath ?? (s.queue.isNotEmpty ? s.queue.first.path : null);

    Widget section(String title, Widget child) => Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.4,
            ),
          ),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        key: const Key('livedj-mode-dj-panel'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Row(
            children: <Widget>[
              Icon(Icons.tune_rounded, size: 18, color: Colors.white),
              SizedBox(width: 6),
              Text(
                kModoDjLabel,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          section(
            'TIPO DE MEZCLA',
            GestureDetector(
              key: const Key('dj-mix-type'),
              onTap: bypass
                  ? null
                  : () {
                      // 3.1.73: elegir a mano fija la curva.
                      ref.read(mixFormulaLockedProvider.notifier).state = true;
                      ref
                          .read(mixFormulaProvider.notifier)
                          .state = formula == MixFormula.dnaEnergy
                          ? MixFormula.phraseGrid
                          : (formula == MixFormula.phraseGrid
                                ? MixFormula.stealthGap
                                : MixFormula.dnaEnergy);
                    },
              child: Tooltip(
                message:
                    '1 DNA 60-80%  ·  2 Phrase 8  ·  3 Stealth sin voz. '
                    'Toca para cambiar. Nunca cambia la siguiente canción.',
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: mixColor.withValues(alpha: 0.6)),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    liveDjMixTypeLabel(formula, bypass: bypass),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: mixColor,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          ),
          section(
            'EFECTO (AUTO / FIJO)',
            const MixFxBadge(badgeKey: Key('dj-fx-badge')),
          ),
          section(
            'BPM Y PUNTO DE MEZCLA',
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                LiveDjBpmChip(path: path, fontSize: 12),
                Text(
                  spotifyNextMixLabel(s),
                  key: const Key('dj-next-mix'),
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
          section(
            'ESTACIÓN',
            Text(
              spotifyStationBadge(station),
              key: const Key('dj-station'),
              style: const TextStyle(
                color: Color(0xFFFF5722),
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

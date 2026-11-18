import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/curator_provider.dart';
import '../../providers/vibe_hub_provider.dart';
import '../../services/smart_discovery_service.dart'
    show CuratorEntry, CuratorStatus;

/// 3.1.87: Guardar y Descartar en 1 clic para la pista que suena cuando es
/// de la Radio Descubrimiento (temporal, aun no guardada). Con cualquier
/// otra pista no ocupa espacio.
class RadioTrackActions extends ConsumerWidget {
  const RadioTrackActions({
    super.key,
    required this.path,
    required this.onSkip,
    this.size = 22,
  });

  /// Pista que suena ahora.
  final String? path;

  /// Siguiente por el camino normal del motor (con cruce).
  final Future<void> Function() onSkip;

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String? p = path;
    final bool on = ref.watch(
      vibeHubProvider.select((VibeHubState s) => s.discoveryOn),
    );
    if (!on || p == null || p.isEmpty) return const SizedBox.shrink();
    final String k = p.replaceAll('\\', '/').toLowerCase();
    final CuratorEntry? e = ref.watch(
      curatorProvider.select((CuratorState s) {
        for (final CuratorEntry x in s.entries) {
          if (x.status == CuratorStatus.pending &&
              x.file.replaceAll('\\', '/').toLowerCase() == k) {
            return x;
          }
        }
        return null;
      }),
    );
    if (e == null) return const SizedBox.shrink();
    final CuratorNotifier cur = ref.read(curatorProvider.notifier);
    final ScaffoldMessengerState? msg = ScaffoldMessenger.maybeOf(context);
    final BoxConstraints box = BoxConstraints.tightFor(
      width: size + 12,
      height: size + 12,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        IconButton(
          key: const Key('radio-save'),
          tooltip: 'Guardar en mi biblioteca (con letra)',
          padding: EdgeInsets.zero,
          constraints: box,
          visualDensity: VisualDensity.compact,
          onPressed: () {
            unawaited(() async {
              try {
                final String? dst = await cur.saveFromRadio(e.id);
                if (dst != null) {
                  msg?.showSnackBar(
                    const SnackBar(content: Text('Guardada en tu biblioteca')),
                  );
                }
              } catch (err) {
                msg?.showSnackBar(
                  SnackBar(content: Text('No se pudo guardar: $err')),
                );
              }
            }());
          },
          icon: Icon(
            Icons.favorite_border_rounded,
            size: size,
            color: const Color(0xFF39FF14),
          ),
        ),
        IconButton(
          key: const Key('radio-discard'),
          tooltip: 'Descartar (no vuelve a salir)',
          padding: EdgeInsets.zero,
          constraints: box,
          visualDensity: VisualDensity.compact,
          onPressed: () {
            unawaited(
              cur
                  .discardFromRadio(e.id, skip: onSkip)
                  .catchError((Object _) => false),
            );
          },
          icon: Icon(Icons.close_rounded, size: size, color: Colors.white70),
        ),
      ],
    );
  }
}

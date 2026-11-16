import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import '../providers/curator_provider.dart';
import '../providers/session_provider.dart';
import '../services/smart_discovery_service.dart';

/// 3.1.53 Curator Inbox: tarjetas de los temas pendientes con vista previa,
/// Agregar, Descartar, Buscar mas y Ver despues.

const Color _curNeon = Color(0xFF00E676);
const Color _curBg = Color(0xFF121212);
const Color _curCard = Color(0xFF1A222D);

Future<void> showCuratorInbox(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const CuratorInboxDialog(),
);

/// Boton de la barra de Live DJ con el numero de pendientes.
class CuratorInboxButton extends ConsumerWidget {
  const CuratorInboxButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final int n = ref.watch(curatorProvider.select((s) => s.pending.length));
    return IconButton(
      key: const ValueKey<String>('curator-inbox-button'),
      icon: Badge(
        isLabelVisible: n > 0,
        label: Text('$n'),
        child: const Icon(Icons.inbox, color: _curNeon, size: 18),
      ),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 28, height: 28),
      visualDensity: VisualDensity.compact,
      tooltip: 'Bandeja del curador',
      onPressed: () => showCuratorInbox(context),
    );
  }
}

class CuratorInboxDialog extends ConsumerStatefulWidget {
  const CuratorInboxDialog({super.key});

  @override
  ConsumerState<CuratorInboxDialog> createState() => _CuratorInboxDialogState();
}

class _CuratorInboxDialogState extends ConsumerState<CuratorInboxDialog> {
  Player? _player;
  String? _playing;

  @override
  void dispose() {
    unawaited(_player?.dispose());
    super.dispose();
  }

  Future<void> _togglePreview(CuratorEntry e) async {
    try {
      final Player p = _player ??= Player();
      if (_playing == e.id) {
        await p.stop();
        if (mounted) setState(() => _playing = null);
        return;
      }
      await p.open(Media(e.file));
      if (mounted) setState(() => _playing = e.id);
    } catch (err) {
      debugPrint('[CURATOR] vista previa: $err');
    }
  }

  Future<void> _stopIf(String id) async {
    if (_playing != id) return;
    try {
      await _player?.stop();
    } catch (_) {}
    if (mounted) setState(() => _playing = null);
  }

  @override
  Widget build(BuildContext context) {
    final CuratorState s = ref.watch(curatorProvider);
    final String? vibe = ref.watch(vibeProvider.select((v) => v.active));
    final List<CuratorEntry> items = s.pending;
    return Dialog(
      backgroundColor: _curBg,
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                vibe == null
                    ? 'Bandeja del curador'
                    : 'Bandeja del curador · $vibe',
                style: const TextStyle(
                  color: _curNeon,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              if (s.message != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    s.message!,
                    style: const TextStyle(color: Colors.orangeAccent),
                  ),
                ),
              Flexible(
                child: items.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Text(
                          'No hay temas pendientes.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white54),
                        ),
                      )
                    : ListView.builder(
                        key: const ValueKey<String>('curator-list'),
                        shrinkWrap: true,
                        itemCount: items.length,
                        itemBuilder: (_, int i) => _card(items[i]),
                      ),
              ),
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const ValueKey<String>('curator-more'),
                      onPressed: s.busy || vibe == null
                          ? null
                          : () => unawaited(
                              ref.read(curatorProvider.notifier).discover(),
                            ),
                      icon: s.busy
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh),
                      label: const Text(
                        'Buscar más',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _curNeon,
                        minimumSize: const Size(0, 48),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextButton(
                      key: const ValueKey<String>('curator-later'),
                      onPressed: () => Navigator.of(context).pop(),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white70,
                        minimumSize: const Size(0, 48),
                      ),
                      child: const Text(
                        'Ver después',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _card(CuratorEntry e) {
    final bool on = _playing == e.id;
    return Card(
      key: ValueKey<String>('curator-card-${e.id}'),
      color: _curCard,
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        child: Row(
          children: <Widget>[
            IconButton(
              tooltip: on ? 'Detener' : 'Escuchar',
              icon: Icon(
                on ? Icons.stop_circle : Icons.play_circle,
                color: Colors.cyanAccent,
              ),
              onPressed: () => unawaited(_togglePreview(e)),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    e.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white),
                  ),
                  Text(
                    e.genre,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
            IconButton(
              key: ValueKey<String>('curator-accept-${e.id}'),
              tooltip: 'Agregar a ${e.genre}',
              icon: const Icon(Icons.thumb_up, color: _curNeon),
              onPressed: () async {
                await _stopIf(e.id);
                final String? dst = await ref
                    .read(curatorProvider.notifier)
                    .accept(e.id);
                if (!mounted || dst == null) return;
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                  SnackBar(
                    content: Text(
                      'Agregado: ${dst.split(Platform.pathSeparator).last}',
                    ),
                  ),
                );
              },
            ),
            IconButton(
              key: ValueKey<String>('curator-reject-${e.id}'),
              tooltip: 'Descartar',
              icon: const Icon(Icons.thumb_down, color: Colors.redAccent),
              onPressed: () async {
                await _stopIf(e.id);
                ref.read(curatorProvider.notifier).reject(e.id);
              },
            ),
          ],
        ),
      ),
    );
  }
}

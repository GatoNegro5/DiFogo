import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'package:difogo/src/rust/frb_generated.dart';
import 'package:difogo/core/brand_paths.dart' show migrateBrandCache;
import 'package:difogo/core/audio/dj_audio_handler.dart';
import 'package:difogo/djiphone/iphone_library.dart';
import 'package:difogo/providers/automix_provider.dart';
import 'package:difogo/providers/livedj_provider.dart';
import 'package:difogo/providers/pipeline_provider.dart';
import 'package:difogo/providers/theme_provider.dart';
import 'package:difogo/services/audio_interruption.dart';
import 'package:difogo/services/lyric_retry_queue.dart';
import 'package:difogo/ui/widgets/app_version_label.dart';
import 'package:difogo/ui/widgets/ticker_stack.dart';
import 'package:difogo/ui/workspaces/automix_workspace.dart';
import 'package:difogo/ui/workspaces/dsp_workspace.dart';
import 'package:difogo/ui/workspaces/lab_workspace.dart';
import 'package:difogo/ui/workspaces/lan_sync_workspace.dart';
import 'package:difogo/ui/workspaces/livedj_workspace.dart';

/// Entrada de DjIphone. No es lib/main.dart.
/// Pantallas: AutomixDj (Live DJ), Mix con Letra (Automix), Masterizar,
/// Laboratorio, Comparte Musica (LAN Sync). 3.1.70: solo cambian nombres
/// visibles y orden; indices iguales al player de escritorio (5, 0, 1, 3, 4).
class DjIphoneRouter extends Notifier<int> {
  // 3.1.62: abre siempre en Live DJ, igual que escritorio.
  @override
  int build() => 5;

  void setRoute(int newRoute) {
    final route = _keep(newRoute);
    if (state == route) return;
    state = route;
    _writeRoute(route);
  }

  void persistRoute() => _writeRoute(state);

  int _keep(int route) {
    if (route == 0 || route == 1 || route == 3 || route == 4 || route == 5) {
      return route;
    }
    return 0;
  }

  void _writeRoute(int route) {
    try {
      File(_routeFilePath()).writeAsStringSync(jsonEncode({'route': route}));
    } catch (_) {}
  }

  String _routeFilePath() {
    return '${IphoneLibrary.playlistsDir}${Platform.pathSeparator}_ui_route.json';
  }
}

final djIphoneRouterProvider = NotifierProvider<DjIphoneRouter, int>(
  DjIphoneRouter.new,
);

Future<void> main() async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
    // 3.2.18: paridad con lib/main.dart (iOS: ~/.difogo -> ~/.gatomix).
    migrateBrandCache();
    await IphoneLibrary.ensure();
    await initGlobalAudioService();
    if (Platform.isIOS) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
    await RustLib.init();
    MediaKit.ensureInitialized();
    runApp(const ProviderScope(child: DjIphoneApp()));
  } catch (e) {
    runApp(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: const Color(0xFF1A0000),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                'GatoMix no pudo abrir la carpeta de música.\n\n$e',
                style: const TextStyle(
                  color: Colors.redAccent,
                  fontFamily: 'Consolas',
                  fontSize: 14,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class DjIphoneApp extends ConsumerWidget {
  const DjIphoneApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appTheme = ref.watch(themeProvider);
    return MaterialApp(
      title: 'GatoMix',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: lyricRetryMessengerKey,
      theme: appTheme,
      builder: (context, child) {
        return _DjIphoneLifecycle(child: child ?? const SizedBox.shrink());
      },
      home: const _DjIphoneBoot(),
    );
  }
}

class _DjIphoneLifecycle extends ConsumerStatefulWidget {
  final Widget child;

  const _DjIphoneLifecycle({required this.child});

  @override
  ConsumerState<_DjIphoneLifecycle> createState() => _DjIphoneLifecycleState();
}

class _DjIphoneLifecycleState extends ConsumerState<_DjIphoneLifecycle>
    with WidgetsBindingObserver {
  late final AudioInterruptionGuard _focusGuard;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    globalAudioHandler.onAppDismissed = _silenceEngines;
    // Llamadas / otras apps de audio: pausa y reanuda como app profesional.
    _focusGuard = AudioInterruptionGuard(ref);
    unawaited(_focusGuard.start());
    ref.read(lyricRetryQueueProvider).start();
  }

  @override
  void dispose() {
    _focusGuard.dispose();
    if (identical(globalAudioHandler.onAppDismissed, _silenceEngines)) {
      globalAudioHandler.onAppDismissed = null;
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _silenceEngines() async {
    try {
      ref.read(djIphoneRouterProvider.notifier).persistRoute();
    } catch (_) {}
    try {
      await ref.read(automixProvider.notifier).persistSession();
    } catch (_) {}
    try {
      await ref.read(liveDjProvider.notifier).persistSession();
    } catch (_) {}
    try {
      await ref.read(automixProvider.notifier).parkIdleDecks(force: true);
    } catch (_) {}
    try {
      await ref.read(liveDjProvider.notifier).parkIdleDecks(force: true);
    } catch (_) {}
    try {
      await globalAudioHandler.stop();
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      globalAudioHandler.noteAppBackgrounded();
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      try {
        ref.read(djIphoneRouterProvider.notifier).persistRoute();
      } catch (_) {}
      try {
        ref.read(automixProvider.notifier).persistSession();
      } catch (_) {}
      try {
        ref.read(liveDjProvider.notifier).persistSession();
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _DjIphoneBoot extends StatefulWidget {
  const _DjIphoneBoot();

  @override
  State<_DjIphoneBoot> createState() => _DjIphoneBootState();
}

class _DjIphoneBootState extends State<_DjIphoneBoot> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (context, animation, secondaryAnimation) =>
              const _DjIphoneHome(),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
          transitionDuration: const Duration(milliseconds: 400),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GatoMixTheme.bgDark,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset(
              'assets/branding/gatomix_logo.png',
              width: 96,
              height: 96,
              fit: BoxFit.contain,
            ),
            const SizedBox(height: 30),
            const CircularProgressIndicator(color: GatoMixTheme.deckA),
            const SizedBox(height: 20),
            const Text(
              'GatoMix',
              style: TextStyle(
                color: GatoMixTheme.textMuted,
                fontFamily: 'Consolas',
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DjIphoneHome extends ConsumerStatefulWidget {
  const _DjIphoneHome();

  @override
  ConsumerState<_DjIphoneHome> createState() => _DjIphoneHomeState();
}

class _DjIphoneHomeState extends ConsumerState<_DjIphoneHome> {
  void _openMenu() {
    ref.read(mobileNavOpenProvider.notifier).state = true;
  }

  void _closeMenu() {
    ref.read(mobileNavOpenProvider.notifier).state = false;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(automixProvider.select((s) => s.isPlaying), (prev, next) {
      final gov = ref.read(hardwareGovernorProvider.notifier);
      if (next) {
        gov.lockForLivePerformance();
      } else {
        gov.releaseLock();
      }
    });
    ref.listen<bool>(liveDjProvider.select((s) => s.isPlaying), (prev, next) {
      final gov = ref.read(hardwareGovernorProvider.notifier);
      if (next) {
        gov.lockForLivePerformance();
      } else {
        gov.releaseLock();
      }
    });

    final currentRoute = ref.watch(djIphoneRouterProvider);
    final menuOpen = ref.watch(mobileNavOpenProvider);
    final inlineChrome = currentRoute == 0 || currentRoute == 5;

    return Scaffold(
      backgroundColor: GatoMixTheme.bgDark,
      body: SafeArea(
        child: Column(
          children: [
            if (!inlineChrome)
              GatoMixMobileModeBar(
                title: _title(currentRoute),
                accent: _accent(currentRoute),
                open: menuOpen,
                onTap: menuOpen ? _closeMenu : _openMenu,
              ),
            Expanded(
              child: Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  Positioned.fill(
                    child: Padding(
                      padding: EdgeInsets.only(
                        right: MediaQuery.viewPaddingOf(context).right == 0
                            ? 48
                            : 0,
                      ),
                      child: const _DjIphoneStage(),
                    ),
                  ),
                  if (menuOpen)
                    Positioned.fill(
                      child: GestureDetector(
                        onTap: _closeMenu,
                        behavior: HitTestBehavior.opaque,
                        child: const ColoredBox(color: Color(0x99000000)),
                      ),
                    ),
                  if (menuOpen)
                    Positioned(
                      left: 8,
                      top: inlineChrome ? 40 : 6,
                      width: 228,
                      child: Material(
                        color: GatoMixTheme.bgDark,
                        elevation: 18,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                          side: const BorderSide(color: Color(0xFF2A2E37)),
                        ),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: MediaQuery.sizeOf(context).height * 0.72,
                          ),
                          child: ListView(
                            shrinkWrap: true,
                            padding: EdgeInsets.zero,
                            children: [
                              _DjIphoneNav(
                                currentRoute: currentRoute,
                                onAfterSelect: _closeMenu,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DjIphoneStage extends ConsumerWidget {
  const _DjIphoneStage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentRoute = ref.watch(djIphoneRouterProvider);
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [GatoMixTheme.bgPanel, GatoMixTheme.bgDark],
        ),
      ),
      child: TickerStack(
        index: currentRoute,
        children: const [
          AutomixWorkspace(),
          DspNlpWorkspace(),
          SizedBox.shrink(),
          LabWorkspace(),
          LanSyncWorkspace(),
          LiveDjWorkspace(),
          SizedBox.shrink(),
        ],
      ),
    );
  }
}

String _title(int route) {
  switch (route) {
    case 0:
      return 'Mix con Letra';
    case 1:
      return 'Masterizar';
    case 3:
      return 'Laboratorio';
    case 4:
      return 'Comparte Música';
    case 5:
      return 'AutomixDj';
    default:
      return 'GatoMix';
  }
}

Color _accent(int route) {
  switch (route) {
    case 0:
      return GatoMixTheme.deckA;
    case 1:
      return GatoMixTheme.deckB;
    case 3:
      return Colors.orangeAccent;
    case 4:
      return GatoMixTheme.masterPeak;
    case 5:
      return GatoMixTheme.syncActive;
    default:
      return GatoMixTheme.textMain;
  }
}

class _DjIphoneNav extends ConsumerWidget {
  final int currentRoute;
  final VoidCallback onAfterSelect;

  const _DjIphoneNav({required this.currentRoute, required this.onAfterSelect});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentTrackPath = ref.watch(
      automixProvider.select((s) => s.currentTrackPath),
    );

    Widget tile({
      required IconData icon,
      required String label,
      required int route,
    }) {
      final active = currentRoute == route;
      const Color menuIdle = GatoMixTheme.syncActive;
      const Color menuSelected = Color(0xFF43B3AE);
      final Color ink = active ? menuSelected : menuIdle;
      return ListTile(
        dense: true,
        visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
        minVerticalPadding: 0,
        minLeadingWidth: 22,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10),
        leading: Icon(icon, size: 18, color: ink),
        title: Text(
          label,
          style: TextStyle(
            fontSize: 15,
            height: 1.05,
            color: ink,
            fontWeight: FontWeight.bold,
          ),
        ),
        onTap: () {
          ref.read(djIphoneRouterProvider.notifier).setRoute(route);
          onAfterSelect();
        },
      );
    }

    final motor = currentTrackPath == null
        ? const SizedBox.shrink()
        : Container(
            padding: const EdgeInsets.all(10),
            decoration: const BoxDecoration(
              color: GatoMixTheme.bgPanel,
              border: Border(top: BorderSide(color: Colors.white10)),
            ),
            width: double.infinity,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'MOTOR AUDIO',
                  style: TextStyle(
                    color: GatoMixTheme.textHidden,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  currentTrackPath.replaceAll('\\', '/').split('/').last,
                  style: const TextStyle(
                    color: GatoMixTheme.syncActive,
                    fontSize: 11,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 3.2.21: wordmark GatoMix (arte previo a 3.1.59) en la cabecera de
        // 130 px y luego la version.
        SizedBox(
          height: 130,
          width: double.infinity,
          child: Center(
            child: Image.asset(
              'assets/branding/gatomix_wordmark.png',
              key: const Key('sidebar-logo'),
              height: 120,
              fit: BoxFit.contain,
            ),
          ),
        ),
        const AppVersionLabel(),
        tile(icon: Icons.radio, label: 'AutomixDj', route: 5),
        tile(icon: Icons.album, label: 'Mix con Letra', route: 0),
        tile(icon: Icons.settings, label: 'Masterizar', route: 1),
        tile(icon: Icons.science, label: 'Laboratorio', route: 3),
        tile(icon: Icons.wifi_tethering, label: 'Comparte Música', route: 4),
        motor,
      ],
    );
  }
}

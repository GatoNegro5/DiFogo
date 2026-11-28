import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;

/// 3.2.36: alto de fila del cilindro TheaterLyricsView (antes 64; compacto 56).
/// Cabe la fuente activa (24 / 20, height 1.15) con un margen corto.
const double kLyricWheelRow = 36.0;
const double kLyricWheelRowCompact = 32.0;

/// Alto de fila del cilindro de letras: siempre caben 3 lineas
/// (anterior, activa y siguiente) en la caja disponible.
double lyricWheelExtent(double height, {double max = 20.0}) {
  if (!height.isFinite || height <= 0) return max;
  final double third = height / 3.0;
  return third < max ? third : max;
}

/// Desplazamiento que deja la linea [index] centrada en el visor; el relleno
/// vertical de medio visor hace que cualquier linea pueda centrarse.
double theaterScrollTarget(int index, double extent, double maxScroll) {
  final double raw = (index < 0 ? 0 : index) * extent;
  final double top = maxScroll < 0 ? 0.0 : maxScroll;
  return raw.clamp(0.0, top).toDouble();
}

/// Visor de Modo Teatro: la linea activa se mantiene centrada con
/// desplazamiento suave; si el usuario arrastra, el seguimiento se pausa 3 s.
class TheaterLyricsView extends StatefulWidget {
  const TheaterLyricsView({
    super.key,
    required this.lines,
    required this.activeIndex,
    this.compact = false,
  });

  final List<String> lines;
  final int activeIndex;
  final bool compact;

  @override
  State<TheaterLyricsView> createState() => TheaterLyricsViewState();
}

@visibleForTesting
class TheaterLyricsViewState extends State<TheaterLyricsView> {
  final ScrollController controller = ScrollController();
  DateTime _userUntil = DateTime.fromMillisecondsSinceEpoch(0);

  double get extent =>
      widget.compact ? kLyricWheelRowCompact : kLyricWheelRow;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => follow(false));
  }

  @override
  void didUpdateWidget(covariant TheaterLyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeIndex != widget.activeIndex ||
        oldWidget.lines.length != widget.lines.length) {
      final bool jump = (oldWidget.activeIndex - widget.activeIndex).abs() > 3;
      WidgetsBinding.instance.addPostFrameCallback((_) => follow(!jump));
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void follow(bool animate) {
    if (!mounted || !controller.hasClients) return;
    if (DateTime.now().isBefore(_userUntil)) return;
    final position = controller.position;
    if (!position.hasContentDimensions) return;
    final double target = theaterScrollTarget(
      widget.activeIndex,
      extent,
      position.maxScrollExtent,
    );
    if ((position.pixels - target).abs() < 0.5) return;
    if (animate) {
      controller.animateTo(
        target,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutCubic,
      );
    } else {
      controller.jumpTo(target);
    }
  }

  bool _onScroll(UserScrollNotification n) {
    if (n.direction != ScrollDirection.idle) {
      _userUntil = DateTime.now().add(const Duration(seconds: 3));
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final double big = widget.compact ? 20 : 24;
    final double small = widget.compact ? 15 : 16;
    return LayoutBuilder(
      builder: (context, c) {
        final double pad = c.maxHeight.isFinite
            ? ((c.maxHeight - extent) / 2).clamp(0.0, double.infinity)
            : 0.0;
        return ShaderMask(
          shaderCallback: (rect) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.transparent,
              Colors.white,
              Colors.white,
              Colors.transparent,
            ],
            stops: [0.0, 0.18, 0.82, 1.0],
          ).createShader(rect),
          blendMode: BlendMode.dstIn,
          child: NotificationListener<UserScrollNotification>(
            onNotification: _onScroll,
            child: ListView.builder(
              key: const ValueKey('theater-lyrics'),
              controller: controller,
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.symmetric(vertical: pad),
              itemExtent: extent,
              itemCount: widget.lines.length,
              itemBuilder: (context, index) {
                final bool isCurrent = index == widget.activeIndex;
                final bool isPassed = index < widget.activeIndex;
                return Center(
                  child: AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOut,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isCurrent
                          ? const Color(0xFF39FF14)
                          : (isPassed ? Colors.white38 : Colors.white70),
                      fontSize: isCurrent ? big : small,
                      height: 1.15,
                      fontWeight: isCurrent
                          ? FontWeight.bold
                          : FontWeight.normal,
                      fontStyle: isPassed ? FontStyle.italic : FontStyle.normal,
                    ),
                    child: Text(widget.lines[index]),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

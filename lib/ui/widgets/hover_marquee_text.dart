import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Pixeles del texto que no caben en [maxWidth] en una sola linea (0 si cabe).
double marqueeOverflow(
  String text,
  TextStyle? style,
  double maxWidth, {
  TextScaler textScaler = TextScaler.noScaling,
  TextDirection textDirection = TextDirection.ltr,
}) {
  if (!maxWidth.isFinite || maxWidth <= 0 || text.isEmpty) return 0;
  final TextPainter tp = TextPainter(
    text: TextSpan(text: text, style: style),
    maxLines: 1,
    textDirection: textDirection,
    textScaler: textScaler,
  )..layout();
  final double extra = tp.width - maxWidth;
  tp.dispose();
  return extra > 0.5 ? extra : 0;
}

/// 3.1.41: titulo de una linea. Si cabe, es un Text normal. Si se trunca, al
/// entrar el mouse se desplaza hasta el final (~40 px/s), pausa ~600 ms y
/// vuelve al inicio; al salir el mouse vuelve al inicio con ellipsis.
/// Sin mouse (Android / iPhone) se ve igual que un Text con ellipsis.
/// No usa LayoutBuilder: mide el ancho real al entrar el mouse.
class HoverMarqueeText extends StatefulWidget {
  const HoverMarqueeText(
    this.text, {
    super.key,
    this.style,
    this.pixelsPerSecond = 40,
    this.pause = const Duration(milliseconds: 600),
  });

  final String text;
  final TextStyle? style;
  final double pixelsPerSecond;
  final Duration pause;

  @override
  State<HoverMarqueeText> createState() => _HoverMarqueeTextState();
}

class _HoverMarqueeTextState extends State<HoverMarqueeText> {
  final ScrollController _scroll = ScrollController();
  bool _hover = false;
  int _run = 0;

  @override
  void didUpdateWidget(covariant HoverMarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _run++;
      _hover = false;
    }
  }

  @override
  void dispose() {
    _run++;
    _scroll.dispose();
    super.dispose();
  }

  void _enter(PointerEnterEvent event) {
    final RenderObject? box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final TextStyle style = DefaultTextStyle.of(
      context,
    ).style.merge(widget.style);
    final double extra = marqueeOverflow(
      widget.text,
      style,
      box.size.width,
      textScaler: MediaQuery.maybeTextScalerOf(context) ?? TextScaler.noScaling,
      textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
    );
    if (extra <= 0) return;
    final int run = ++_run;
    setState(() => _hover = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _play(run));
  }

  void _exit(PointerExitEvent event) {
    _run++;
    if (_hover && mounted) setState(() => _hover = false);
  }

  Future<void> _play(int run) async {
    if (!mounted || run != _run || !_scroll.hasClients) return;
    final double end = _scroll.position.maxScrollExtent;
    if (end <= 0) return;
    final int ms = (end / widget.pixelsPerSecond * 1000).round().clamp(
      200,
      60000,
    );
    final Duration d = Duration(milliseconds: ms);
    await _scroll.animateTo(end, duration: d, curve: Curves.easeInOut);
    if (!mounted || run != _run) return;
    await Future<void>.delayed(widget.pause);
    if (!mounted || run != _run || !_scroll.hasClients) return;
    await _scroll.animateTo(0, duration: d, curve: Curves.easeInOut);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: _enter,
      onExit: _exit,
      child: _hover
          ? SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              controller: _scroll,
              physics: const NeverScrollableScrollPhysics(),
              child: Text(
                widget.text,
                style: widget.style,
                maxLines: 1,
                softWrap: false,
              ),
            )
          : Text(
              widget.text,
              style: widget.style,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
            ),
    );
  }
}

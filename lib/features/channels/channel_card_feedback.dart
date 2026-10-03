import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Acknowledge the pointer before route preparation can occupy the UI isolate.
/// Single clicks are immediate; a second click is an explicit force-play action.
class ChannelCardFeedback extends StatefulWidget {
  const ChannelCardFeedback({
    super.key,
    required this.loading,
    required this.onTap,
    required this.onDoubleTap,
    required this.builder,
  });
  final bool loading;
  final Future<void> Function() onTap;
  final Future<void> Function() onDoubleTap;
  final Widget Function(bool busy) builder;

  @override
  State<ChannelCardFeedback> createState() => _ChannelCardFeedbackState();
}

class _ChannelCardFeedbackState extends State<ChannelCardFeedback>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 440),
  );
  bool _hovered = false;
  bool _acknowledged = false;
  Offset? _down;
  int? _pointer;
  Duration? _lastClick;
  Offset? _lastPosition;
  int _request = 0;

  void _keyboardActivate() {
    setState(() => _acknowledged = true);
    _sweep.forward(from: 0);
    unawaited(_activate(false));
  }

  void _cancel() {
    _down = null;
    _pointer = null;
    if (mounted) setState(() => _acknowledged = false);
  }

  Future<void> _activate(bool force) async {
    final request = ++_request;
    try {
      // Paint the spinner and click acknowledgement before synchronous work.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || request != _request) return;
      await (force ? widget.onDoubleTap() : widget.onTap());
    } finally {
      if (mounted && request == _request) {
        setState(() => _acknowledged = false);
      }
    }
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final busy = widget.loading || _acknowledged;
    return FocusableActionDetector(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _keyboardActivate();
            return null;
          },
        ),
      },
      child: Semantics(
        button: true,
        onTap: _keyboardActivate,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: Listener(
            onPointerDown: (event) {
              if (event.buttons != kPrimaryMouseButton || _pointer != null) {
                return;
              }
              _down = event.position;
              _pointer = event.pointer;
              setState(() => _acknowledged = true);
              _sweep.forward(from: 0);
            },
            onPointerMove: (event) {
              if (event.pointer == _pointer &&
                  _down != null &&
                  (event.position - _down!).distance > kTouchSlop) {
                _cancel();
              }
            },
            onPointerCancel: (_) => _cancel(),
            onPointerUp: (event) {
              if (event.pointer != _pointer || _down == null) return;
              _pointer = null;
              _down = null;
              final doubleClick =
                  _lastClick != null &&
                  event.timeStamp - _lastClick! <= kDoubleTapTimeout &&
                  _lastPosition != null &&
                  (event.position - _lastPosition!).distance <= kDoubleTapSlop;
              _lastClick = doubleClick ? null : event.timeStamp;
              _lastPosition = event.position;
              unawaited(_activate(doubleClick));
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: const Color(
                      0xFFAAC8FF,
                    ).withValues(alpha: _hovered ? 0.24 : 0),
                    blurRadius: 15,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  widget.builder(busy),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: Colors.white.withValues(
                              alpha: _hovered ? 0.48 : 0,
                            ),
                            width: 1.2,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: RepaintBoundary(
                        child: AnimatedBuilder(
                          animation: _sweep,
                          builder: (context, child) => CustomPaint(
                            painter: _CardSweepPainter(_sweep.value),
                          ),
                        ),
                      ),
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

class _CardSweepPainter extends CustomPainter {
  const _CardSweepPainter(this.progress);
  final double progress;
  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0 || progress >= 1) return;
    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(20)),
    );
    final width = size.width * 0.45;
    final x = -width + (size.width + width * 2) * progress;
    final rect = Rect.fromLTWH(x, 0, width, size.height);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [
            Colors.white.withValues(alpha: 0),
            const Color(0xFFCCE1FF).withValues(alpha: 0.25),
            Colors.white.withValues(alpha: 0),
          ],
        ).createShader(rect),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CardSweepPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

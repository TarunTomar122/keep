import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

class Oa {
  Oa._();

  static const ink = Color(0xFF292929);
  static const fg80 = Color(0xCC292929);
  static const stage = Color(0xFFF6F6F6);
  static const card = Color(0xFFFFFFFF);
  static const border = Color(0x1F292929);
  static const inputBorder = Color(0x24292929);
  static const accentWash = Color(0x0D292929);
  static const mutedFg = Color(0xFF6D6D6D);
  static const primary = Color(0xFF305DDE);
  static const primaryBevel = Color(0xFF3159D5);
  static const primaryBevelBorder = Color(0xFF3255CB);
  static const primaryDeep = Color(0xFF3A3480);
  static const primaryForeground = Color(0xFFFFFFFF);
  static const ring = Color(0xFF3BA6F1);
  static const secondary = Color(0xFFE9E9E9);
  static const secondaryHover = Color(0xFFDCDCDC);
  static const destructive = Color(0xFFEF4444);
  static const dangerText = Color(0xFFB91C1C);
  static const successText = Color(0xFF047857);
  static const warningText = Color(0xFFB45309);

  static const radiusSm = 6.0;
  static const radiusMd = 8.0;
  static const radiusLg = 10.0;
  static const radiusXl = 14.0;
  static const radius2xl = 18.0;

  static const cardRadius = 14.0;
  static const cardHandle = 2.25;
  static const insetRadius = 12.0;
  static const insetHandle = 2.0;

  static const restingShadows = [
    BoxShadow(color: Color(0x0F000000), offset: Offset(0, 1), blurRadius: 2),
  ];
  static const floatingShadows = [
    BoxShadow(color: Color(0x14000000), offset: Offset(0, 1), blurRadius: 2),
    BoxShadow(color: Color(0x14000000), offset: Offset(0, 8), blurRadius: 24),
  ];

  static const panelSpring = SpringDescription(mass: 1, stiffness: 550, damping: 38);
  static const layoutSpring = SpringDescription(mass: 1, stiffness: 550, damping: 40);
  static const popSpring = SpringDescription(mass: 1, stiffness: 400, damping: 26);
  static const popExitSpring = SpringDescription(mass: 1, stiffness: 380, damping: 28);
  static const bannerSpring = SpringDescription(mass: 1, stiffness: 400, damping: 30);
}

Path oaSquirclePath(Rect rect, double radius, double handle) {
  final r = math.min(radius, math.min(rect.width, rect.height) / 2);
  final h = math.min(handle, r);
  final left = rect.left;
  final top = rect.top;
  final right = rect.right;
  final bottom = rect.bottom;
  return Path()
    ..moveTo(left + r, top)
    ..lineTo(right - r, top)
    ..cubicTo(right - h, top, right, top + h, right, top + r)
    ..lineTo(right, bottom - r)
    ..cubicTo(right, bottom - h, right - h, bottom, right - r, bottom)
    ..lineTo(left + r, bottom)
    ..cubicTo(left + h, bottom, left, bottom - h, left, bottom - r)
    ..lineTo(left, top + r)
    ..cubicTo(left, top + h, left + h, top, left + r, top)
    ..close();
}

class OaSquircleClipper extends CustomClipper<Path> {
  const OaSquircleClipper({this.radius = Oa.insetRadius, this.handle = Oa.insetHandle});

  final double radius;
  final double handle;

  @override
  Path getClip(Size size) =>
      oaSquirclePath(Offset.zero & size, radius, handle);

  @override
  bool shouldReclip(OaSquircleClipper oldClipper) =>
      oldClipper.radius != radius || oldClipper.handle != handle;
}

class SquircleBorder extends ShapeBorder {
  const SquircleBorder({
    this.radius = Oa.cardRadius,
    this.handle = Oa.cardHandle,
    this.side = BorderSide.none,
  });

  final double radius;
  final double handle;
  final BorderSide side;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(side.width);

  Path _path(Rect rect) => oaSquirclePath(rect, radius, handle);

  @override
  ShapeBorder scale(double t) => SquircleBorder(
        radius: radius * t,
        handle: handle * t,
        side: side.scale(t),
      );

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) => _path(rect);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      _path(rect.deflate(side.width));

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none || side.width <= 0) return;
    canvas.drawPath(
      _path(rect.deflate(side.width / 2)),
      side.toPaint(),
    );
  }

  @override
  ShapeBorder lerpFrom(ShapeBorder? a, double t) => this;

  @override
  ShapeBorder lerpTo(ShapeBorder? b, double t) => b ?? this;
}

enum OaButtonVariant { primary, secondary, ghost, destructive }

enum OaButtonSize { md, sm, xs }

class OaButton extends StatefulWidget {
  const OaButton({
    required this.label,
    this.onPressed,
    this.variant = OaButtonVariant.primary,
    this.size = OaButtonSize.sm,
    this.loading = false,
    this.expand = false,
    this.tooltip,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final OaButtonVariant variant;
  final OaButtonSize size;
  final bool loading;
  final bool expand;
  final String? tooltip;

  @override
  State<OaButton> createState() => _OaButtonState();
}

class _OaButtonState extends State<OaButton> {
  bool _pressed = false;

  bool get _disabled => widget.loading || widget.onPressed == null;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  TextStyle get _labelStyle {
    final size = switch (widget.size) {
      OaButtonSize.md => 14.0,
      OaButtonSize.sm => 13.0,
      OaButtonSize.xs => 12.0,
    };
    return TextStyle(
      fontSize: size,
      fontWeight: FontWeight.w500,
      letterSpacing: -0.1,
      color: switch (widget.variant) {
        OaButtonVariant.primary => Oa.primaryForeground,
        OaButtonVariant.secondary => Oa.ink,
        OaButtonVariant.ghost => Oa.mutedFg,
        OaButtonVariant.destructive => Oa.primaryForeground,
      },
    );
  }

  double get _height => switch (widget.size) {
        OaButtonSize.md => 36,
        OaButtonSize.sm => 32,
        OaButtonSize.xs => 28,
      };

  EdgeInsets get _padding => switch (widget.size) {
        OaButtonSize.md => const EdgeInsets.symmetric(horizontal: 12),
        OaButtonSize.sm => const EdgeInsets.symmetric(horizontal: 12),
        OaButtonSize.xs => const EdgeInsets.symmetric(horizontal: 8),
      };

  Decoration _decoration() => switch (widget.variant) {
        OaButtonVariant.primary => ShapeDecoration(
            color: Oa.primaryBevel,
            shadows: const [],
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Oa.radiusLg),
              side: const BorderSide(color: Oa.primaryBevelBorder),
            ),
          ),
        OaButtonVariant.secondary => ShapeDecoration(
            color: _pressed ? Oa.secondaryHover : Oa.secondary,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Oa.radiusLg),
            ),
          ),
        OaButtonVariant.ghost => ShapeDecoration(
            color: _pressed ? Oa.accentWash : Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Oa.radiusLg),
            ),
          ),
        OaButtonVariant.destructive => ShapeDecoration(
            color: Oa.destructive,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Oa.radiusLg),
            ),
          ),
      };

  @override
  Widget build(BuildContext context) {
    final content = Stack(
      alignment: Alignment.center,
      children: [
        Opacity(
          opacity: widget.loading ? 0 : 1,
          child: Text(widget.label, style: _labelStyle),
        ),
        if (widget.loading)
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
      ],
    );

    final button = AnimatedScale(
      scale: _pressed && !_disabled ? 0.98 : 1,
      duration: const Duration(milliseconds: 90),
      curve: Curves.easeOut,
      child: Transform.translate(
        offset: Offset(0, _pressed && !_disabled ? 1 : 0),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 120),
          opacity: _disabled && !widget.loading ? 0.5 : 1,
          child: Container(
            height: _height,
            padding: _padding,
            decoration: _decoration(),
            foregroundDecoration: widget.variant == OaButtonVariant.primary
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(Oa.radiusLg),
                    gradient: const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: [0, 0.35, 0.65, 1],
                      colors: [
                        Color(0x38FFFFFF),
                        Color(0x00000000),
                        Color(0x00000000),
                        Color(0x4A3A3480),
                      ],
                    ),
                  )
                : null,
            alignment: Alignment.center,
            child: content,
          ),
        ),
      ),
    );

    final wrapped = widget.expand
        ? SizedBox(width: double.infinity, child: button)
        : button;

    return MergeSemantics(
      child: Semantics(
        button: true,
        enabled: !_disabled,
        label: widget.tooltip,
        child: Tooltip(
          message: widget.tooltip ?? '',
          excludeFromSemantics: widget.tooltip == null,
          child: AbsorbPointer(
            absorbing: _disabled,
            child: Listener(
              onPointerDown: (_) => _setPressed(true),
              onPointerUp: (_) => _setPressed(false),
              onPointerCancel: (_) => _setPressed(false),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _disabled ? null : widget.onPressed,
                child: wrapped,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class OaIconButton extends StatefulWidget {
  const OaIconButton({
    required this.icon,
    this.onPressed,
    this.tooltip,
    this.danger = false,
    super.key,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final bool danger;

  @override
  State<OaIconButton> createState() => _OaIconButtonState();
}

class _OaIconButtonState extends State<OaIconButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip ?? '',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          width: 34,
          height: 34,
          decoration: ShapeDecoration(
            color: _pressed ? Oa.accentWash : Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Oa.radiusLg),
            ),
          ),
          child: Icon(
            widget.icon,
            size: 20,
            color: widget.danger ? Oa.dangerText : Oa.mutedFg,
          ),
        ),
      ),
    );
  }
}

class OaPanel extends StatelessWidget {
  const OaPanel({required this.child, this.padding = const EdgeInsets.all(12), super.key});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: ShapeDecoration(
        color: Oa.card,
        shadows: Oa.restingShadows,
        shape: const SquircleBorder(side: BorderSide(color: Oa.border)),
      ),
      child: child,
    );
  }
}

class OaInset extends StatelessWidget {
  const OaInset({required this.child, this.height, super.key});

  final Widget child;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final inset = ClipPath(
      clipper: const OaSquircleClipper(),
      child: Container(
        color: Oa.stage,
        width: double.infinity,
        height: height,
        child: child,
      ),
    );
    return DecoratedBox(
      decoration: const ShapeDecoration(
        color: Oa.stage,
        shadows: Oa.restingShadows,
        shape: SquircleBorder(radius: Oa.insetRadius, handle: Oa.insetHandle),
      ),
      child: inset,
    );
  }
}

class OaSectionHeading extends StatelessWidget {
  const OaSectionHeading(this.title, this.sentence, {super.key});

  final String title;
  final String sentence;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              letterSpacing: -0.2,
              color: Oa.fg80,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            sentence,
            style: const TextStyle(fontSize: 13, color: Oa.mutedFg),
          ),
        ],
      ),
    );
  }
}

class OaNoticeStrip extends StatelessWidget {
  const OaNoticeStrip({
    required this.claim,
    this.sentence,
    this.actionLabel,
    this.onAction,
    super.key,
  });

  final String claim;
  final String? sentence;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: ShapeDecoration(
        color: Oa.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Oa.radius2xl),
          side: const BorderSide(color: Oa.border),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: RichText(
              text: TextSpan(
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.45,
                  color: Oa.mutedFg,
                  fontFamily: 'InterTight',
                ),
                children: [
                  TextSpan(
                    text: claim,
                    style: const TextStyle(
                      fontWeight: FontWeight.w500,
                      color: Oa.ink,
                    ),
                  ),
                  if (sentence != null) TextSpan(text: ' ${sentence!}'),
                ],
              ),
            ),
          ),
          if (actionLabel != null) ...[
            const SizedBox(width: 12),
            OaButton(
              label: actionLabel!,
              variant: OaButtonVariant.secondary,
              size: OaButtonSize.xs,
              onPressed: onAction,
            ),
          ],
        ],
      ),
    );
  }
}

class OaSwitch extends StatelessWidget {
  const OaSwitch({required this.value, required this.onChanged, super.key});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      toggled: value,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(!value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          width: 44,
          height: 26,
          padding: const EdgeInsets.all(2),
          decoration: ShapeDecoration(
            color: value ? Oa.primary : Oa.secondary,
            shape: const StadiumBorder(),
          ),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: 22,
              height: 22,
              decoration: const ShapeDecoration(
                color: Colors.white,
                shape: CircleBorder(),
                shadows: Oa.restingShadows,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class OaSegmented extends StatefulWidget {
  const OaSegmented({
    required this.labels,
    required this.index,
    required this.onChanged,
    super.key,
  });

  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  State<OaSegmented> createState() => _OaSegmentedState();
}

class _OaSegmentedState extends State<OaSegmented>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, value: widget.index.toDouble());
  late double _target = widget.index.toDouble();

  @override
  void didUpdateWidget(OaSegmented oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index != oldWidget.index) {
      _target = widget.index.toDouble();
      _controller.animateWith(
        SpringSimulation(Oa.layoutSpring, _controller.value, _target, 0),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.labels.length;
    return Container(
      height: 32,
      padding: const EdgeInsets.all(2),
      decoration: ShapeDecoration(
        color: Oa.secondary,
        shape: const StadiumBorder(),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final segmentWidth = (constraints.maxWidth - 4) / count;
          return Stack(
            children: [
              AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  final x = _controller.value * segmentWidth;
                  return Positioned(
                    left: x,
                    top: 0,
                    width: segmentWidth,
                    height: 28,
                    child: Container(
                      decoration: const ShapeDecoration(
                        color: Oa.card,
                        shadows: Oa.restingShadows,
                        shape: StadiumBorder(),
                      ),
                    ),
                  );
                },
              ),
              Row(
                children: [
                  for (var i = 0; i < count; i++)
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => widget.onChanged(i),
                        child: Center(
                          child: AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 120),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              fontFamily: 'InterTight',
                              color: i == widget.index ? Oa.ink : Oa.mutedFg,
                            ),
                            child: Text(widget.labels[i]),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class OaModal {
  OaModal._();

  static Future<bool> show(BuildContext context, {required Widget child}) {
    final completer = Completer<bool>();
    late OverlayEntry entry;
    final backdrop = AnimationController(
      vsync: Navigator.of(context),
      duration: const Duration(milliseconds: 150),
    )..forward();
    final panel = AnimationController(
      vsync: Navigator.of(context),
      duration: const Duration(milliseconds: 300),
    );

    void close(bool result) {
      if (!completer.isCompleted) {
        panel.animateWith(
          SpringSimulation(Oa.popExitSpring, panel.value, 0, 0),
        );
        backdrop.reverse().then((_) {
          if (entry.mounted) entry.remove();
          if (!completer.isCompleted) completer.complete(result);
        });
      }
    }

    entry = OverlayEntry(
      builder: (context) => Stack(
        children: [
          FadeTransition(
            opacity: backdrop,
            child: ColoredBox(
              color: const Color(0x66292929),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => close(false),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          AnimatedBuilder(
            animation: Listenable.merge([panel, backdrop]),
            builder: (context, _) {
              final t = panel.value;
              return Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Opacity(
                    opacity: t.clamp(0, 1),
                    child: Transform.scale(
                      scale: 0.96 + 0.04 * t,
                      child: Container(
                        width: double.infinity,
                        constraints: const BoxConstraints(maxWidth: 360),
                        padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                        decoration: ShapeDecoration(
                          color: Oa.card,
                          shadows: Oa.floatingShadows,
                          shape: const SquircleBorder(
                            radius: Oa.radius2xl,
                            handle: 3,
                          ),
                        ),
                        child: child,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );

    Overlay.of(context).insert(entry);
    panel.animateWith(SpringSimulation(Oa.popSpring, 0, 1, 0));
    return completer.future;
  }
}

class OaModalFooter extends StatelessWidget {
  const OaModalFooter({
    required this.backLabel,
    required this.actionLabel,
    this.destructive = false,
    required this.onBack,
    required this.onAction,
    super.key,
  });

  final String backLabel;
  final String actionLabel;
  final bool destructive;
  final VoidCallback onBack;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 16),
      height: 48,
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Oa.border)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          OaButton(
            label: backLabel,
            variant: OaButtonVariant.secondary,
            size: OaButtonSize.xs,
            onPressed: onBack,
          ),
          const SizedBox(width: 8),
          OaButton(
            label: actionLabel,
            variant: destructive
                ? OaButtonVariant.destructive
                : OaButtonVariant.primary,
            size: OaButtonSize.xs,
            onPressed: onAction,
          ),
        ],
      ),
    );
  }
}

class OaToast {
  OaToast._();

  static void show(
    BuildContext context, {
    required bool good,
    required String message,
  }) {
    final overlay = Overlay.of(context, rootOverlay: true);
    late OverlayEntry entry;
    final controller = AnimationController(
      vsync: Navigator.of(context),
      duration: const Duration(milliseconds: 200),
    )..forward();

    void retire() async {
      await controller.reverse();
      if (entry.mounted) entry.remove();
    }

    entry = OverlayEntry(
      builder: (context) => Positioned(
        left: 0,
        right: 0,
        bottom: MediaQuery.paddingOf(context).bottom + 28,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.4),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: controller, curve: Curves.easeOut)),
          child: FadeTransition(
            opacity: controller,
            child: Center(
              child: _ToastBody(
                good: good,
                message: message,
                onDone: retire,
              ),
            ),
          ),
        ),
      ),
    );

    overlay.insert(entry);
  }
}

class _ToastBody extends StatefulWidget {
  const _ToastBody({required this.good, required this.message, required this.onDone});

  final bool good;
  final String message;
  final VoidCallback onDone;

  @override
  State<_ToastBody> createState() => _ToastBodyState();
}

class _ToastBodyState extends State<_ToastBody>
    with SingleTickerProviderStateMixin {
  late final AnimationController _effect =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 320));

  @override
  void initState() {
    super.initState();
    Timer(const Duration(milliseconds: 220), () {
      if (mounted) _effect.forward(from: 0);
    });
    Timer(const Duration(seconds: 4), () {
      if (mounted) widget.onDone();
    });
  }

  @override
  void dispose() {
    _effect.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _effect,
      builder: (context, child) {
        final t = _effect.value;
        var scale = 1.0;
        var dx = 0.0;
        if (widget.good) {
          if (t < 0.3) {
            scale = 1 + 0.025 * Curves.easeOut.transform(t / 0.3);
          } else if (t < 0.6) {
            scale = 1.025 - 0.035 * ((t - 0.3) / 0.3);
          } else {
            scale = 0.99 + 0.01 * ((t - 0.6) / 0.4);
          }
        } else if (t < 0.75) {
          final phase = (t / 0.25).floor();
          final dir = phase.isEven ? -1 : 1;
          dx = 3 * dir * (1 - ((t % 0.25) / 0.25));
        }
        return Transform.translate(
          offset: Offset(dx, 0),
          child: Transform.scale(
            scale: scale,
            child: child,
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.only(left: 12, right: 16, top: 6, bottom: 6),
        decoration: ShapeDecoration(
          color: Oa.card,
          shadows: Oa.floatingShadows,
          shape: const StadiumBorder(side: BorderSide(color: Oa.border)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: ShapeDecoration(
                color: widget.good ? Oa.successText : Oa.dangerText,
                shape: const CircleBorder(),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              widget.message,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Oa.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

ThemeData oaTheme() {
  final base = ThemeData(
    useMaterial3: true,
    fontFamily: 'InterTight',
    scaffoldBackgroundColor: Colors.white,
    splashFactory: NoSplash.splashFactory,
    colorScheme: ColorScheme.fromSeed(
      seedColor: Oa.primary,
      brightness: Brightness.light,
      surface: Colors.white,
      primary: Oa.primary,
    ),
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: Oa.ink,
      displayColor: Oa.ink,
      fontFamily: 'InterTight',
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: Oa.primary,
      selectionColor: Color(0x33305DDE),
      selectionHandleColor: Oa.primary,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      hintStyle: const TextStyle(fontSize: 14, color: Oa.mutedFg),
      labelStyle: const TextStyle(fontSize: 13, color: Oa.mutedFg),
      floatingLabelStyle: const TextStyle(fontSize: 12, color: Oa.mutedFg),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Oa.radiusLg),
        borderSide: const BorderSide(color: Oa.inputBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Oa.radiusLg),
        borderSide: const BorderSide(color: Oa.inputBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Oa.radiusLg),
        borderSide: const BorderSide(color: Oa.ring, width: 1.5),
      ),
    ),
  );
}

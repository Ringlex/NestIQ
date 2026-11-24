import 'dart:async';

import 'package:flutter/material.dart';

import '../account/account_models.dart';

/// Czasy i krzywe animacji w całej aplikacji (patrz makiety, ekran 11).
class Motion {
  static const enter = Duration(milliseconds: 400);
  static const toggle = Duration(milliseconds: 220);
  static const tabs = Duration(milliseconds: 320);
  static const expand = Duration(milliseconds: 320);
  static const stagger = Duration(milliseconds: 70);
  static const curve = Curves.easeOutCubic;
  static const bounce = Curves.easeOutBack;

  /// Zgodnie z ustawieniem systemowym „ogranicz ruch”.
  static bool reduced(BuildContext context) =>
      MediaQuery.of(context).disableAnimations;
}

/// Pojawienie się z lekkim wsunięciem od dołu; kolejne elementy listy dostają
/// rosnące [index], żeby wchodziły kaskadą.
class FadeUp extends StatefulWidget {
  const FadeUp({super.key, required this.child, this.index = 0});

  final Widget child;
  final int index;

  @override
  State<FadeUp> createState() => _FadeUpState();
}

class _FadeUpState extends State<FadeUp> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: Motion.enter);
  Timer? _delay;

  @override
  void initState() {
    super.initState();
    final delay = Motion.stagger * widget.index;
    if (delay == Duration.zero) {
      _controller.forward();
    } else {
      _delay = Timer(delay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _delay?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (Motion.reduced(context)) return widget.child;
    final curved = CurvedAnimation(parent: _controller, curve: Motion.curve);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.06), end: Offset.zero)
            .animate(curved),
        child: widget.child,
      ),
    );
  }
}

/// Szkielet ładowania z przesuwającym się blaskiem – zamiast kółka.
class Skeleton extends StatefulWidget {
  const Skeleton({super.key, this.height = 56, this.width, this.radius = 20});

  final double height;
  final double? width;
  final double radius;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1300))
    ..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = scheme.surfaceContainerHigh;
    final shine = scheme.surfaceContainerLowest;
    final still = Motion.reduced(context);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = still ? 0.5 : _controller.value;
        return Container(
          height: widget.height,
          width: widget.width,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            gradient: LinearGradient(
              begin: Alignment(-1.5 + 3 * t, 0),
              end: Alignment(-0.5 + 3 * t, 0),
              colors: [base, shine, base],
            ),
          ),
        );
      },
    );
  }
}

class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({super.key, required this.profile, this.size = 48});

  final Profile profile;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration:
          BoxDecoration(color: profile.background, shape: BoxShape.circle),
      child: Text(
        profile.letter,
        style: TextStyle(
          fontSize: size * 0.4,
          fontWeight: FontWeight.w700,
          color: profile.foreground,
        ),
      ),
    );
  }
}

/// Zakładki ze wskaźnikiem, który się przesuwa. Przy [collapseInactive] zaznaczona
/// ma ikonę i napis, a pozostałe tylko ikonę (nazwa w podpowiedzi i dla czytników ekranu);
/// bez tego wszystkie są równe i mają napisy.
class SlidingTabs extends StatelessWidget {
  const SlidingTabs({
    super.key,
    required this.labels,
    required this.icons,
    required this.index,
    required this.onChanged,
    this.collapseInactive = false,
  });

  final bool collapseInactive;
  final List<String> labels;
  final List<IconData> icons;
  final int index;
  final ValueChanged<int> onChanged;

  static const _height = 48.0;
  static const _padding = 4.0;

  /// Szerokość zakładki z samą ikoną.
  static const _compact = 48.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final n = labels.length;
    return Container(
      height: _height,
      padding: const EdgeInsets.all(_padding),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh.withOpacity(0.6),
        borderRadius: BorderRadius.circular(24),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          // Zaznaczona zakładka dostaje całą resztę szerokości, ale nie mniej niż dwie kompaktowe.
          final selectedWidth = (box.maxWidth - (n - 1) * _compact)
              .clamp(_compact * 2, box.maxWidth);
          final equal = box.maxWidth / n;
          double widthOf(int i) => !collapseInactive
              ? equal
              : (i == index ? selectedWidth : _compact);
          double leftOf(int i) {
            var left = 0.0;
            for (var k = 0; k < i; k++) {
              left += widthOf(k);
            }
            return left;
          }

          final height = box.maxHeight;
          return Stack(
            children: [
              AnimatedPositioned(
                duration: Motion.tabs,
                curve: Curves.easeOutCubic,
                left: leftOf(index),
                width: widthOf(index),
                height: height,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ),
              for (var i = 0; i < n; i++)
                AnimatedPositioned(
                  duration: Motion.tabs,
                  curve: Curves.easeOutCubic,
                  left: leftOf(i),
                  width: widthOf(i),
                  height: height,
                  child: Tooltip(
                    message: collapseInactive ? labels[i] : '',
                    child: Semantics(
                      button: true,
                      selected: i == index,
                      label: labels[i],
                      excludeSemantics: true,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: () => onChanged(i),
                        child: Center(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(icons[i],
                                    size: 22,
                                    color: i == index
                                        ? scheme.onPrimary
                                        : scheme.onSurfaceVariant),
                                if (!collapseInactive || i == index) ...[
                                  const SizedBox(width: 8),
                                  Text(
                                    labels[i],
                                    maxLines: 1,
                                    softWrap: false,
                                    style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w500,
                                        color: i == index
                                            ? scheme.onPrimary
                                            : scheme.onSurfaceVariant),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

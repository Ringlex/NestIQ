import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Progi szerokości (w dp): telefon < 600, tablet w pionie, tablet w poziomie.
class Breakpoints {
  static const tablet = 600.0;
  static const wide = 840.0;
}

/// Szerokie okno: zamiast dolnego paska używamy panelu z boku i kilku kolumn.
bool isWide(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= Breakpoints.wide;

/// Telefon (krótszy bok poniżej 600 dp): ekran zostaje w pionie.
bool isPhone(Size size) => size.shortestSide < Breakpoints.tablet;

/// Układa elementy w tylu kolumnach, ile mieści się przy szerokości [minColumnWidth],
/// żeby na tablecie nie zostawały puste pasy po bokach. Elementy trafiają do kolumn po kolei.
class ResponsiveColumns extends StatelessWidget {
  const ResponsiveColumns({
    super.key,
    required this.children,
    this.minColumnWidth = 360,
    this.maxColumns = 3,
    this.spacing = 12,
  });

  final List<Widget> children;
  final double minColumnWidth;
  final int maxColumns;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final columns = ((box.maxWidth + spacing) / (minColumnWidth + spacing))
            .floor()
            .clamp(1, maxColumns);
        if (columns == 1 || children.length < 2) {
          return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children);
        }
        final lanes = List.generate(columns, (_) => <Widget>[]);
        for (var i = 0; i < children.length; i++) {
          lanes[i % columns].add(children[i]);
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var c = 0; c < columns; c++) ...[
              if (c > 0) SizedBox(width: spacing),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: lanes[c])),
            ],
          ],
        );
      },
    );
  }
}

/// Ogranicza szerokość treści (formularze, ustawienia) i centruje ją na szerokim ekranie.
class ContentWidth extends StatelessWidget {
  const ContentWidth({super.key, required this.child, this.maxWidth = 640});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth), child: child),
      ),
    );
  }
}

/// Trasa jak `MaterialPageRoute`, ale z treścią o ograniczonej szerokości na tablecie.
class AppRoute<T> extends MaterialPageRoute<T> {
  AppRoute(
      {required WidgetBuilder builder, super.settings, super.fullscreenDialog})
      : super(builder: (context) => ContentWidth(child: builder(context)));
}

/// Telefon tylko w pionie, tablet w dowolnej orientacji. Sprawdza rozmiar przy każdej zmianie.
class OrientationPolicy extends StatefulWidget {
  const OrientationPolicy({super.key, required this.child});

  final Widget child;

  @override
  State<OrientationPolicy> createState() => _OrientationPolicyState();
}

class _OrientationPolicyState extends State<OrientationPolicy> {
  bool? _phone;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final phone = isPhone(MediaQuery.sizeOf(context));
    if (phone == _phone) return;
    _phone = phone;
    SystemChrome.setPreferredOrientations(
      phone ? const [DeviceOrientation.portraitUp] : DeviceOrientation.values,
    ).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

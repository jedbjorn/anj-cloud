import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// The shared responsive rule (spec #28 Phone Layout): one widget tree for
/// every client, compact below these breakpoints. A phone in portrait is
/// narrow; a phone in landscape is short. Desktop windows at their usual
/// sizes are neither, so they keep the desktop layout unchanged.
const compactWidthBreakpoint = 600.0;
const compactHeightBreakpoint = 480.0;

/// Narrower than [compactWidthBreakpoint]: labelled app-bar and toolbar
/// buttons become icon buttons with the same words as tooltip and label.
bool compactWidth(BuildContext context) =>
    MediaQuery.sizeOf(context).width < compactWidthBreakpoint;

/// Phone-sized: tap to open, long-press for the icon colour, scrollable
/// dialogs, the Admin views as tabs, and the area above a list capped so the
/// list always keeps room. Narrow windows are compact everywhere; a short
/// window is compact only on Android (a phone in landscape). A desktop
/// (Linux, macOS, Windows) in a short window keeps the desktop layout, with
/// its mouse gestures (planner ruling on spec #31: a Mac never uses the
/// phone layout; Linux and Windows alike).
bool compactLayout(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return size.width < compactWidthBreakpoint ||
      (defaultTargetPlatform == TargetPlatform.android &&
          size.height < compactHeightBreakpoint);
}

/// Content above a list in a compact layout: its natural height up to
/// [fraction] of [available], scrolling beyond that. A notice or a large
/// font then never pushes the list off a landscape phone or overflows.
class CappedHeader extends StatelessWidget {
  const CappedHeader({
    super.key,
    required this.available,
    required this.child,
    this.fraction = 0.5,
  });
  final double available;
  final double fraction;
  final Widget child;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(maxHeight: available * fraction),
    child: SingleChildScrollView(child: child),
  );
}

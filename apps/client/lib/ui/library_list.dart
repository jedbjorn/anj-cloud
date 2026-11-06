import 'package:flutter/material.dart';

/// A normal lazy list, or an exact destination anchored inside a lazy viewport.
/// Splitting at the destination avoids estimating offsets for variable-height
/// cards or laying out every preceding row. The preceding sliver grows upward,
/// so all rows remain reachable in their original order in both directions.
class LibraryList extends StatelessWidget {
  const LibraryList({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.revealIndex,
    this.animate = true,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final int? revealIndex;

  /// False while the window is hidden: tickers below are off, so rows show
  /// static indicators and no animation keeps the process awake.
  final bool animate;
  static const _center = ValueKey('library-reveal-center');

  @override
  Widget build(BuildContext context) =>
      TickerMode(enabled: animate, child: _list());

  Widget _list() {
    final index = revealIndex;
    if (index == null || index < 0 || index >= itemCount) {
      return ListView.builder(itemCount: itemCount, itemBuilder: itemBuilder);
    }
    return CustomScrollView(
      center: _center,
      anchor: 0.15,
      slivers: [
        SliverList.builder(
          itemCount: index,
          itemBuilder: (context, offset) =>
              itemBuilder(context, index - offset - 1),
        ),
        SliverList.builder(
          key: _center,
          itemCount: itemCount - index,
          itemBuilder: (context, offset) =>
              itemBuilder(context, index + offset),
        ),
      ],
    );
  }
}

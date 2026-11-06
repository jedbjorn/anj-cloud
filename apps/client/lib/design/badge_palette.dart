import 'package:flutter/material.dart';

/// Shared design tokens for row badges (decision #60, superseding #59).
///
/// Colour is used sparingly and only where it carries meaning at a glance:
/// light blue for Cloud, light green for Local, light lavender for Editing,
/// amber for Conflict and Needs attention, light grey for Recovery copy, and
/// no tint at all (outline only) for Queued. Tints are light and
/// low-saturation; every foreground meets 4.5:1 against its background in
/// both themes, and the badge text always remains, so colour is never the
/// only signal. Future platform clients reuse these tokens (decision #58).
enum BadgeTone {
  /// Cloud-only on this device.
  cloud,

  /// Kept on this device.
  local,

  /// Open in an editor, or a finish is pending.
  editing,

  /// Conflict or needs attention. Harmonised with the amber attention bar.
  attention,

  /// A retained copy awaiting Recover or Dismiss.
  recovery,

  /// No tint: the row surface shows through an outline.
  plain,
}

/// One badge's colours. A null [background] means the row surface shows
/// through; [border] is drawn only when non-null.
@immutable
class BadgeColors {
  const BadgeColors({required this.foreground, this.background, this.border});
  final Color? background;
  final Color foreground;
  final Color? border;

  static BadgeColors lerp(BadgeColors a, BadgeColors b, double t) =>
      BadgeColors(
        background: Color.lerp(a.background, b.background, t),
        foreground: Color.lerp(a.foreground, b.foreground, t)!,
        border: Color.lerp(a.border, b.border, t),
      );
}

/// The badge palette as a theme extension, defined once for light and dark.
@immutable
class BadgePalette extends ThemeExtension<BadgePalette> {
  const BadgePalette({
    required this.cloud,
    required this.local,
    required this.editing,
    required this.attention,
    required this.recovery,
    required this.plain,
  });

  final BadgeColors cloud;
  final BadgeColors local;
  final BadgeColors editing;
  final BadgeColors attention;
  final BadgeColors recovery;
  final BadgeColors plain;

  static const light = BadgePalette(
    cloud: BadgeColors(
      background: Color(0xffdceafa),
      foreground: Color(0xff0d3a6b),
    ),
    local: BadgeColors(
      background: Color(0xffdcf0df),
      foreground: Color(0xff1c4a29),
    ),
    editing: BadgeColors(
      background: Color(0xffece6f8),
      foreground: Color(0xff45337a),
    ),
    attention: BadgeColors(
      background: Color(0xffffedc2),
      foreground: Color(0xff5a4100),
    ),
    recovery: BadgeColors(
      background: Color(0xffe7e7ea),
      foreground: Color(0xff3b3b41),
    ),
    plain: BadgeColors(
      foreground: Color(0xff40484b),
      border: Color(0xffc0c8cb),
    ),
  );

  static const dark = BadgePalette(
    cloud: BadgeColors(
      background: Color(0xff1e3550),
      foreground: Color(0xffcfe3ff),
    ),
    local: BadgeColors(
      background: Color(0xff1f3a27),
      foreground: Color(0xffcdedd4),
    ),
    editing: BadgeColors(
      background: Color(0xff342c4d),
      foreground: Color(0xffe4dbfb),
    ),
    attention: BadgeColors(
      background: Color(0xff45360b),
      foreground: Color(0xffffdf94),
    ),
    recovery: BadgeColors(
      background: Color(0xff343438),
      foreground: Color(0xffe3e3e7),
    ),
    plain: BadgeColors(
      foreground: Color(0xffdce3e6),
      border: Color(0xff40484b),
    ),
  );

  /// The palette for [brightness].
  static BadgePalette forBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  /// The theme's palette, or the default for the theme's brightness.
  static BadgePalette of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<BadgePalette>() ?? forBrightness(theme.brightness);
  }

  BadgeColors operator [](BadgeTone tone) => switch (tone) {
    BadgeTone.cloud => cloud,
    BadgeTone.local => local,
    BadgeTone.editing => editing,
    BadgeTone.attention => attention,
    BadgeTone.recovery => recovery,
    BadgeTone.plain => plain,
  };

  @override
  BadgePalette copyWith({
    BadgeColors? cloud,
    BadgeColors? local,
    BadgeColors? editing,
    BadgeColors? attention,
    BadgeColors? recovery,
    BadgeColors? plain,
  }) => BadgePalette(
    cloud: cloud ?? this.cloud,
    local: local ?? this.local,
    editing: editing ?? this.editing,
    attention: attention ?? this.attention,
    recovery: recovery ?? this.recovery,
    plain: plain ?? this.plain,
  );

  @override
  BadgePalette lerp(BadgePalette? other, double t) {
    if (other == null) return this;
    return BadgePalette(
      cloud: BadgeColors.lerp(cloud, other.cloud, t),
      local: BadgeColors.lerp(local, other.local, t),
      editing: BadgeColors.lerp(editing, other.editing, t),
      attention: BadgeColors.lerp(attention, other.attention, t),
      recovery: BadgeColors.lerp(recovery, other.recovery, t),
      plain: BadgeColors.lerp(plain, other.plain, t),
    );
  }
}

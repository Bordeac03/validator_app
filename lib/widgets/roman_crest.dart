import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme.dart';

/// Official coat of arms (stema) of Municipiul Roman.
///
/// Heraldic blazon: a French heater shield with rounded base, **gules** (red)
/// field, charged with a golden boar's head (**or**) with two silver tusks
/// (**argent**), timbered with a **silver mural crown of five crenellated
/// towers** denoting the rank of municipality.
///
/// Rendered from the high-fidelity asset `assets/images/roman_crest.png`
/// (transparent background) so it stays faithful to the official emblem.
class RomanCrest extends StatelessWidget {
  /// Logical width of the crest. Height is derived from the emblem aspect.
  final double size;

  /// Adds a soft drop shadow / golden glow behind the crest.
  final bool withShadow;

  const RomanCrest({super.key, this.size = 48, this.withShadow = false});

  /// Aspect ratio of the source asset (width / height).
  static const double _aspect = 0.565;

  @override
  Widget build(BuildContext context) {
    final width = size;
    final height = size / _aspect;

    Widget image = Image.asset(
      // Bold logo-mark variant — stays crisp & legible at any size.
      'assets/images/roman_crest_mark.png',
      width: width,
      height: height,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
      errorBuilder: (_, __, ___) =>
          Icon(Icons.shield, size: width, color: MovaColors.red),
    );

    // A drop shadow must follow the emblem's silhouette, not the bounding
    // box, otherwise a transparent PNG casts an ugly solid rectangle. Use a
    // soft golden glow drawn *through* the alpha channel via a blurred copy.
    if (withShadow) {
      image = Stack(
        alignment: Alignment.center,
        children: [
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: size * 0.06, sigmaY: size * 0.06),
            child: ColorFiltered(
              colorFilter: ColorFilter.mode(
                MovaColors.gold.withValues(alpha: 0.45),
                BlendMode.srcATop,
              ),
              child: image,
            ),
          ),
          image,
        ],
      );
    }

    return SizedBox(width: width, height: height, child: image);
  }
}

/// A rectangle in CSS pixels.
class CoreRect {
  final double x;
  final double y;
  final double width;
  final double height;

  const CoreRect(
      {required this.x,
      required this.y,
      required this.width,
      required this.height});

  /// Rounds outward to whole pixels, the way upstream does before handing a
  /// rect to an engine: a fractional box would otherwise drop a row.
  CoreRect get enclosingIntRect {
    final left = x.floorToDouble();
    final top = y.floorToDouble();
    return CoreRect(
      x: left,
      y: top,
      width: (x + width).ceilToDouble() - left,
      height: (y + height).ceilToDouble() - top,
    );
  }

  @override
  String toString() => 'CoreRect($x, $y, $width x $height)';
}

/// Options for a screenshot.
///
/// Everything here is engine-neutral; the drivers translate it into whatever
/// their protocol wants, and the rectangle always reaches them in *document*
/// coordinates, which is the one system all three accept.
class CoreScreenshotOptions {
  /// `png`, `jpeg` or `webp`.
  final String type;

  /// 0-100, only meaningful for `jpeg` and `webp`.
  final int? quality;

  /// Capture the whole scrollable document rather than the viewport.
  final bool fullPage;

  /// A rectangle to capture, in CSS pixels relative to the document.
  final CoreRect? clip;

  /// `css` captures at CSS-pixel resolution; `device` uses the device pixel
  /// ratio, giving a larger image on a HiDPI screen.
  final String scale;

  const CoreScreenshotOptions({
    this.type = 'png',
    this.quality,
    this.fullPage = false,
    this.clip,
    this.scale = 'device',
  });

  /// Validates the combination the way upstream does, so a bad call fails
  /// with a clear message instead of an engine error.
  void validate() {
    if (!const ['png', 'jpeg', 'webp'].contains(type)) {
      throw ArgumentError.value(
          type, 'type', 'Expected one of: png, jpeg, webp');
    }
    if (quality != null) {
      if (type == 'png') {
        throw ArgumentError.value(
            quality, 'quality', 'quality is not supported for png screenshots');
      }
      if (quality! < 0 || quality! > 100) {
        throw ArgumentError.value(quality, 'quality', 'Expected 0..100');
      }
    }
    final rect = clip;
    if (rect != null && (rect.width <= 0 || rect.height <= 0)) {
      throw ArgumentError.value(
          clip, 'clip', 'Clipped area is either empty or outside the page');
    }
    if (!const ['css', 'device'].contains(scale)) {
      throw ArgumentError.value(scale, 'scale', 'Expected one of: css, device');
    }
  }

  /// The effective quality: upstream defaults jpeg to 80 and webp to 100, and
  /// png never carries one.
  int? get effectiveQuality {
    if (type == 'png') return null;
    if (quality != null) return quality;
    return type == 'jpeg' ? 80 : 100;
  }
}

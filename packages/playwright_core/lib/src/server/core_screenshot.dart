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

/// One entry of `screenshot(mask: ...)`: the elements a selector resolves to
/// inside one frame, painted over before the capture.
///
/// `parts` is the engine chain the injected `window.__pwDart` consumes, the
/// same JSON a locator carries.
typedef CoreScreenshotMask = ({Object frame, List<Map<String, dynamic>> parts});

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

  /// Paints the page over a transparent background rather than the white the
  /// engine defaults to. Ignored for `jpeg`, which has no alpha channel —
  /// upstream skips it there too.
  final bool omitBackground;

  /// `allow` leaves animations running; `disabled` finishes every finite CSS
  /// animation and transition and cancels the infinite ones, so a capture of
  /// an animated page is reproducible.
  final String animations;

  /// `hide` (the default) paints the text caret transparent; `initial` leaves
  /// it, so a focused input blinks into some captures and not others.
  final String caret;

  /// CSS injected into every frame — and into every shadow root — for the
  /// duration of the capture. Upstream's `style`.
  final String? style;

  /// Elements painted over with [maskColor] before the capture.
  final List<CoreScreenshotMask> mask;

  /// The colour of the mask boxes, in any CSS colour syntax.
  final String maskColor;

  const CoreScreenshotOptions({
    this.type = 'png',
    this.quality,
    this.fullPage = false,
    this.clip,
    this.scale = 'device',
    this.omitBackground = false,
    this.animations = 'allow',
    this.caret = 'hide',
    this.style,
    this.mask = const [],
    this.maskColor = '#F0F',
  });

  /// Whether anything has to be done to the page before the capture.
  bool get needsPagePreparation =>
      style != null || caret != 'initial' || animations == 'disabled';

  /// Upstream reads `caret !== 'initial'`, so anything but `initial` hides it.
  bool get hideCaret => caret != 'initial';

  bool get disableAnimations => animations == 'disabled';

  /// jpeg has no alpha channel, so upstream skips the override there.
  bool get shouldSetDefaultBackground => omitBackground && type != 'jpeg';

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
    if (!const ['allow', 'disabled'].contains(animations)) {
      throw ArgumentError.value(
          animations, 'animations', 'Expected one of: allow, disabled');
    }
    if (!const ['hide', 'initial'].contains(caret)) {
      throw ArgumentError.value(
          caret, 'caret', 'Expected one of: hide, initial');
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

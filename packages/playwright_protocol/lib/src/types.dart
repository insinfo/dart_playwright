/// Shared types used across the Playwright Dart packages.

/// Viewport dimensions.
class ViewportSize {
  final int width;
  final int height;

  const ViewportSize({required this.width, required this.height});

  Map<String, dynamic> toJson() => {'width': width, 'height': height};

  factory ViewportSize.fromJson(Map<String, dynamic> json) {
    return ViewportSize(
      width: json['width'] as int,
      height: json['height'] as int,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ViewportSize && width == other.width && height == other.height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'ViewportSize($width x $height)';
}

/// Screen dimensions.
class ScreenSize {
  final int width;
  final int height;

  const ScreenSize({required this.width, required this.height});

  Map<String, dynamic> toJson() => {'width': width, 'height': height};

  @override
  String toString() => 'ScreenSize($width x $height)';
}

/// A rectangle on the page.
class Rect {
  final double x;
  final double y;
  final double width;
  final double height;

  const Rect({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  double get left => x;
  double get top => y;
  double get right => x + width;
  double get bottom => y + height;

  Map<String, dynamic> toJson() => {
        'x': x,
        'y': y,
        'width': width,
        'height': height,
      };

  factory Rect.fromJson(Map<String, dynamic> json) {
    return Rect(
      x: (json['x'] as num).toDouble(),
      y: (json['y'] as num).toDouble(),
      width: (json['width'] as num).toDouble(),
      height: (json['height'] as num).toDouble(),
    );
  }

  @override
  String toString() => 'Rect($x, $y, $width, $height)';
}

/// Geolocation coordinates.
class Geolocation {
  final double latitude;
  final double longitude;
  final double? accuracy;

  const Geolocation({
    required this.latitude,
    required this.longitude,
    this.accuracy,
  });

  Map<String, dynamic> toJson() => {
        'latitude': latitude,
        'longitude': longitude,
        if (accuracy != null) 'accuracy': accuracy,
      };

  @override
  String toString() => 'Geolocation($latitude, $longitude)';
}

/// Proxy configuration.
class ProxySettings {
  final String server;
  final String? bypass;
  final String? username;
  final String? password;

  const ProxySettings({
    required this.server,
    this.bypass,
    this.username,
    this.password,
  });

  Map<String, dynamic> toJson() => {
        'server': server,
        if (bypass != null) 'bypass': bypass,
        if (username != null) 'username': username,
        if (password != null) 'password': password,
      };
}

/// HTTP credentials for authentication.
class HttpCredentials {
  final String username;
  final String password;
  final String? origin;

  const HttpCredentials({
    required this.username,
    required this.password,
    this.origin,
  });

  Map<String, dynamic> toJson() => {
        'username': username,
        'password': password,
        if (origin != null) 'origin': origin,
      };
}

// === Enums ===

/// When to consider a navigation as finished.
enum WaitUntil {
  /// Wait for the `load` event.
  load,

  /// Wait for the `DOMContentLoaded` event.
  domContentLoaded,

  /// Wait until there are no more than 0 network connections for at least 500ms.
  networkIdle,

  /// Wait for the first non-about:blank navigation to commit.
  commit,
}

/// Load state to wait for.
enum LoadState {
  load,
  domContentLoaded,
  networkIdle,
}

/// Screenshot image format.
enum ScreenshotType {
  png,
  jpeg,
}

/// Preferred color scheme for `prefers-color-scheme` media query.
enum ColorScheme {
  light,
  dark,
  noPreference,
}

/// Preferred reduced motion for `prefers-reduced-motion` media query.
enum ReducedMotion {
  reduce,
  noPreference,
}

/// Forced colors mode.
enum ForcedColors {
  active,
  none,
}

/// CSS media type to emulate.
enum MediaType {
  screen,
  print,
}

/// Mouse button.
enum MouseButton {
  left,
  right,
  middle,
}

/// State to wait for with `waitForSelector`.
enum WaitForSelectorState {
  attached,
  detached,
  visible,
  hidden,
}

/// Browser name.
enum BrowserName {
  chromium,
  firefox,
  webkit,
}

/// Service worker policy.
enum ServiceWorkerPolicy {
  allow,
  block,
}

/// SameSite cookie attribute.
enum SameSiteAttribute {
  strict,
  lax,
  none,
}

/// ARIA role for `getByRole`.
enum AriaRole {
  alert,
  alertdialog,
  application,
  article,
  banner,
  blockquote,
  button,
  caption,
  cell,
  checkbox,
  code,
  columnheader,
  combobox,
  complementary,
  contentinfo,
  definition,
  deletion,
  dialog,
  directory,
  document,
  emphasis,
  feed,
  figure,
  form,
  generic,
  grid,
  gridcell,
  group,
  heading,
  img,
  insertion,
  link,
  list,
  listbox,
  listitem,
  log,
  main,
  marquee,
  math,
  meter,
  menu,
  menubar,
  menuitem,
  menuitemcheckbox,
  menuitemradio,
  navigation,
  none,
  note,
  option,
  paragraph,
  presentation,
  progressbar,
  radio,
  radiogroup,
  region,
  row,
  rowgroup,
  rowheader,
  scrollbar,
  search,
  searchbox,
  separator,
  slider,
  spinbutton,
  status,
  strong,
  subscript,
  superscript,
  $switch,
  tab,
  table,
  tablist,
  tabpanel,
  term,
  textbox,
  time,
  timer,
  toolbar,
  tooltip,
  tree,
  treegrid,
  treeitem,
}

// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.

/// A JavaScript regular expression literal: a source and a flag string.
///
/// Upstream's selector strings and generated snippets both carry regular
/// expressions in their literal `/source/flags` form, and every generator
/// reads back `re.source` and `re.flags` to rewrite them for its own
/// language. Dart's [RegExp] keeps neither: it normalizes flags into
/// booleans and gives no way to recover the original order, so round tripping
/// `/a/im` through it would not be faithful.
///
/// This type is therefore what a "RegExp" means everywhere in this package.
/// Call [toDart] when an actual matcher is needed.
class JsRegExp {
  /// The pattern between the slashes, exactly as written.
  final String source;

  /// The flag letters after the closing slash, in their original order.
  final String flags;

  const JsRegExp(this.source, [this.flags = '']);

  /// Parses a `/source/flags` literal.
  ///
  /// Throws [FormatException] when [literal] is not one.
  factory JsRegExp.parse(String literal) {
    if (!literal.startsWith('/')) {
      throw FormatException("Invalid regex, must start with '/'", literal);
    }
    final lastSlash = literal.lastIndexOf('/');
    if (lastSlash <= 0) {
      throw FormatException(
          "Invalid regex, must end with '/' followed by optional flags",
          literal);
    }
    return JsRegExp(
        literal.substring(1, lastSlash), literal.substring(lastSlash + 1));
  }

  /// Builds a regex from a raw pattern, escaping it the way JavaScript's
  /// `new RegExp(pattern).source` does.
  ///
  /// This matters more than it looks: `new RegExp('a/b').source` is `a\/b`,
  /// not `a/b`, because the source has to be pasteable back between slashes.
  /// Every generated locator that carries a regex goes through that, so a
  /// port that skipped it would fail to round trip `getByText(/he\/lo/)`.
  ///
  /// Use it wherever upstream calls `new RegExp(someString)`; it is
  /// idempotent, so an already escaped pattern comes back unchanged.
  factory JsRegExp.fromPattern(String pattern, [String flags = '']) =>
      JsRegExp(_escapeRegExpPattern(pattern), flags);

  bool get ignoreCase => flags.contains('i');
  bool get multiline => flags.contains('m');
  bool get dotAll => flags.contains('s');

  /// True for the two Unicode modes, which upstream treats alike because
  /// neither allows identity character escapes.
  bool get unicode => flags.contains('u') || flags.contains('v');

  /// A Dart matcher with the same behaviour, as far as the flags map over.
  RegExp toDart() => RegExp(source,
      caseSensitive: !ignoreCase,
      multiLine: multiline,
      dotAll: dotAll,
      unicode: unicode);

  /// The literal form, which is what `String(re)` yields in JavaScript.
  @override
  String toString() => '/$source/$flags';

  @override
  bool operator ==(Object other) =>
      other is JsRegExp && other.source == source && other.flags == flags;

  @override
  int get hashCode => Object.hash(source, flags);
}

/// The abstract EscapeRegExpPattern operation of ECMA-262, as V8 implements
/// it: an unescaped `/` outside a character class, and the line terminators,
/// are escaped, and an empty pattern becomes `(?:)`.
///
/// U+2028 and U+2029 are left alone. V8 escapes them too, but a selector has
/// no way to carry them in the first place and no upstream case exercises it.
String _escapeRegExpPattern(String pattern) {
  if (pattern.isEmpty) return '(?:)';
  final buffer = StringBuffer();
  var inCharacterClass = false;
  for (var i = 0; i < pattern.length; i++) {
    final c = pattern[i];
    if (c == r'\') {
      buffer.write(c);
      if (i + 1 < pattern.length) buffer.write(pattern[++i]);
      continue;
    }
    if (c == '[') inCharacterClass = true;
    if (c == ']') inCharacterClass = false;
    switch (c) {
      case '/':
        buffer.write(inCharacterClass ? '/' : r'\/');
        break;
      case '\n':
        buffer.write(r'\n');
        break;
      case '\r':
        buffer.write(r'\r');
        break;
      default:
        buffer.write(c);
    }
  }
  return buffer.toString();
}

/// Whether [value] is a regular expression rather than a plain string.
///
/// The generators take `String | RegExp` unions, which Dart spells as
/// [Object]; this is upstream's `isRegExp` guard.
bool isJsRegExp(Object? value) => value is JsRegExp;

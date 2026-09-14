// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/stringUtils.ts and
// packages/playwright-core/src/utils/isomorphic/locatorUtils.ts

import 'dart:convert';

/// How a piece of text is matched: a literal string (exact or a
/// case-insensitive substring) or a regular expression.
///
/// Mirrors `escapeForTextSelector`/`escapeForAttributeSelector` in upstream's
/// `packages/isomorphic/stringUtils.ts`: the `exact` flag is upstream's `s`/`i`
/// suffix, and a `RegExp` bypasses it entirely.
class TextMatch {
  final String? value;
  final bool exact;
  final RegExp? regex;

  const TextMatch.text(String this.value, {this.exact = false}) : regex = null;
  const TextMatch.pattern(RegExp this.regex)
      : value = null,
        exact = false;

  /// Builds a matcher from a [Pattern]: a [RegExp] matches as a regex, a
  /// [String] as a literal honouring [exact].
  factory TextMatch.from(Pattern pattern, {bool exact = false}) {
    if (pattern is RegExp) return TextMatch.pattern(pattern);
    return TextMatch.text(pattern.toString(), exact: exact);
  }

  Map<String, dynamic> toJson() {
    final re = regex;
    if (re != null) {
      return {
        'regex': {'source': re.pattern, 'flags': _regexFlags(re)},
      };
    }
    return {'value': value, 'exact': exact};
  }

  @override
  String toString() {
    final re = regex;
    if (re != null) return '/${re.pattern}/${_regexFlags(re)}';
    return '${jsonEncode(value)}${exact ? 's' : 'i'}';
  }

  static String _regexFlags(RegExp re) {
    final buffer = StringBuffer();
    if (!re.isCaseSensitive) buffer.write('i');
    if (re.isMultiLine) buffer.write('m');
    if (re.isDotAll) buffer.write('s');
    if (re.isUnicode) buffer.write('u');
    return buffer.toString();
  }
}

/// Options of the `internal:role` selector engine.
///
/// Mirrors `ByRoleOptions` in upstream's `locatorUtils.ts`.
class RoleOptions {
  final Object? checked; // bool or 'mixed'
  final bool? disabled;
  final bool? expanded;
  final bool? includeHidden;
  final int? level;
  final Pattern? name;
  final Object? pressed; // bool or 'mixed'
  final bool? selected;
  final Pattern? description;
  final bool exact;

  const RoleOptions({
    this.checked,
    this.disabled,
    this.expanded,
    this.includeHidden,
    this.level,
    this.name,
    this.pressed,
    this.selected,
    this.description,
    this.exact = false,
  });
}

/// A selector: an ordered list of engine parts, evaluated left to right, each
/// scoped by the results of the previous one.
///
/// The JSON shape is what `window.__pwDart` in
/// `injected/injected_script_source.dart` consumes.
class ParsedSelector {
  final List<Map<String, dynamic>> parts;

  const ParsedSelector(this.parts);

  /// Appends [more] to this selector, producing a new one.
  ParsedSelector append(List<Map<String, dynamic>> more) =>
      ParsedSelector([...parts, ...more]);

  ParsedSelector appendSelector(ParsedSelector other) => append(other.parts);

  /// True when the selector crosses at least one frame boundary.
  bool get hasFrameParts => parts.any((part) => part['engine'] == 'frame');

  /// Splits the selector on frame boundaries: `[a, frame, b, frame, c]`
  /// becomes `[[a], [b], [c]]`. The first group runs in the starting frame,
  /// each subsequent group inside the frame the previous group resolved to.
  List<List<Map<String, dynamic>>> splitOnFrames() {
    final groups = <List<Map<String, dynamic>>>[[]];
    for (final part in parts) {
      if (part['engine'] == 'frame') {
        groups.add([]);
      } else {
        groups.last.add(part);
      }
    }
    return groups;
  }

  String get description => parts.map(_describePart).join(' >> ');

  @override
  String toString() => description;

  static String _describePart(Map<String, dynamic> part) {
    switch (part['engine']) {
      case 'css':
        return part['body'] as String;
      case 'xpath':
        return 'xpath=${part['body']}';
      case 'text':
        return 'internal:text=${_describeText(part['text'])}';
      case 'label':
        return 'internal:label=${_describeText(part['text'])}';
      case 'attr':
        return 'internal:attr=[${part['name']}=${_describeText(part['text'])}]';
      case 'testid':
        return 'internal:testid=[${(part['names'] as List).join(',')}'
            '=${_describeText(part['text'])}]';
      case 'role':
        return 'internal:role=${part['role']}'
            '${part['name'] != null ? '[name=${_describeText(part['name'])}]' : ''}';
      case 'nth':
        return 'nth=${part['index']}';
      case 'visible':
        return 'visible=${part['value']}';
      case 'has':
        return 'internal:has=${ParsedSelector(_nested(part)).description}';
      case 'hasNot':
        return 'internal:has-not=${ParsedSelector(_nested(part)).description}';
      case 'hasText':
        return 'internal:has-text=${_describeText(part['text'])}';
      case 'hasNotText':
        return 'internal:has-not-text=${_describeText(part['text'])}';
      case 'and':
        return 'internal:and=${ParsedSelector(_nested(part)).description}';
      case 'or':
        return 'internal:or=${ParsedSelector(_nested(part)).description}';
      case 'frame':
        return 'internal:control=enter-frame';
      default:
        return part['engine'].toString();
    }
  }

  static List<Map<String, dynamic>> _nested(Map<String, dynamic> part) =>
      (part['parts'] as List).cast<Map<String, dynamic>>();

  static String _describeText(dynamic json) {
    if (json is! Map) return '';
    if (json['regex'] != null) {
      final regex = json['regex'] as Map;
      return '/${regex['source']}/${regex['flags']}';
    }
    return '${jsonEncode(json['value'])}${json['exact'] == true ? 's' : 'i'}';
  }
}

/// Builders for the selector parts, mirroring upstream's `locatorUtils.ts`.
class Selectors {
  Selectors._();

  static const String defaultTestIdAttribute = 'data-testid';

  static Map<String, dynamic> css(String body) =>
      {'engine': 'css', 'body': body};

  static Map<String, dynamic> xpath(String body) =>
      {'engine': 'xpath', 'body': body};

  static Map<String, dynamic> nth(int index) =>
      {'engine': 'nth', 'index': index};

  static Map<String, dynamic> visible(bool value) =>
      {'engine': 'visible', 'value': value};

  static Map<String, dynamic> frame() => {'engine': 'frame'};

  static Map<String, dynamic> has(ParsedSelector inner) =>
      {'engine': 'has', 'parts': inner.parts};

  static Map<String, dynamic> hasNot(ParsedSelector inner) =>
      {'engine': 'hasNot', 'parts': inner.parts};

  static Map<String, dynamic> and(ParsedSelector other) =>
      {'engine': 'and', 'parts': other.parts};

  static Map<String, dynamic> or(ParsedSelector other) =>
      {'engine': 'or', 'parts': other.parts};

  static Map<String, dynamic> hasText(Pattern text) => {
        'engine': 'hasText',
        'text': TextMatch.from(text).toJson(),
      };

  static Map<String, dynamic> hasNotText(Pattern text) => {
        'engine': 'hasNotText',
        'text': TextMatch.from(text).toJson(),
      };

  /// `getByText`: `internal:text=`.
  static Map<String, dynamic> byText(Pattern text, {bool exact = false}) => {
        'engine': 'text',
        'text': TextMatch.from(text, exact: exact).toJson(),
      };

  /// `getByLabel`: `internal:label=`.
  static Map<String, dynamic> byLabel(Pattern text, {bool exact = false}) => {
        'engine': 'label',
        'text': TextMatch.from(text, exact: exact).toJson(),
      };

  /// `internal:attr=[name=...]`, the engine behind `getByPlaceholder`,
  /// `getByAltText` and `getByTitle`.
  static Map<String, dynamic> byAttribute(String name, Pattern text,
          {bool exact = false}) =>
      {
        'engine': 'attr',
        'name': name,
        'text': TextMatch.from(text, exact: exact).toJson(),
      };

  static Map<String, dynamic> byPlaceholder(Pattern text,
          {bool exact = false}) =>
      byAttribute('placeholder', text, exact: exact);

  static Map<String, dynamic> byAltText(Pattern text, {bool exact = false}) =>
      byAttribute('alt', text, exact: exact);

  static Map<String, dynamic> byTitle(Pattern text, {bool exact = false}) =>
      byAttribute('title', text, exact: exact);

  /// `getByTestId`: matching is always exact, as upstream does.
  static Map<String, dynamic> byTestId(Pattern testId,
          {String attributeName = defaultTestIdAttribute}) =>
      {
        'engine': 'testid',
        'names': attributeName.split(','),
        'text': TextMatch.from(testId, exact: true).toJson(),
      };

  /// `getByRole`: `internal:role=`.
  static Map<String, dynamic> byRole(String role, RoleOptions options) {
    final part = <String, dynamic>{'engine': 'role', 'role': role};
    if (options.checked != null) part['checked'] = options.checked;
    if (options.disabled != null) part['disabled'] = options.disabled;
    if (options.expanded != null) part['expanded'] = options.expanded;
    if (options.includeHidden != null) {
      part['includeHidden'] = options.includeHidden;
    }
    if (options.level != null) part['level'] = options.level;
    if (options.pressed != null) part['pressed'] = options.pressed;
    if (options.selected != null) part['selected'] = options.selected;
    final name = options.name;
    if (name != null) {
      part['name'] = TextMatch.from(name, exact: options.exact).toJson();
    }
    final description = options.description;
    if (description != null) {
      part['description'] =
          TextMatch.from(description, exact: options.exact).toJson();
    }
    return part;
  }

  /// Parses a Playwright selector string into engine parts.
  ///
  /// Supports the forms the port actually needs: `>>` chaining, the `css=`,
  /// `css:light=`, `xpath=`, `text=`, `id=`, `nth=` and `visible=` prefixes,
  /// and upstream's implicit detection (`//`/`..` is XPath, a quoted string is
  /// text, anything else is CSS). The CSS body itself is parsed in the page by
  /// the ported `cssParser`, so Playwright's CSS extensions (`:has-text()`,
  /// `:visible`, `:nth-match()`, the layout selectors, `:light()`) all work.
  /// Custom registered engines are not supported.
  static ParsedSelector parse(String selector) {
    final parts = <Map<String, dynamic>>[];
    for (final chunk in _splitChain(selector)) {
      parts.add(_parsePart(chunk.trim()));
    }
    if (parts.isEmpty) {
      throw ArgumentError('Selector must not be empty');
    }
    return ParsedSelector(parts);
  }

  /// Splits on `>>` that is not inside a quoted string.
  static List<String> _splitChain(String selector) {
    final result = <String>[];
    final buffer = StringBuffer();
    String? quote;
    for (var i = 0; i < selector.length; i++) {
      final ch = selector[i];
      if (quote != null) {
        if (ch == r'\' && i + 1 < selector.length) {
          buffer.write(ch);
          buffer.write(selector[++i]);
          continue;
        }
        if (ch == quote) quote = null;
        buffer.write(ch);
        continue;
      }
      if (ch == '"' || ch == "'" || ch == '`') {
        quote = ch;
        buffer.write(ch);
        continue;
      }
      if (ch == '>' && i + 1 < selector.length && selector[i + 1] == '>') {
        result.add(buffer.toString());
        buffer.clear();
        i++;
        continue;
      }
      buffer.write(ch);
    }
    result.add(buffer.toString());
    return result;
  }

  static Map<String, dynamic> _parsePart(String body) {
    if (body.isEmpty) {
      throw ArgumentError('Selector part must not be empty');
    }
    if (body.startsWith('css=')) return css(body.substring(4));
    // `css:light=` is upstream's opt-out from shadow piercing; it is spelled
    // `:light()` once it reaches the evaluator.
    if (body.startsWith('css:light=')) {
      return css(':light(${body.substring(10)})');
    }
    if (body.startsWith('xpath=')) return xpath(body.substring(6));
    if (body.startsWith('nth=')) {
      final raw = body.substring(4);
      if (raw == 'first') return nth(0);
      if (raw == 'last') return nth(-1);
      return nth(int.parse(raw));
    }
    if (body.startsWith('visible=')) {
      return visible(body.substring(8) == 'true');
    }
    if (body.startsWith('id=')) return css('#${body.substring(3)}');
    if (body.startsWith('text=')) return _parseTextBody(body.substring(5));
    if (body.startsWith('//') || body.startsWith('..')) return xpath(body);
    if (body.length > 1 && body.startsWith('"') && body.endsWith('"')) {
      return _parseTextBody(body);
    }
    return css(body);
  }

  /// `text="foo"` is exact; `text=foo` is a case-insensitive substring;
  /// `text=/re/flags` is a regular expression. Matches upstream's
  /// `createTextMatcher`.
  static Map<String, dynamic> _parseTextBody(String body) {
    if (body.length > 1 && body.startsWith('/') && body.lastIndexOf('/') > 0) {
      final lastSlash = body.lastIndexOf('/');
      final source = body.substring(1, lastSlash);
      final flags = body.substring(lastSlash + 1);
      return byText(RegExp(source,
          caseSensitive: !flags.contains('i'),
          multiLine: flags.contains('m'),
          dotAll: flags.contains('s'),
          unicode: flags.contains('u')));
    }
    if (body.length > 1 && body.startsWith('"') && body.endsWith('"')) {
      return byText(jsonDecode(body) as String, exact: true);
    }
    if (body.length > 1 && body.startsWith("'") && body.endsWith("'")) {
      return byText(body.substring(1, body.length - 1), exact: true);
    }
    return byText(body);
  }
}

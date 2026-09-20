// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/selectorParser.ts

import 'dart:convert';

import 'css_parser.dart';
import 'js_regexp.dart';

export 'css_parser.dart' show InvalidSelectorError, isInvalidSelectorError;

/// The body of a selector that wraps another selector, such as
/// `internal:has=` or the layout engines.
class NestedSelectorBody {
  final ParsedSelector parsed;

  /// The pixel distance of `near=`, `above=` and their siblings.
  final num? distance;

  NestedSelectorBody(this.parsed, [this.distance]);
}

const Set<String> _kNestedSelectorNames = {
  'internal:has',
  'internal:has-not',
  'internal:and',
  'internal:or',
  'internal:chain',
  'left-of',
  'right-of',
  'above',
  'below',
  'near',
};

const Set<String> _kNestedSelectorNamesWithDistance = {
  'left-of',
  'right-of',
  'above',
  'below',
  'near',
};

/// One engine of a selector chain.
class ParsedSelectorPart {
  /// The engine name: `css`, `xpath`, `internal:role`, and so on.
  final String name;

  /// A [String], a `List<CssComplexSelector>` for `css`, or a
  /// [NestedSelectorBody] for the wrapping engines.
  final Object body;

  /// The body exactly as it was written, which is what [stringifySelector]
  /// prints.
  final String source;

  ParsedSelectorPart(
      {required this.name, required this.body, required this.source});
}

/// A selector: the engine chain plus the index of the `*` capture, if any.
class ParsedSelector {
  final List<ParsedSelectorPart> parts;
  int? capture;

  ParsedSelector(this.parts, {this.capture});
}

class _ParsedSelectorString {
  final List<({String name, String body})> parts = [];
  int? capture;
}

/// The pseudo-class names that are Playwright extensions rather than CSS.
const Set<String> customCSSNames = {
  'not',
  'is',
  'where',
  'has',
  'scope',
  'light',
  'visible',
  'text',
  'text-matches',
  'text-is',
  'has-text',
  'above',
  'below',
  'right-of',
  'left-of',
  'near',
  'nth-match',
};

/// Parses a Playwright selector string into its engine chain.
///
/// Throws [InvalidSelectorError] when [selector] is not a selector, which is
/// what `asLocator` and `locatorOrSelectorAsSelector` lean on to tell a
/// selector apart from a locator expression.
ParsedSelector parseSelector(String selector) {
  final parsedStrings = _parseSelectorString(selector);
  final parts = <ParsedSelectorPart>[];
  for (final part in parsedStrings.parts) {
    var name = part.name;
    var body = part.body;
    if (name == 'css' || name == 'css:light') {
      if (name == 'css:light') body = ':light($body)';
      final parsedCSS = parseCss(body, customCSSNames);
      parts.add(ParsedSelectorPart(
          name: 'css', body: parsedCSS.selector, source: body));
      continue;
    }
    if (_kNestedSelectorNames.contains(name)) {
      String innerSelector;
      num? distance;
      try {
        final unescaped = jsonDecode('[$body]');
        if (unescaped is! List ||
            unescaped.isEmpty ||
            unescaped.length > 2 ||
            unescaped[0] is! String) {
          throw InvalidSelectorError('Malformed selector: $name=$body');
        }
        innerSelector = unescaped[0] as String;
        if (unescaped.length == 2) {
          if (unescaped[1] is! num ||
              !_kNestedSelectorNamesWithDistance.contains(name)) {
            throw InvalidSelectorError('Malformed selector: $name=$body');
          }
          distance = unescaped[1] as num;
        }
      } catch (_) {
        throw InvalidSelectorError('Malformed selector: $name=$body');
      }
      final nestedParsed = parseSelector(innerSelector);
      final nested = ParsedSelectorPart(
          name: name,
          body: NestedSelectorBody(nestedParsed, distance),
          source: body);
      var lastFrameIndex = -1;
      for (var i = nestedParsed.parts.length - 1; i >= 0; i--) {
        final p = nestedParsed.parts[i];
        if (p.name == 'internal:control' && p.body == 'enter-frame') {
          lastFrameIndex = i;
          break;
        }
      }
      // The "any-frame" token applies to the whole selector, so nested
      // selectors must not repeat it.
      final outerParts = parts.isNotEmpty &&
              parts[0].name == 'internal:control' &&
              parts[0].body == 'any-frame'
          ? parts.sublist(1)
          : parts;
      // Allow nested selectors to start with the same frame selector.
      if (lastFrameIndex != -1 &&
          outerParts.length >= lastFrameIndex + 1 &&
          _selectorPartsEqual(nestedParsed.parts.sublist(0, lastFrameIndex + 1),
              outerParts.sublist(0, lastFrameIndex + 1))) {
        nestedParsed.parts.removeRange(0, lastFrameIndex + 1);
        final capture = nestedParsed.capture;
        if (capture != null) {
          if (capture <= lastFrameIndex) {
            throw InvalidSelectorError(
                'Can not capture the selector before diving into the frame. '
                'Only use * after the last frame has been selected');
          }
          // The capture refers to a part index, so it shifts along with the
          // removed prefix.
          nestedParsed.capture = capture - lastFrameIndex - 1;
        }
      }
      parts.add(nested);
      continue;
    }
    parts.add(ParsedSelectorPart(name: name, body: body, source: body));
  }
  if (_kNestedSelectorNames.contains(parts[0].name)) {
    throw InvalidSelectorError('"${parts[0].name}" selector cannot be first');
  }
  return ParsedSelector(parts, capture: parsedStrings.capture);
}

/// Matches in any frame of the subtree instead of in the frame itself. Only
/// allowed as the first token.
const String kAnyFrameSelector = 'internal:control=any-frame';

/// The result of [splitSelectorByFrame].
class SplitSelectorByFrame {
  final bool anyFrame;
  final List<ParsedSelector> chunks;
  SplitSelectorByFrame(this.anyFrame, this.chunks);
}

/// Splits [selectorText] into per-frame chunks separated by `enter-frame`
/// boundaries. The optional leading `any-frame` token is reported separately.
SplitSelectorByFrame splitSelectorByFrame(String selectorText) {
  final selector = parseSelector(selectorText);
  final chunks = <ParsedSelector>[];
  var chunk = ParsedSelector(<ParsedSelectorPart>[]);
  var anyFrame = false;
  var chunkStartIndex = 0;
  for (var i = 0; i < selector.parts.length; ++i) {
    final part = selector.parts[i];
    if (part.name == 'internal:control' && part.body == 'any-frame') {
      // The starting frame applies to the whole selector, so the token only
      // makes sense as the very first one.
      if (i != 0) {
        throw InvalidSelectorError(
            '"${part.body}" is only allowed as the first selector token, '
            'while parsing selector $selectorText');
      }
      anyFrame = true;
      chunkStartIndex = i + 1;
      continue;
    }
    if (part.name == 'internal:control' && part.body == 'enter-frame') {
      final lastPart = chunk.parts.isEmpty ? null : chunk.parts.last;
      if (lastPart == null ||
          (lastPart.name == 'internal:control' &&
              lastPart.body == 'enter-frame')) {
        throw InvalidSelectorError(
            'Selector cannot start with entering frame, select the iframe '
            'first');
      }
      chunks.add(chunk);
      chunk = ParsedSelector(<ParsedSelectorPart>[]);
      chunkStartIndex = i + 1;
      continue;
    }
    if (selector.capture == i) chunk.capture = i - chunkStartIndex;
    chunk.parts.add(part);
  }
  if (chunk.parts.isEmpty) {
    if (anyFrame && chunks.isEmpty) {
      throw InvalidSelectorError(
          'Selector cannot be empty after frameLocator(), while parsing '
          'selector $selectorText');
    }
    throw InvalidSelectorError(
        'Selector cannot end with entering frame, while parsing selector '
        '$selectorText');
  }
  final lastPart = chunk.parts.last;
  if (lastPart.name == 'internal:control' && lastPart.body == 'enter-frame') {
    throw InvalidSelectorError(
        'Selector cannot end with entering frame, while parsing selector '
        '$selectorText');
  }
  chunks.add(chunk);
  if (selector.capture != null && chunks.last.capture == null) {
    throw InvalidSelectorError(
        'Can not capture the selector before diving into the frame. Only use '
        '* after the last frame has been selected');
  }
  return SplitSelectorByFrame(anyFrame, chunks);
}

bool _selectorPartsEqual(
        List<ParsedSelectorPart> list1, List<ParsedSelectorPart> list2) =>
    stringifySelector(ParsedSelector(list1)) ==
    stringifySelector(ParsedSelector(list2));

/// Renders [selector] back to its string form.
///
/// A `css` part and an implicit `xpath` drop their engine prefix unless
/// [forceEngineName] asks for it, or unless the part is the `*` capture.
String stringifySelector(ParsedSelector selector,
    {bool forceEngineName = false}) {
  final buffer = <String>[];
  for (var i = 0; i < selector.parts.length; i++) {
    final p = selector.parts[i];
    var includeEngine = true;
    if (!forceEngineName && i != selector.capture) {
      if (p.name == 'css') {
        includeEngine = false;
      } else if (p.name == 'xpath' &&
          (p.source.startsWith('//') || p.source.startsWith('..'))) {
        includeEngine = false;
      }
    }
    final prefix = includeEngine ? '${p.name}=' : '';
    buffer.add('${i == selector.capture ? '*' : ''}$prefix${p.source}');
  }
  return buffer.join(' >> ');
}

/// Walks every part of [selector], descending into the nested engines.
void visitAllSelectorParts(ParsedSelector selector,
    void Function(ParsedSelectorPart part, bool nested) visitor) {
  void visit(ParsedSelector selector, bool nested) {
    for (final part in selector.parts) {
      visitor(part, nested);
      if (_kNestedSelectorNames.contains(part.name)) {
        visit((part.body as NestedSelectorBody).parsed, true);
      }
    }
  }

  visit(selector, false);
}

final RegExp _kEngineNameRe = RegExp(r'^[a-zA-Z_0-9\-+:*]+$');
final RegExp _kXPathPrefixRe = RegExp(r'^\(*//');
final RegExp _kTextSelectorPrefixRe = RegExp(r'^\s*text\s*=(.*)$');

_ParsedSelectorString _parseSelectorString(String selector) {
  var index = 0;
  String? quote;
  var start = 0;
  final result = _ParsedSelectorString();

  void append() {
    final part = selector.substring(start, index).trim();
    final eqIndex = part.indexOf('=');
    String name;
    String body;
    if (eqIndex != -1 &&
        _kEngineNameRe.hasMatch(part.substring(0, eqIndex).trim())) {
      name = part.substring(0, eqIndex).trim();
      body = part.substring(eqIndex + 1);
    } else if (part.length > 1 &&
        part[0] == '"' &&
        part[part.length - 1] == '"') {
      name = 'text';
      body = part;
    } else if (part.length > 1 &&
        part[0] == "'" &&
        part[part.length - 1] == "'") {
      name = 'text';
      body = part;
    } else if (_kXPathPrefixRe.hasMatch(part) || part.startsWith('..')) {
      // A selector that starts with "//", or with "//" behind opening
      // parentheses, is XPath; so is one that starts with "..".
      name = 'xpath';
      body = part;
    } else {
      name = 'css';
      body = part;
    }
    var capture = false;
    if (name.isNotEmpty && name[0] == '*') {
      capture = true;
      name = name.substring(1);
    }
    result.parts.add((name: name, body: body));
    if (capture) {
      if (result.capture != null) {
        throw InvalidSelectorError(
            'Only one of the selectors can capture using * modifier');
      }
      result.capture = result.parts.length - 1;
    }
  }

  if (!selector.contains('>>')) {
    index = selector.length;
    append();
    return result;
  }

  bool shouldIgnoreTextSelectorQuote() {
    final prefix = selector.substring(start, index);
    final match = _kTextSelectorPrefixRe.firstMatch(prefix);
    // Must be a text selector with some text before the quote.
    return match != null && (match[1] ?? '').isNotEmpty;
  }

  while (index < selector.length) {
    final c = selector[index];
    if (c == r'\' && index + 1 < selector.length) {
      index += 2;
    } else if (c == quote) {
      quote = null;
      index++;
    } else if (quote == null &&
        (c == '"' || c == "'" || c == '`') &&
        !shouldIgnoreTextSelectorQuote()) {
      quote = c;
      index++;
    } else if (quote == null &&
        c == '>' &&
        index + 1 < selector.length &&
        selector[index + 1] == '>') {
      append();
      index += 2;
      start = index;
    } else {
      index++;
    }
  }
  append();
  return result;
}

/// The operators an attribute selector can use.
typedef AttributeSelectorOperator = String;

/// One `[name=value]` clause of an attribute selector.
class AttributeSelectorPart {
  final String name;
  final List<String> jsonPath;
  final AttributeSelectorOperator op;

  /// A [String], a [bool], a [num] or a [JsRegExp]; null for `<truthy>`.
  Object? value;
  final bool caseSensitive;

  AttributeSelectorPart({
    required this.name,
    required this.jsonPath,
    required this.op,
    required this.value,
    required this.caseSensitive,
  });
}

/// The parsed form of `role[name="x"i]` and its relatives.
class AttributeSelector {
  String name;
  final List<AttributeSelectorPart> attributes;
  AttributeSelector(this.name, this.attributes);
}

final RegExp _kSpaceRe = RegExp(r'\s');
final RegExp _kRegexFlagRe = RegExp(r'[dgimsuvy]');

/// Parses `role[name="x"i][level=2]` into a name and its attribute clauses.
///
/// With [allowUnquotedStrings] an unquoted value stays a string instead of
/// being coerced to a number, which is what the `internal:` engines want.
AttributeSelector parseAttributeSelector(
    String selector, bool allowUnquotedStrings) {
  var wp = 0;
  var eol = selector.isEmpty;

  String next() => wp < selector.length ? selector[wp] : '';

  String eat1() {
    final result = next();
    ++wp;
    eol = wp >= selector.length;
    return result;
  }

  Never syntaxError(String? stage) {
    if (eol) {
      throw InvalidSelectorError(
          'Unexpected end of selector while parsing selector `$selector`');
    }
    throw InvalidSelectorError(
        'Error while parsing selector `$selector` - unexpected symbol '
        '"${next()}" at position $wp${stage != null ? ' during $stage' : ''}');
  }

  void skipSpaces() {
    while (!eol && _kSpaceRe.hasMatch(next())) {
      eat1();
    }
  }

  // https://www.w3.org/TR/css-syntax-3/#ident-token-diagram
  bool isCSSNameChar(String char) {
    if (char.isEmpty) return false;
    final code = char.codeUnitAt(0);
    return code >= 0x80 ||
        (code >= 0x30 && code <= 0x39) ||
        (code >= 0x41 && code <= 0x5a) ||
        (code >= 0x61 && code <= 0x7a) ||
        code == 0x5f ||
        code == 0x2d;
  }

  String readIdentifier() {
    final result = StringBuffer();
    skipSpaces();
    while (!eol && isCSSNameChar(next())) {
      result.write(eat1());
    }
    return result.toString();
  }

  String readQuotedString(String quote) {
    final result = StringBuffer(eat1());
    if (result.toString() != quote) syntaxError('parsing quoted string');
    while (!eol && next() != quote) {
      if (next() == r'\') eat1();
      result.write(eat1());
    }
    if (next() != quote) syntaxError('parsing quoted string');
    result.write(eat1());
    return result.toString();
  }

  JsRegExp readRegularExpression() {
    if (eat1() != '/') syntaxError('parsing regular expression');
    final source = StringBuffer();
    var inClass = false;
    // https://262.ecma-international.org/11.0/#sec-literals-regular-expression-literals
    while (!eol) {
      if (next() == r'\') {
        source.write(eat1());
        if (eol) syntaxError('parsing regular expression');
      } else if (inClass && next() == ']') {
        inClass = false;
      } else if (!inClass && next() == '[') {
        inClass = true;
      } else if (!inClass && next() == '/') {
        break;
      }
      source.write(eat1());
    }
    if (eat1() != '/') syntaxError('parsing regular expression');
    final flags = StringBuffer();
    while (!eol && _kRegexFlagRe.hasMatch(next())) {
      flags.write(eat1());
    }
    return JsRegExp.fromPattern(source.toString(), flags.toString());
  }

  String readAttributeToken() {
    String token;
    skipSpaces();
    if (next() == "'" || next() == '"') {
      final quoted = readQuotedString(next());
      token = quoted.substring(1, quoted.length - 1);
    } else {
      token = readIdentifier();
    }
    if (token.isEmpty) syntaxError('parsing property path');
    return token;
  }

  AttributeSelectorOperator readOperator() {
    skipSpaces();
    var op = '';
    if (!eol) op += eat1();
    if (!eol && op != '=') op += eat1();
    if (!const ['=', '*=', '^=', r'$=', '|=', '~='].contains(op)) {
      syntaxError('parsing operator');
    }
    return op;
  }

  AttributeSelectorPart readAttribute() {
    // Skip the leading "[".
    eat1();

    // Read the attribute name: foo.bar, or 'foo' . "ba zz".
    final jsonPath = <String>[];
    jsonPath.add(readAttributeToken());
    skipSpaces();
    while (next() == '.') {
      eat1();
      jsonPath.add(readAttributeToken());
      skipSpaces();
    }
    // Check the property is truthy: [enabled].
    if (next() == ']') {
      eat1();
      return AttributeSelectorPart(
          name: jsonPath.join('.'),
          jsonPath: jsonPath,
          op: '<truthy>',
          value: null,
          caseSensitive: false);
    }

    final operator = readOperator();

    Object? value;
    var caseSensitive = true;
    skipSpaces();
    if (next() == '/') {
      if (operator != '=') {
        throw InvalidSelectorError(
            'Error while parsing selector `$selector` - cannot use $operator '
            'in attribute with regular expression');
      }
      value = readRegularExpression();
    } else if (next() == "'" || next() == '"') {
      final quoted = readQuotedString(next());
      value = quoted.substring(1, quoted.length - 1);
      skipSpaces();
      if (next() == 'i' || next() == 'I') {
        caseSensitive = false;
        eat1();
      } else if (next() == 's' || next() == 'S') {
        caseSensitive = true;
        eat1();
      }
    } else {
      final raw = StringBuffer();
      while (
          !eol && (isCSSNameChar(next()) || next() == '+' || next() == '.')) {
        raw.write(eat1());
      }
      final text = raw.toString();
      if (text == 'true') {
        value = true;
      } else if (text == 'false') {
        value = false;
      } else if (!allowUnquotedStrings) {
        final parsed = num.tryParse(text);
        if (parsed == null) syntaxError('parsing attribute value');
        value = parsed;
      } else {
        value = text;
      }
    }
    skipSpaces();
    if (next() != ']') syntaxError('parsing attribute value');

    eat1();
    if (operator != '=' && value is! String) {
      throw InvalidSelectorError(
          'Error while parsing selector `$selector` - cannot use $operator in '
          'attribute with non-string matching value - $value');
    }
    return AttributeSelectorPart(
        name: jsonPath.join('.'),
        jsonPath: jsonPath,
        op: operator,
        value: value,
        caseSensitive: caseSensitive);
  }

  final result = AttributeSelector('', <AttributeSelectorPart>[]);
  result.name = readIdentifier();
  skipSpaces();
  while (next() == '[') {
    result.attributes.add(readAttribute());
    skipSpaces();
  }
  if (!eol) syntaxError(null);
  if (result.name.isEmpty && result.attributes.isEmpty) {
    throw InvalidSelectorError(
        'Error while parsing selector `$selector` - selector cannot be empty');
  }
  return result;
}

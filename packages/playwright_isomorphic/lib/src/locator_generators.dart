// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/locatorGenerators.ts
//
// The Dart factory at the bottom has no upstream counterpart: there is no
// official Dart binding, so it targets this port's own API.

import 'dart:convert';

import 'js_regexp.dart';
import 'selector_parser.dart';
import 'string_utils.dart';

/// The languages a selector can be rendered in.
///
/// Upstream spells this as a string union and so does this port, because the
/// value travels through the recorder protocol and the trace as a string.
typedef Language = String;

/// The known [Language] values. `dart` is this port's addition.
abstract final class Languages {
  static const String javascript = 'javascript';
  static const String python = 'python';
  static const String java = 'java';
  static const String csharp = 'csharp';
  static const String jsonl = 'jsonl';
  static const String dart = 'dart';

  static const List<String> all = [
    javascript,
    python,
    java,
    csharp,
    jsonl,
    dart,
  ];
}

/// What a single selector part turns into on the locator side.
typedef LocatorType = String;

/// What the locator is chained off: the page, another locator, or a frame
/// locator.
typedef LocatorBase = String;

/// The quote character a generated locator prefers for its strings.
typedef Quote = String;

/// One `getByRole` attribute: a name and a [String], [bool] or [num] value.
class LocatorAttr {
  final String name;
  final Object value;
  LocatorAttr(this.name, this.value);
}

/// The options passed alongside a locator body.
///
/// Backed by an insertion ordered map because the JSONL generator serializes
/// it verbatim, and key order is part of that output.
class LocatorOptions {
  final Map<String, Object?> fields = <String, Object?>{};

  List<LocatorAttr>? get attrs => fields['attrs'] as List<LocatorAttr>?;
  set attrs(List<LocatorAttr>? value) => fields['attrs'] = value;

  bool? get exact => fields['exact'] as bool?;
  set exact(bool? value) => fields['exact'] = value;

  /// A [String] or a [JsRegExp].
  Object? get name => fields['name'];
  set name(Object? value) => fields['name'] = value;

  /// A [String] or a [JsRegExp].
  Object? get description => fields['description'];
  set description(Object? value) => fields['description'] = value;

  /// A [String] or a [JsRegExp].
  Object? get hasText => fields['hasText'];
  set hasText(Object? value) => fields['hasText'] = value;

  /// A [String] or a [JsRegExp].
  Object? get hasNotText => fields['hasNotText'];
  set hasNotText(Object? value) => fields['hasNotText'] = value;

  bool has(String key) => fields.containsKey(key);
}

/// Turns one selector part into a locator call in a given language.
abstract class LocatorFactory {
  /// Renders one call. [body] is a [String] or a [JsRegExp].
  String generateLocator(LocatorBase base, LocatorType kind, Object body,
      [LocatorOptions? options]);

  /// Joins the calls of a chain.
  String chainLocators(List<String> locators);
}

/// The human readable description of [selector], honouring
/// `internal:describe`.
String asLocatorDescription(Language lang, String selector) {
  try {
    final parsed = parseSelector(selector);
    final customDescription = _parseCustomDescription(parsed);
    if (customDescription != null) return customDescription;
    return _innerAsLocators(_createFactory(lang), parsed, false, 1)[0];
  } catch (_) {
    // Tolerate invalid input.
    return selector;
  }
}

/// The `internal:describe` description of [selector], if it has one.
String? locatorCustomDescription(String selector) {
  try {
    return _parseCustomDescription(parseSelector(selector));
  } catch (_) {
    return null;
  }
}

String? _parseCustomDescription(ParsedSelector parsed) {
  if (parsed.parts.isEmpty) return null;
  final lastPart = parsed.parts.last;
  if (lastPart.name == 'internal:describe') {
    try {
      final description = jsonDecode(lastPart.body as String);
      if (description is String) return description;
    } catch (_) {
      return null;
    }
  }
  return null;
}

/// Renders [selector] as the idiomatic locator of [lang].
String asLocator(Language lang, String selector,
        [bool isFrameLocator = false]) =>
    asLocators(lang, selector, isFrameLocator, 1)[0];

/// Every locator that renders back to [selector], best first.
///
/// A selector can have several faithful spellings — `first()` and `nth(0)`,
/// or `locator(x).filter({hasText})` and `locator(x, {hasText})` — and the
/// recorder offers them all. Invalid input comes back unchanged.
List<String> asLocators(Language lang, String selector,
    [bool isFrameLocator = false,
    int maxOutputSize = 20,
    Quote? preferredQuote]) {
  try {
    return _innerAsLocators(_createFactory(lang, preferredQuote),
        parseSelector(selector), isFrameLocator, maxOutputSize);
  } catch (_) {
    // Tolerate invalid input.
    return [selector];
  }
}

List<String> _innerAsLocators(
    LocatorFactory factory, ParsedSelector parsed, bool isFrameLocator,
    [int maxOutputSize = 20]) {
  final parts = [...parsed.parts];
  final tokens = <List<String>>[];
  var nextBase = isFrameLocator ? 'frame-locator' : 'page';
  outer:
  for (var index = 0; index < parts.length; index++) {
    final part = parts[index];
    final base = nextBase;
    nextBase = 'locator';

    if (part.name == 'internal:describe') continue;
    if (part.name == 'nth') {
      if (part.body == '0') {
        tokens.add([
          factory.generateLocator(base, 'first', ''),
          factory.generateLocator(base, 'nth', '0'),
        ]);
      } else if (part.body == '-1') {
        tokens.add([
          factory.generateLocator(base, 'last', ''),
          factory.generateLocator(base, 'nth', '-1'),
        ]);
      } else {
        tokens.add([factory.generateLocator(base, 'nth', part.body as String)]);
      }
      continue;
    }
    if (part.name == 'visible') {
      final tokenList = <String>[];
      if (part.body == 'true') {
        tokenList.add(factory.generateLocator(base, 'visible', ''));
      }
      tokenList.add(
          factory.generateLocator(base, 'filter-visible', part.body as String));
      tokenList.add(
          factory.generateLocator(base, 'default', 'visible=${part.body}'));
      tokens.add(tokenList);
      continue;
    }
    if (part.name == 'internal:text') {
      final detected = _detectExact(part.body as String);
      final options = LocatorOptions();
      if (detected.exact != null) options.exact = detected.exact;
      tokens
          .add([factory.generateLocator(base, 'text', detected.text, options)]);
      continue;
    }
    if (part.name == 'internal:has-text') {
      final detected = _detectExact(part.body as String);
      // There is no locator equivalent for strict has-text, leave it as is.
      if (detected.exact != true) {
        final options = LocatorOptions();
        if (detected.exact != null) options.exact = detected.exact;
        tokens.add([
          factory.generateLocator(base, 'has-text', detected.text, options)
        ]);
        continue;
      }
    }
    if (part.name == 'internal:has-not-text') {
      final detected = _detectExact(part.body as String);
      // There is no locator equivalent for strict has-not-text.
      if (detected.exact != true) {
        final options = LocatorOptions();
        if (detected.exact != null) options.exact = detected.exact;
        tokens.add([
          factory.generateLocator(base, 'has-not-text', detected.text, options)
        ]);
        continue;
      }
    }
    if (const [
      'internal:has',
      'internal:has-not',
      'internal:and',
      'internal:or',
      'internal:chain'
    ].contains(part.name)) {
      final kind = const {
        'internal:has': 'has',
        'internal:has-not': 'hasNot',
        'internal:and': 'and',
        'internal:or': 'or',
        'internal:chain': 'chain',
      }[part.name]!;
      final inners = _innerAsLocators(factory,
          (part.body as NestedSelectorBody).parsed, false, maxOutputSize);
      tokens.add([
        for (final inner in inners) factory.generateLocator(base, kind, inner)
      ]);
      continue;
    }
    if (part.name == 'internal:label') {
      final detected = _detectExact(part.body as String);
      final options = LocatorOptions();
      if (detected.exact != null) options.exact = detected.exact;
      tokens.add(
          [factory.generateLocator(base, 'label', detected.text, options)]);
      continue;
    }
    if (part.name == 'internal:role') {
      final attrSelector = parseAttributeSelector(part.body as String, true);
      final options = LocatorOptions();
      options.attrs = <LocatorAttr>[];
      for (final attr in attrSelector.attributes) {
        if (attr.name == 'name') {
          if (options.has('exact') && options.exact != attr.caseSensitive) {
            throw InvalidSelectorError(
                'Conflicting exactness in internal:role selector: '
                '${stringifySelector(ParsedSelector([part]))}');
          }
          options.exact = attr.caseSensitive;
          options.name = attr.value;
        } else if (attr.name == 'description') {
          if (options.has('exact') && options.exact != attr.caseSensitive) {
            throw InvalidSelectorError(
                'Conflicting exactness in internal:role selector: '
                '${stringifySelector(ParsedSelector([part]))}');
          }
          options.exact = attr.caseSensitive;
          options.description = attr.value;
        } else {
          var value = attr.value;
          if (attr.name == 'level' && value is String) value = num.parse(value);
          options.attrs!.add(LocatorAttr(
              attr.name == 'include-hidden' ? 'includeHidden' : attr.name,
              value as Object));
        }
      }
      tokens.add(
          [factory.generateLocator(base, 'role', attrSelector.name, options)]);
      continue;
    }
    if (part.name == 'internal:testid') {
      final attrSelector = parseAttributeSelector(part.body as String, true);
      final value = attrSelector.attributes[0].value!;
      tokens.add([factory.generateLocator(base, 'test-id', value)]);
      continue;
    }
    if (part.name == 'internal:attr') {
      final attrSelector = parseAttributeSelector(part.body as String, true);
      final attr = attrSelector.attributes[0];
      final text = attr.value!;
      final options = LocatorOptions();
      options.exact = attr.caseSensitive;
      for (final kind in const ['placeholder', 'alt', 'title']) {
        if (attr.name == kind) {
          tokens.add([factory.generateLocator(base, kind, text, options)]);
          continue outer;
        }
      }
    }
    if (part.name == 'internal:control' && part.body == 'any-frame') {
      tokens.add([factory.generateLocator(base, 'any-frame', '')]);
      nextBase = 'frame-locator';
      continue;
    }
    if (part.name == 'internal:control' && part.body == 'enter-frame') {
      // Turn the previous tokens from `${selector}` into
      // `${selector}.contentFrame()` and `frameLocator(${selector})`.
      final lastTokens = tokens[tokens.length - 1];
      final lastPart = parts[index - 1];

      final transformed = [
        for (final token in lastTokens)
          factory.chainLocators(
              [token, factory.generateLocator(base, 'frame', '')])
      ];
      if (const ['xpath', 'css'].contains(lastPart.name)) {
        transformed.add(factory.generateLocator(base, 'frame-locator',
            stringifySelector(ParsedSelector([lastPart]))));
        transformed.add(factory.generateLocator(
            base,
            'frame-locator',
            stringifySelector(ParsedSelector([lastPart]),
                forceEngineName: true)));
      }

      lastTokens
        ..clear()
        ..addAll(transformed);
      nextBase = 'frame-locator';
      continue;
    }

    final nextPart = index + 1 < parts.length ? parts[index + 1] : null;

    final selectorPart = stringifySelector(ParsedSelector([part]));
    final locatorPart = factory.generateLocator(base, 'default', selectorPart);

    if (nextPart != null &&
        const ['internal:has-text', 'internal:has-not-text']
            .contains(nextPart.name)) {
      final detected = _detectExact(nextPart.body as String);
      // There is no locator equivalent for strict has-text and has-not-text.
      if (detected.exact != true) {
        final nextOptions = LocatorOptions();
        if (detected.exact != null) nextOptions.exact = detected.exact;
        final nextLocatorPart = factory.generateLocator(
            'locator',
            nextPart.name == 'internal:has-text' ? 'has-text' : 'has-not-text',
            detected.text,
            nextOptions);
        final options = LocatorOptions();
        if (nextPart.name == 'internal:has-text') {
          options.hasText = detected.text;
        } else {
          options.hasNotText = detected.text;
        }
        final combinedPart =
            factory.generateLocator(base, 'default', selectorPart, options);
        // Two options:
        // - locator('div').filter({ hasText: 'foo' })
        // - locator('div', { hasText: 'foo' })
        tokens.add([
          factory.chainLocators([locatorPart, nextLocatorPart]),
          combinedPart,
        ]);
        index++;
        continue;
      }
    }

    // Selectors can be prefixed with an engine name, e.g. xpath=//foo.
    String? locatorPartWithEngine;
    if (const ['xpath', 'css'].contains(part.name)) {
      final forced =
          stringifySelector(ParsedSelector([part]), forceEngineName: true);
      locatorPartWithEngine = factory.generateLocator(base, 'default', forced);
    }

    tokens.add([
      locatorPart,
      if (locatorPartWithEngine != null) locatorPartWithEngine,
    ]);
  }

  return _combineTokens(factory, tokens, maxOutputSize);
}

List<String> _combineTokens(
    LocatorFactory factory, List<List<String>> tokens, int maxOutputSize) {
  final currentTokens = List<String>.filled(tokens.length, '');
  final result = <String>[];

  bool visit(int index) {
    if (index == tokens.length) {
      result.add(factory.chainLocators(currentTokens));
      return result.length < maxOutputSize;
    }
    for (final taken in tokens[index]) {
      currentTokens[index] = taken;
      if (!visit(index + 1)) return false;
    }
    return true;
  }

  visit(0);
  return result;
}

final RegExp _kRegexLiteralRe = RegExp(r'^/(.*)/([igm]*)$');

({bool? exact, Object text}) _detectExact(String text) {
  var exact = false;
  final match = _kRegexLiteralRe.firstMatch(text);
  if (match != null) {
    return (exact: null, text: JsRegExp.fromPattern(match[1]!, match[2]!));
  }
  var value = text;
  if (value.endsWith('"')) {
    value = jsonDecode(value) as String;
    exact = true;
  } else if (value.endsWith('"s')) {
    value = jsonDecode(value.substring(0, value.length - 1)) as String;
    exact = true;
  } else if (value.endsWith('"i')) {
    value = jsonDecode(value.substring(0, value.length - 1)) as String;
    exact = false;
  }
  return (exact: exact, text: value);
}

// --------------------------------------------------------------- JavaScript

/// Renders selectors as `@playwright/test` locators.
class JavaScriptLocatorFactory implements LocatorFactory {
  final Quote? preferredQuote;
  JavaScriptLocatorFactory([this.preferredQuote]);

  @override
  String generateLocator(LocatorBase base, LocatorType kind, Object body,
      [LocatorOptions? options]) {
    final opts = options ?? LocatorOptions();
    switch (kind) {
      case 'default':
        if (opts.has('hasText')) {
          return 'locator(${_quote(body as String)}, '
              '{ hasText: ${_toHasText(opts.hasText!)} })';
        }
        if (opts.has('hasNotText')) {
          return 'locator(${_quote(body as String)}, '
              '{ hasNotText: ${_toHasText(opts.hasNotText!)} })';
        }
        return 'locator(${_quote(body as String)})';
      case 'frame-locator':
        return 'frameLocator(${_quote(body as String)})';
      case 'frame':
        return 'contentFrame()';
      case 'any-frame':
        return 'frameLocator()';
      case 'nth':
        return 'nth($body)';
      case 'first':
        return 'first()';
      case 'last':
        return 'last()';
      case 'visible':
        return 'visible()';
      case 'filter-visible':
        return 'filter({ visible: ${body == 'true' ? 'true' : 'false'} })';
      case 'role':
        final attrs = <String>[];
        if (opts.name is JsRegExp) {
          attrs.add('name: ${_regexToSourceString(opts.name as JsRegExp)}');
        } else if (opts.name is String) {
          attrs.add('name: ${_quote(opts.name as String)}');
        }
        if (opts.description is JsRegExp) {
          attrs.add('description: '
              '${_regexToSourceString(opts.description as JsRegExp)}');
        } else if (opts.description is String) {
          attrs.add('description: ${_quote(opts.description as String)}');
        }
        if (opts.exact == true &&
            (opts.name is String || opts.description is String)) {
          attrs.add('exact: true');
        }
        for (final attr in opts.attrs ?? const <LocatorAttr>[]) {
          attrs.add('${attr.name}: '
              '${attr.value is String ? _quote(attr.value as String) : attr.value}');
        }
        final attrString = attrs.isNotEmpty ? ', { ${attrs.join(', ')} }' : '';
        return 'getByRole(${_quote(body as String)}$attrString)';
      case 'has-text':
        return 'filter({ hasText: ${_toHasText(body)} })';
      case 'has-not-text':
        return 'filter({ hasNotText: ${_toHasText(body)} })';
      case 'has':
        return 'filter({ has: $body })';
      case 'hasNot':
        return 'filter({ hasNot: $body })';
      case 'and':
        return 'and($body)';
      case 'or':
        return 'or($body)';
      case 'chain':
        return 'locator($body)';
      case 'test-id':
        return 'getByTestId(${_toTestIdValue(body)})';
      case 'text':
        return _toCallWithExact('getByText', body, opts.exact == true);
      case 'alt':
        return _toCallWithExact('getByAltText', body, opts.exact == true);
      case 'placeholder':
        return _toCallWithExact('getByPlaceholder', body, opts.exact == true);
      case 'label':
        return _toCallWithExact('getByLabel', body, opts.exact == true);
      case 'title':
        return _toCallWithExact('getByTitle', body, opts.exact == true);
      default:
        throw ArgumentError('Unknown selector kind $kind');
    }
  }

  @override
  String chainLocators(List<String> locators) => locators.join('.');

  String _regexToSourceString(JsRegExp re) =>
      normalizeEscapedRegexQuotes(re.toString());

  String _toCallWithExact(String method, Object body, bool exact) {
    if (body is JsRegExp) return '$method(${_regexToSourceString(body)})';
    return exact
        ? '$method(${_quote(body as String)}, { exact: true })'
        : '$method(${_quote(body as String)})';
  }

  String _toHasText(Object body) {
    if (body is JsRegExp) return _regexToSourceString(body);
    return _quote(body as String);
  }

  String _toTestIdValue(Object value) {
    if (value is JsRegExp) return _regexToSourceString(value);
    return _quote(value as String);
  }

  String _quote(String text) => escapeWithQuotes(text, preferredQuote ?? "'");
}

// ------------------------------------------------------------------- Python

/// Renders selectors as `playwright-python` locators.
class PythonLocatorFactory implements LocatorFactory {
  PythonLocatorFactory([Quote? preferredQuote]);

  @override
  String generateLocator(LocatorBase base, LocatorType kind, Object body,
      [LocatorOptions? options]) {
    final opts = options ?? LocatorOptions();
    switch (kind) {
      case 'default':
        if (opts.has('hasText')) {
          return 'locator(${_quote(body as String)}, '
              'has_text=${_toHasText(opts.hasText!)})';
        }
        if (opts.has('hasNotText')) {
          return 'locator(${_quote(body as String)}, '
              'has_not_text=${_toHasText(opts.hasNotText!)})';
        }
        return 'locator(${_quote(body as String)})';
      case 'frame-locator':
        return 'frame_locator(${_quote(body as String)})';
      case 'frame':
        return 'content_frame';
      case 'any-frame':
        return 'frame_locator()';
      case 'nth':
        return 'nth($body)';
      case 'first':
        return 'first';
      case 'last':
        return 'last';
      case 'visible':
        return 'visible';
      case 'filter-visible':
        return 'filter(visible=${body == 'true' ? 'True' : 'False'})';
      case 'role':
        final attrs = <String>[];
        if (opts.name is JsRegExp) {
          attrs.add('name=${_regexToString(opts.name as JsRegExp)}');
        } else if (opts.name is String) {
          attrs.add('name=${_quote(opts.name as String)}');
        }
        if (opts.description is JsRegExp) {
          attrs.add(
              'description=${_regexToString(opts.description as JsRegExp)}');
        } else if (opts.description is String) {
          attrs.add('description=${_quote(opts.description as String)}');
        }
        if (opts.exact == true &&
            (opts.name is String || opts.description is String)) {
          attrs.add('exact=True');
        }
        for (final attr in opts.attrs ?? const <LocatorAttr>[]) {
          final value = attr.value;
          final String valueString;
          if (value is bool) {
            valueString = value ? 'True' : 'False';
          } else if (value is String) {
            valueString = _quote(value);
          } else {
            valueString = '$value';
          }
          attrs.add('${toSnakeCase(attr.name)}=$valueString');
        }
        final attrString = attrs.isNotEmpty ? ', ${attrs.join(', ')}' : '';
        return 'get_by_role(${_quote(body as String)}$attrString)';
      case 'has-text':
        return 'filter(has_text=${_toHasText(body)})';
      case 'has-not-text':
        return 'filter(has_not_text=${_toHasText(body)})';
      case 'has':
        return 'filter(has=$body)';
      case 'hasNot':
        return 'filter(has_not=$body)';
      case 'and':
        return 'and_($body)';
      case 'or':
        return 'or_($body)';
      case 'chain':
        return 'locator($body)';
      case 'test-id':
        return 'get_by_test_id(${_toTestIdValue(body)})';
      case 'text':
        return _toCallWithExact('get_by_text', body, opts.exact == true);
      case 'alt':
        return _toCallWithExact('get_by_alt_text', body, opts.exact == true);
      case 'placeholder':
        return _toCallWithExact('get_by_placeholder', body, opts.exact == true);
      case 'label':
        return _toCallWithExact('get_by_label', body, opts.exact == true);
      case 'title':
        return _toCallWithExact('get_by_title', body, opts.exact == true);
      default:
        throw ArgumentError('Unknown selector kind $kind');
    }
  }

  @override
  String chainLocators(List<String> locators) => locators.join('.');

  String _regexToString(JsRegExp body) {
    final suffix = body.ignoreCase ? ', re.IGNORECASE' : '';
    final source = normalizeEscapedRegexQuotes(body.source)
        .replaceFirst(r'\/', '/')
        .replaceAll('"', r'\"');
    return 're.compile(r"$source"$suffix)';
  }

  String _toCallWithExact(String method, Object body, bool exact) {
    if (body is JsRegExp) return '$method(${_regexToString(body)})';
    if (exact) return '$method(${_quote(body as String)}, exact=True)';
    return '$method(${_quote(body as String)})';
  }

  String _toHasText(Object body) {
    if (body is JsRegExp) return _regexToString(body);
    return _quote(body as String);
  }

  String _toTestIdValue(Object value) {
    if (value is JsRegExp) return _regexToString(value);
    return _quote(value as String);
  }

  String _quote(String text) => escapeWithQuotes(text, '"');
}

// --------------------------------------------------------------------- Java

/// Renders selectors as `playwright-java` locators.
class JavaLocatorFactory implements LocatorFactory {
  JavaLocatorFactory([Quote? preferredQuote]);

  @override
  String generateLocator(LocatorBase base, LocatorType kind, Object body,
      [LocatorOptions? options]) {
    final opts = options ?? LocatorOptions();
    final String clazz;
    switch (base) {
      case 'page':
        clazz = 'Page';
        break;
      case 'frame-locator':
        clazz = 'FrameLocator';
        break;
      default:
        clazz = 'Locator';
        break;
    }
    switch (kind) {
      case 'default':
        if (opts.has('hasText')) {
          return 'locator(${_quote(body as String)}, new $clazz'
              '.LocatorOptions().setHasText(${_toHasText(opts.hasText!)}))';
        }
        if (opts.has('hasNotText')) {
          return 'locator(${_quote(body as String)}, new $clazz'
              '.LocatorOptions().setHasNotText('
              '${_toHasText(opts.hasNotText!)}))';
        }
        return 'locator(${_quote(body as String)})';
      case 'frame-locator':
        return 'frameLocator(${_quote(body as String)})';
      case 'frame':
        return 'contentFrame()';
      case 'any-frame':
        return 'frameLocator()';
      case 'nth':
        return 'nth($body)';
      case 'first':
        return 'first()';
      case 'last':
        return 'last()';
      case 'visible':
        return 'visible()';
      case 'filter-visible':
        return 'filter(new $clazz.FilterOptions().setVisible('
            '${body == 'true' ? 'true' : 'false'}))';
      case 'role':
        final attrs = <String>[];
        if (opts.name is JsRegExp) {
          attrs.add('.setName(${_regexToString(opts.name as JsRegExp)})');
        } else if (opts.name is String) {
          attrs.add('.setName(${_quote(opts.name as String)})');
        }
        if (opts.description is JsRegExp) {
          attrs.add(
              '.setDescription(${_regexToString(opts.description as JsRegExp)})');
        } else if (opts.description is String) {
          attrs.add('.setDescription(${_quote(opts.description as String)})');
        }
        if (opts.exact == true &&
            (opts.name is String || opts.description is String)) {
          attrs.add('.setExact(true)');
        }
        for (final attr in opts.attrs ?? const <LocatorAttr>[]) {
          attrs.add('.set${toTitleCase(attr.name)}('
              '${attr.value is String ? _quote(attr.value as String) : attr.value})');
        }
        final attrString = attrs.isNotEmpty
            ? ', new $clazz.GetByRoleOptions()${attrs.join('')}'
            : '';
        return 'getByRole(AriaRole.'
            '${toSnakeCase(body as String).toUpperCase()}$attrString)';
      case 'has-text':
        return 'filter(new $clazz.FilterOptions().setHasText('
            '${_toHasText(body)}))';
      case 'has-not-text':
        return 'filter(new $clazz.FilterOptions().setHasNotText('
            '${_toHasText(body)}))';
      case 'has':
        return 'filter(new $clazz.FilterOptions().setHas($body))';
      case 'hasNot':
        return 'filter(new $clazz.FilterOptions().setHasNot($body))';
      case 'and':
        return 'and($body)';
      case 'or':
        return 'or($body)';
      case 'chain':
        return 'locator($body)';
      case 'test-id':
        return 'getByTestId(${_toTestIdValue(body)})';
      case 'text':
        return _toCallWithExact(clazz, 'getByText', body, opts.exact == true);
      case 'alt':
        return _toCallWithExact(
            clazz, 'getByAltText', body, opts.exact == true);
      case 'placeholder':
        return _toCallWithExact(
            clazz, 'getByPlaceholder', body, opts.exact == true);
      case 'label':
        return _toCallWithExact(clazz, 'getByLabel', body, opts.exact == true);
      case 'title':
        return _toCallWithExact(clazz, 'getByTitle', body, opts.exact == true);
      default:
        throw ArgumentError('Unknown selector kind $kind');
    }
  }

  @override
  String chainLocators(List<String> locators) => locators.join('.');

  String _regexToString(JsRegExp body) {
    final suffix = body.ignoreCase ? ', Pattern.CASE_INSENSITIVE' : '';
    return 'Pattern.compile('
        '${_quote(normalizeEscapedRegexQuotes(body.source))}$suffix)';
  }

  String _toCallWithExact(
      String clazz, String method, Object body, bool exact) {
    if (body is JsRegExp) return '$method(${_regexToString(body)})';
    if (exact) {
      return '$method(${_quote(body as String)}, new $clazz'
          '.${toTitleCase(method)}Options().setExact(true))';
    }
    return '$method(${_quote(body as String)})';
  }

  String _toHasText(Object body) {
    if (body is JsRegExp) return _regexToString(body);
    return _quote(body as String);
  }

  String _toTestIdValue(Object value) {
    if (value is JsRegExp) return _regexToString(value);
    return _quote(value as String);
  }

  String _quote(String text) => escapeWithQuotes(text, '"');
}

// ----------------------------------------------------------------------- C#

/// Renders selectors as `Microsoft.Playwright` locators.
class CSharpLocatorFactory implements LocatorFactory {
  CSharpLocatorFactory([Quote? preferredQuote]);

  @override
  String generateLocator(LocatorBase base, LocatorType kind, Object body,
      [LocatorOptions? options]) {
    final opts = options ?? LocatorOptions();
    switch (kind) {
      case 'default':
        if (opts.has('hasText')) {
          return 'Locator(${_quote(body as String)}, new() { '
              '${_toHasText(opts.hasText!)} })';
        }
        if (opts.has('hasNotText')) {
          return 'Locator(${_quote(body as String)}, new() { '
              '${_toHasNotText(opts.hasNotText!)} })';
        }
        return 'Locator(${_quote(body as String)})';
      case 'frame-locator':
        return 'FrameLocator(${_quote(body as String)})';
      case 'frame':
        return 'ContentFrame';
      case 'any-frame':
        return 'FrameLocator()';
      case 'nth':
        return 'Nth($body)';
      case 'first':
        return 'First';
      case 'last':
        return 'Last';
      case 'visible':
        return 'Visible';
      case 'filter-visible':
        return 'Filter(new() { Visible = '
            '${body == 'true' ? 'true' : 'false'} })';
      case 'role':
        final attrs = <String>[];
        if (opts.name is JsRegExp) {
          attrs.add('NameRegex = ${_regexToString(opts.name as JsRegExp)}');
        } else if (opts.name is String) {
          attrs.add('Name = ${_quote(opts.name as String)}');
        }
        if (opts.description is JsRegExp) {
          attrs.add('DescriptionRegex = '
              '${_regexToString(opts.description as JsRegExp)}');
        } else if (opts.description is String) {
          attrs.add('Description = ${_quote(opts.description as String)}');
        }
        if (opts.exact == true &&
            (opts.name is String || opts.description is String)) {
          attrs.add('Exact = true');
        }
        for (final attr in opts.attrs ?? const <LocatorAttr>[]) {
          attrs.add('${toTitleCase(attr.name)} = '
              '${attr.value is String ? _quote(attr.value as String) : attr.value}');
        }
        final attrString =
            attrs.isNotEmpty ? ', new() { ${attrs.join(', ')} }' : '';
        return 'GetByRole(AriaRole.${toTitleCase(body as String)}$attrString)';
      case 'has-text':
        return 'Filter(new() { ${_toHasText(body)} })';
      case 'has-not-text':
        return 'Filter(new() { ${_toHasNotText(body)} })';
      case 'has':
        return 'Filter(new() { Has = $body })';
      case 'hasNot':
        return 'Filter(new() { HasNot = $body })';
      case 'and':
        return 'And($body)';
      case 'or':
        return 'Or($body)';
      case 'chain':
        return 'Locator($body)';
      case 'test-id':
        return 'GetByTestId(${_toTestIdValue(body)})';
      case 'text':
        return _toCallWithExact('GetByText', body, opts.exact == true);
      case 'alt':
        return _toCallWithExact('GetByAltText', body, opts.exact == true);
      case 'placeholder':
        return _toCallWithExact('GetByPlaceholder', body, opts.exact == true);
      case 'label':
        return _toCallWithExact('GetByLabel', body, opts.exact == true);
      case 'title':
        return _toCallWithExact('GetByTitle', body, opts.exact == true);
      default:
        throw ArgumentError('Unknown selector kind $kind');
    }
  }

  @override
  String chainLocators(List<String> locators) => locators.join('.');

  String _regexToString(JsRegExp body) {
    final suffix = body.ignoreCase ? ', RegexOptions.IgnoreCase' : '';
    return 'new Regex('
        '${_quote(normalizeEscapedRegexQuotes(body.source))}$suffix)';
  }

  String _toCallWithExact(String method, Object body, bool exact) {
    if (body is JsRegExp) return '$method(${_regexToString(body)})';
    if (exact) {
      return '$method(${_quote(body as String)}, new() { Exact = true })';
    }
    return '$method(${_quote(body as String)})';
  }

  String _toHasText(Object body) {
    if (body is JsRegExp) return 'HasTextRegex = ${_regexToString(body)}';
    return 'HasText = ${_quote(body as String)}';
  }

  String _toHasNotText(Object body) {
    if (body is JsRegExp) return 'HasNotTextRegex = ${_regexToString(body)}';
    return 'HasNotText = ${_quote(body as String)}';
  }

  String _toTestIdValue(Object value) {
    if (value is JsRegExp) return _regexToString(value);
    return _quote(value as String);
  }

  String _quote(String text) => escapeWithQuotes(text, '"');
}

// -------------------------------------------------------------------- JSONL

/// Renders selectors as the machine readable JSON the recorder protocol uses.
class JsonlLocatorFactory implements LocatorFactory {
  JsonlLocatorFactory([Quote? preferredQuote]);

  @override
  String generateLocator(LocatorBase base, LocatorType kind, Object body,
      [LocatorOptions? options]) {
    final opts = options ?? LocatorOptions();
    return jsonEncode({
      'kind': kind,
      'body': _jsonValue(body),
      'options': {
        for (final entry in opts.fields.entries)
          if (entry.value != null) entry.key: _jsonValue(entry.value!),
      },
    });
  }

  @override
  String chainLocators(List<String> locators) {
    final objects = [
      for (final l in locators) jsonDecode(l) as Map<String, dynamic>
    ];
    for (var i = 0; i < objects.length - 1; ++i) {
      // A locator may already be a chain, e.g. contentFrame() produces one.
      // Append to its tail.
      var tail = objects[i];
      while (tail['next'] != null) {
        tail = tail['next'] as Map<String, dynamic>;
      }
      tail['next'] = objects[i + 1];
    }
    return jsonEncode(objects[0]);
  }

  static Object? _jsonValue(Object value) {
    // JSON.stringify turns a RegExp into an empty object; mirror that.
    if (value is JsRegExp) return <String, Object?>{};
    if (value is List<LocatorAttr>) {
      return [
        for (final attr in value)
          {'name': attr.name, 'value': _jsonValue(attr.value)}
      ];
    }
    return value;
  }
}

// --------------------------------------------------------------------- Dart

/// Renders selectors as locators of this port's `package:playwright`.
///
/// This factory has no upstream counterpart: Playwright ships no Dart
/// binding, so the shapes here follow this port's own [Locator] API. Three
/// calls differ from the other languages on purpose:
///
/// * `first` and `last` are getters, so they render without parentheses.
/// * A nested locator argument — `has`, `hasNot`, `and` — is prefixed with
///   `page.`, because Dart has no bare `locator()` function the way the other
///   bindings' fluent chains imply one. Generated code has a `page` in scope.
/// * `any-frame` and `chain` have no equivalent in this port and throw, which
///   makes `asLocator` fall back to the raw selector.
class DartLocatorFactory implements LocatorFactory {
  DartLocatorFactory([Quote? preferredQuote]);

  @override
  String generateLocator(LocatorBase base, LocatorType kind, Object body,
      [LocatorOptions? options]) {
    final opts = options ?? LocatorOptions();
    switch (kind) {
      case 'default':
        if (opts.has('hasText')) {
          return 'locator(${_quote(body as String)}, '
              'hasText: ${_toHasText(opts.hasText!)})';
        }
        if (opts.has('hasNotText')) {
          return 'locator(${_quote(body as String)}, '
              'hasNotText: ${_toHasText(opts.hasNotText!)})';
        }
        return 'locator(${_quote(body as String)})';
      case 'frame-locator':
        return 'frameLocator(${_quote(body as String)})';
      case 'frame':
        return 'contentFrame()';
      case 'nth':
        return 'nth($body)';
      case 'first':
        return 'first';
      case 'last':
        return 'last';
      case 'visible':
        return 'visible()';
      case 'filter-visible':
        return body == 'true' ? 'visible()' : 'visible(value: false)';
      case 'role':
        final attrs = <String>[];
        if (opts.name is JsRegExp) {
          attrs.add('name: ${dartRegExpLiteral(opts.name as JsRegExp)}');
        } else if (opts.name is String) {
          attrs.add('name: ${_quote(opts.name as String)}');
        }
        if (opts.description is JsRegExp) {
          attrs.add('description: '
              '${dartRegExpLiteral(opts.description as JsRegExp)}');
        } else if (opts.description is String) {
          attrs.add('description: ${_quote(opts.description as String)}');
        }
        if (opts.exact == true &&
            (opts.name is String || opts.description is String)) {
          attrs.add('exact: true');
        }
        for (final attr in opts.attrs ?? const <LocatorAttr>[]) {
          attrs.add('${attr.name}: '
              '${attr.value is String ? _quote(attr.value as String) : attr.value}');
        }
        final attrString = attrs.isNotEmpty ? ', ${attrs.join(', ')}' : '';
        return 'getByRole(${_quote(body as String)}$attrString)';
      case 'has-text':
        return 'filter(hasText: ${_toHasText(body)})';
      case 'has-not-text':
        return 'filter(hasNotText: ${_toHasText(body)})';
      case 'has':
        return 'filter(has: page.$body)';
      case 'hasNot':
        return 'filter(hasNot: page.$body)';
      case 'and':
        return 'and(page.$body)';
      case 'or':
        return 'or(page.$body)';
      case 'test-id':
        return 'getByTestId(${_toTestIdValue(body)})';
      case 'text':
        return _toCallWithExact('getByText', body, opts.exact == true);
      case 'alt':
        return _toCallWithExact('getByAltText', body, opts.exact == true);
      case 'placeholder':
        return _toCallWithExact('getByPlaceholder', body, opts.exact == true);
      case 'label':
        return _toCallWithExact('getByLabel', body, opts.exact == true);
      case 'title':
        return _toCallWithExact('getByTitle', body, opts.exact == true);
      default:
        // 'any-frame' and 'chain' land here: this port has neither a
        // selectorless frameLocator() nor locator(Locator).
        throw ArgumentError('Unknown selector kind $kind');
    }
  }

  @override
  String chainLocators(List<String> locators) => locators.join('.');

  String _toCallWithExact(String method, Object body, bool exact) {
    if (body is JsRegExp) return '$method(${dartRegExpLiteral(body)})';
    return exact
        ? '$method(${_quote(body as String)}, exact: true)'
        : '$method(${_quote(body as String)})';
  }

  String _toHasText(Object body) {
    if (body is JsRegExp) return dartRegExpLiteral(body);
    return _quote(body as String);
  }

  String _toTestIdValue(Object value) {
    if (value is JsRegExp) return dartRegExpLiteral(value);
    return _quote(value as String);
  }

  String _quote(String text) => dartStringLiteral(text);
}

/// Quotes [text] as a single quoted Dart string literal.
///
/// On top of the JavaScript escaping, `$` has to be escaped too, because Dart
/// interpolates it.
String dartStringLiteral(String text) {
  final stringified = jsonEncode(text);
  final body = stringified
      .substring(1, stringified.length - 1)
      .replaceAll(r'\"', '"')
      .replaceAll(r'$', r'\$')
      .replaceAll("'", r"\'");
  return "'$body'";
}

/// Renders [re] as a Dart `RegExp(...)` expression.
///
/// Dart has no regex literal, and it spells the JavaScript flags as named
/// arguments; `g` and `y` have no equivalent and are dropped, as they are
/// meaningless for the matching a locator does. The `\/` that a JavaScript
/// regex source carries is unescaped, the way the Python generator does it:
/// outside a literal there is no slash to escape.
String dartRegExpLiteral(JsRegExp re) {
  final source = normalizeEscapedRegexQuotes(re.source).replaceAll(r'\/', '/');
  final args = <String>[dartStringLiteral(source)];
  if (re.ignoreCase) args.add('caseSensitive: false');
  if (re.multiline) args.add('multiLine: true');
  if (re.dotAll) args.add('dotAll: true');
  if (re.unicode) args.add('unicode: true');
  return 'RegExp(${args.join(', ')})';
}

LocatorFactory _createFactory(Language lang, [Quote? preferredQuote]) {
  switch (lang) {
    case Languages.javascript:
      return JavaScriptLocatorFactory(preferredQuote);
    case Languages.python:
      return PythonLocatorFactory(preferredQuote);
    case Languages.java:
      return JavaLocatorFactory(preferredQuote);
    case Languages.csharp:
      return CSharpLocatorFactory(preferredQuote);
    case Languages.jsonl:
      return JsonlLocatorFactory(preferredQuote);
    case Languages.dart:
      return DartLocatorFactory(preferredQuote);
    default:
      throw ArgumentError('Unknown language $lang');
  }
}

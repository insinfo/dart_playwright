// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/locatorParser.ts

import 'dart:convert';

import 'js_regexp.dart';
import 'locator_generators.dart';
import 'locator_utils.dart';
import 'selector_parser.dart';
import 'string_utils.dart';

class _TemplateParam {
  final String quote;
  final String text;
  _TemplateParam(this.quote, this.text);
}

class _ParsedLocator {
  final String selector;
  final Quote? preferredQuote;
  _ParsedLocator(this.selector, this.preferredQuote);
}

final RegExp _kAriaRoleRe = RegExp(r'AriaRole\s*\.\s*(\w+)');
final RegExp _kGetByRoleRe =
    RegExp('(get_by_role|getByRole)\\s*\\(\\s*(?:["\'`])([^\'"`]+)[\'"`]');

_ParsedLocator _parseLocator(String locatorInput, String testIdAttributeName) {
  var locator = locatorInput
      .replaceAllMapped(_kAriaRoleRe, (m) => m[1]!.toLowerCase())
      .replaceAllMapped(_kGetByRoleRe, (m) => '${m[1]}(${m[2]!.toLowerCase()}');
  var params = <_TemplateParam>[];
  var template = '';
  for (var i = 0; i < locator.length; ++i) {
    final quote = locator[i];
    if (quote != '"' && quote != "'" && quote != '`' && quote != '/') {
      template += quote;
      continue;
    }
    final isRegexEscaping =
        (i > 0 && locator[i - 1] == 'r') || locator[i] == '/';
    ++i;
    var text = '';
    while (i < locator.length) {
      if (locator[i] == r'\') {
        if (isRegexEscaping) {
          if (i + 1 >= locator.length || locator[i + 1] != quote) {
            text += locator[i];
          }
          ++i;
          if (i < locator.length) text += locator[i];
        } else {
          ++i;
          if (i < locator.length) {
            if (locator[i] == 'n') {
              text += '\n';
            } else if (locator[i] == 'r') {
              text += '\r';
            } else if (locator[i] == 't') {
              text += '\t';
            } else {
              text += locator[i];
            }
          }
        }
        ++i;
        continue;
      }
      if (locator[i] != quote) {
        text += locator[i++];
        continue;
      }
      break;
    }
    params.add(_TemplateParam(quote, text));
    template += '${quote == '/' ? 'r' : ''}\$${params.length}';
  }

  // Equalize the languages.
  template = template
      .toLowerCase()
      .replaceAll('get_by_alt_text', 'getbyalttext')
      .replaceAll('get_by_test_id', 'getbytestid')
      .replaceAllMapped(RegExp(r'get_by_(\w+)'), (m) => 'getby${m[1]}')
      .replaceAll('has_not_text', 'hasnottext')
      .replaceAll('has_text', 'hastext')
      .replaceAll('has_not', 'hasnot')
      .replaceAll('frame_locator', 'framelocator')
      .replaceAll('content_frame', 'contentframe')
      .replaceAll(RegExp(r'[{}\s]'), '')
      .replaceAll('new()', '')
      .replaceAll(RegExp(r'new\w+\.\w+options\(\)'), '')
      .replaceAll('.set', ',set')
      // Python has "or_" instead of "or".
      .replaceAll('.or_(', 'or(')
      // Python has "and_" instead of "and".
      .replaceAll('.and_(', 'and(')
      .replaceAll(':', '=')
      .replaceAll(',re.ignorecase', 'i')
      .replaceAll(',pattern.case_insensitive', 'i')
      .replaceAll(',regexoptions.ignorecase', 'i')
      // Python has regex strings as r"foo".
      .replaceAllMapped(RegExp(r're.compile\(([^)]+)\)'), (m) => m[1]!)
      .replaceAllMapped(
          RegExp(r'pattern.compile\(([^)]+)\)'), (m) => 'r${m[1]}')
      .replaceAllMapped(RegExp(r'newregex\(([^)]+)\)'), (m) => 'r${m[1]}')
      .replaceAll('string=', '=')
      .replaceAll('regex=', '=')
      .replaceAll(',,', ',')
      .replaceAll(',)', ')');

  Quote? preferredQuote;
  for (final p in params) {
    if ("'\"`".contains(p.quote)) {
      preferredQuote = p.quote;
      break;
    }
  }
  return _ParsedLocator(
      _transform(template, params, testIdAttributeName), preferredQuote);
}

int _countParams(String template) =>
    RegExp(r'\$\d+').allMatches(template).length;

String _shiftParams(String template, int sub) => template.replaceAllMapped(
    RegExp(r'\$(\d+)'), (m) => '\$${int.parse(m[1]!) - sub}');

final RegExp _kHasRe = RegExp(r'filter\(,?(has=|hasnot=|sethas\(|sethasnot\()');

String _transform(String templateInput, List<_TemplateParam> paramsInput,
    String testIdAttributeName) {
  var template = templateInput;
  var params = paramsInput;

  // Recursively handle filter(has=, hasnot=, sethas(), sethasnot()).
  while (true) {
    final hasMatch = _kHasRe.firstMatch(template);
    if (hasMatch == null) break;

    // Extract the inner locator by balancing parentheses.
    final start = hasMatch.start + hasMatch[0]!.length;
    var balance = 0;
    var end = start;
    for (; end < template.length; end++) {
      if (template[end] == '(') {
        balance++;
      } else if (template[end] == ')') {
        balance--;
      }
      if (balance < 0) break;
    }

    // Replace Java sethas(...) and sethasnot(...) with has=... and hasnot=...
    var prefix = template.substring(0, start);
    var extraSymbol = 0;
    if (hasMatch[1] == 'sethas(' || hasMatch[1] == 'sethasnot(') {
      // Eat the extra ")" at the end of sethas(...).
      extraSymbol = 1;
      prefix = prefix
          .replaceAll(RegExp(r'sethas\($'), 'has=')
          .replaceAll(RegExp(r'sethasnot\($'), 'hasnot=');
    }

    final paramsCountBeforeHas = _countParams(template.substring(0, start));
    final hasTemplate =
        _shiftParams(template.substring(start, end), paramsCountBeforeHas);
    final paramsCountInHas = _countParams(hasTemplate);
    final hasParams = params.sublist(
        paramsCountBeforeHas, paramsCountBeforeHas + paramsCountInHas);
    final hasSelector =
        jsonEncode(_transform(hasTemplate, hasParams, testIdAttributeName));

    // Replace filter(has=...) with filter(has2=$5); "has2" keeps the same
    // filter from matching again.
    template = prefix.replaceAll(RegExp(r'=$'), '2=') +
        '\$${paramsCountBeforeHas + 1}' +
        _shiftParams(
            template.substring(end + extraSymbol), paramsCountInHas - 1);

    // Replace the inner params with the $5 value.
    final paramsBeforeHas = params.sublist(0, paramsCountBeforeHas);
    final paramsAfterHas =
        params.sublist(paramsCountBeforeHas + paramsCountInHas);
    params = [
      ...paramsBeforeHas,
      _TemplateParam('"', hasSelector),
      ...paramsAfterHas,
    ];
  }

  // Transform to the selector engines.
  template = template
      .replaceAllMapped(RegExp(r',set(\w+)\(([^)]+)\)'),
          (m) => ',${m[1]!.toLowerCase()}=${m[2]!.toLowerCase()}')
      .replaceAll('framelocator()', 'internal:control=any-frame')
      .replaceAllMapped(RegExp(r'framelocator\(([^)]+)\)'),
          (m) => '${m[1]}.internal:control=enter-frame')
      .replaceAllMapped(
          RegExp(r'contentframe(\(\))?'), (_) => 'internal:control=enter-frame')
      .replaceAllMapped(RegExp(r'locator\(([^)]+),hastext=([^),]+)\)'),
          (m) => 'locator(${m[1]}).internal:has-text=${m[2]}')
      .replaceAllMapped(RegExp(r'locator\(([^)]+),hasnottext=([^),]+)\)'),
          (m) => 'locator(${m[1]}).internal:has-not-text=${m[2]}')
      .replaceAllMapped(RegExp(r'locator\(([^)]+),hastext=([^),]+)\)'),
          (m) => 'locator(${m[1]}).internal:has-text=${m[2]}')
      .replaceAllMapped(RegExp(r'locator\(([^)]+)\)'), (m) => m[1]!)
      .replaceAllMapped(
          RegExp(r'getbyrole\(([^)]+)\)'), (m) => 'internal:role=${m[1]}')
      .replaceAllMapped(
          RegExp(r'getbytext\(([^)]+)\)'), (m) => 'internal:text=${m[1]}')
      .replaceAllMapped(
          RegExp(r'getbylabel\(([^)]+)\)'), (m) => 'internal:label=${m[1]}')
      .replaceAllMapped(
          RegExp(r'getbytestid\(([^)]+)\)'),
          (m) => 'internal:testid=['
              '${encodeTestIdAttributeName(testIdAttributeName)}=${m[1]}]')
      .replaceAllMapped(
          RegExp(r'getby(placeholder|alt|title)(?:text)?\(([^)]+)\)'),
          (m) => 'internal:attr=[${m[1]}=${m[2]}]')
      .replaceAllMapped(RegExp(r'first(\(\))?'), (_) => 'nth=0')
      .replaceAllMapped(RegExp(r'last(\(\))?'), (_) => 'nth=-1')
      .replaceAllMapped(RegExp(r'nth\(([^)]+)\)'), (m) => 'nth=${m[1]}')
      .replaceAll(RegExp(r'filter\(,?visible=true\)'), 'visible=true')
      .replaceAll(RegExp(r'filter\(,?visible=false\)'), 'visible=false')
      .replaceAllMapped(
          RegExp(r'\.visible(\(\))?(?!=)'), (_) => '.visible=true')
      .replaceAllMapped(RegExp(r'filter\(,?hastext=([^)]+)\)'),
          (m) => 'internal:has-text=${m[1]}')
      .replaceAllMapped(RegExp(r'filter\(,?hasnottext=([^)]+)\)'),
          (m) => 'internal:has-not-text=${m[1]}')
      .replaceAllMapped(
          RegExp(r'filter\(,?has2=([^)]+)\)'), (m) => 'internal:has=${m[1]}')
      .replaceAllMapped(RegExp(r'filter\(,?hasnot2=([^)]+)\)'),
          (m) => 'internal:has-not=${m[1]}')
      .replaceAll(',exact=false', '')
      // exact=true is shared between name and description, so applying it to
      // both needs a special case.
      .replaceAllMapped(RegExp(r'(,name=\$\d+)(,description=\$\d+),exact=true'),
          (m) => '${m[1]}s${m[2]}s')
      .replaceAll(',exact=true', 's')
      .replaceAll(',includehidden=', ',include-hidden=')
      .replaceAll(',', '][');

  final parts = template.split('.');
  // Turn "internal:control=enter-frame >> nth=0" into
  // "nth=0 >> internal:control=enter-frame", because these are swapped in
  // locators against selectors.
  for (var index = 0; index < parts.length - 1; index++) {
    if (parts[index] == 'internal:control=enter-frame' &&
        parts[index + 1].startsWith('nth=')) {
      final nth = parts.removeAt(index);
      parts.insert(index + 1, nth);
    }
  }

  final substituted = <String>[];
  for (var t in parts) {
    if (!t.startsWith('internal:') || t == 'internal:control') {
      substituted.add(t.replaceAllMapped(
          RegExp(r'\$(\d+)'), (m) => params[int.parse(m[1]!) - 1].text));
      continue;
    }
    t = t.contains('[') ? '${t.replaceFirst(']', '')}]' : t;
    final prefix = t;
    t = t.replaceAllMapped(RegExp(r'(?:r)\$(\d+)(i)?'), (m) {
      final param = params[int.parse(m[1]!) - 1];
      final suffix = m[2];
      if (prefix.startsWith('internal:attr') ||
          prefix.startsWith('internal:testid') ||
          prefix.startsWith('internal:role')) {
        return escapeForAttributeSelector(
                JsRegExp.fromPattern(param.text), false) +
            (suffix ?? '');
      }
      return escapeForTextSelector(
          JsRegExp.fromPattern(param.text, suffix ?? ''), false);
    }).replaceAllMapped(RegExp(r'\$(\d+)(i|s)?'), (m) {
      final param = params[int.parse(m[1]!) - 1];
      final suffix = m[2];
      if (prefix.startsWith('internal:has=') ||
          prefix.startsWith('internal:has-not=')) {
        return param.text;
      }
      if (prefix.startsWith('internal:testid')) {
        return escapeForAttributeSelector(param.text, true);
      }
      if (prefix.startsWith('internal:attr') ||
          prefix.startsWith('internal:role')) {
        return escapeForAttributeSelector(param.text, suffix == 's');
      }
      return escapeForTextSelector(param.text, suffix == 's');
    });
    substituted.add(t);
  }
  return substituted.join(' >> ');
}

/// Turns a locator expression written in [language] back into a selector.
///
/// Returns an empty string when [locator] is neither a selector nor a locator
/// that renders back to itself. This is what the recorder's "pick locator"
/// box and the trace viewer's locator field call on every keystroke.
String locatorOrSelectorAsSelector(Language language, String locator,
    [String testIdAttributeName = 'data-testid']) {
  try {
    return unsafeLocatorOrSelectorAsSelector(
        language, locator, testIdAttributeName);
  } catch (_) {
    return '';
  }
}

/// [locatorOrSelectorAsSelector] without the catch-all.
String unsafeLocatorOrSelectorAsSelector(Language language, String locator,
    [String testIdAttributeName = 'data-testid']) {
  try {
    parseSelector(locator);
    return locator;
  } catch (_) {
    // Not a selector, so it should be a locator expression.
  }
  final parsed = _parseLocator(locator, testIdAttributeName);
  final locators =
      asLocators(language, parsed.selector, false, 20, parsed.preferredQuote);
  final digest = _digestForComparison(language, locator);
  for (final candidate in locators) {
    if (_digestForComparison(language, candidate) == digest) {
      return parsed.selector;
    }
  }
  return '';
}

String _digestForComparison(Language language, String locatorInput) {
  var locator = locatorInput.replaceAll(RegExp(r'\s'), '');
  if (language == Languages.javascript) {
    locator =
        locator.replaceAll(RegExp(r'''\\?["`]'''), "'").replaceAll(',{}', '');
  }
  return locator;
}

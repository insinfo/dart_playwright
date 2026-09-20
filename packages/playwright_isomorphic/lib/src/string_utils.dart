// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/stringUtils.ts

import 'dart:convert';

import 'js_regexp.dart';

/// Wraps [text] in [char], escaping it the way a JavaScript string literal
/// would.
///
/// Note: this must not be used to escape selectors; those have their own
/// escaping, in [escapeForTextSelector] and [escapeForAttributeSelector].
String escapeWithQuotes(String text, [String char = "'"]) {
  final stringified = jsonEncode(text);
  final escapedText =
      stringified.substring(1, stringified.length - 1).replaceAll(r'\"', '"');
  if (char == "'") return char + escapedText.replaceAll("'", r"\'") + char;
  if (char == '"') return char + escapedText.replaceAll('"', r'\"') + char;
  if (char == '`') return char + escapedText.replaceAll('`', r'\`') + char;
  throw ArgumentError.value(char, 'char', 'Invalid escape char');
}

/// Escapes [text] so it can sit inside a JavaScript template literal.
String escapeTemplateString(String text) => text
    .replaceAll(r'\', r'\\')
    .replaceAll('`', r'\`')
    .replaceAll(r'${', r'\${');

/// `foo` becomes `Foo`.
String toTitleCase(String name) =>
    name.isEmpty ? name : name[0].toUpperCase() + name.substring(1);

/// `ignoreHTTPSErrors` becomes `ignore_https_errors`.
String toSnakeCase(String name) => name
    .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]}_${m[2]}')
    .replaceAllMapped(RegExp(r'([A-Z])([A-Z][a-z])'), (m) => '${m[1]}_${m[2]}')
    .toLowerCase();

/// Renders [value] as a JavaScript object literal.
///
/// Keys are sorted, `timeout` and null values are dropped, and strings are
/// single quoted, exactly as upstream does. [mode] picks between one key per
/// line and everything on one line.
String formatObject(Object? value,
    {String indent = '  ', String mode = 'multiline'}) {
  if (value is String) return escapeWithQuotes(value, "'");
  if (value is List) {
    return '[${value.map((o) => formatObject(o)).join(', ')}]';
  }
  if (value is Map) {
    final keys = value.keys
        .map((k) => k.toString())
        .where((key) => key != 'timeout' && value[key] != null)
        .toList()
      ..sort();
    if (keys.isEmpty) return '{}';
    final tokens = [
      for (final key in keys) '$key: ${formatObject(value[key])}',
    ];
    if (mode == 'multiline') {
      return '{\n${tokens.map((t) => indent + t).join(',\n')}\n}';
    }
    return '{ ${tokens.join(', ')} }';
  }
  return '$value';
}

/// [formatObject], but an empty object renders as nothing at all.
String formatObjectOrVoid(Object? value, {String indent = '  '}) {
  final result = formatObject(value, indent: indent);
  return result == '{}' ? '' : result;
}

/// Quotes [text] as a CSS attribute value.
String quoteCSSAttributeValue(String text) =>
    '"${text.replaceAllMapped(RegExp(r'["\\]'), (m) => '\\${m[0]}')}"';

/// Collapses runs of whitespace and drops zero-width characters.
String normalizeWhiteSpace(String text) =>
    text.replaceAll(RegExp('[​­]'), '').trim().replaceAll(RegExp(r'\s+'), ' ');

/// Undoes the quote escaping that [escapeRegexForSelector] adds.
///
/// An odd number of backslashes before a quote means one of them was inserted
/// on the way into the selector, so it comes back out here.
String normalizeEscapedRegexQuotes(String source) => source.replaceAllMapped(
    RegExp(r'''(^|[^\\])(\\\\)*\\(['"`])'''),
    (m) => '${m[1] ?? ''}${m[2] ?? ''}${m[3] ?? ''}');

/// The reverse of [normalizeEscapedRegexQuotes]: makes a regex literal safe
/// to embed in a selector string.
String escapeRegexForSelector(JsRegExp re) {
  // Unicode mode does not allow identity character escapes, so the quotes are
  // left alone and we hope the source has neither quotes nor ">>".
  if (re.unicode) return re.toString();
  return re
      .toString()
      .replaceAllMapped(RegExp(r'''(^|[^\\])(\\\\)*(["'`])'''),
          (m) => '${m[1] ?? ''}${m[2] ?? ''}\\${m[3] ?? ''}')
      .replaceAll('>>', r'\>\>');
}

/// Escapes [text] (a [String] or a [JsRegExp]) for `internal:text=` and its
/// relatives.
String escapeForTextSelector(Object text, bool exact) {
  if (text is JsRegExp) return escapeRegexForSelector(text);
  return '${jsonEncode(text as String)}${exact ? 's' : 'i'}';
}

/// Escapes [value] (a [String] or a [JsRegExp]) for the attribute selectors,
/// `internal:attr=`, `internal:testid=` and `internal:role=`.
String escapeForAttributeSelector(Object value, bool exact) {
  if (value is JsRegExp) return escapeRegexForSelector(value);
  // Upstream note: this should be cssEscape(value).replace(/\\ /g, ' '), but
  // Playwright's attribute selectors do not follow the CSS parsing spec, so
  // they are escaped differently.
  final escaped =
      (value as String).replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  return '"$escaped"${exact ? 's' : 'i'}';
}

/// Parses a `/source/flags` literal into a [JsRegExp].
JsRegExp parseRegex(String regex) => JsRegExp.parse(regex);

/// Escapes the characters that are special inside a regular expression.
String escapeRegExp(String s) =>
    s.replaceAllMapped(RegExp(r'[.*+?^${}()|[\]\\]'), (m) => '\\${m[0]}');

/// Trims [input] to [cap] characters, appending [suffix] when it had to cut.
String trimString(String input, int cap, [String suffix = '']) {
  if (input.length <= cap) return input;
  final chars = input.runes.toList();
  if (chars.length > cap) {
    return String.fromCharCodes(chars.take(cap - suffix.length)) + suffix;
  }
  return String.fromCharCodes(chars);
}

/// [trimString] with an ellipsis as the suffix.
String trimStringWithEllipsis(String input, int cap) =>
    trimString(input, cap, '…');

// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/stringUtils.ts (the two escapers only)

/// The HTML escapers the snapshot renderer needs.
library;

const Map<String, String> _escaped = {
  '&': '&amp;',
  '<': '&lt;',
  '>': '&gt;',
  '"': '&quot;',
  "'": '&#39;',
};

final RegExp _attributeChars = RegExp(r'''[&<>"']''');
final RegExp _textChars = RegExp(r'[&<]');

/// Escapes a value that will sit inside a double-quoted attribute.
String escapeHtmlAttribute(String s) =>
    s.replaceAllMapped(_attributeChars, (m) => _escaped[m[0]!]!);

/// Escapes a text node. Only `&` and `<` can end text content.
String escapeHtml(String s) =>
    s.replaceAllMapped(_textChars, (m) => _escaped[m[0]!]!);

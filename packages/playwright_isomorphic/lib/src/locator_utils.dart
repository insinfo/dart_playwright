// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/locatorUtils.ts

import 'dart:convert';

import 'string_utils.dart';

/// The options of `getByRole`, as the selector builder sees them.
///
/// [name] and [description] are a [String] or a [JsRegExp]; [checked] and
/// [pressed] are a [bool] or the string `mixed`.
class ByRoleOptions {
  final Object? checked;
  final Object? description;
  final bool? disabled;
  final bool? exact;
  final bool? expanded;
  final bool? includeHidden;
  final int? level;
  final Object? name;
  final Object? pressed;
  final bool? selected;

  const ByRoleOptions({
    this.checked,
    this.description,
    this.disabled,
    this.exact,
    this.expanded,
    this.includeHidden,
    this.level,
    this.name,
    this.pressed,
    this.selected,
  });
}

String _getByAttributeTextSelector(String attrName, Object text,
        {bool exact = false}) =>
    'internal:attr=[$attrName=${escapeForAttributeSelector(text, exact)}]';

/// Several test id attribute names can be joined with a comma; attribute
/// names cannot contain commas.
List<String> splitTestIdAttributeNames(String testIdAttributeName) =>
    testIdAttributeName.split(',');

/// Quotes a test id attribute name when it holds more than one name.
String encodeTestIdAttributeName(String testIdAttributeName) =>
    testIdAttributeName.contains(',')
        ? jsonEncode(testIdAttributeName)
        : testIdAttributeName;

/// The selector behind `getByTestId`.
String getByTestIdSelector(String testIdAttributeName, Object testId) =>
    'internal:testid=[${encodeTestIdAttributeName(testIdAttributeName)}='
    '${escapeForAttributeSelector(testId, true)}]';

/// The selector behind `getByLabel`.
String getByLabelSelector(Object text, {bool exact = false}) =>
    'internal:label=${escapeForTextSelector(text, exact)}';

/// The selector behind `getByAltText`.
String getByAltTextSelector(Object text, {bool exact = false}) =>
    _getByAttributeTextSelector('alt', text, exact: exact);

/// The selector behind `getByTitle`.
String getByTitleSelector(Object text, {bool exact = false}) =>
    _getByAttributeTextSelector('title', text, exact: exact);

/// The selector behind `getByPlaceholder`.
String getByPlaceholderSelector(Object text, {bool exact = false}) =>
    _getByAttributeTextSelector('placeholder', text, exact: exact);

/// The selector behind `getByText`.
String getByTextSelector(Object text, {bool exact = false}) =>
    'internal:text=${escapeForTextSelector(text, exact)}';

/// The selector behind `getByRole`.
String getByRoleSelector(String role,
    [ByRoleOptions options = const ByRoleOptions()]) {
  final props = <List<String>>[];
  if (options.checked != null) props.add(['checked', '${options.checked}']);
  if (options.disabled != null) props.add(['disabled', '${options.disabled}']);
  if (options.selected != null) props.add(['selected', '${options.selected}']);
  if (options.expanded != null) props.add(['expanded', '${options.expanded}']);
  if (options.includeHidden != null) {
    props.add(['include-hidden', '${options.includeHidden}']);
  }
  if (options.level != null) props.add(['level', '${options.level}']);
  final name = options.name;
  if (name != null) {
    props.add(
        ['name', escapeForAttributeSelector(name, options.exact ?? false)]);
  }
  final description = options.description;
  if (description != null) {
    props.add([
      'description',
      escapeForAttributeSelector(description, options.exact ?? false)
    ]);
  }
  if (options.pressed != null) props.add(['pressed', '${options.pressed}']);
  return 'internal:role=$role'
      '${props.map((p) => '[${p[0]}=${p[1]}]').join('')}';
}

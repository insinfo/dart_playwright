// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/codegen/actions.d.ts, read from the
// page side of packages/injected/src/recorder/recorder.ts.

import 'package:playwright_isomorphic/playwright_isomorphic.dart';

/// Decodes one action as the injected recorder sends it.
///
/// Upstream does not need this: TypeScript's `actions.d.ts` is a type, so the
/// object that crosses the binding *is* the action. Here the action hierarchy
/// is a sealed class, so the JSON has to be mapped onto it. The field names
/// are upstream's, unchanged.
///
/// Returns null for a name this port does not model, so an unknown action from
/// a newer page script is dropped instead of crashing the recorder.
Action? actionFromJson(Map<String, Object?> json) {
  final name = json['name'] as String?;
  final selector = json['selector'] as String? ?? '';
  final ref = json['ref'] as String?;
  switch (name) {
    case 'click':
      return ClickAction(
        selector: selector,
        ref: ref,
        button: json['button'] as String? ?? 'left',
        modifiers: (json['modifiers'] as num?)?.toInt() ?? 0,
        clickCount: (json['clickCount'] as num?)?.toInt() ?? 1,
        position: _pointFromJson(json['position']),
      );
    case 'hover':
      return HoverAction(
        selector: selector,
        ref: ref,
        position: _pointFromJson(json['position']),
      );
    case 'check':
      return CheckAction(selector: selector, ref: ref);
    case 'uncheck':
      return UncheckAction(selector: selector, ref: ref);
    case 'fill':
      return FillAction(
          selector: selector, ref: ref, text: json['text'] as String? ?? '');
    case 'press':
      return PressAction(
        selector: selector,
        ref: ref,
        key: json['key'] as String? ?? '',
        modifiers: (json['modifiers'] as num?)?.toInt() ?? 0,
      );
    case 'select':
      return SelectAction(
          selector: selector, ref: ref, options: _stringList(json['options']));
    case 'setInputFiles':
      return SetInputFilesAction(
          selector: selector, ref: ref, files: _stringList(json['files']));
    case 'navigate':
      return NavigateAction(url: json['url'] as String? ?? '');
    case 'openPage':
      return OpenPageAction(url: json['url'] as String? ?? '');
    case 'closePage':
      return ClosesPageAction();
    case 'assertText':
      return AssertTextAction(
        selector: selector,
        ref: ref,
        text: json['text'] as String? ?? '',
        substring: json['substring'] as bool? ?? true,
      );
    case 'assertValue':
      return AssertValueAction(
          selector: selector, ref: ref, value: json['value'] as String? ?? '');
    case 'assertChecked':
      return AssertCheckedAction(
          selector: selector,
          ref: ref,
          checked: json['checked'] as bool? ?? false);
    case 'assertVisible':
      return AssertVisibleAction(selector: selector, ref: ref);
    case 'assertSnapshot':
      return AssertSnapshotAction(
        selector: selector,
        ref: ref,
        ariaSnapshot: json['ariaSnapshot'] as String? ?? '',
      );
    default:
      return null;
  }
}

/// A copy of [action] with its selector replaced.
///
/// The page reports a selector relative to the frame the event happened in;
/// the driver prefixes it with the frame chain before recording it. Upstream
/// mutates `action.selector` in place, which a sealed immutable class cannot.
Action withSelector(Action action, String selector) {
  return switch (action) {
    ClickAction a => ClickAction(
        selector: selector,
        ref: a.ref,
        button: a.button,
        modifiers: a.modifiers,
        clickCount: a.clickCount,
        position: a.position),
    HoverAction a =>
      HoverAction(selector: selector, ref: a.ref, position: a.position),
    CheckAction a => CheckAction(selector: selector, ref: a.ref),
    UncheckAction a => UncheckAction(selector: selector, ref: a.ref),
    FillAction a => FillAction(selector: selector, ref: a.ref, text: a.text),
    PressAction a => PressAction(
        selector: selector, ref: a.ref, key: a.key, modifiers: a.modifiers),
    SelectAction a =>
      SelectAction(selector: selector, ref: a.ref, options: a.options),
    SetInputFilesAction a =>
      SetInputFilesAction(selector: selector, ref: a.ref, files: a.files),
    AssertTextAction a => AssertTextAction(
        selector: selector, ref: a.ref, text: a.text, substring: a.substring),
    AssertValueAction a =>
      AssertValueAction(selector: selector, ref: a.ref, value: a.value),
    AssertCheckedAction a =>
      AssertCheckedAction(selector: selector, ref: a.ref, checked: a.checked),
    AssertVisibleAction a =>
      AssertVisibleAction(selector: selector, ref: a.ref),
    AssertSnapshotAction a => AssertSnapshotAction(
        selector: selector, ref: a.ref, ariaSnapshot: a.ariaSnapshot),
    _ => action,
  };
}

/// The url of a [NavigateAction], replaced. See [withSelector].
NavigateAction withUrl(NavigateAction action, String url) =>
    NavigateAction(url: url);

Point? _pointFromJson(Object? value) {
  if (value is! Map) return null;
  final x = value['x'];
  final y = value['y'];
  if (x is! num || y is! num) return null;
  return Point(x, y);
}

List<String> _stringList(Object? value) {
  if (value is! List) return const [];
  return [for (final item in value) '$item'];
}

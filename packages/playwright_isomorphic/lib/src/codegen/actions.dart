// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/codegen/actions.d.ts
//
// Upstream declares these as TypeScript types only, because the recorder
// builds them as plain objects. Dart has no structural types, so they become
// a sealed hierarchy; the `toJson` methods are what the JSONL generator
// serializes.

/// A point in CSS pixels.
class Point {
  final num x;
  final num y;
  const Point(this.x, this.y);

  Map<String, Object?> toJson() => {'x': x, 'y': y};

  @override
  bool operator ==(Object other) =>
      other is Point && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);
}

/// One recorded step.
sealed class Action {
  /// The action name, as it travels over the recorder protocol.
  String get name;

  /// The aria snapshot an `assertSnapshot` carries.
  String? get ariaSnapshot => null;

  Map<String, Object?> toJson();
}

/// An [Action] that targets an element.
sealed class ActionWithSelector extends Action {
  /// The internal selector of the target element.
  String get selector;

  /// The aria ref of the target element, when the recorder knows one.
  String? get ref => null;
}

/// A click, double click or multi click.
class ClickAction extends ActionWithSelector {
  @override
  final String name = 'click';
  @override
  final String selector;
  @override
  final String? ref;
  final String button;

  /// A bitmask; see `toKeyboardModifiers`.
  final int modifiers;
  final int clickCount;
  final Point? position;

  ClickAction({
    required this.selector,
    this.ref,
    this.button = 'left',
    this.modifiers = 0,
    this.clickCount = 1,
    this.position,
  });

  @override
  Map<String, Object?> toJson() => {
        'name': name,
        'selector': selector,
        if (ref != null) 'ref': ref,
        'button': button,
        'modifiers': modifiers,
        'clickCount': clickCount,
        if (position != null) 'position': position!.toJson(),
      };
}

/// A hover.
class HoverAction extends ActionWithSelector {
  @override
  final String name = 'hover';
  @override
  final String selector;
  @override
  final String? ref;
  final Point? position;

  HoverAction({required this.selector, this.ref, this.position});

  @override
  Map<String, Object?> toJson() => {
        'name': name,
        'selector': selector,
        if (ref != null) 'ref': ref,
        if (position != null) 'position': position!.toJson(),
      };
}

/// Checking a checkbox or radio.
class CheckAction extends ActionWithSelector {
  @override
  final String name = 'check';
  @override
  final String selector;
  @override
  final String? ref;

  CheckAction({required this.selector, this.ref});

  @override
  Map<String, Object?> toJson() =>
      {'name': name, 'selector': selector, if (ref != null) 'ref': ref};
}

/// Unchecking a checkbox.
class UncheckAction extends ActionWithSelector {
  @override
  final String name = 'uncheck';
  @override
  final String selector;
  @override
  final String? ref;

  UncheckAction({required this.selector, this.ref});

  @override
  Map<String, Object?> toJson() =>
      {'name': name, 'selector': selector, if (ref != null) 'ref': ref};
}

/// Typing into a field.
class FillAction extends ActionWithSelector {
  @override
  final String name = 'fill';
  @override
  final String selector;
  @override
  final String? ref;
  final String text;

  FillAction({required this.selector, this.ref, required this.text});

  @override
  Map<String, Object?> toJson() => {
        'name': name,
        'selector': selector,
        if (ref != null) 'ref': ref,
        'text': text,
      };
}

/// A navigation typed into the address bar.
class NavigateAction extends Action {
  @override
  final String name = 'navigate';
  final String url;

  NavigateAction({required this.url});

  @override
  Map<String, Object?> toJson() => {'name': name, 'url': url};
}

/// A new page opening.
class OpenPageAction extends Action {
  @override
  final String name = 'openPage';
  final String url;

  OpenPageAction({required this.url});

  @override
  Map<String, Object?> toJson() => {'name': name, 'url': url};
}

/// A page closing.
class ClosesPageAction extends Action {
  @override
  final String name = 'closePage';

  @override
  Map<String, Object?> toJson() => {'name': name};
}

/// A key press.
class PressAction extends ActionWithSelector {
  @override
  final String name = 'press';
  @override
  final String selector;
  @override
  final String? ref;
  final String key;
  final int modifiers;

  PressAction({
    required this.selector,
    this.ref,
    required this.key,
    this.modifiers = 0,
  });

  @override
  Map<String, Object?> toJson() => {
        'name': name,
        'selector': selector,
        if (ref != null) 'ref': ref,
        'key': key,
        'modifiers': modifiers,
      };
}

/// Choosing options in a `<select>`.
class SelectAction extends ActionWithSelector {
  @override
  final String name = 'select';
  @override
  final String selector;
  @override
  final String? ref;
  final List<String> options;

  SelectAction({required this.selector, this.ref, required this.options});

  @override
  Map<String, Object?> toJson() => {
        'name': name,
        'selector': selector,
        if (ref != null) 'ref': ref,
        'options': options,
      };
}

/// Picking files for an `<input type=file>`.
class SetInputFilesAction extends ActionWithSelector {
  @override
  final String name = 'setInputFiles';
  @override
  final String selector;
  @override
  final String? ref;
  final List<String> files;

  SetInputFilesAction({required this.selector, this.ref, required this.files});

  @override
  Map<String, Object?> toJson() => {
        'name': name,
        'selector': selector,
        if (ref != null) 'ref': ref,
        'files': files,
      };
}

/// An assertion on the element's text.
class AssertTextAction extends ActionWithSelector {
  @override
  final String name = 'assertText';
  @override
  final String selector;
  @override
  final String? ref;
  final String text;

  /// True for `toContainText`, false for `toHaveText`.
  final bool substring;

  AssertTextAction({
    required this.selector,
    this.ref,
    required this.text,
    this.substring = false,
  });

  @override
  Map<String, Object?> toJson() => {
        'name': name,
        'selector': selector,
        if (ref != null) 'ref': ref,
        'text': text,
        'substring': substring,
      };
}

/// An assertion on the element's value.
class AssertValueAction extends ActionWithSelector {
  @override
  final String name = 'assertValue';
  @override
  final String selector;
  @override
  final String? ref;
  final String value;

  AssertValueAction({required this.selector, this.ref, required this.value});

  @override
  Map<String, Object?> toJson() => {
        'name': name,
        'selector': selector,
        if (ref != null) 'ref': ref,
        'value': value,
      };
}

/// An assertion on the element's checked state.
class AssertCheckedAction extends ActionWithSelector {
  @override
  final String name = 'assertChecked';
  @override
  final String selector;
  @override
  final String? ref;
  final bool checked;

  AssertCheckedAction(
      {required this.selector, this.ref, required this.checked});

  @override
  Map<String, Object?> toJson() => {
        'name': name,
        'selector': selector,
        if (ref != null) 'ref': ref,
        'checked': checked,
      };
}

/// An assertion that the element is visible.
class AssertVisibleAction extends ActionWithSelector {
  @override
  final String name = 'assertVisible';
  @override
  final String selector;
  @override
  final String? ref;

  AssertVisibleAction({required this.selector, this.ref});

  @override
  Map<String, Object?> toJson() =>
      {'name': name, 'selector': selector, if (ref != null) 'ref': ref};
}

/// An assertion against an aria snapshot.
class AssertSnapshotAction extends ActionWithSelector {
  @override
  final String name = 'assertSnapshot';
  @override
  final String selector;
  @override
  final String? ref;
  @override
  final String ariaSnapshot;

  AssertSnapshotAction(
      {required this.selector, this.ref, required this.ariaSnapshot});

  @override
  Map<String, Object?> toJson() => {
        'name': name,
        'selector': selector,
        if (ref != null) 'ref': ref,
        'ariaSnapshot': ariaSnapshot,
      };
}

/// Something that happened because of an action.
sealed class Signal {
  String get name;
  Map<String, Object?> toJson();
}

/// The page navigated.
class NavigationSignal extends Signal {
  @override
  final String name = 'navigation';
  final String url;

  NavigationSignal({required this.url});

  @override
  Map<String, Object?> toJson() => {'name': name, 'url': url};
}

/// A popup opened.
class PopupSignal extends Signal {
  @override
  final String name = 'popup';
  final String popupPageGuid;

  PopupSignal({required this.popupPageGuid});

  @override
  Map<String, Object?> toJson() =>
      {'name': name, 'popupPageGuid': popupPageGuid};
}

/// A download started.
class DownloadSignal extends Signal {
  @override
  final String name = 'download';
  final String downloadAlias;

  DownloadSignal({required this.downloadAlias});

  @override
  Map<String, Object?> toJson() =>
      {'name': name, 'downloadAlias': downloadAlias};
}

/// A dialog appeared.
class DialogSignal extends Signal {
  @override
  final String name = 'dialog';
  final String dialogAlias;

  DialogSignal({required this.dialogAlias});

  @override
  Map<String, Object?> toJson() => {'name': name, 'dialogAlias': dialogAlias};
}

/// An element that appeared since the previous action, asserted before this
/// action runs.
class ExpectSignal extends Signal {
  @override
  final String name = 'expect';
  final String selector;

  ExpectSignal({required this.selector});

  @override
  Map<String, Object?> toJson() => {'name': name, 'selector': selector};
}

/// One recorded action, with the page it happened on and what it triggered.
class ActionInContext {
  final String pageGuid;
  final Action action;
  final List<Signal> signals;

  ActionInContext({
    required this.pageGuid,
    required this.action,
    this.signals = const [],
  });
}

/// A signal and the page it happened on.
class SignalInContext {
  final String pageGuid;
  final Signal signal;

  SignalInContext({required this.pageGuid, required this.signal});
}

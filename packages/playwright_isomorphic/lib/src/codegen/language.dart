// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/codegen/language.ts

import 'dart:convert';

import 'actions.dart';
import 'types.dart';

/// The device descriptors the generators look [LanguageGeneratorOptions]'s
/// `deviceName` up in.
///
/// Upstream imports an 80 KB JSON table here. This port keeps the table out
/// of the codegen package and lets the embedder install it, because the
/// device list belongs to the browser layer and a browserless trace viewer
/// has no use for it. An empty table simply means no device is expanded.
final Map<String, Map<String, Object?>> deviceDescriptors =
    <String, Map<String, Object?>>{};

/// The result of [generateCode]: the whole file, and its pieces.
class GeneratedCode {
  final String header;
  final String footer;
  final List<String> actionTexts;
  final String text;

  GeneratedCode({
    required this.header,
    required this.footer,
    required this.actionTexts,
    required this.text,
  });
}

/// Runs [languageGenerator] over [actions] and joins the result.
GeneratedCode generateCode(List<ActionInContext> actions,
    LanguageGenerator languageGenerator, LanguageGeneratorOptions options) {
  languageGenerator.reset();
  final header = languageGenerator.generateHeader(options);
  final footer = languageGenerator.generateFooter(options.saveStorage);
  final actionTexts = [
    for (final a in actions) languageGenerator.generateAction(a, options),
  ].where((text) => text.isNotEmpty).toList();
  final text = [header, ...actionTexts, footer].join('\n');
  return GeneratedCode(
      header: header, footer: footer, actionTexts: actionTexts, text: text);
}

/// The synthetic `assertVisible` action an [ExpectSignal] stands for.
ActionInContext expectSignalAction(
        ActionInContext actionInContext, ExpectSignal signal) =>
    ActionInContext(
      pageGuid: actionInContext.pageGuid,
      signals: const [],
      action: AssertVisibleAction(selector: signal.selector),
    );

/// Drops from [options] every property the device descriptor already sets.
Map<String, Object?> sanitizeDeviceOptions(
    Map<String, Object?> device, Map<String, Object?> options) {
  final cleanedOptions = <String, Object?>{};
  for (final entry in options.entries) {
    if (jsonEncode(device[entry.key]) != jsonEncode(entry.value)) {
      cleanedOptions[entry.key] = entry.value;
    }
  }
  return cleanedOptions;
}

/// The signals of an [ActionInContext], one slot each.
class SignalMap {
  final PopupSignal? popup;
  final DownloadSignal? download;
  final DialogSignal? dialog;
  final ExpectSignal? expect;

  const SignalMap({this.popup, this.download, this.dialog, this.expect});
}

/// Picks the last signal of each kind out of [actionInContext].
SignalMap toSignalMap(ActionInContext actionInContext) {
  PopupSignal? popup;
  DownloadSignal? download;
  DialogSignal? dialog;
  ExpectSignal? expect;
  for (final signal in actionInContext.signals) {
    if (signal is PopupSignal) {
      popup = signal;
    } else if (signal is DownloadSignal) {
      download = signal;
    } else if (signal is DialogSignal) {
      dialog = signal;
    } else if (signal is ExpectSignal) {
      expect = signal;
    }
  }
  return SignalMap(
      popup: popup, download: download, dialog: dialog, expect: expect);
}

/// Turns the recorder's modifier bitmask into names.
///
/// Both bit 2 and bit 4 come out as `ControlOrMeta`: the recorder cannot tell
/// which of the two the user meant, and the generated code should work on
/// both platforms.
List<SmartKeyboardModifier> toKeyboardModifiers(int modifiers) {
  final result = <SmartKeyboardModifier>[];
  if (modifiers & 1 != 0) result.add('Alt');
  if (modifiers & 2 != 0) result.add('ControlOrMeta');
  if (modifiers & 4 != 0) result.add('ControlOrMeta');
  if (modifiers & 8 != 0) result.add('Shift');
  return result;
}

/// The inverse of [toKeyboardModifiers].
int fromKeyboardModifiers([List<SmartKeyboardModifier>? modifiers]) {
  var result = 0;
  if (modifiers == null) return result;
  if (modifiers.contains('Alt')) result |= 1;
  if (modifiers.contains('Control')) result |= 2;
  if (modifiers.contains('ControlOrMeta')) result |= 2;
  if (modifiers.contains('Meta')) result |= 4;
  if (modifiers.contains('Shift')) result |= 8;
  return result;
}

/// The click options worth printing: the defaults are left out.
MouseClickOptions toClickOptionsForSourceCode(ClickAction action) {
  final modifiers = toKeyboardModifiers(action.modifiers);
  return MouseClickOptions(
    button: action.button != 'left' ? action.button : null,
    modifiers: modifiers.isNotEmpty ? modifiers : null,
    // Do not render clickCount === 2 for dblclick.
    clickCount: action.clickCount > 2 ? action.clickCount : null,
    position: action.position,
  );
}

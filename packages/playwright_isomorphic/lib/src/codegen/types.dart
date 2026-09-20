// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/codegen/types.ts

import '../locator_generators.dart';
import 'actions.dart';

export '../locator_generators.dart' show Language, Languages;

/// A keyboard modifier as the generators spell it.
///
/// `ControlOrMeta` is the portable one the recorder prefers; `Control` and
/// `Meta` only appear on input.
typedef SmartKeyboardModifier = String;

/// The click options that survive into generated source.
class MouseClickOptions {
  final List<SmartKeyboardModifier>? modifiers;
  final Point? position;
  final Duration? delay;
  final String? button;
  final int? clickCount;

  const MouseClickOptions({
    this.modifiers,
    this.position,
    this.delay,
    this.button,
    this.clickCount,
  });

  /// The options as the object literal the generators format.
  ///
  /// Key order follows upstream's assignment order: button, modifiers,
  /// clickCount, position. The formatters sort the keys themselves where the
  /// target language wants them sorted.
  Map<String, Object?> toMap() => {
        if (button != null) 'button': button,
        if (modifiers != null) 'modifiers': modifiers,
        if (clickCount != null) 'clickCount': clickCount,
        if (position != null) 'position': position!.toJson(),
      };

  bool get isEmpty => toMap().isEmpty;
}

/// Everything a generator needs besides the actions themselves.
///
/// [launchOptions] and [contextOptions] are the JSON-ish maps the recorder
/// sends, not typed option objects: the generators only read them to print
/// them back out.
class LanguageGeneratorOptions {
  final String browserName;
  final Map<String, Object?> launchOptions;
  final Map<String, Object?> contextOptions;
  final String? deviceName;
  final String? saveStorage;
  final bool generateExpectSignal;

  const LanguageGeneratorOptions({
    required this.browserName,
    this.launchOptions = const {},
    this.contextOptions = const {},
    this.deviceName,
    this.saveStorage,
    this.generateExpectSignal = false,
  });
}

/// A source code generator for one language and one flavour of it.
abstract class LanguageGenerator {
  /// A stable id, such as `playwright-test` or `dart`.
  String get id;

  /// The group the recorder's language picker puts this generator in.
  String get groupName;

  /// The name inside that group, such as `Library` or `Test Runner`.
  String get name;

  /// Which [Language] the generated source should be highlighted as.
  Language get highlighter;

  /// Forgets the page aliases of the previous run.
  void reset();

  String generateHeader(LanguageGeneratorOptions options);

  String generateAction(
      ActionInContext actionInContext, LanguageGeneratorOptions options);

  String generateFooter(String? saveStorage);
}

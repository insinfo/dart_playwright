// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/codegen/jsonl.ts

import 'dart:convert';

import '../locator_generators.dart';
import 'actions.dart';
import 'language.dart';
import 'types.dart';

/// Emits one JSON object per action, for the tools that consume the recording
/// instead of reading it.
class JsonlLanguageGenerator implements LanguageGenerator {
  @override
  final String id = 'jsonl';
  @override
  final String groupName = '';
  @override
  final String name = 'JSONL';
  @override
  final Language highlighter = Languages.javascript;

  @override
  void reset() {}

  @override
  String generateAction(
      ActionInContext actionInContext, LanguageGeneratorOptions options) {
    final action = actionInContext.action;
    final locator = action is ActionWithSelector
        ? jsonDecode(asLocator(Languages.jsonl, action.selector))
        : null;
    final entry = <String, Object?>{...action.toJson()};
    // Upstream overwrites ariaSnapshot with undefined, which JSON.stringify
    // then drops.
    entry.remove('ariaSnapshot');
    entry['signals'] = [
      for (final signal in actionInContext.signals) signal.toJson(),
    ];
    entry['pageGuid'] = actionInContext.pageGuid;
    if (locator != null) entry['locator'] = locator;
    final lines = <String>[jsonEncode(entry)];
    final expect = toSignalMap(actionInContext).expect;
    if (options.generateExpectSignal && expect != null) {
      lines.add(
          generateAction(expectSignalAction(actionInContext, expect), options));
    }
    return lines.join('\n');
  }

  @override
  String generateHeader(LanguageGeneratorOptions options) => jsonEncode({
        'browserName': options.browserName,
        'launchOptions': options.launchOptions,
        'contextOptions': options.contextOptions,
        if (options.deviceName != null) 'deviceName': options.deviceName,
        if (options.saveStorage != null) 'saveStorage': options.saveStorage,
        if (options.generateExpectSignal)
          'generateExpectSignal': options.generateExpectSignal,
      });

  @override
  String generateFooter(String? saveStorage) => '';
}

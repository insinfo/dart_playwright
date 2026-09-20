// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/codegen/python.ts

import 'dart:convert';

import '../locator_generators.dart';
import '../string_utils.dart';
import 'actions.dart';
import 'javascript.dart' show dedent;
import 'language.dart';
import 'types.dart';

/// Generates `playwright-python` sources, sync, async or pytest.
class PythonLanguageGenerator implements LanguageGenerator {
  @override
  final String id;
  @override
  final String groupName = 'Python';
  @override
  final String name;
  @override
  final Language highlighter = Languages.python;

  final String _awaitPrefix;
  final String _asyncPrefix;
  final bool _isAsync;
  final bool _isPyTest;
  final Map<String, String> _pageAliases = <String, String>{};

  PythonLanguageGenerator(bool isAsync, bool isPyTest)
      : id = isPyTest ? 'python-pytest' : (isAsync ? 'python-async' : 'python'),
        name = isPyTest ? 'Pytest' : (isAsync ? 'Library Async' : 'Library'),
        _isAsync = isAsync,
        _isPyTest = isPyTest,
        _awaitPrefix = isAsync ? 'await ' : '',
        _asyncPrefix = isAsync ? 'async ' : '';

  @override
  void reset() => _pageAliases.clear();

  String _pageAlias(String pageGuid) => _pageAliases.putIfAbsent(
      pageGuid, () => 'page${_pageAliases.isEmpty ? '' : _pageAliases.length}');

  @override
  String generateAction(
      ActionInContext actionInContext, LanguageGeneratorOptions options) {
    final action = actionInContext.action;
    // Resolve before the early return, so that pages are named in the order
    // they are opened.
    final pageAlias = _pageAlias(actionInContext.pageGuid);
    if (_isPyTest && (action is OpenPageAction || action is ClosesPageAction)) {
      return '';
    }

    final formatter = PythonFormatter(4);

    if (action is OpenPageAction) {
      formatter.add('$pageAlias = ${_awaitPrefix}context.new_page()');
      if (action.url.isNotEmpty &&
          action.url != 'about:blank' &&
          action.url != 'chrome://newtab/') {
        formatter.add('$_awaitPrefix$pageAlias.goto(${_quote(action.url)})');
      }
      return formatter.format();
    }

    final subject = pageAlias;
    final signals = toSignalMap(actionInContext);

    if (signals.dialog != null) {
      formatter
          .add('  $pageAlias.once("dialog", lambda dialog: dialog.dismiss())');
    }

    var code = '$_awaitPrefix${_generateActionCall(subject, actionInContext)}';

    if (signals.popup != null) {
      final popupAlias = _pageAlias(signals.popup!.popupPageGuid);
      code = '${_asyncPrefix}with $pageAlias.expect_popup() as '
          '${popupAlias}_info {\n'
          '        $code\n'
          '      }\n'
          '      $popupAlias = $_awaitPrefix${popupAlias}_info.value';
    }

    if (signals.download != null) {
      final alias = signals.download!.downloadAlias;
      code = '${_asyncPrefix}with $pageAlias.expect_download() as '
          'download${alias}_info {\n'
          '        $code\n'
          '      }\n'
          '      download$alias = ${_awaitPrefix}download${alias}_info.value';
    }

    formatter.add(code);

    if (options.generateExpectSignal && signals.expect != null) {
      formatter.add(generateAction(
          expectSignalAction(actionInContext, signals.expect!), options));
    }

    return formatter.format();
  }

  String _generateActionCall(String subject, ActionInContext actionInContext) {
    final action = actionInContext.action;
    switch (action) {
      case OpenPageAction():
        throw StateError('Not reached');
      case ClosesPageAction():
        return '$subject.close()';
      case ClickAction():
        final method = action.clickCount == 2 ? 'dblclick' : 'click';
        final options = toClickOptionsForSourceCode(action);
        final optionsString = _formatOptions(options.toMap(), false);
        return '$subject.${_asLocator(action.selector)}.$method($optionsString)';
      case HoverAction():
        return '$subject.${_asLocator(action.selector)}.hover('
            '${_formatOptions({
              'position': action.position?.toJson()
            }, false)})';
      case CheckAction():
        return '$subject.${_asLocator(action.selector)}.check()';
      case UncheckAction():
        return '$subject.${_asLocator(action.selector)}.uncheck()';
      case FillAction():
        return '$subject.${_asLocator(action.selector)}'
            '.fill(${_quote(action.text)})';
      case SetInputFilesAction():
        return '$subject.${_asLocator(action.selector)}.set_input_files('
            '${_formatValue(action.files.length == 1 ? action.files[0] : action.files)})';
      case PressAction():
        final modifiers = toKeyboardModifiers(action.modifiers);
        final shortcut = [...modifiers, action.key].join('+');
        return '$subject.${_asLocator(action.selector)}'
            '.press(${_quote(shortcut)})';
      case NavigateAction():
        return '$subject.goto(${_quote(action.url)})';
      case SelectAction():
        return '$subject.${_asLocator(action.selector)}.select_option('
            '${_formatValue(action.options.length == 1 ? action.options[0] : action.options)})';
      case AssertTextAction():
        return 'expect($subject.${_asLocator(action.selector)})'
            '.${action.substring ? 'to_contain_text' : 'to_have_text'}'
            '(${_quote(action.text)})';
      case AssertCheckedAction():
        return 'expect($subject.${_asLocator(action.selector)}).'
            '${action.checked ? 'to_be_checked()' : 'not_to_be_checked()'}';
      case AssertVisibleAction():
        return 'expect($subject.${_asLocator(action.selector)})'
            '.to_be_visible()';
      case AssertValueAction():
        final assertion = action.value.isNotEmpty
            ? 'to_have_value(${_quote(action.value)})'
            : 'to_be_empty()';
        return 'expect($subject.${_asLocator(action.selector)}).$assertion';
      case AssertSnapshotAction():
        return 'expect($subject.${_asLocator(action.selector)})'
            '.to_match_aria_snapshot(${_quote(action.ariaSnapshot)})';
    }
  }

  String _asLocator(String selector) => asLocator(Languages.python, selector);

  @override
  String generateHeader(LanguageGeneratorOptions options) {
    final formatter = PythonFormatter();
    final recordHar = options.contextOptions['recordHar'] as Map?;
    final harUrl = recordHar == null ? null : recordHar['urlFilter'];
    if (_isPyTest) {
      final contextOptions = _formatContextOptions(
          options.contextOptions, options.deviceName, true);
      final fixture = contextOptions.isNotEmpty
          ? '''


@pytest.fixture(scope="session")
def browser_context_args(browser_context_args, playwright) {
    return {$contextOptions}
}
'''
          : '';
      formatter.add(
          '${options.deviceName != null || contextOptions.isNotEmpty ? 'import pytest\n' : ''}import re\n'
          'from playwright.sync_api import Page, expect\n'
          '$fixture\n'
          '\n'
          'def test_example(page: Page) -> None {');
      if (recordHar != null) {
        formatter.add('    page.route_from_har('
            '${_quote(recordHar['path'] as String)}'
            '${harUrl is String ? ', url=${_quote(harUrl)}' : ''})');
      }
    } else if (_isAsync) {
      formatter.add('''
import asyncio
import re
from playwright.async_api import Playwright, async_playwright, expect


async def run(playwright: Playwright) -> None {
    browser = await playwright.${options.browserName}.launch(${_formatOptions(options.launchOptions, false)})
    context = await browser.new_context(${_formatContextOptions(options.contextOptions, options.deviceName)})''');
      if (recordHar != null) {
        formatter.add('    await context.route_from_har('
            '${_quote(recordHar['path'] as String)}'
            '${harUrl is String ? ', url=${_quote(harUrl)}' : ''})');
      }
    } else {
      formatter.add('''
import re
from playwright.sync_api import Playwright, sync_playwright, expect


def run(playwright: Playwright) -> None {
    browser = playwright.${options.browserName}.launch(${_formatOptions(options.launchOptions, false)})
    context = browser.new_context(${_formatContextOptions(options.contextOptions, options.deviceName)})''');
      if (recordHar != null) {
        formatter.add('    context.route_from_har('
            '${_quote(recordHar['path'] as String)}'
            '${harUrl is String ? ', url=${_quote(harUrl)}' : ''})');
      }
    }
    return formatter.format();
  }

  @override
  String generateFooter(String? saveStorage) {
    if (_isPyTest) return '';
    if (_isAsync) {
      final storageStateLine = saveStorage != null
          ? '\n    await context.storage_state(path=${_quote(saveStorage)})'
          : '';
      return '\n    # ---------------------$storageStateLine\n'
          '    await context.close()\n'
          '    await browser.close()\n'
          '\n'
          '\n'
          'async def main() -> None:\n'
          '    async with async_playwright() as playwright:\n'
          '        await run(playwright)\n'
          '\n'
          '\n'
          'asyncio.run(main())\n';
    }
    final storageStateLine = saveStorage != null
        ? '\n    context.storage_state(path=${_quote(saveStorage)})'
        : '';
    return '\n    # ---------------------$storageStateLine\n'
        '    context.close()\n'
        '    browser.close()\n'
        '\n'
        '\n'
        'with sync_playwright() as playwright:\n'
        '    run(playwright)\n';
  }
}

String _formatValue(Object? value) {
  if (value == false) return 'False';
  if (value == true) return 'True';
  if (value == null) return 'None';
  if (value is List) return '[${value.map(_formatValue).join(', ')}]';
  if (value is String) return _quote(value);
  if (value is Map) return jsonEncode(value);
  return '$value';
}

String _formatOptions(Map<String, Object?> value, bool hasArguments,
    [bool asDict = false]) {
  final keys = value.keys.where((key) => value[key] != null).toList()..sort();
  if (keys.isEmpty) return '';
  return (hasArguments ? ', ' : '') +
      keys.map((key) {
        if (asDict) return '"${toSnakeCase(key)}": ${_formatValue(value[key])}';
        return '${toSnakeCase(key)}=${_formatValue(value[key])}';
      }).join(', ');
}

String _formatContextOptions(
    Map<String, Object?> contextOptions, String? deviceName,
    [bool asDict = false]) {
  // recordHar is replaced with route_from_har in the generated code.
  final options = <String, Object?>{...contextOptions};
  options.remove('recordHar');
  final device = deviceName != null ? deviceDescriptors[deviceName] : null;
  if (device == null) return _formatOptions(options, false, asDict);
  return '**playwright.devices[${_quote(deviceName!)}]' +
      _formatOptions(sanitizeDeviceOptions(device, options), true, asDict);
}

/// The Python flavour of the indent-as-you-go formatter: a trailing `{`
/// becomes a `:` and opens a block, a lone `}` closes it.
class PythonFormatter {
  final String _baseIndent = '    ';
  final String _baseOffset;
  List<String> _lines = <String>[];

  PythonFormatter([int offset = 0]) : _baseOffset = ' ' * offset;

  void prepend(String text) {
    _lines = [
      ...text.trim().split('\n').map((line) => line.trim()),
      ..._lines,
    ];
  }

  void add(String text) =>
      _lines.addAll(text.trim().split('\n').map((line) => line.trim()));

  void newLine() => _lines.add('');

  String format() {
    var spaces = '';
    final lines = <String>[];
    for (var line in _lines) {
      if (line.isEmpty) {
        lines.add(line);
        continue;
      }
      if (line == '}') {
        spaces = dedent(spaces, _baseIndent);
        continue;
      }

      line = spaces + line;
      if (line.endsWith('{')) {
        spaces += _baseIndent;
        line = '${line.substring(0, line.length - 1).trimRight()}:';
      }
      lines.add(_baseOffset + line);
    }
    return lines.join('\n');
  }
}

String _quote(String text) => escapeWithQuotes(text, '"');

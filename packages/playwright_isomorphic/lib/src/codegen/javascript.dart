// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/codegen/javascript.ts

import '../locator_generators.dart';
import '../string_utils.dart';
import 'actions.dart';
import 'language.dart';
import 'types.dart';

/// Generates `playwright` and `@playwright/test` sources.
class JavaScriptLanguageGenerator implements LanguageGenerator {
  @override
  final String id;
  @override
  final String groupName = 'Node.js';
  @override
  final String name;
  @override
  final Language highlighter = Languages.javascript;

  final bool _isTest;
  final Map<String, String> _pageAliases = <String, String>{};

  JavaScriptLanguageGenerator(bool isTest)
      : id = isTest ? 'playwright-test' : 'javascript',
        name = isTest ? 'Test Runner' : 'Library',
        _isTest = isTest;

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
    if (_isTest && (action is OpenPageAction || action is ClosesPageAction)) {
      return '';
    }

    final formatter = JavaScriptFormatter(2);

    if (action is OpenPageAction) {
      formatter.add('const $pageAlias = await context.newPage();');
      if (action.url.isNotEmpty &&
          action.url != 'about:blank' &&
          action.url != 'chrome://newtab/') {
        formatter.add('await $pageAlias.goto(${_quote(action.url)});');
      }
      return formatter.format();
    }

    final subject = pageAlias;
    final signals = toSignalMap(actionInContext);

    if (signals.dialog != null) {
      formatter.add('''  $pageAlias.once('dialog', dialog => {
    console.log(`Dialog message: \${dialog.message()}`);
    dialog.dismiss().catch(() => {});
  });''');
    }

    final popupAlias =
        signals.popup != null ? _pageAlias(signals.popup!.popupPageGuid) : null;
    if (popupAlias != null) {
      formatter.add(
          'const ${popupAlias}Promise = $pageAlias.waitForEvent(\'popup\');');
    }
    if (signals.download != null) {
      formatter.add('const download${signals.download!.downloadAlias}Promise '
          '= $pageAlias.waitForEvent(\'download\');');
    }

    formatter.add(_generateActionCall(subject, actionInContext));

    if (popupAlias != null) {
      formatter.add('const $popupAlias = await ${popupAlias}Promise;');
    }
    if (signals.download != null) {
      final alias = signals.download!.downloadAlias;
      formatter.add('const download$alias = await download${alias}Promise;');
    }
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
        return 'await $subject.close();';
      case ClickAction():
        final method = action.clickCount == 2 ? 'dblclick' : 'click';
        final options = toClickOptionsForSourceCode(action);
        final optionsString = _formatOptions(options.toMap(), false);
        return 'await $subject.${_asLocator(action.selector)}'
            '.$method($optionsString);';
      case HoverAction():
        return 'await $subject.${_asLocator(action.selector)}.hover('
            '${_formatOptions({
              'position': action.position?.toJson()
            }, false)});';
      case CheckAction():
        return 'await $subject.${_asLocator(action.selector)}.check();';
      case UncheckAction():
        return 'await $subject.${_asLocator(action.selector)}.uncheck();';
      case FillAction():
        return 'await $subject.${_asLocator(action.selector)}'
            '.fill(${_quote(action.text)});';
      case SetInputFilesAction():
        return 'await $subject.${_asLocator(action.selector)}.setInputFiles('
            '${formatObject(action.files.length == 1 ? action.files[0] : action.files)});';
      case PressAction():
        final modifiers = toKeyboardModifiers(action.modifiers);
        final shortcut = [...modifiers, action.key].join('+');
        return 'await $subject.${_asLocator(action.selector)}'
            '.press(${_quote(shortcut)});';
      case NavigateAction():
        return 'await $subject.goto(${_quote(action.url)});';
      case SelectAction():
        return 'await $subject.${_asLocator(action.selector)}.selectOption('
            '${formatObject(action.options.length == 1 ? action.options[0] : action.options)});';
      case AssertTextAction():
        return '${_isTest ? '' : '// '}await expect($subject'
            '.${_asLocator(action.selector)}).'
            '${action.substring ? 'toContainText' : 'toHaveText'}'
            '(${_quote(action.text)});';
      case AssertCheckedAction():
        return '${_isTest ? '' : '// '}await expect($subject'
            '.${_asLocator(action.selector)})'
            '${action.checked ? '' : '.not'}.toBeChecked();';
      case AssertVisibleAction():
        return '${_isTest ? '' : '// '}await expect($subject'
            '.${_asLocator(action.selector)}).toBeVisible();';
      case AssertValueAction():
        final assertion = action.value.isNotEmpty
            ? 'toHaveValue(${_quote(action.value)})'
            : 'toBeEmpty()';
        return '${_isTest ? '' : '// '}await expect($subject'
            '.${_asLocator(action.selector)}).$assertion;';
      case AssertSnapshotAction():
        final commentIfNeeded = _isTest ? '' : '// ';
        return '${commentIfNeeded}await expect($subject'
            '.${_asLocator(action.selector)}).toMatchAriaSnapshot('
            '${quoteMultiline(action.ariaSnapshot, '$commentIfNeeded  ')});';
    }
  }

  String _asLocator(String selector) =>
      asLocator(Languages.javascript, selector);

  @override
  String generateHeader(LanguageGeneratorOptions options) =>
      _isTest ? generateTestHeader(options) : generateStandaloneHeader(options);

  @override
  String generateFooter(String? saveStorage) => _isTest
      ? generateTestFooter(saveStorage)
      : generateStandaloneFooter(saveStorage);

  String generateTestHeader(LanguageGeneratorOptions options) {
    final formatter = JavaScriptFormatter();
    final useText = _formatContextOptions(
        options.contextOptions, options.deviceName, _isTest);
    formatter.add('''
      import { test, expect${options.deviceName != null ? ', devices' : ''} } from '@playwright/test';
${useText.isNotEmpty ? '\ntest.use($useText);\n' : ''}
      test('test', async ({ page }) => {''');
    final recordHar = options.contextOptions['recordHar'] as Map?;
    if (recordHar != null) {
      final url = recordHar['urlFilter'];
      formatter.add('  await page.routeFromHAR('
          '${_quote(recordHar['path'] as String)}'
          '${url != null ? ', ${_formatOptions({'url': url}, false)}' : ''});');
    }
    return formatter.format();
  }

  String generateTestFooter(String? saveStorage) => '});';

  String generateStandaloneHeader(LanguageGeneratorOptions options) {
    final formatter = JavaScriptFormatter();
    formatter.add('''
      const { ${options.browserName}${options.deviceName != null ? ', devices' : ''} } = require('playwright');

      (async () => {
        const browser = await ${options.browserName}.launch(${formatObjectOrVoid(options.launchOptions)});
        const context = await browser.newContext(${_formatContextOptions(options.contextOptions, options.deviceName, false)});''');
    final recordHar = options.contextOptions['recordHar'] as Map?;
    if (recordHar != null) {
      formatter.add('        await context.routeFromHAR('
          '${_quote(recordHar['path'] as String)});');
    }
    return formatter.format();
  }

  String generateStandaloneFooter(String? saveStorage) {
    final storageStateLine = saveStorage != null
        ? '\n  await context.storageState({ path: ${_quote(saveStorage)} });'
        : '';
    return '\n  // ---------------------$storageStateLine\n'
        '  await context.close();\n'
        '  await browser.close();\n'
        '})();';
  }
}

String _formatOptions(Map<String, Object?> value, bool hasArguments) {
  final keys = value.keys.where((key) => value[key] != null).toList();
  if (keys.isEmpty) return '';
  return (hasArguments ? ', ' : '') + formatObject(value);
}

String _formatContextOptions(
    Map<String, Object?> contextOptions, String? deviceName, bool isTest) {
  final device = deviceName != null ? deviceDescriptors[deviceName] : null;
  // recordHar is replaced with routeFromHAR in the generated code.
  final options = <String, Object?>{...contextOptions};
  options.remove('recordHar');
  if (device == null) return formatObjectOrVoid(options);
  // Filter out all the properties from the device descriptor.
  var serializedObject =
      formatObjectOrVoid(sanitizeDeviceOptions(device, options));
  // When there are no additional context options, we still want to spread the
  // device inside.
  if (serializedObject.isEmpty) serializedObject = '{\n}';
  final lines = serializedObject.split('\n');
  lines.insert(1, '...devices[${_quote(deviceName!)}],');
  return lines.join('\n');
}

/// The indent-as-you-go formatter the JavaScript and Java generators share.
class JavaScriptFormatter {
  final String _baseIndent = '  ';
  final String _baseOffset;
  List<String> _lines = <String>[];

  JavaScriptFormatter([int offset = 0]) : _baseOffset = ' ' * offset;

  void prepend(String text) {
    final multiline = _isMultilineString(text);
    _lines = [
      ...text.trim().split('\n').map((line) => multiline ? line : line.trim()),
      ..._lines,
    ];
  }

  void add(String text) {
    final multiline = _isMultilineString(text);
    _lines.addAll(
        text.trim().split('\n').map((line) => multiline ? line : line.trim()));
  }

  void newLine() => _lines.add('');

  String format() {
    var spaces = '';
    var previousLine = '';
    return _lines.map((line) {
      if (line.isEmpty) return line;
      if (line.startsWith('}') || line.startsWith(']')) {
        spaces = dedent(spaces, _baseIndent);
      }

      final extraSpaces =
          _kControlFlowRe.hasMatch(previousLine) ? _baseIndent : '';
      previousLine = line;

      final callCarryOver = line.startsWith('.set');
      var out =
          spaces + extraSpaces + (callCarryOver ? _baseIndent : '') + line;
      if (out.endsWith('{') || out.endsWith('[')) spaces += _baseIndent;
      return _baseOffset + out;
    }).join('\n');
  }
}

/// Removes one indent level, tolerating an already empty prefix.
///
/// JavaScript's `substring` clamps; Dart's throws, and the formatters lean on
/// the clamping whenever a closing brace arrives at column zero.
String dedent(String spaces, String indent) =>
    spaces.length >= indent.length ? spaces.substring(indent.length) : '';

final RegExp _kControlFlowRe = RegExp(r'^(for|while|if|try).*\(.*\)$');
final RegExp _kMultilineRe = RegExp(r'`[\S\s]*`');

String _quote(String text) => escapeWithQuotes(text, "'");

/// Renders [text] as a JavaScript template literal, indenting it by [indent]
/// when it spans several lines.
String quoteMultiline(String text, [String indent = '  ']) {
  String escape(String text) => text
      .replaceAll(r'\', r'\\')
      .replaceAll('`', r'\`')
      .replaceAll(r'${', r'\${');
  final lines = text.split('\n');
  if (lines.length == 1) return '`${escape(text)}`';
  return '`\n${lines.map((line) => indent + escape(line).replaceAll(r'${', r'\${')).join('\n')}\n$indent`';
}

bool _isMultilineString(String text) {
  final match = _kMultilineRe.firstMatch(text);
  return match != null && match[0]!.contains('\n');
}

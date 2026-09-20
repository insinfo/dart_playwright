// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/codegen/csharp.ts

import '../locator_generators.dart';
import '../string_utils.dart';
import 'actions.dart';
import 'javascript.dart' show dedent;
import 'language.dart';
import 'types.dart';

/// Generates `Microsoft.Playwright` sources, as a library or for one of the
/// three .NET test runners.
class CSharpLanguageGenerator implements LanguageGenerator {
  @override
  final String id;
  @override
  final String groupName = '.NET C#';
  @override
  final String name;
  @override
  final Language highlighter = Languages.csharp;

  final String _mode;
  final Map<String, String> _pageAliases = <String, String>{};

  CSharpLanguageGenerator(String mode)
      : id = _idFor(mode),
        name = _nameFor(mode),
        _mode = mode;

  static String _idFor(String mode) {
    switch (mode) {
      case 'library':
        return 'csharp';
      case 'mstest':
        return 'csharp-mstest';
      case 'nunit':
        return 'csharp-nunit';
      case 'xunit':
        return 'csharp-xunit';
      default:
        throw ArgumentError('Unknown C# language mode: $mode');
    }
  }

  static String _nameFor(String mode) {
    switch (mode) {
      case 'library':
        return 'Library';
      case 'mstest':
        return 'MSTest';
      case 'nunit':
        return 'NUnit';
      case 'xunit':
        return 'xUnit';
      default:
        throw ArgumentError('Unknown C# language mode: $mode');
    }
  }

  @override
  void reset() => _pageAliases.clear();

  String _pageAlias(String pageGuid) => _pageAliases.putIfAbsent(pageGuid, () {
        var alias = 'page${_pageAliases.isEmpty ? '' : _pageAliases.length}';
        // Outside of the library mode, the first page is a class member and
        // the rest are local variables.
        if (_mode != 'library' && alias == 'page') alias = 'Page';
        return alias;
      });

  @override
  String generateAction(
      ActionInContext actionInContext, LanguageGeneratorOptions options) {
    final action = actionInContext.action;
    // Resolve before the early return, so that pages are named in the order
    // they are opened.
    final pageAlias = _pageAlias(actionInContext.pageGuid);
    if (_mode != 'library' &&
        (action is OpenPageAction || action is ClosesPageAction)) {
      return '';
    }
    final formatter = CSharpFormatter(_mode == 'library' ? 0 : 8);

    if (action is OpenPageAction) {
      formatter.add('var $pageAlias = await context.NewPageAsync();');
      if (action.url.isNotEmpty &&
          action.url != 'about:blank' &&
          action.url != 'chrome://newtab/') {
        formatter.add('await $pageAlias.GotoAsync(${_quote(action.url)});');
      }
      return formatter.format();
    }

    final subject = pageAlias;
    final signals = toSignalMap(actionInContext);

    if (signals.dialog != null) {
      final alias = signals.dialog!.dialogAlias;
      formatter.add(
          '    void ${pageAlias}_Dialog${alias}_EventHandler(object sender, IDialog dialog)\n'
          '      {\n'
          '          Console.WriteLine(\$"Dialog message: {dialog.Message}");\n'
          '          dialog.DismissAsync();\n'
          '          $pageAlias.Dialog -= ${pageAlias}_Dialog${alias}_EventHandler;\n'
          '      }\n'
          '      $pageAlias.Dialog += ${pageAlias}_Dialog${alias}_EventHandler;');
    }

    final lines = <String>[_generateActionCall(subject, actionInContext)];

    if (signals.download != null) {
      lines.insert(
          0,
          'var download${signals.download!.downloadAlias} = await $pageAlias'
          '.RunAndWaitForDownloadAsync(async () =>\n{');
      lines.add('});');
    }

    if (signals.popup != null) {
      final popupAlias = _pageAlias(signals.popup!.popupPageGuid);
      lines.insert(
          0,
          'var $popupAlias = await $pageAlias.RunAndWaitForPopupAsync('
          'async () =>\n{');
      lines.add('});');
    }

    for (final line in lines) {
      formatter.add(line);
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
        return 'await $subject.CloseAsync();';
      case ClickAction():
        final method = action.clickCount == 2 ? 'DblClick' : 'Click';
        final options = toClickOptionsForSourceCode(action);
        if (options.isEmpty) {
          return 'await $subject.${_asLocator(action.selector)}'
              '.${method}Async();';
        }
        final optionsString = _formatObject(options.toMap(), '    ');
        return 'await $subject.${_asLocator(action.selector)}'
            '.${method}Async($optionsString);';
      case HoverAction():
        final optionsString = action.position != null
            ? _formatObject({'position': action.position!.toJson()}, '    ')
            : '';
        return 'await $subject.${_asLocator(action.selector)}'
            '.HoverAsync($optionsString);';
      case CheckAction():
        return 'await $subject.${_asLocator(action.selector)}.CheckAsync();';
      case UncheckAction():
        return 'await $subject.${_asLocator(action.selector)}.UncheckAsync();';
      case FillAction():
        return 'await $subject.${_asLocator(action.selector)}'
            '.FillAsync(${_quote(action.text)});';
      case SetInputFilesAction():
        return 'await $subject.${_asLocator(action.selector)}'
            '.SetInputFilesAsync(${_formatObject(action.files)});';
      case PressAction():
        final modifiers = toKeyboardModifiers(action.modifiers);
        final shortcut = [...modifiers, action.key].join('+');
        return 'await $subject.${_asLocator(action.selector)}'
            '.PressAsync(${_quote(shortcut)});';
      case NavigateAction():
        return 'await $subject.GotoAsync(${_quote(action.url)});';
      case SelectAction():
        return 'await $subject.${_asLocator(action.selector)}'
            '.SelectOptionAsync(${_formatObject(action.options)});';
      case AssertTextAction():
        return 'await Expect($subject.${_asLocator(action.selector)})'
            '.${action.substring ? 'ToContainTextAsync' : 'ToHaveTextAsync'}'
            '(${_quote(action.text)});';
      case AssertCheckedAction():
        return 'await Expect($subject.${_asLocator(action.selector)})'
            '${action.checked ? '' : '.Not'}.ToBeCheckedAsync();';
      case AssertVisibleAction():
        return 'await Expect($subject.${_asLocator(action.selector)})'
            '.ToBeVisibleAsync();';
      case AssertValueAction():
        final assertion = action.value.isNotEmpty
            ? 'ToHaveValueAsync(${_quote(action.value)})'
            : 'ToBeEmptyAsync()';
        return 'await Expect($subject.${_asLocator(action.selector)})'
            '.$assertion;';
      case AssertSnapshotAction():
        return 'await Expect($subject.${_asLocator(action.selector)})'
            '.ToMatchAriaSnapshotAsync(${_quote(action.ariaSnapshot)});';
    }
  }

  String _asLocator(String selector) => asLocator(Languages.csharp, selector);

  @override
  String generateHeader(LanguageGeneratorOptions options) => _mode == 'library'
      ? generateStandaloneHeader(options)
      : generateTestRunnerHeader(options);

  String generateStandaloneHeader(LanguageGeneratorOptions options) {
    final formatter = CSharpFormatter(0);
    formatter.add('''
      using Microsoft.Playwright;
      using System;
      using System.Threading.Tasks;

      using var playwright = await Playwright.CreateAsync();
      await using var browser = await playwright.${_toPascal(options.browserName)}.LaunchAsync(${_formatObject(options.launchOptions, '    ')});
      var context = await browser.NewContextAsync(${_formatContextOptions(options.contextOptions, options.deviceName)});''');
    final recordHar = options.contextOptions['recordHar'] as Map?;
    if (recordHar != null) {
      final url = recordHar['urlFilter'];
      formatter.add('      await context.RouteFromHARAsync('
          '${_quote(recordHar['path'] as String)}'
          '${url != null ? ', ${_formatObject({'url': url}, '    ')}' : ''});');
    }
    formatter.newLine();
    return formatter.format();
  }

  String generateTestRunnerHeader(LanguageGeneratorOptions options) {
    final formatter = CSharpFormatter(0);
    final playwrightNamespace = _mode == 'nunit'
        ? 'NUnit'
        : _mode == 'xunit'
            ? 'Xunit'
            : 'MSTest';
    final classAttributes = _mode == 'nunit'
        ? '[Parallelizable(ParallelScope.Self)]\n      [TestFixture]\n      '
        : _mode == 'mstest'
            ? '[TestClass]\n      '
            : '';
    formatter.add('''
      using Microsoft.Playwright.$playwrightNamespace;
      using Microsoft.Playwright;${_mode == 'xunit' ? '\n      using Xunit;' : ''}

      ${classAttributes}public class Tests : PageTest
      {''');
    final formattedContextOptions =
        _formatContextOptions(options.contextOptions, options.deviceName);
    if (formattedContextOptions.isNotEmpty) {
      formatter
          .add('public override BrowserNewContextOptions ContextOptions()\n'
              '      {\n'
              '          return $formattedContextOptions;\n'
              '      }');
      formatter.newLine();
    }
    final testAttribute = _mode == 'nunit'
        ? 'Test'
        : _mode == 'xunit'
            ? 'Fact'
            : 'TestMethod';
    formatter.add('    [$testAttribute]\n'
        '    public async Task MyTest()\n'
        '    {');
    final recordHar = options.contextOptions['recordHar'] as Map?;
    if (recordHar != null) {
      final url = recordHar['urlFilter'];
      formatter.add('    await Context.RouteFromHARAsync('
          '${_quote(recordHar['path'] as String)}'
          '${url != null ? ', ${_formatObject({'url': url}, '    ')}' : ''});');
    }
    return formatter.format();
  }

  @override
  String generateFooter(String? saveStorage) {
    final offset = _mode == 'library' ? '' : '        ';
    var storageStateLine = saveStorage != null
        ? '\n${offset}await context.StorageStateAsync(new()\n$offset{\n'
            '$offset    Path = ${_quote(saveStorage)}\n$offset});\n'
        : '';
    if (_mode != 'library') storageStateLine += '    }\n}\n';
    return storageStateLine;
  }
}

String _formatObject(Object? value,
    [String indent = '    ', String name = '']) {
  if (value is String) {
    if (const [
      'colorScheme',
      'modifiers',
      'button',
      'recordHarContent',
      'recordHarMode',
      'serviceWorkers'
    ].contains(name)) {
      return '${_getEnumName(name)}.${_toPascal(value)}';
    }
    return _quote(value);
  }
  if (value is List) {
    return 'new[] { ${value.map((o) => _formatObject(o, indent, name)).join(', ')} }';
  }
  if (value is Map) {
    final keys = value.keys
        .map((k) => k.toString())
        .where((key) => value[key] != null)
        .toList()
      ..sort();
    if (keys.isEmpty) return 'new()';
    final tokens = [
      for (final key in keys)
        '${_getPropertyName(key)} = ${_formatObject(value[key], indent, key)},',
    ];
    return 'new()\n{\n$indent${tokens.join('\n$indent')}\n$indent}';
  }
  if (name == 'latitude' || name == 'longitude') return '${value}m';
  return '$value';
}

String _getEnumName(String value) {
  switch (value) {
    case 'modifiers':
      return 'KeyboardModifier';
    case 'button':
      return 'MouseButton';
    case 'recordHarMode':
      return 'HarMode';
    case 'recordHarContent':
      return 'HarContentPolicy';
    case 'serviceWorkers':
      return 'ServiceWorkerPolicy';
    default:
      return _toPascal(value);
  }
}

String _getPropertyName(String key) {
  switch (key) {
    case 'storageState':
      return 'StorageStatePath';
    case 'viewport':
      return 'ViewportSize';
    default:
      return _toPascal(key);
  }
}

String _toPascal(String value) =>
    value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);

String _formatContextOptions(
    Map<String, Object?> contextOptions, String? deviceName) {
  final options = <String, Object?>{...contextOptions};
  // recordHar is replaced with RouteFromHAR in the generated code.
  options.remove('recordHar');
  final device = deviceName != null ? deviceDescriptors[deviceName] : null;
  if (device == null) {
    if (options.isEmpty) return '';
    return _formatObject(options, '    ');
  }

  // If the options are the same as in the device, just use the device.
  if (sanitizeDeviceOptions(device, options).isEmpty) {
    return 'playwright.Devices[${_quote(deviceName!)}]';
  }
  // In C# there is no easy way to merge options, so expand everything.
  options.remove('defaultBrowserType');
  return _formatObject(options, '    ');
}

/// The C# flavour of the indent-as-you-go formatter.
class CSharpFormatter {
  final String _baseIndent = '    ';
  final String _baseOffset;
  List<String> _lines = <String>[];

  CSharpFormatter([int offset = 0]) : _baseOffset = ' ' * offset;

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
    var previousLine = '';
    return _lines.map((line) {
      if (line.isEmpty) return line;
      if (line.startsWith('}') ||
          line.startsWith(']') ||
          line.contains('});') ||
          line == ');') {
        spaces = dedent(spaces, _baseIndent);
      }

      final extraSpaces =
          _kControlFlowRe.hasMatch(previousLine) ? _baseIndent : '';
      previousLine = line;

      var out = spaces + extraSpaces + line;
      if (out.endsWith('{') || out.endsWith('[') || out.endsWith('(')) {
        spaces += _baseIndent;
      }
      if (out.endsWith('));')) spaces = dedent(spaces, _baseIndent);

      return _baseOffset + out;
    }).join('\n');
  }
}

final RegExp _kControlFlowRe = RegExp(r'^(for|while|if).*\(.*\)$');

String _quote(String text) => escapeWithQuotes(text, '"');

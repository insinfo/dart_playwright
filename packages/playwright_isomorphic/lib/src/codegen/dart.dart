// This generator has no upstream counterpart: Playwright ships no Dart
// binding, so nothing here is a translation. It follows the structure of the
// ported generators — same LanguageGenerator contract, same formatter, same
// action switch — and targets this port's own API: `package:playwright` for
// the library flavour and `package:playwright_test` for the test flavour.
//
// The output is meant to compile, not merely to read well: the test
// `dart_codegen_compiles_test.dart` writes a generated file into a temporary
// package and runs `dart analyze` over it.

import '../locator_generators.dart';
import 'actions.dart';
import 'javascript.dart' show JavaScriptFormatter;
import 'language.dart';
import 'types.dart';

/// Which flavour of Dart source to emit.
enum DartLanguageMode {
  /// A `package:test` file driven by `package:playwright_test` fixtures.
  test,

  /// A standalone `main()` that launches a browser itself.
  library,
}

/// Generates sources for this port's Dart API.
class DartLanguageGenerator implements LanguageGenerator {
  @override
  final String id;
  @override
  final String groupName = 'Dart';
  @override
  final String name;
  @override
  final Language highlighter = Languages.dart;

  final DartLanguageMode _mode;
  final Map<String, String> _pageAliases = <String, String>{};

  DartLanguageGenerator(DartLanguageMode mode)
      : id = mode == DartLanguageMode.test ? 'dart-test' : 'dart',
        name = mode == DartLanguageMode.test ? 'Test Runner' : 'Library',
        _mode = mode;

  bool get _isTest => _mode == DartLanguageMode.test;

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
    // In test mode the page comes from the fixture, so opening and closing it
    // is not the test's business.
    if (_isTest && (action is OpenPageAction || action is ClosesPageAction)) {
      return '';
    }

    final formatter = JavaScriptFormatter(_isTest ? 4 : 2);

    if (action is OpenPageAction) {
      formatter.add('final $pageAlias = await context.newPage();');
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
      // Dialogs are auto-dismissed unless something listens, so the listener
      // is what keeps the recorded run reproducible.
      formatter.add('$pageAlias.onDialog.listen((dialog) {\n'
          '  print(\'Dialog message: \${dialog.message}\');\n'
          '  dialog.dismiss().ignore();\n'
          '});');
    }

    if (signals.popup != null) {
      final popupAlias = _pageAlias(signals.popup!.popupPageGuid);
      formatter.add('final ${popupAlias}Future = $pageAlias.onPopup.first;');
    }
    if (signals.download != null) {
      final alias = signals.download!.downloadAlias;
      formatter
          .add('final download${alias}Future = $pageAlias.onDownload.first;');
    }

    formatter.add(_generateActionCall(subject, actionInContext));

    if (signals.popup != null) {
      final popupAlias = _pageAlias(signals.popup!.popupPageGuid);
      formatter.add('final $popupAlias = await ${popupAlias}Future;');
    }
    if (signals.download != null) {
      final alias = signals.download!.downloadAlias;
      formatter.add('final download$alias = await download${alias}Future;');
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
        final args = <String>[];
        if (options.button != null)
          args.add('button: ${_quote(options.button!)}');
        if (options.clickCount != null && method == 'click') {
          args.add('clickCount: ${options.clickCount}');
        }
        if (options.position != null) {
          args.add('position: ${_position(options.position!)}');
        }
        // This port's click takes no modifiers, so they are recorded as a
        // comment rather than dropped silently.
        final modifiers = options.modifiers != null
            ? ' // modifiers: ${options.modifiers!.join('+')}'
            : '';
        return 'await $subject.${_asLocator(action.selector)}'
            '.$method(${args.join(', ')});$modifiers';
      case HoverAction():
        final args = action.position != null
            ? 'position: ${_position(action.position!)}'
            : '';
        return 'await $subject.${_asLocator(action.selector)}.hover($args);';
      case CheckAction():
        return 'await $subject.${_asLocator(action.selector)}.check();';
      case UncheckAction():
        return 'await $subject.${_asLocator(action.selector)}.uncheck();';
      case FillAction():
        return 'await $subject.${_asLocator(action.selector)}'
            '.fill(${_quote(action.text)});';
      case SetInputFilesAction():
        return 'await $subject.${_asLocator(action.selector)}.setInputFiles('
            '${_stringList(action.files)});';
      case PressAction():
        final modifiers = toKeyboardModifiers(action.modifiers);
        final shortcut = [...modifiers, action.key].join('+');
        return 'await $subject.${_asLocator(action.selector)}'
            '.press(${_quote(shortcut)});';
      case NavigateAction():
        return 'await $subject.goto(${_quote(action.url)});';
      case SelectAction():
        final value = action.options.length == 1
            ? _quote(action.options[0])
            : _stringList(action.options);
        return 'await $subject.${_asLocator(action.selector)}'
            '.selectOption($value);';
      case AssertTextAction():
        return '${_assertPrefix}await expectLocator($subject'
            '.${_asLocator(action.selector)})'
            '.${action.substring ? 'toContainText' : 'toHaveText'}'
            '(${_quote(action.text)});';
      case AssertCheckedAction():
        return '${_assertPrefix}await expectLocator($subject'
            '.${_asLocator(action.selector)})'
            '${action.checked ? '' : '.not'}.toBeChecked();';
      case AssertVisibleAction():
        return '${_assertPrefix}await expectLocator($subject'
            '.${_asLocator(action.selector)}).toBeVisible();';
      case AssertValueAction():
        final assertion = action.value.isNotEmpty
            ? 'toHaveValue(${_quote(action.value)})'
            : 'toBeEmpty()';
        return '${_assertPrefix}await expectLocator($subject'
            '.${_asLocator(action.selector)}).$assertion;';
      case AssertSnapshotAction():
        return '${_assertPrefix}await expectLocator($subject'
            '.${_asLocator(action.selector)}).toMatchAriaSnapshot('
            '${_quote(action.ariaSnapshot)});';
    }
  }

  /// Assertions live in `package:playwright_test`, so the library flavour
  /// comments them out the way upstream's JavaScript library flavour does.
  ///
  /// This is also why an aria snapshot is emitted as one escaped line rather
  /// than a triple quoted block: a block would spill past the `//` and stop
  /// compiling, and the formatter would re-indent its lines and change the
  /// snapshot itself.
  String get _assertPrefix => _isTest ? '' : '// ';

  String _asLocator(String selector) => asLocator(Languages.dart, selector);

  @override
  String generateHeader(LanguageGeneratorOptions options) =>
      _isTest ? _generateTestHeader(options) : _generateLibraryHeader(options);

  String _generateTestHeader(LanguageGeneratorOptions options) {
    final formatter = JavaScriptFormatter();
    final storageImports = options.saveStorage != null
        ? "import 'dart:convert';\nimport 'dart:io';\n\n"
        : '';
    formatter.add('''
      ${storageImports}import 'package:playwright_test/playwright_test.dart';

      void main() {
        playwrightTest('test', (t) async {
          final page = t.page;''');
    return formatter.format();
  }

  String _generateLibraryHeader(LanguageGeneratorOptions options) {
    final formatter = JavaScriptFormatter();
    final storageImports = options.saveStorage != null
        ? "import 'dart:convert';\nimport 'dart:io';\n\n"
        : '';
    formatter.add('''
      ${storageImports}import 'package:playwright/playwright.dart';

      Future<void> main() async {
        final playwright = await Playwright.create();
        final browser = await playwright.${options.browserName}.launch(${formatDartLaunchOptions(options.launchOptions)});
        final context = await browser.newContext(${formatDartContextOptions(options.contextOptions)});''');
    return formatter.format();
  }

  @override
  String generateFooter(String? saveStorage) {
    if (_isTest) {
      final storageStateLine = saveStorage != null
          ? '\n    await File(${_quote(saveStorage)}).writeAsString('
              'jsonEncode(await t.context.storageState()));'
          : '';
      return '$storageStateLine\n  });\n}';
    }
    final storageStateLine = saveStorage != null
        ? '\n  await File(${_quote(saveStorage)}).writeAsString('
            'jsonEncode(await context.storageState()));'
        : '';
    return '\n  // ---------------------$storageStateLine\n'
        '  await context.close();\n'
        '  await browser.close();\n'
        '}';
  }
}

String _quote(String text) => dartStringLiteral(text);

String _position(Point point) =>
    '(x: ${_double(point.x)}, y: ${_double(point.y)})';

/// This port's `position` is a record of doubles, so an integer coordinate
/// still has to be written as one.
String _double(num value) => value is int ? '$value.0' : '$value';

String _stringList(List<String> values) => '[${values.map(_quote).join(', ')}]';

/// The launch options this port's `BrowserType.launch` understands.
///
/// The recorder sends a JSON-ish map; only the keys the Dart API has are
/// printed, because an unknown named argument would not compile.
String formatDartLaunchOptions(Map<String, Object?> options) {
  final args = <String>[];
  if (options['headless'] is bool) args.add('headless: ${options['headless']}');
  if (options['channel'] is String) {
    args.add('channel: ${_quote(options['channel'] as String)}');
  }
  if (options['executablePath'] is String) {
    args.add('executablePath: ${_quote(options['executablePath'] as String)}');
  }
  return args.join(', ');
}

/// The context options this port's `Browser.newContext` understands.
String formatDartContextOptions(Map<String, Object?> options) {
  final args = <String>[];
  final viewport = options['viewport'] as Map?;
  if (viewport != null) {
    args.add('viewport: (width: ${viewport['width']}, '
        'height: ${viewport['height']})');
  }
  for (final key in const [
    'userAgent',
    'locale',
    'timezoneId',
    'colorScheme'
  ]) {
    final value = options[key];
    if (value is String) args.add('$key: ${_quote(value)}');
  }
  for (final key in const [
    'acceptDownloads',
    'isMobile',
    'hasTouch',
    'offline'
  ]) {
    final value = options[key];
    if (value is bool) args.add('$key: $value');
  }
  final deviceScaleFactor = options['deviceScaleFactor'];
  if (deviceScaleFactor is num) {
    args.add('deviceScaleFactor: ${_double(deviceScaleFactor)}');
  }
  final geolocation = options['geolocation'] as Map?;
  if (geolocation != null) {
    args.add('geolocation: (latitude: '
        '${_double(geolocation['latitude'] as num)}, longitude: '
        '${_double(geolocation['longitude'] as num)}, accuracy: '
        '${_double((geolocation['accuracy'] as num?) ?? 0)})');
  }
  final permissions = options['permissions'];
  if (permissions is List) {
    args.add('permissions: ${_stringList(permissions.cast<String>())}');
  }
  return args.join(', ');
}

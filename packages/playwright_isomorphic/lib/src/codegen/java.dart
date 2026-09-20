// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/codegen/java.ts

import '../locator_generators.dart';
import '../string_utils.dart';
import 'actions.dart';
import 'javascript.dart' show JavaScriptFormatter;
import 'language.dart';
import 'types.dart';

/// Generates `playwright-java` sources, as a library or as a JUnit test.
class JavaLanguageGenerator implements LanguageGenerator {
  @override
  final String id;
  @override
  final String groupName = 'Java';
  @override
  final String name;
  @override
  final Language highlighter = Languages.java;

  final String _mode;
  final Map<String, String> _pageAliases = <String, String>{};

  JavaLanguageGenerator(String mode)
      : id = mode == 'library'
            ? 'java'
            : mode == 'junit'
                ? 'java-junit'
                : throw ArgumentError('Unknown Java language mode: $mode'),
        name = mode == 'library' ? 'Library' : 'JUnit',
        _mode = mode;

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
    final offset = _mode == 'junit' ? 4 : 6;
    final formatter = JavaScriptFormatter(offset);

    if (_mode != 'library' &&
        (action is OpenPageAction || action is ClosesPageAction)) {
      return '';
    }

    if (action is OpenPageAction) {
      formatter.add('Page $pageAlias = context.newPage();');
      if (action.url.isNotEmpty &&
          action.url != 'about:blank' &&
          action.url != 'chrome://newtab/') {
        formatter.add('$pageAlias.navigate(${_quote(action.url)});');
      }
      return formatter.format();
    }

    final subject = pageAlias;
    final signals = toSignalMap(actionInContext);

    if (signals.dialog != null) {
      formatter.add('  $pageAlias.onceDialog(dialog -> {\n'
          '        System.out.println(String.format("Dialog message: %s", dialog.message()));\n'
          '        dialog.dismiss();\n'
          '      });');
    }

    var code = _generateActionCall(subject, actionInContext);

    if (signals.popup != null) {
      final popupAlias = _pageAlias(signals.popup!.popupPageGuid);
      code = 'Page $popupAlias = $pageAlias.waitForPopup(() -> {\n'
          '        $code\n'
          '      });';
    }

    if (signals.download != null) {
      final alias = signals.download!.downloadAlias;
      code = 'Download download$alias = $pageAlias.waitForDownload(() -> {\n'
          '        $code\n'
          '      });';
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
        return '$subject.close();';
      case ClickAction():
        final method = action.clickCount == 2 ? 'dblclick' : 'click';
        final options = toClickOptionsForSourceCode(action);
        final optionsText = _formatClickOptions(options);
        return '$subject.${_asLocator(action.selector)}.$method($optionsText);';
      case HoverAction():
        final optionsText = action.position != null
            ? 'new Locator.HoverOptions().setPosition('
                '${action.position!.x}, ${action.position!.y})'
            : '';
        return '$subject.${_asLocator(action.selector)}.hover($optionsText);';
      case CheckAction():
        return '$subject.${_asLocator(action.selector)}.check();';
      case UncheckAction():
        return '$subject.${_asLocator(action.selector)}.uncheck();';
      case FillAction():
        return '$subject.${_asLocator(action.selector)}'
            '.fill(${_quote(action.text)});';
      case SetInputFilesAction():
        return '$subject.${_asLocator(action.selector)}.setInputFiles('
            '${_formatPath(action.files)});';
      case PressAction():
        final modifiers = toKeyboardModifiers(action.modifiers);
        final shortcut = [...modifiers, action.key].join('+');
        return '$subject.${_asLocator(action.selector)}'
            '.press(${_quote(shortcut)});';
      case NavigateAction():
        return '$subject.navigate(${_quote(action.url)});';
      case SelectAction():
        return '$subject.${_asLocator(action.selector)}.selectOption('
            '${_formatSelectOption(action.options)});';
      case AssertTextAction():
        return 'assertThat($subject.${_asLocator(action.selector)})'
            '.${action.substring ? 'containsText' : 'hasText'}'
            '(${_quote(action.text)});';
      case AssertCheckedAction():
        return 'assertThat($subject.${_asLocator(action.selector)})'
            '${action.checked ? '' : '.not()'}.isChecked();';
      case AssertVisibleAction():
        return 'assertThat($subject.${_asLocator(action.selector)})'
            '.isVisible();';
      case AssertValueAction():
        final assertion = action.value.isNotEmpty
            ? 'hasValue(${_quote(action.value)})'
            : 'isEmpty()';
        return 'assertThat($subject.${_asLocator(action.selector)})'
            '.$assertion;';
      case AssertSnapshotAction():
        return 'assertThat($subject.${_asLocator(action.selector)})'
            '.matchesAriaSnapshot(${_quote(action.ariaSnapshot)});';
    }
  }

  String _asLocator(String selector) => asLocator(Languages.java, selector);

  @override
  String generateHeader(LanguageGeneratorOptions options) {
    final formatter = JavaScriptFormatter();
    final recordHar = options.contextOptions['recordHar'] as Map?;
    if (_mode == 'junit') {
      formatter.add('''
      import com.microsoft.playwright.junit.UsePlaywright;
      import com.microsoft.playwright.Page;
      import com.microsoft.playwright.options.*;

      ${recordHar != null ? 'import java.nio.file.Paths;\n' : ''}import org.junit.jupiter.api.*;
      import static com.microsoft.playwright.assertions.PlaywrightAssertions.*;

      @UsePlaywright
      public class TestExample {
        @Test
        void test(Page page) {''');
      if (recordHar != null) {
        final url = recordHar['urlFilter'];
        final recordHarOptions = url is String
            ? ', new Page.RouteFromHAROptions()\n            .setUrl(${_quote(url)})'
            : '';
        formatter.add('          page.routeFromHAR(Paths.get('
            '${_quote(recordHar['path'] as String)})$recordHarOptions);');
      }
      return formatter.format();
    }
    formatter.add('''
    import com.microsoft.playwright.*;
    import com.microsoft.playwright.options.*;
    import static com.microsoft.playwright.assertions.PlaywrightAssertions.assertThat;
    ${recordHar != null ? 'import java.nio.file.Paths;\n' : ''}import java.util.*;

    public class Example {
      public static void main(String[] args) {
        try (Playwright playwright = Playwright.create()) {
          Browser browser = playwright.${options.browserName}().launch(${_formatLaunchOptions(options.launchOptions)});
          BrowserContext context = browser.newContext(${_formatContextOptions(options.contextOptions, options.deviceName)});''');
    if (recordHar != null) {
      final url = recordHar['urlFilter'];
      final recordHarOptions = url is String
          ? ', new BrowserContext.RouteFromHAROptions()\n          .setUrl(${_quote(url)})'
          : '';
      formatter.add('          context.routeFromHAR(Paths.get('
          '${_quote(recordHar['path'] as String)})$recordHarOptions);');
    }
    return formatter.format();
  }

  @override
  String generateFooter(String? saveStorage) {
    final storageStateLine = saveStorage != null
        ? '\n      context.storageState(new BrowserContext.StorageStateOptions()'
            '.setPath(${_quote(saveStorage)}));\n'
        : '';
    if (_mode == 'junit') return '$storageStateLine  }\n}';
    return '$storageStateLine    }\n  }\n}';
  }
}

String _formatPath(List<String> files) {
  if (files.length == 1) return 'Paths.get(${_quote(files[0])})';
  if (files.isEmpty) return 'new Path[0]';
  return 'new Path[] {${files.map((s) => 'Paths.get(${_quote(s)})').join(', ')}}';
}

String _formatSelectOption(List<String> options) {
  if (options.length == 1) return _quote(options[0]);
  if (options.isEmpty) return 'new String[0]';
  return 'new String[] {${options.map(_quote).join(', ')}}';
}

String _formatLaunchOptions(Map<String, Object?> options) {
  final lines = <String>[];
  if (options.keys.where((key) => options[key] != null).isEmpty) return '';
  lines.add('new BrowserType.LaunchOptions()');
  if (options['channel'] != null) {
    lines.add('  .setChannel(${_quote(options['channel'] as String)})');
  }
  if (options['headless'] is bool) lines.add('  .setHeadless(false)');
  return lines.join('\n');
}

String _formatContextOptions(
    Map<String, Object?> contextOptions, String? deviceName) {
  final lines = <String>[];
  if (contextOptions.isEmpty && deviceName == null) return '';
  final device =
      deviceName != null ? (deviceDescriptors[deviceName] ?? {}) : {};
  final options = <String, Object?>{...device, ...contextOptions};
  lines.add('new Browser.NewContextOptions()');
  if (options['acceptDownloads'] == true) {
    lines.add('  .setAcceptDownloads(true)');
  }
  if (options['bypassCSP'] == true) lines.add('  .setBypassCSP(true)');
  if (options['colorScheme'] != null) {
    lines.add('  .setColorScheme(ColorScheme.'
        '${(options['colorScheme'] as String).toUpperCase()})');
  }
  if (options['deviceScaleFactor'] != null) {
    lines.add('  .setDeviceScaleFactor(${options['deviceScaleFactor']})');
  }
  final geolocation = options['geolocation'] as Map?;
  if (geolocation != null) {
    lines.add('  .setGeolocation(${geolocation['latitude']}, '
        '${geolocation['longitude']})');
  }
  if (options['hasTouch'] == true) {
    lines.add('  .setHasTouch(${options['hasTouch']})');
  }
  if (options['isMobile'] == true) {
    lines.add('  .setIsMobile(${options['isMobile']})');
  }
  if (options['locale'] != null) {
    lines.add('  .setLocale(${_quote(options['locale'] as String)})');
  }
  final proxy = options['proxy'] as Map?;
  if (proxy != null) {
    lines.add('  .setProxy(new Proxy(${_quote(proxy['server'] as String)}))');
  }
  if (options['serviceWorkers'] != null) {
    lines.add('  .setServiceWorkers(ServiceWorkerPolicy.'
        '${(options['serviceWorkers'] as String).toUpperCase()})');
  }
  if (options['storageState'] != null) {
    lines.add('  .setStorageStatePath(Paths.get('
        '${_quote(options['storageState'] as String)}))');
  }
  if (options['timezoneId'] != null) {
    lines.add('  .setTimezoneId(${_quote(options['timezoneId'] as String)})');
  }
  if (options['userAgent'] != null) {
    lines.add('  .setUserAgent(${_quote(options['userAgent'] as String)})');
  }
  final viewport = options['viewport'] as Map?;
  if (viewport != null) {
    lines.add('  .setViewportSize(${viewport['width']}, '
        '${viewport['height']})');
  }
  return lines.join('\n');
}

String _formatClickOptions(MouseClickOptions options) {
  final lines = <String>[];
  if (options.button != null) {
    lines.add('  .setButton(MouseButton.${options.button!.toUpperCase()})');
  }
  if (options.modifiers != null) {
    lines.add('  .setModifiers(Arrays.asList('
        '${options.modifiers!.map((m) => 'KeyboardModifier.${m.toUpperCase()}').join(', ')}))');
  }
  if (options.clickCount != null) {
    lines.add('  .setClickCount(${options.clickCount})');
  }
  if (options.position != null) {
    lines.add('  .setPosition(${options.position!.x}, '
        '${options.position!.y})');
  }
  if (lines.isEmpty) return '';
  return 'new Locator.ClickOptions()\n${lines.join('\n')}';
}

String _quote(String text) => escapeWithQuotes(text, '"');

// The expected sources here are transcribed from upstream's
// referencias/playwright-typescript/tests/library/inspector/cli-codegen-*.ts,
// which drive the real recorder. Here the same actions are fed to the
// generators directly, which needs no browser.

import 'package:playwright_isomorphic/playwright_isomorphic.dart';
import 'package:test/test.dart';

const _url = 'http://localhost:1234/empty.html';

const _options = LanguageGeneratorOptions(
  browserName: 'chromium',
  launchOptions: {'headless': false},
  contextOptions: {},
);

ActionInContext _open() => ActionInContext(
    pageGuid: 'page@1', action: OpenPageAction(url: _url), signals: const []);

ActionInContext _act(Action action) =>
    ActionInContext(pageGuid: 'page@1', action: action, signals: const []);

String _generate(LanguageGenerator generator, List<ActionInContext> actions,
        [LanguageGeneratorOptions options = _options]) =>
    generateCode(actions, generator, options).text;

void main() {
  group('javascript', () {
    test('imports and context options', () {
      expect(_generate(JavaScriptLanguageGenerator(false), [_open()]),
          '''const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch({
    headless: false
  });
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto('$_url');

  // ---------------------
  await context.close();
  await browser.close();
})();''');
    });

    test('context options for custom settings', () {
      expect(
          _generate(
              JavaScriptLanguageGenerator(false),
              [],
              const LanguageGeneratorOptions(
                browserName: 'chromium',
                launchOptions: {'headless': false},
                contextOptions: {'colorScheme': 'light'},
              )),
          contains('''  const context = await browser.newContext({
    colorScheme: 'light'
  });'''));
    });

    test('test runner header', () {
      expect(JavaScriptLanguageGenerator(true).generateHeader(_options),
          '''import { test, expect } from '@playwright/test';

test('test', async ({ page }) => {''');
      expect(JavaScriptLanguageGenerator(true).generateFooter(null), '});');
    });

    test('actions', () {
      final generator = JavaScriptLanguageGenerator(false);
      generator.reset();
      expect(
          generator.generateAction(
              _act(ClickAction(
                  selector: 'internal:role=button[name="Submit"i]')),
              _options),
          "  await page.getByRole('button', { name: 'Submit' }).click();");
      expect(
          generator.generateAction(
              _act(ClickAction(
                  selector: 'internal:role=button[name="Submit"i]',
                  clickCount: 2)),
              _options),
          "  await page.getByRole('button', { name: 'Submit' }).dblclick();");
      expect(
          generator.generateAction(
              _act(ClickAction(
                  selector: 'canvas', position: const Point(250, 250))),
              _options),
          '''  await page.locator('canvas').click({
    position: {
      x: 250,
      y: 250
    }
  });''');
      expect(
          generator.generateAction(
              _act(FillAction(selector: '#input', text: 'John')), _options),
          "  await page.locator('#input').fill('John');");
      expect(
          generator.generateAction(
              _act(PressAction(
                  selector: 'internal:role=textbox',
                  key: 'Enter',
                  modifiers: 8)),
              _options),
          "  await page.getByRole('textbox').press('Shift+Enter');");
    });
  });

  group('python', () {
    test('sync header', () {
      expect(PythonLanguageGenerator(false, false).generateHeader(_options),
          '''import re
from playwright.sync_api import Playwright, sync_playwright, expect


def run(playwright: Playwright) -> None:
    browser = playwright.chromium.launch(headless=False)
    context = browser.new_context()''');
    });

    test('async header', () {
      expect(PythonLanguageGenerator(true, false).generateHeader(_options),
          '''import asyncio
import re
from playwright.async_api import Playwright, async_playwright, expect


async def run(playwright: Playwright) -> None:
    browser = await playwright.chromium.launch(headless=False)
    context = await browser.new_context()''');
    });

    test('pytest header', () {
      expect(PythonLanguageGenerator(false, true).generateHeader(_options),
          '''import re
from playwright.sync_api import Page, expect


def test_example(page: Page) -> None:''');
    });

    test('context options for custom settings', () {
      expect(
          PythonLanguageGenerator(false, false).generateHeader(
              const LanguageGeneratorOptions(
                  browserName: 'chromium',
                  launchOptions: {'headless': false},
                  contextOptions: {'colorScheme': 'light'})),
          contains('    context = browser.new_context(color_scheme="light")'));
    });

    test('actions', () {
      final sync = PythonLanguageGenerator(false, false)..reset();
      expect(
          sync.generateAction(
              _act(ClickAction(
                  selector: 'internal:role=button[name="Submit"i]')),
              _options),
          '    page.get_by_role("button", name="Submit").click()');
      expect(
          sync.generateAction(
              _act(ClickAction(
                  selector: 'canvas', position: const Point(250, 250))),
              _options),
          '    page.locator("canvas").click(position={"x":250,"y":250})');
      expect(
          sync.generateAction(
              _act(PressAction(
                  selector: 'internal:role=textbox',
                  key: 'Enter',
                  modifiers: 8)),
              _options),
          '    page.get_by_role("textbox").press("Shift+Enter")');

      final async = PythonLanguageGenerator(true, false)..reset();
      expect(
          async.generateAction(
              _act(ClickAction(
                  selector: 'internal:role=button[name="Submit"i]')),
              _options),
          '    await page.get_by_role("button", name="Submit").click()');
    });
  });

  group('java', () {
    test('imports and context options', () {
      expect(JavaLanguageGenerator('library').generateHeader(_options),
          '''import com.microsoft.playwright.*;
import com.microsoft.playwright.options.*;
import static com.microsoft.playwright.assertions.PlaywrightAssertions.assertThat;
import java.util.*;

public class Example {
  public static void main(String[] args) {
    try (Playwright playwright = Playwright.create()) {
      Browser browser = playwright.chromium().launch(new BrowserType.LaunchOptions()
        .setHeadless(false));
      BrowserContext context = browser.newContext();''');
    });

    test('context options for custom settings', () {
      expect(
          JavaLanguageGenerator('library').generateHeader(
              const LanguageGeneratorOptions(
                  browserName: 'chromium',
                  launchOptions: {'headless': false},
                  contextOptions: {'colorScheme': 'light'})),
          contains(
              '''      BrowserContext context = browser.newContext(new Browser.NewContextOptions()
        .setColorScheme(ColorScheme.LIGHT));'''));
    });

    test('actions', () {
      final generator = JavaLanguageGenerator('library')..reset();
      expect(
          generator.generateAction(
              _act(ClickAction(
                  selector: 'internal:role=button[name="Submit"i]')),
              _options),
          '      page.getByRole(AriaRole.BUTTON, new Page.GetByRoleOptions().setName("Submit")).click();');
      expect(
          generator.generateAction(
              _act(ClickAction(
                  selector: 'canvas', position: const Point(250, 250))),
              _options),
          '''      page.locator("canvas").click(new Locator.ClickOptions()
        .setPosition(250, 250));''');
      expect(
          generator.generateAction(
              _act(PressAction(
                  selector: 'internal:role=textbox',
                  key: 'Enter',
                  modifiers: 8)),
              _options),
          '      page.getByRole(AriaRole.TEXTBOX).press("Shift+Enter");');
    });
  });

  group('csharp', () {
    test('imports and context options', () {
      expect(CSharpLanguageGenerator('library').generateHeader(_options),
          '''using Microsoft.Playwright;
using System;
using System.Threading.Tasks;

using var playwright = await Playwright.CreateAsync();
await using var browser = await playwright.Chromium.LaunchAsync(new()
{
    Headless = false,
});
var context = await browser.NewContextAsync();
''');
    });

    test('actions', () {
      final generator = CSharpLanguageGenerator('library')..reset();
      expect(
          generator.generateAction(
              _act(ClickAction(
                  selector: 'internal:role=button[name="Submit"i]')),
              _options),
          'await page.GetByRole(AriaRole.Button, new() { Name = "Submit" }).ClickAsync();');
      expect(
          generator.generateAction(
              _act(ClickAction(
                  selector: 'canvas', position: const Point(250, 250))),
              _options),
          '''await page.Locator("canvas").ClickAsync(new()
{
    Position = new()
    {
        X = 250,
        Y = 250,
    },
});''');
      expect(
          generator.generateAction(
              _act(PressAction(
                  selector: 'internal:role=textbox',
                  key: 'Enter',
                  modifiers: 8)),
              _options),
          'await page.GetByRole(AriaRole.Textbox).PressAsync("Shift+Enter");');
    });
  });

  group('jsonl', () {
    test('header and actions', () {
      final generator = JsonlLanguageGenerator()..reset();
      expect(generator.generateHeader(_options),
          '{"browserName":"chromium","launchOptions":{"headless":false},"contextOptions":{}}');
      expect(
          generator.generateAction(
              _act(FillAction(selector: '#input', text: 'John')), _options),
          '{"name":"fill","selector":"#input","text":"John","signals":[],'
          '"pageGuid":"page@1","locator":{"kind":"default","body":"#input",'
          '"options":{}}}');
      expect(generator.generateFooter(null), '');
    });
  });

  test('language set covers every generator id', () {
    expect(languageSet().map((g) => g.id).toList(), [
      'dart-test',
      'dart',
      'playwright-test',
      'javascript',
      'python-pytest',
      'python',
      'python-async',
      'csharp-mstest',
      'csharp-nunit',
      'csharp-xunit',
      'csharp',
      'java-junit',
      'java',
      'jsonl',
    ]);
  });

  test('keyboard modifiers round trip', () {
    expect(toKeyboardModifiers(0), <String>[]);
    expect(toKeyboardModifiers(1), ['Alt']);
    expect(toKeyboardModifiers(2), ['ControlOrMeta']);
    expect(toKeyboardModifiers(4), ['ControlOrMeta']);
    expect(toKeyboardModifiers(8), ['Shift']);
    expect(toKeyboardModifiers(9), ['Alt', 'Shift']);
    expect(fromKeyboardModifiers(['Alt', 'Shift']), 9);
    expect(fromKeyboardModifiers(['Control']), 2);
    expect(fromKeyboardModifiers(['Meta']), 4);
    expect(fromKeyboardModifiers(null), 0);
  });

  test('sanitizeDeviceOptions drops what the device already sets', () {
    expect(
        sanitizeDeviceOptions({'isMobile': true, 'hasTouch': true},
            {'isMobile': true, 'colorScheme': 'light'}),
        {'colorScheme': 'light'});
  });
}

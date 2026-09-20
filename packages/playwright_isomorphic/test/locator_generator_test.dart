// The cases here are transcribed from upstream's
// referencias/playwright-typescript/tests/library/locator-generator.spec.ts.
// Upstream builds the selectors by calling page.getByX(); this port builds
// the same strings with locator_utils, which needs no browser and tests that
// layer at the same time.

import 'dart:convert';

import 'package:playwright_isomorphic/playwright_isomorphic.dart';
import 'package:test/test.dart';

const _langs = ['javascript', 'python', 'java', 'csharp'];

/// Renders [selector] in the four upstream languages and asserts that every
/// rendering parses back to the same selector.
Map<String, String> generate(String selector) {
  final result = <String, String>{};
  for (final lang in _langs) {
    final locatorString = asLocator(lang, selector);
    expect(locatorOrSelectorAsSelector(lang, locatorString, 'data-testid'),
        selector,
        reason: '$lang round trip of $locatorString');
    result[lang] = locatorString;
  }
  return result;
}

String testId(Object value) => getByTestIdSelector('data-testid', value);
String text(Object value, {bool exact = false}) =>
    getByTextSelector(value, exact: exact);
String label(Object value, {bool exact = false}) =>
    getByLabelSelector(value, exact: exact);
String placeholder(Object value, {bool exact = false}) =>
    getByPlaceholderSelector(value, exact: exact);
String alt(Object value, {bool exact = false}) =>
    getByAltTextSelector(value, exact: exact);
String title(Object value, {bool exact = false}) =>
    getByTitleSelector(value, exact: exact);
String role(String name, [ByRoleOptions options = const ByRoleOptions()]) =>
    getByRoleSelector(name, options);
String hasText(Object value, {bool exact = false}) =>
    'internal:has-text=${escapeForTextSelector(value, exact)}';
String hasNotText(Object value, {bool exact = false}) =>
    'internal:has-not-text=${escapeForTextSelector(value, exact)}';
String has(String inner) => 'internal:has=${jsonEncode(inner)}';
String hasNot(String inner) => 'internal:has-not=${jsonEncode(inner)}';
String chain(List<String> parts) => parts.join(' >> ');

const enterFrame = 'internal:control=enter-frame';
const anyFrame = 'internal:control=any-frame';

void main() {
  group('reverse engineer locators', () {
    test('getByTestId', () {
      expect(generate(testId('Hello')), {
        'javascript': "getByTestId('Hello')",
        'python': 'get_by_test_id("Hello")',
        'java': 'getByTestId("Hello")',
        'csharp': 'GetByTestId("Hello")',
      });

      expect(generate(testId('He"llo')), {
        'javascript': 'getByTestId(\'He"llo\')',
        'python': 'get_by_test_id("He\\"llo")',
        'java': 'getByTestId("He\\"llo")',
        'csharp': 'GetByTestId("He\\"llo")',
      });

      expect(generate(testId(JsRegExp('He"llo'))), {
        'javascript': 'getByTestId(/He"llo/)',
        'python': 'get_by_test_id(re.compile(r"He\\"llo"))',
        'java': 'getByTestId(Pattern.compile("He\\"llo"))',
        'csharp': 'GetByTestId(new Regex("He\\"llo"))',
      });

      expect(generate(testId(JsRegExp(r'He\\"llo'))), {
        'javascript': r'getByTestId(/He\\"llo/)',
        'python': r'get_by_test_id(re.compile(r"He\\\"llo"))',
        'java': r'getByTestId(Pattern.compile("He\\\\\"llo"))',
        'csharp': r'GetByTestId(new Regex("He\\\\\"llo"))',
      });
    });

    test('getByText, getByLabel', () {
      expect(generate(text('Hello', exact: true)), {
        'csharp': 'GetByText("Hello", new() { Exact = true })',
        'java':
            'getByText("Hello", new Page.GetByTextOptions().setExact(true))',
        'javascript': "getByText('Hello', { exact: true })",
        'python': 'get_by_text("Hello", exact=True)',
      });

      expect(generate(text('Hello')), {
        'csharp': 'GetByText("Hello")',
        'java': 'getByText("Hello")',
        'javascript': "getByText('Hello')",
        'python': 'get_by_text("Hello")',
      });

      expect(generate(text(JsRegExp('Hello'))), {
        'csharp': 'GetByText(new Regex("Hello"))',
        'java': 'getByText(Pattern.compile("Hello"))',
        'javascript': 'getByText(/Hello/)',
        'python': 'get_by_text(re.compile(r"Hello"))',
      });

      expect(generate(label('Name')), {
        'csharp': 'GetByLabel("Name")',
        'java': 'getByLabel("Name")',
        'javascript': "getByLabel('Name')",
        'python': 'get_by_label("Name")',
      });

      expect(generate(label('Last Name', exact: true)), {
        'csharp': 'GetByLabel("Last Name", new() { Exact = true })',
        'java':
            'getByLabel("Last Name", new Page.GetByLabelOptions().setExact(true))',
        'javascript': "getByLabel('Last Name', { exact: true })",
        'python': 'get_by_label("Last Name", exact=True)',
      });

      expect(generate(label(JsRegExp(r'Last\s+name', 'i'))), {
        'csharp':
            r'GetByLabel(new Regex("Last\\s+name", RegexOptions.IgnoreCase))',
        'java':
            r'getByLabel(Pattern.compile("Last\\s+name", Pattern.CASE_INSENSITIVE))',
        'javascript': r'getByLabel(/Last\s+name/i)',
        'python': r'get_by_label(re.compile(r"Last\s+name", re.IGNORECASE))',
      });
    });

    test('getByPlaceholder, getByAltText, getByTitle', () {
      expect(generate(placeholder('hello')), {
        'csharp': 'GetByPlaceholder("hello")',
        'java': 'getByPlaceholder("hello")',
        'javascript': "getByPlaceholder('hello')",
        'python': 'get_by_placeholder("hello")',
      });
      expect(generate(placeholder('Hello', exact: true)), {
        'csharp': 'GetByPlaceholder("Hello", new() { Exact = true })',
        'java':
            'getByPlaceholder("Hello", new Page.GetByPlaceholderOptions().setExact(true))',
        'javascript': "getByPlaceholder('Hello', { exact: true })",
        'python': 'get_by_placeholder("Hello", exact=True)',
      });
      expect(generate(placeholder(JsRegExp('wor', 'i'))), {
        'csharp': 'GetByPlaceholder(new Regex("wor", RegexOptions.IgnoreCase))',
        'java':
            'getByPlaceholder(Pattern.compile("wor", Pattern.CASE_INSENSITIVE))',
        'javascript': 'getByPlaceholder(/wor/i)',
        'python': 'get_by_placeholder(re.compile(r"wor", re.IGNORECASE))',
      });

      expect(generate(alt('hello')), {
        'csharp': 'GetByAltText("hello")',
        'java': 'getByAltText("hello")',
        'javascript': "getByAltText('hello')",
        'python': 'get_by_alt_text("hello")',
      });
      expect(generate(alt('Hello', exact: true)), {
        'csharp': 'GetByAltText("Hello", new() { Exact = true })',
        'java':
            'getByAltText("Hello", new Page.GetByAltTextOptions().setExact(true))',
        'javascript': "getByAltText('Hello', { exact: true })",
        'python': 'get_by_alt_text("Hello", exact=True)',
      });
      expect(generate(alt(JsRegExp('wor', 'i'))), {
        'csharp': 'GetByAltText(new Regex("wor", RegexOptions.IgnoreCase))',
        'java':
            'getByAltText(Pattern.compile("wor", Pattern.CASE_INSENSITIVE))',
        'javascript': 'getByAltText(/wor/i)',
        'python': 'get_by_alt_text(re.compile(r"wor", re.IGNORECASE))',
      });

      expect(generate(title('hello')), {
        'csharp': 'GetByTitle("hello")',
        'java': 'getByTitle("hello")',
        'javascript': "getByTitle('hello')",
        'python': 'get_by_title("hello")',
      });
      expect(generate(title('Hello', exact: true)), {
        'csharp': 'GetByTitle("Hello", new() { Exact = true })',
        'java':
            'getByTitle("Hello", new Page.GetByTitleOptions().setExact(true))',
        'javascript': "getByTitle('Hello', { exact: true })",
        'python': 'get_by_title("Hello", exact=True)',
      });
      expect(generate(title(JsRegExp('wor', 'i'))), {
        'csharp': 'GetByTitle(new Regex("wor", RegexOptions.IgnoreCase))',
        'java': 'getByTitle(Pattern.compile("wor", Pattern.CASE_INSENSITIVE))',
        'javascript': 'getByTitle(/wor/i)',
        'python': 'get_by_title(re.compile(r"wor", re.IGNORECASE))',
      });
    });

    test('multiline and quoted text', () {
      expect(generate(placeholder('hello my\nwo"rld')), {
        'csharp': 'GetByPlaceholder("hello my\\nwo\\"rld")',
        'java': 'getByPlaceholder("hello my\\nwo\\"rld")',
        'javascript': "getByPlaceholder('hello my\\nwo\"rld')",
        'python': 'get_by_placeholder("hello my\\nwo\\"rld")',
      });
      expect(generate(alt('hello my\nwo"rld')), {
        'csharp': 'GetByAltText("hello my\\nwo\\"rld")',
        'java': 'getByAltText("hello my\\nwo\\"rld")',
        'javascript': "getByAltText('hello my\\nwo\"rld')",
        'python': 'get_by_alt_text("hello my\\nwo\\"rld")',
      });
      expect(generate(title('hello my\nwo"rld')), {
        'csharp': 'GetByTitle("hello my\\nwo\\"rld")',
        'java': 'getByTitle("hello my\\nwo\\"rld")',
        'javascript': "getByTitle('hello my\\nwo\"rld')",
        'python': 'get_by_title("hello my\\nwo\\"rld")',
      });
    });
  });

  test('reverse engineer getByRole', () {
    expect(generate(role('button')), {
      'javascript': "getByRole('button')",
      'python': 'get_by_role("button")',
      'java': 'getByRole(AriaRole.BUTTON)',
      'csharp': 'GetByRole(AriaRole.Button)',
    });
    expect(generate(role('heading')), {
      'javascript': "getByRole('heading')",
      'python': 'get_by_role("heading")',
      'java': 'getByRole(AriaRole.HEADING)',
      'csharp': 'GetByRole(AriaRole.Heading)',
    });
    expect(generate(role('button', const ByRoleOptions(name: 'Hello'))), {
      'javascript': "getByRole('button', { name: 'Hello' })",
      'python': 'get_by_role("button", name="Hello")',
      'java':
          'getByRole(AriaRole.BUTTON, new Page.GetByRoleOptions().setName("Hello"))',
      'csharp': 'GetByRole(AriaRole.Button, new() { Name = "Hello" })',
    });
    expect(generate(role('button', ByRoleOptions(name: JsRegExp('Hello')))), {
      'javascript': "getByRole('button', { name: /Hello/ })",
      'python': 'get_by_role("button", name=re.compile(r"Hello"))',
      'java':
          'getByRole(AriaRole.BUTTON, new Page.GetByRoleOptions().setName(Pattern.compile("Hello")))',
      'csharp':
          'GetByRole(AriaRole.Button, new() { NameRegex = new Regex("Hello") })',
    });
    expect(
        generate(
            role('button', const ByRoleOptions(name: 'He"llo', exact: true))),
        {
          'javascript':
              'getByRole(\'button\', { name: \'He"llo\', exact: true })',
          'python': 'get_by_role("button", name="He\\"llo", exact=True)',
          'java':
              'getByRole(AriaRole.BUTTON, new Page.GetByRoleOptions().setName("He\\"llo").setExact(true))',
          'csharp':
              'GetByRole(AriaRole.Button, new() { Name = "He\\"llo", Exact = true })',
        });
    expect(
        generate(role('button',
            const ByRoleOptions(checked: true, pressed: false, level: 3))),
        {
          'javascript':
              "getByRole('button', { checked: true, level: 3, pressed: false })",
          'python':
              'get_by_role("button", checked=True, level=3, pressed=False)',
          'java':
              'getByRole(AriaRole.BUTTON, new Page.GetByRoleOptions().setChecked(true).setLevel(3).setPressed(false))',
          'csharp':
              'GetByRole(AriaRole.Button, new() { Checked = true, Level = 3, Pressed = false })',
        });
    expect(
        generate(role('alert',
            const ByRoleOptions(name: 'Upload', description: 'doc.pdf'))),
        {
          'javascript':
              "getByRole('alert', { name: 'Upload', description: 'doc.pdf' })",
          'python':
              'get_by_role("alert", name="Upload", description="doc.pdf")',
          'java':
              'getByRole(AriaRole.ALERT, new Page.GetByRoleOptions().setName("Upload").setDescription("doc.pdf"))',
          'csharp':
              'GetByRole(AriaRole.Alert, new() { Name = "Upload", Description = "doc.pdf" })',
        });
    expect(
        generate(role('alert', const ByRoleOptions(description: 'doc.pdf'))), {
      'javascript': "getByRole('alert', { description: 'doc.pdf' })",
      'python': 'get_by_role("alert", description="doc.pdf")',
      'java':
          'getByRole(AriaRole.ALERT, new Page.GetByRoleOptions().setDescription("doc.pdf"))',
      'csharp': 'GetByRole(AriaRole.Alert, new() { Description = "doc.pdf" })',
    });
    expect(
        generate(
            role('alert', ByRoleOptions(description: JsRegExp(r'doc\.pdf')))),
        {
          'javascript': r"getByRole('alert', { description: /doc\.pdf/ })",
          'python':
              r'get_by_role("alert", description=re.compile(r"doc\.pdf"))',
          'java':
              r'getByRole(AriaRole.ALERT, new Page.GetByRoleOptions().setDescription(Pattern.compile("doc\\.pdf")))',
          'csharp':
              r'GetByRole(AriaRole.Alert, new() { DescriptionRegex = new Regex("doc\\.pdf") })',
        });
    expect(
        generate(role(
            'alert',
            const ByRoleOptions(
                name: 'Upload', description: 'doc.pdf', exact: true))),
        {
          'javascript':
              "getByRole('alert', { name: 'Upload', description: 'doc.pdf', exact: true })",
          'python':
              'get_by_role("alert", name="Upload", description="doc.pdf", exact=True)',
          'java':
              'getByRole(AriaRole.ALERT, new Page.GetByRoleOptions().setName("Upload").setDescription("doc.pdf").setExact(true))',
          'csharp':
              'GetByRole(AriaRole.Alert, new() { Name = "Upload", Description = "doc.pdf", Exact = true })',
        });
  });

  test('refuses to translate internal:role with conflicting exactness', () {
    const conflicting = 'internal:role=row[name="abc"i][description="d"s]';
    const conflictingReversed =
        'internal:role=row[name="abc"s][description="d"i]';
    for (final lang in _langs) {
      expect(asLocator(lang, conflicting), conflicting, reason: lang);
      expect(asLocator(lang, conflictingReversed), conflictingReversed,
          reason: lang);
    }
  });

  test('reverse engineer ignore-case locators', () {
    expect(generate(text('hello my\nwo"rld')), {
      'csharp': 'GetByText("hello my\\nwo\\"rld")',
      'java': 'getByText("hello my\\nwo\\"rld")',
      'javascript': "getByText('hello my\\nwo\"rld')",
      'python': 'get_by_text("hello my\\nwo\\"rld")',
    });
    expect(generate(text('hello       my     wo"rld')), {
      'csharp': 'GetByText("hello       my     wo\\"rld")',
      'java': 'getByText("hello       my     wo\\"rld")',
      'javascript': "getByText('hello       my     wo\"rld')",
      'python': 'get_by_text("hello       my     wo\\"rld")',
    });
    expect(generate(label('hello my\nwo"rld')), {
      'csharp': 'GetByLabel("hello my\\nwo\\"rld")',
      'java': 'getByLabel("hello my\\nwo\\"rld")',
      'javascript': "getByLabel('hello my\\nwo\"rld')",
      'python': 'get_by_label("hello my\\nwo\\"rld")',
    });
  });

  test('reverse engineer ordered locators', () {
    expect(generate(chain(['div', 'nth=3', 'nth=0', 'nth=-1'])), {
      'csharp': 'Locator("div").Nth(3).First.Last',
      'java': 'locator("div").nth(3).first().last()',
      'javascript': "locator('div').nth(3).first().last()",
      'python': 'locator("div").nth(3).first.last',
    });
  });

  test('reverse engineer locators with regex', () {
    expect(generate(text(JsRegExp(r'he\/\sl\nlo'))), {
      'csharp': r'GetByText(new Regex("he\\/\\sl\\nlo"))',
      'java': r'getByText(Pattern.compile("he\\/\\sl\\nlo"))',
      'javascript': r'getByText(/he\/\sl\nlo/)',
      'python': r'get_by_text(re.compile(r"he/\sl\nlo"))',
    });

    expect(generate(placeholder(JsRegExp(r'he\/\sl\nlo'))), {
      'csharp': r'GetByPlaceholder(new Regex("he\\/\\sl\\nlo"))',
      'java': r'getByPlaceholder(Pattern.compile("he\\/\\sl\\nlo"))',
      'javascript': r'getByPlaceholder(/he\/\sl\nlo/)',
      'python': r'get_by_placeholder(re.compile(r"he/\sl\nlo"))',
    });

    expect(generate(text(JsRegExp('hel"lo'))), {
      'csharp': 'GetByText(new Regex("hel\\"lo"))',
      'java': 'getByText(Pattern.compile("hel\\"lo"))',
      'javascript': 'getByText(/hel"lo/)',
      'python': 'get_by_text(re.compile(r"hel\\"lo"))',
    });

    expect(generate(placeholder(JsRegExp('hel"lo'))), {
      'csharp': 'GetByPlaceholder(new Regex("hel\\"lo"))',
      'java': 'getByPlaceholder(Pattern.compile("hel\\"lo"))',
      'javascript': 'getByPlaceholder(/hel"lo/)',
      'python': 'get_by_placeholder(re.compile(r"hel\\"lo"))',
    });
  });

  test('reverse engineer hasText', () {
    expect(generate(chain([text('Hello'), hasText('wo"rld\n')])), {
      'csharp': 'GetByText("Hello").Filter(new() { HasText = "wo\\"rld\\n" })',
      'java':
          'getByText("Hello").filter(new Locator.FilterOptions().setHasText("wo\\"rld\\n"))',
      'javascript': 'getByText(\'Hello\').filter({ hasText: \'wo"rld\\n\' })',
      'python': 'get_by_text("Hello").filter(has_text="wo\\"rld\\n")',
    });

    expect(
        generate(chain([text('Hello'), hasText(JsRegExp(r'wo\/\srld\n'))])), {
      'csharp':
          r'GetByText("Hello").Filter(new() { HasTextRegex = new Regex("wo\\/\\srld\\n") })',
      'java':
          r'getByText("Hello").filter(new Locator.FilterOptions().setHasText(Pattern.compile("wo\\/\\srld\\n")))',
      'javascript': r"getByText('Hello').filter({ hasText: /wo\/\srld\n/ })",
      'python':
          r'get_by_text("Hello").filter(has_text=re.compile(r"wo/\srld\n"))',
    });

    expect(generate(chain([text('Hello'), hasText(JsRegExp('wor"ld'))])), {
      'csharp':
          'GetByText("Hello").Filter(new() { HasTextRegex = new Regex("wor\\"ld") })',
      'java':
          'getByText("Hello").filter(new Locator.FilterOptions().setHasText(Pattern.compile("wor\\"ld")))',
      'javascript': 'getByText(\'Hello\').filter({ hasText: /wor"ld/ })',
      'python': 'get_by_text("Hello").filter(has_text=re.compile(r"wor\\"ld"))',
    });
  });

  test('reverse engineer hasNotText', () {
    expect(generate(chain([text('Hello'), hasNotText('wo"rld\n')])), {
      'csharp':
          'GetByText("Hello").Filter(new() { HasNotText = "wo\\"rld\\n" })',
      'java':
          'getByText("Hello").filter(new Locator.FilterOptions().setHasNotText("wo\\"rld\\n"))',
      'javascript':
          'getByText(\'Hello\').filter({ hasNotText: \'wo"rld\\n\' })',
      'python': 'get_by_text("Hello").filter(has_not_text="wo\\"rld\\n")',
    });
  });

  test('reverse engineer visible', () {
    expect(generate(chain([text('Hello'), 'visible=true', 'div'])), {
      'csharp': 'GetByText("Hello").Visible.Locator("div")',
      'java': 'getByText("Hello").visible().locator("div")',
      'javascript': "getByText('Hello').visible().locator('div')",
      'python': 'get_by_text("Hello").visible.locator("div")',
    });
    expect(generate(chain([text('Hello'), 'visible=false', 'div'])), {
      'csharp':
          'GetByText("Hello").Filter(new() { Visible = false }).Locator("div")',
      'java':
          'getByText("Hello").filter(new Locator.FilterOptions().setVisible(false)).locator("div")',
      'javascript':
          "getByText('Hello').filter({ visible: false }).locator('div')",
      'python': 'get_by_text("Hello").filter(visible=False).locator("div")',
    });
    final selector = chain([text('Hello'), 'visible=true']);
    expect(
        locatorOrSelectorAsSelector('javascript',
            "getByText('Hello').filter({ visible: true })", 'data-testid'),
        selector);
    expect(
        locatorOrSelectorAsSelector(
            'java',
            'getByText("Hello").filter(new Locator.FilterOptions().setVisible(true))',
            'data-testid'),
        selector);
    expect(
        locatorOrSelectorAsSelector('python',
            'get_by_text("Hello").filter(visible=True)', 'data-testid'),
        selector);
    expect(
        locatorOrSelectorAsSelector(
            'csharp',
            'GetByText("Hello").Filter(new() { Visible = true })',
            'data-testid'),
        selector);
  });

  test('reverse engineer has', () {
    expect(
        generate(chain([
          text('Hello'),
          has(chain(['div', text('bye')]))
        ])),
        {
          'csharp':
              'GetByText("Hello").Filter(new() { Has = Locator("div").GetByText("bye") })',
          'java':
              'getByText("Hello").filter(new Locator.FilterOptions().setHas(locator("div").getByText("bye")))',
          'javascript':
              "getByText('Hello').filter({ has: locator('div').getByText('bye') })",
          'python':
              'get_by_text("Hello").filter(has=locator("div").get_by_text("bye"))',
        });

    final selector = chain([
      'section',
      has(chain(['div', has('span')])),
      hasText('foo'),
      has('a'),
    ]);
    expect(generate(selector), {
      'csharp':
          'Locator("section").Filter(new() { Has = Locator("div").Filter(new() { Has = Locator("span") }) }).Filter(new() { HasText = "foo" }).Filter(new() { Has = Locator("a") })',
      'java':
          'locator("section").filter(new Locator.FilterOptions().setHas(locator("div").filter(new Locator.FilterOptions().setHas(locator("span"))))).filter(new Locator.FilterOptions().setHasText("foo")).filter(new Locator.FilterOptions().setHas(locator("a")))',
      'javascript':
          "locator('section').filter({ has: locator('div').filter({ has: locator('span') }) }).filter({ hasText: 'foo' }).filter({ has: locator('a') })",
      'python':
          'locator("section").filter(has=locator("div").filter(has=locator("span"))).filter(has_text="foo").filter(has=locator("a"))',
    });
  });

  test('reverse engineer hasNot', () {
    expect(
        generate(chain([
          text('Hello'),
          hasNot(chain(['div', text('bye')]))
        ])),
        {
          'csharp':
              'GetByText("Hello").Filter(new() { HasNot = Locator("div").GetByText("bye") })',
          'java':
              'getByText("Hello").filter(new Locator.FilterOptions().setHasNot(locator("div").getByText("bye")))',
          'javascript':
              "getByText('Hello').filter({ hasNot: locator('div').getByText('bye') })",
          'python':
              'get_by_text("Hello").filter(has_not=locator("div").get_by_text("bye"))',
        });

    final selector = chain([
      'section',
      has(chain(['div', hasNot('span')])),
      hasText('foo'),
      hasNot('a'),
    ]);
    expect(generate(selector), {
      'csharp':
          'Locator("section").Filter(new() { Has = Locator("div").Filter(new() { HasNot = Locator("span") }) }).Filter(new() { HasText = "foo" }).Filter(new() { HasNot = Locator("a") })',
      'java':
          'locator("section").filter(new Locator.FilterOptions().setHas(locator("div").filter(new Locator.FilterOptions().setHasNot(locator("span"))))).filter(new Locator.FilterOptions().setHasText("foo")).filter(new Locator.FilterOptions().setHasNot(locator("a")))',
      'javascript':
          "locator('section').filter({ has: locator('div').filter({ hasNot: locator('span') }) }).filter({ hasText: 'foo' }).filter({ hasNot: locator('a') })",
      'python':
          'locator("section").filter(has=locator("div").filter(has_not=locator("span"))).filter(has_text="foo").filter(has_not=locator("a"))',
    });
  });

  test('reverse engineer has + hasText', () {
    final selector = chain(['section', hasText('foo'), has('div'), 'a']);
    expect(generate(selector), {
      'csharp':
          'Locator("section").Filter(new() { HasText = "foo" }).Filter(new() { Has = Locator("div") }).Locator("a")',
      'java':
          'locator("section").filter(new Locator.FilterOptions().setHasText("foo")).filter(new Locator.FilterOptions().setHas(locator("div"))).locator("a")',
      'javascript':
          "locator('section').filter({ hasText: 'foo' }).filter({ has: locator('div') }).locator('a')",
      'python':
          'locator("section").filter(has_text="foo").filter(has=locator("div")).locator("a")',
    });
  });

  test('reverse engineer frameLocator', () {
    final selector = chain([
      'iframe',
      enterFrame,
      text('foo', exact: true),
      'frame',
      'nth=0',
      enterFrame,
      'iframe',
      enterFrame,
      'span',
    ]);
    expect(generate(selector), {
      'csharp':
          'Locator("iframe").ContentFrame.GetByText("foo", new() { Exact = true }).Locator("frame").First.ContentFrame.Locator("iframe").ContentFrame.Locator("span")',
      'java':
          'locator("iframe").contentFrame().getByText("foo", new FrameLocator.GetByTextOptions().setExact(true)).locator("frame").first().contentFrame().locator("iframe").contentFrame().locator("span")',
      'javascript':
          "locator('iframe').contentFrame().getByText('foo', { exact: true }).locator('frame').first().contentFrame().locator('iframe').contentFrame().locator('span')",
      'python':
          'locator("iframe").content_frame.get_by_text("foo", exact=True).locator("frame").first.content_frame.locator("iframe").content_frame.locator("span")',
    });

    // Frame locators with ">>" are not restored back, because of ambiguity.
    expect(
        asLocator('javascript', chain(['div', 'iframe', enterFrame, 'span'])),
        "locator('div').locator('iframe').contentFrame().locator('span')");
  });

  test('reverse engineer frameLocator without a selector', () {
    expect(generate(chain([anyFrame, text('foo'), 'span'])), {
      'csharp': 'FrameLocator().GetByText("foo").Locator("span")',
      'java': 'frameLocator().getByText("foo").locator("span")',
      'javascript': "frameLocator().getByText('foo').locator('span')",
      'python': 'frame_locator().get_by_text("foo").locator("span")',
    });

    expect(asLocator('javascript', anyFrame), 'frameLocator()');
    expect(asLocator('python', anyFrame), 'frame_locator()');
    expect(asLocator('java', anyFrame), 'frameLocator()');
    expect(asLocator('csharp', anyFrame), 'FrameLocator()');
  });

  test('generate multiple locators', () {
    final selector = chain([
      'div',
      hasText('foo'),
      'nth=0',
      has(chain(['span', hasNotText('bar'), 'nth=-1'])),
    ]);
    final locators = {
      'javascript': [
        "locator('div').filter({ hasText: 'foo' }).first().filter({ has: locator('span').filter({ hasNotText: 'bar' }).last() })",
        "locator('div').filter({ hasText: 'foo' }).first().filter({ has: locator('span').filter({ hasNotText: 'bar' }).nth(-1) })",
        "locator('div').filter({ hasText: 'foo' }).first().filter({ has: locator('span', { hasNotText: 'bar' }).last() })",
        "locator('div').filter({ hasText: 'foo' }).first().filter({ has: locator('span', { hasNotText: 'bar' }).nth(-1) })",
        "locator('div').filter({ hasText: 'foo' }).nth(0).filter({ has: locator('span').filter({ hasNotText: 'bar' }).last() })",
        "locator('div').filter({ hasText: 'foo' }).nth(0).filter({ has: locator('span').filter({ hasNotText: 'bar' }).nth(-1) })",
        "locator('div').filter({ hasText: 'foo' }).nth(0).filter({ has: locator('span', { hasNotText: 'bar' }).last() })",
        "locator('div').filter({ hasText: 'foo' }).nth(0).filter({ has: locator('span', { hasNotText: 'bar' }).nth(-1) })",
        "locator('div', { hasText: 'foo' }).first().filter({ has: locator('span').filter({ hasNotText: 'bar' }).last() })",
        "locator('div', { hasText: 'foo' }).first().filter({ has: locator('span').filter({ hasNotText: 'bar' }).nth(-1) })",
        "locator('div', { hasText: 'foo' }).first().filter({ has: locator('span', { hasNotText: 'bar' }).last() })",
        "locator('div', { hasText: 'foo' }).first().filter({ has: locator('span', { hasNotText: 'bar' }).nth(-1) })",
        "locator('div', { hasText: 'foo' }).nth(0).filter({ has: locator('span').filter({ hasNotText: 'bar' }).last() })",
        "locator('div', { hasText: 'foo' }).nth(0).filter({ has: locator('span').filter({ hasNotText: 'bar' }).nth(-1) })",
        "locator('div', { hasText: 'foo' }).nth(0).filter({ has: locator('span', { hasNotText: 'bar' }).last() })",
        "locator('div', { hasText: 'foo' }).nth(0).filter({ has: locator('span', { hasNotText: 'bar' }).nth(-1) })",
      ],
      'java': [
        'locator("div").filter(new Locator.FilterOptions().setHasText("foo")).first().filter(new Locator.FilterOptions().setHas(locator("span").filter(new Locator.FilterOptions().setHasNotText("bar")).last()))',
        'locator("div").filter(new Locator.FilterOptions().setHasText("foo")).first().filter(new Locator.FilterOptions().setHas(locator("span").filter(new Locator.FilterOptions().setHasNotText("bar")).nth(-1)))',
        'locator("div").filter(new Locator.FilterOptions().setHasText("foo")).first().filter(new Locator.FilterOptions().setHas(locator("span", new Page.LocatorOptions().setHasNotText("bar")).last()))',
        'locator("div").filter(new Locator.FilterOptions().setHasText("foo")).first().filter(new Locator.FilterOptions().setHas(locator("span", new Page.LocatorOptions().setHasNotText("bar")).nth(-1)))',
        'locator("div").filter(new Locator.FilterOptions().setHasText("foo")).nth(0).filter(new Locator.FilterOptions().setHas(locator("span").filter(new Locator.FilterOptions().setHasNotText("bar")).last()))',
        'locator("div").filter(new Locator.FilterOptions().setHasText("foo")).nth(0).filter(new Locator.FilterOptions().setHas(locator("span").filter(new Locator.FilterOptions().setHasNotText("bar")).nth(-1)))',
        'locator("div").filter(new Locator.FilterOptions().setHasText("foo")).nth(0).filter(new Locator.FilterOptions().setHas(locator("span", new Page.LocatorOptions().setHasNotText("bar")).last()))',
        'locator("div").filter(new Locator.FilterOptions().setHasText("foo")).nth(0).filter(new Locator.FilterOptions().setHas(locator("span", new Page.LocatorOptions().setHasNotText("bar")).nth(-1)))',
        'locator("div", new Page.LocatorOptions().setHasText("foo")).first().filter(new Locator.FilterOptions().setHas(locator("span").filter(new Locator.FilterOptions().setHasNotText("bar")).last()))',
        'locator("div", new Page.LocatorOptions().setHasText("foo")).first().filter(new Locator.FilterOptions().setHas(locator("span").filter(new Locator.FilterOptions().setHasNotText("bar")).nth(-1)))',
        'locator("div", new Page.LocatorOptions().setHasText("foo")).first().filter(new Locator.FilterOptions().setHas(locator("span", new Page.LocatorOptions().setHasNotText("bar")).last()))',
        'locator("div", new Page.LocatorOptions().setHasText("foo")).first().filter(new Locator.FilterOptions().setHas(locator("span", new Page.LocatorOptions().setHasNotText("bar")).nth(-1)))',
        'locator("div", new Page.LocatorOptions().setHasText("foo")).nth(0).filter(new Locator.FilterOptions().setHas(locator("span").filter(new Locator.FilterOptions().setHasNotText("bar")).last()))',
        'locator("div", new Page.LocatorOptions().setHasText("foo")).nth(0).filter(new Locator.FilterOptions().setHas(locator("span").filter(new Locator.FilterOptions().setHasNotText("bar")).nth(-1)))',
        'locator("div", new Page.LocatorOptions().setHasText("foo")).nth(0).filter(new Locator.FilterOptions().setHas(locator("span", new Page.LocatorOptions().setHasNotText("bar")).last()))',
        'locator("div", new Page.LocatorOptions().setHasText("foo")).nth(0).filter(new Locator.FilterOptions().setHas(locator("span", new Page.LocatorOptions().setHasNotText("bar")).nth(-1)))',
      ],
      'python': [
        'locator("div").filter(has_text="foo").first.filter(has=locator("span").filter(has_not_text="bar").last)',
        'locator("div").filter(has_text="foo").first.filter(has=locator("span").filter(has_not_text="bar").nth(-1))',
        'locator("div").filter(has_text="foo").first.filter(has=locator("span", has_not_text="bar").last)',
        'locator("div").filter(has_text="foo").first.filter(has=locator("span", has_not_text="bar").nth(-1))',
        'locator("div").filter(has_text="foo").nth(0).filter(has=locator("span").filter(has_not_text="bar").last)',
        'locator("div").filter(has_text="foo").nth(0).filter(has=locator("span").filter(has_not_text="bar").nth(-1))',
        'locator("div").filter(has_text="foo").nth(0).filter(has=locator("span", has_not_text="bar").last)',
        'locator("div").filter(has_text="foo").nth(0).filter(has=locator("span", has_not_text="bar").nth(-1))',
        'locator("div", has_text="foo").first.filter(has=locator("span").filter(has_not_text="bar").last)',
        'locator("div", has_text="foo").first.filter(has=locator("span").filter(has_not_text="bar").nth(-1))',
        'locator("div", has_text="foo").first.filter(has=locator("span", has_not_text="bar").last)',
        'locator("div", has_text="foo").first.filter(has=locator("span", has_not_text="bar").nth(-1))',
        'locator("div", has_text="foo").nth(0).filter(has=locator("span").filter(has_not_text="bar").last)',
        'locator("div", has_text="foo").nth(0).filter(has=locator("span").filter(has_not_text="bar").nth(-1))',
        'locator("div", has_text="foo").nth(0).filter(has=locator("span", has_not_text="bar").last)',
        'locator("div", has_text="foo").nth(0).filter(has=locator("span", has_not_text="bar").nth(-1))',
      ],
      'csharp': [
        'Locator("div").Filter(new() { HasText = "foo" }).First.Filter(new() { Has = Locator("span").Filter(new() { HasNotText = "bar" }).Last })',
        'Locator("div").Filter(new() { HasText = "foo" }).First.Filter(new() { Has = Locator("span").Filter(new() { HasNotText = "bar" }).Nth(-1) })',
        'Locator("div").Filter(new() { HasText = "foo" }).First.Filter(new() { Has = Locator("span", new() { HasNotText = "bar" }).Last })',
        'Locator("div").Filter(new() { HasText = "foo" }).First.Filter(new() { Has = Locator("span", new() { HasNotText = "bar" }).Nth(-1) })',
        'Locator("div").Filter(new() { HasText = "foo" }).Nth(0).Filter(new() { Has = Locator("span").Filter(new() { HasNotText = "bar" }).Last })',
        'Locator("div").Filter(new() { HasText = "foo" }).Nth(0).Filter(new() { Has = Locator("span").Filter(new() { HasNotText = "bar" }).Nth(-1) })',
        'Locator("div").Filter(new() { HasText = "foo" }).Nth(0).Filter(new() { Has = Locator("span", new() { HasNotText = "bar" }).Last })',
        'Locator("div").Filter(new() { HasText = "foo" }).Nth(0).Filter(new() { Has = Locator("span", new() { HasNotText = "bar" }).Nth(-1) })',
        'Locator("div", new() { HasText = "foo" }).First.Filter(new() { Has = Locator("span").Filter(new() { HasNotText = "bar" }).Last })',
        'Locator("div", new() { HasText = "foo" }).First.Filter(new() { Has = Locator("span").Filter(new() { HasNotText = "bar" }).Nth(-1) })',
        'Locator("div", new() { HasText = "foo" }).First.Filter(new() { Has = Locator("span", new() { HasNotText = "bar" }).Last })',
        'Locator("div", new() { HasText = "foo" }).First.Filter(new() { Has = Locator("span", new() { HasNotText = "bar" }).Nth(-1) })',
        'Locator("div", new() { HasText = "foo" }).Nth(0).Filter(new() { Has = Locator("span").Filter(new() { HasNotText = "bar" }).Last })',
        'Locator("div", new() { HasText = "foo" }).Nth(0).Filter(new() { Has = Locator("span").Filter(new() { HasNotText = "bar" }).Nth(-1) })',
        'Locator("div", new() { HasText = "foo" }).Nth(0).Filter(new() { Has = Locator("span", new() { HasNotText = "bar" }).Last })',
        'Locator("div", new() { HasText = "foo" }).Nth(0).Filter(new() { Has = Locator("span", new() { HasNotText = "bar" }).Nth(-1) })',
      ],
    };
    for (final lang in _langs) {
      expect(asLocators(lang, selector), locators[lang], reason: lang);
      for (final locator in locators[lang]!) {
        expect(
            locatorOrSelectorAsSelector(lang, locator, 'data-testid'), selector,
            reason: 'parse($lang): $locator');
      }
    }
  });

  test('reverse engineer internal:has-text locators', () {
    expect(generate(chain(['div', hasText('Goodbye world'), 'span'])), {
      'csharp':
          'Locator("div").Filter(new() { HasText = "Goodbye world" }).Locator("span")',
      'java':
          'locator("div").filter(new Locator.FilterOptions().setHasText("Goodbye world")).locator("span")',
      'javascript':
          "locator('div').filter({ hasText: 'Goodbye world' }).locator('span')",
      'python':
          'locator("div").filter(has_text="Goodbye world").locator("span")',
    });

    expect(asLocator('javascript', 'div >> internal:has-text="foo"s'),
        """locator('div').locator('internal:has-text="foo"s')""");
    expect(asLocator('javascript', 'div >> internal:has-not-text="foo"s'),
        """locator('div').locator('internal:has-not-text="foo"s')""");
  });

  test('asLocator internal:and', () {
    const selector = 'div >> internal:and="span >> article"';
    expect(asLocator('javascript', selector),
        "locator('div').and(locator('span').locator('article'))");
    expect(asLocator('python', selector),
        'locator("div").and_(locator("span").locator("article"))');
    expect(asLocator('java', selector),
        'locator("div").and(locator("span").locator("article"))');
    expect(asLocator('csharp', selector),
        'Locator("div").And(Locator("span").Locator("article"))');
  });

  test('asLocator internal:or', () {
    const selector = 'div >> internal:or="span >> article"';
    expect(asLocator('javascript', selector),
        "locator('div').or(locator('span').locator('article'))");
    expect(asLocator('python', selector),
        'locator("div").or_(locator("span").locator("article"))');
    expect(asLocator('java', selector),
        'locator("div").or(locator("span").locator("article"))');
    expect(asLocator('csharp', selector),
        'Locator("div").Or(Locator("span").Locator("article"))');
  });

  test('asLocator internal:chain', () {
    const selector = 'div >> internal:chain="span >> article"';
    expect(asLocator('javascript', selector),
        "locator('div').locator(locator('span').locator('article'))");
    expect(asLocator('python', selector),
        'locator("div").locator(locator("span").locator("article"))');
    expect(asLocator('java', selector),
        'locator("div").locator(locator("span").locator("article"))');
    expect(asLocator('csharp', selector),
        'Locator("div").Locator(Locator("span").Locator("article"))');
  });

  test('asLocator xpath', () {
    const selector = "//*[contains(normalizer-text(), 'foo']";
    expect(asLocator('javascript', selector),
        r"locator('//*[contains(normalizer-text(), \'foo\']')");
    expect(asLocator('python', selector),
        'locator("//*[contains(normalizer-text(), \'foo\']")');
    expect(asLocator('java', selector),
        'locator("//*[contains(normalizer-text(), \'foo\']")');
    expect(asLocator('csharp', selector),
        'Locator("//*[contains(normalizer-text(), \'foo\']")');
    expect(
        locatorOrSelectorAsSelector(
            'javascript',
            r"locator('//*[contains(normalizer-text(), \'foo\']')",
            'data-testid'),
        selector);
    expect(
        locatorOrSelectorAsSelector(
            'javascript',
            'locator("//*[contains(normalizer-text(), \'foo\']")',
            'data-testid'),
        selector);
    expect(
        locatorOrSelectorAsSelector(
            'javascript',
            r"locator('xpath=//*[contains(normalizer-text(), \'foo\']')",
            'data-testid'),
        'xpath=$selector');
    expect(
        locatorOrSelectorAsSelector(
            'javascript',
            'locator("xpath=//*[contains(normalizer-text(), \'foo\']")',
            'data-testid'),
        'xpath=$selector');
    expect(
        locatorOrSelectorAsSelector(
            'python',
            'locator("//*[contains(normalizer-text(), \'foo\']")',
            'data-testid'),
        selector);
    expect(
        locatorOrSelectorAsSelector(
            'csharp',
            'Locator("//*[contains(normalizer-text(), \'foo\']")',
            'data-testid'),
        selector);
  });

  test('parseLocator quotes', () {
    expect(
        locatorOrSelectorAsSelector(
            'javascript', """locator('text="bar"')""", ''),
        'text="bar"');
    expect(
        locatorOrSelectorAsSelector(
            'javascript', '''locator("text='bar'")''', ''),
        "text='bar'");
    expect(
        locatorOrSelectorAsSelector(
            'javascript', 'locator(`text=\'bar\'`)', ''),
        "text='bar'");
    expect(
        locatorOrSelectorAsSelector('python', '''locator("text='bar'")''', ''),
        "text='bar'");
    expect(
        locatorOrSelectorAsSelector('python', """locator('text="bar"')""", ''),
        '');
    expect(locatorOrSelectorAsSelector('java', '''locator("text='bar'")''', ''),
        "text='bar'");
    expect(locatorOrSelectorAsSelector('java', """locator('text="bar"')""", ''),
        '');
    expect(
        locatorOrSelectorAsSelector('csharp', '''Locator("text='bar'")''', ''),
        "text='bar'");
    expect(
        locatorOrSelectorAsSelector('csharp', """Locator('text="bar"')""", ''),
        '');

    const mixedQuotes = '''
    locator("[id*=freetext-field]")
        .locator('input:below(:text("Assigned Number:"))')
        .locator("visible=true")
  ''';
    expect(locatorOrSelectorAsSelector('javascript', mixedQuotes, ''),
        '[id*=freetext-field] >> input:below(:text("Assigned Number:")) >> visible=true');
  });

  test('parseLocator css', () {
    expect(locatorOrSelectorAsSelector('javascript', "locator('.foo')", ''),
        '.foo');
    expect(locatorOrSelectorAsSelector('javascript', "locator('css=.foo')", ''),
        'css=.foo');
    expect(
        locatorOrSelectorAsSelector('python', 'locator(".foo")', ''), '.foo');
    expect(locatorOrSelectorAsSelector('python', 'locator("css=.foo")', ''),
        'css=.foo');
    expect(locatorOrSelectorAsSelector('java', 'locator(".foo")', ''), '.foo');
    expect(locatorOrSelectorAsSelector('java', 'locator("css=.foo")', ''),
        'css=.foo');
    expect(
        locatorOrSelectorAsSelector('csharp', 'Locator(".foo")', ''), '.foo');
    expect(locatorOrSelectorAsSelector('csharp', 'Locator("css=.foo")', ''),
        'css=.foo');
  });

  test('parseLocator options', () {
    expect(
        locatorOrSelectorAsSelector(
            'javascript', "getByRole('heading', {})", ''),
        'internal:role=heading');
    expect(
        locatorOrSelectorAsSelector(
            'javascript',
            "getByRole('checkbox', { checked:false, includeHidden: true })",
            ''),
        'internal:role=checkbox[checked=false][include-hidden=true]');
  });

  test('parse locators strictly', () {
    const selector = 'div >> internal:has-text="Goodbye world"i >> span';

    // Exact.
    expect(
        locatorOrSelectorAsSelector('csharp',
            'Locator("div").Filter(new() { HasText = "Goodbye world" }).Locator("span")'),
        selector);
    expect(
        locatorOrSelectorAsSelector('java',
            'locator("div").filter(new Locator.FilterOptions().setHasText("Goodbye world")).locator("span")'),
        selector);
    expect(
        locatorOrSelectorAsSelector('javascript',
            "locator('div').filter({ hasText: 'Goodbye world' }).locator('span')"),
        selector);
    expect(
        locatorOrSelectorAsSelector('python',
            'locator("div").filter(has_text="Goodbye world").locator("span")'),
        selector);

    // Quotes.
    expect(
        locatorOrSelectorAsSelector('javascript',
            'locator("div").filter({ hasText: "Goodbye world" }).locator("span")'),
        selector);
    expect(
        locatorOrSelectorAsSelector('python',
            "locator('div').filter(has_text='Goodbye world').locator('span')"),
        isNot(selector));

    // Whitespace.
    expect(
        locatorOrSelectorAsSelector('csharp',
            'Locator("div")  .  Filter (new ( ) {  HasText =    "Goodbye world" }).Locator(  "span"   )'),
        selector);
    expect(
        locatorOrSelectorAsSelector('java',
            '  locator("div"  ).  filter(  new    Locator. FilterOptions    ( ) .setHasText(   "Goodbye world" ) ).locator(   "span")'),
        selector);
    expect(
        locatorOrSelectorAsSelector('javascript',
            "locator\n('div')\n\n.filter({ hasText  : 'Goodbye world'\n }\n).locator('span')\n"),
        selector);
    expect(
        locatorOrSelectorAsSelector('python',
            '\tlocator(\t"div").filter(\thas_text="Goodbye world"\t).locator\t("span")'),
        selector);

    // Extra symbols.
    expect(
        locatorOrSelectorAsSelector('csharp',
            'Locator("div").Filter(new() { HasText = "Goodbye world" }).Locator("span"))'),
        isNot(selector));
    expect(
        locatorOrSelectorAsSelector('java',
            'locator("div").filter(new Locator.FilterOptions().setHasText("Goodbye world"))..locator("span")'),
        isNot(selector));
    expect(
        locatorOrSelectorAsSelector('javascript',
            "locator('div').filter({ hasText: 'Goodbye world' }}).locator('span')"),
        isNot(selector));
    expect(
        locatorOrSelectorAsSelector('python',
            'locator("div").filter(has_text=="Goodbye world").locator("span")'),
        isNot(selector));
  });

  test('parseLocator frames', () {
    const framed =
        'iframe >> internal:control=enter-frame >> internal:text="foo"i';
    expect(
        locatorOrSelectorAsSelector('javascript',
            "locator('iframe').contentFrame().getByText('foo')", ''),
        framed);
    expect(
        locatorOrSelectorAsSelector(
            'javascript', "frameLocator('iframe').getByText('foo')", ''),
        framed);
    expect(
        locatorOrSelectorAsSelector(
            'javascript', "frameLocator('css=iframe').getByText('foo')", ''),
        'css=$framed');
    expect(
        locatorOrSelectorAsSelector(
            'javascript', "getByTitle('iframe title').contentFrame()"),
        'internal:attr=[title="iframe title"i] >> internal:control=enter-frame');

    expect(
        asLocators('javascript',
            'internal:attr=[title="iframe title"i] >> internal:control=enter-frame'),
        ["getByTitle('iframe title').contentFrame()"]);

    expect(
        locatorOrSelectorAsSelector(
            'python', 'locator("iframe").content_frame.get_by_text("foo")', ''),
        framed);
    expect(
        locatorOrSelectorAsSelector(
            'python', 'frame_locator("iframe").get_by_text("foo")', ''),
        framed);
    expect(
        locatorOrSelectorAsSelector(
            'python', 'frame_locator("css=iframe").get_by_text("foo")', ''),
        'css=$framed');

    expect(
        locatorOrSelectorAsSelector(
            'csharp', 'Locator("iframe").ContentFrame.GetByText("foo")', ''),
        framed);
    expect(
        locatorOrSelectorAsSelector(
            'csharp', 'FrameLocator("iframe").GetByText("foo")', ''),
        framed);

    expect(
        locatorOrSelectorAsSelector(
            'java', 'locator("iframe").contentFrame().getByText("foo")', ''),
        framed);
    expect(
        locatorOrSelectorAsSelector(
            'java', 'frameLocator("iframe").getByText("foo")', ''),
        framed);
  });

  test('asLocatorDescription invalid input', () {
    expect(
        asLocatorDescription('javascript', 'body >> internal:describe="desc"'),
        'desc');
    expect(asLocatorDescription('javascript', 'body >> internal:describe=12'),
        "locator('body')");
    expect(asLocatorDescription('javascript', 'following-sibling::*[1]'),
        'following-sibling::*[1]');
    expect(
        asLocatorDescription(
            'javascript', 'body >> internal:describe="desc" >> div'),
        "locator('body').locator('div')");
  });
}

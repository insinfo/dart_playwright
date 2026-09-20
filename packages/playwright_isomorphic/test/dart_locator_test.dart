// The Dart locator factory has no upstream fixtures, because upstream has no
// Dart binding. The cases here mirror the ones in locator_generator_test.dart
// one for one, so that a change in the shared machinery shows up on the Dart
// side too; dart_codegen_compiles_test.dart is what proves the output is
// valid Dart.

import 'package:playwright_isomorphic/playwright_isomorphic.dart';
import 'package:test/test.dart';

String dart(String selector) => asLocator(Languages.dart, selector);

void main() {
  test('getBy* family', () {
    expect(
        dart('internal:testid=[data-testid="Hello"s]'), "getByTestId('Hello')");
    expect(dart('internal:text="Hello"i'), "getByText('Hello')");
    expect(dart('internal:text="Hello"s'), "getByText('Hello', exact: true)");
    expect(dart('internal:label="Name"i'), "getByLabel('Name')");
    expect(dart('internal:attr=[placeholder="hi"i]'), "getByPlaceholder('hi')");
    expect(
        dart('internal:attr=[alt="hi"s]'), "getByAltText('hi', exact: true)");
    expect(dart('internal:attr=[title="hi"i]'), "getByTitle('hi')");
  });

  test('getByRole with options', () {
    expect(dart('internal:role=button'), "getByRole('button')");
    expect(dart('internal:role=button[name="Hello"i]'),
        "getByRole('button', name: 'Hello')");
    expect(dart('internal:role=button[name="Hello"s]'),
        "getByRole('button', name: 'Hello', exact: true)");
    expect(dart('internal:role=button[checked=true][level=3][pressed=false]'),
        "getByRole('button', checked: true, level: 3, pressed: false)");
    expect(dart('internal:role=checkbox[include-hidden=true]'),
        "getByRole('checkbox', includeHidden: true)");
    expect(dart('internal:role=alert[description="doc.pdf"i]'),
        "getByRole('alert', description: 'doc.pdf')");
  });

  test('regular expressions become RegExp expressions', () {
    expect(dart(r'internal:label=/Last\s+name/i'),
        r"getByLabel(RegExp('Last\\s+name', caseSensitive: false))");
    expect(dart(r'internal:text=/he\/\sl\nlo/'),
        r"getByText(RegExp('he/\\sl\\nlo'))");
    expect(dart('internal:testid=[data-testid=/He\\"llo/]'),
        r"""getByTestId(RegExp('He"llo'))""");
  });

  test('Dart string literals escape what Dart interpolates', () {
    expect(dart('internal:text="it\'s"i'), r"getByText('it\'s')");
    expect(dart(r'internal:text="a $b"i'), r"getByText('a \$b')");
    expect(dart('internal:text="two\\nlines"i'), r"getByText('two\nlines')");
  });

  test('ordering uses getters where this port has getters', () {
    expect(dart('div >> nth=3 >> nth=0 >> nth=-1'),
        "locator('div').nth(3).first.last");
  });

  test('visible', () {
    expect(dart('internal:text="Hello"i >> visible=true >> div'),
        "getByText('Hello').visible().locator('div')");
    expect(dart('internal:text="Hello"i >> visible=false >> div'),
        "getByText('Hello').visible(value: false).locator('div')");
  });

  test('filters and composition prefix nested locators with page', () {
    expect(
        dart(
            r'internal:text="Hello"i >> internal:has="div >> internal:text=\"bye\"i"'),
        "getByText('Hello').filter(has: page.locator('div').getByText('bye'))");
    expect(dart(r'internal:text="Hello"i >> internal:has-not="div"'),
        "getByText('Hello').filter(hasNot: page.locator('div'))");
    expect(dart('internal:text="Hello"i >> internal:has-text="wo rld"i'),
        "getByText('Hello').filter(hasText: 'wo rld')");
    expect(dart('internal:text="Hello"i >> internal:has-not-text="wo rld"i'),
        "getByText('Hello').filter(hasNotText: 'wo rld')");
    expect(dart('div >> internal:and="span >> article"'),
        "locator('div').and(page.locator('span').locator('article'))");
    expect(dart('div >> internal:or="span >> article"'),
        "locator('div').or(page.locator('span').locator('article'))");
  });

  test('frames', () {
    expect(dart('iframe >> internal:control=enter-frame >> span'),
        "locator('iframe').contentFrame().locator('span')");
    expect(
        asLocators(Languages.dart, 'iframe >> internal:control=enter-frame'), [
      "locator('iframe').contentFrame()",
      "locator('css=iframe').contentFrame()",
      "frameLocator('iframe')",
      "frameLocator('css=iframe')",
    ]);
  });

  test('what this port has no spelling for falls back to the raw selector', () {
    // No selectorless frameLocator(), and no locator(Locator).
    expect(dart('internal:control=any-frame >> span'),
        'internal:control=any-frame >> span');
    expect(
        dart('div >> internal:chain="span"'), 'div >> internal:chain="span"');
  });

  test('locator with hasText offers both spellings', () {
    expect(asLocators(Languages.dart, 'div >> internal:has-text="foo"i'), [
      "locator('div').filter(hasText: 'foo')",
      "locator('div', hasText: 'foo')",
    ]);
  });
}

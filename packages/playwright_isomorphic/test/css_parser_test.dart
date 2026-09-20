// Transcribed from upstream's
// referencias/playwright-typescript/tests/library/css-parser.spec.ts.

import 'package:playwright_isomorphic/playwright_isomorphic.dart';
import 'package:test/test.dart';

final _customNames = {
  'text',
  'not',
  'has',
  'react',
  'scope',
  'right-of',
  'is',
};

List<Object> _parse(String selector) =>
    parseCss(selector, _customNames).selector.cast<Object>();

String _round(String selector) => serializeCssSelector(_parse(selector));

void main() {
  test('should parse css', () {
    expect(_round('div'), 'div');
    expect(_round('div.class'), 'div.class');
    expect(_round('.class'), '.class');
    expect(_round('#id'), '#id');
    expect(_round('.class#id'), '.class#id');
    expect(_round('div#id.class'), 'div#id.class');
    expect(_round('*'), '*');
    expect(_round('*div'), '*div');
    expect(_round('div[attr *= foo i]'), 'div[attr *= foo i]');
    expect(_round('div[attr~="Bar baz"  ]'), 'div[attr~="Bar baz" ]');
    expect(_round("div    [ foo = 'bar'  s]"), 'div [ foo = "bar" s]');

    expect(_round(':hover'), ':hover');
    expect(_round('div:hover'), 'div:hover');
    expect(_round('#id:active:hover'), '#id:active:hover');
    expect(_round(':dir(ltr)'), ':dir(ltr)');
    expect(_round('#foo-bar.cls:nth-child(3n + 10)'),
        '#foo-bar.cls:nth-child(3n + 10)');
    expect(_round(':lang(en)'), ':lang(en)');
    expect(_round('*:hover'), '*:hover');

    expect(_round('div span'), 'div span');
    expect(_round('div>span'), 'div > span');
    expect(_round('div +span'), 'div + span');
    expect(_round('div~ span'), 'div ~ span');
    expect(_round('div   >.class #id+ span'), 'div > .class #id + span');
    expect(_round('div>span+.class'), 'div > span + .class');
    expect(_round('>span'), ':scope() > span');

    expect(_round('div:not(span)'), 'div:not(span)');
    expect(_round(':not(span)#id'), '#id:not(span)');
    expect(_round('div:not(span):hover'), 'div:hover:not(span)');
    expect(_round('div:has(span):hover'), 'div:hover:has(span)');
    expect(_round('div:right-of(span):hover'), 'div:hover:right-of(span)');
    expect(_round(':right-of(span):react(foobar)'),
        ':right-of(span):react(foobar)');
    expect(_round('div:is(span):hover'), 'div:hover:is(span)');
    expect(_round('div:scope:hover'), 'div:hover:scope()');
    expect(_round('div:sCOpe:HOVER'), 'div:HOVER:scope()');
    expect(_round('div:NOT(span):hoVER'), 'div:hoVER:not(span)');

    expect(_round(':text("foo")'), ':text("foo")');
    expect(_round(':text("*")'), ':text("*")');
    expect(_round(':text(*)'), ':text(*)');
    expect(_round(':text("foo", normalize-space)'),
        ':text("foo", normalize-space)');
    expect(_round(':index(3, div    span)'), ':index(3, div span)');
    expect(_round(':is(foo, bar>baz.cls+:not(qux))'),
        ':is(foo, bar > baz.cls + :not(qux))');
  });

  test('should throw on malformed css', () {
    void expectError(String selector) {
      var message = '';
      try {
        _parse(selector);
      } on InvalidSelectorError catch (e) {
        message = e.message;
      }
      expect(message, contains('while parsing css selector "$selector"'),
          reason: selector);
      expect(message, contains('Did you mean to CSS.escape it?'),
          reason: selector);
    }

    expectError('');
    expectError('.');
    expectError('#');
    expectError('..');
    expectError('#.');
    expectError('.#');
    expectError('[attr=');
    expectError(':not(div');
    expectError('div)');
    expectError('()');
    expectError(':not(##)');
    expectError(':not()');
    expectError(':not(.)');
    expectError('div,');
    expectError(',div');
    expectError('div,,span');
    expectError('div > > span');
    expectError('div > > > > span');
    expectError('div >');
    expectError('"foo"');
    expectError('23');
    expectError('span, div>"foo"');
  });

  test('tokenizer round trips through toSource', () {
    expect(tokenizeCss('div.foo#bar').map((t) => t.toSource()).join(''),
        'div.foo#bar');
    expect(tokenizeCss('a[href="x"]').map((t) => t.toSource()).join(''),
        'a[href="x"]');
    expect(tokenizeCss('3.5em').single.toSource(), '3.5em');
    expect(tokenizeCss('/* comment */div').map((t) => t.toSource()).join(''),
        'div');
  });
}

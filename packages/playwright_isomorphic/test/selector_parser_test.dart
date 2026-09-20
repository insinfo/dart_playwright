// Covers the pieces of selectorParser.ts and stringUtils.ts that the codegen
// leans on. Upstream exercises most of these through the browser; here they
// are pinned directly, using the shapes that appear in upstream's own
// selector strings.

import 'package:playwright_isomorphic/playwright_isomorphic.dart';
import 'package:test/test.dart';

void main() {
  group('parseSelector', () {
    test('splits on >> and keeps the source', () {
      final parsed = parseSelector('div >> internal:text="foo"i >> nth=0');
      expect(parsed.parts.map((p) => p.name).toList(),
          ['css', 'internal:text', 'nth']);
      expect(
          parsed.parts.map((p) => p.source).toList(), ['div', '"foo"i', '0']);
      expect(stringifySelector(parsed), 'div >> internal:text="foo"i >> nth=0');
    });

    test('detects implicit engines', () {
      expect(parseSelector('//div').parts.single.name, 'xpath');
      expect(parseSelector('..').parts.single.name, 'xpath');
      expect(parseSelector('(//div)[1]').parts.single.name, 'xpath');
      expect(parseSelector('"hello"').parts.single.name, 'text');
      expect(parseSelector("'hello'").parts.single.name, 'text');
      expect(parseSelector('div').parts.single.name, 'css');
    });

    test('css:light becomes css with a :light() wrapper', () {
      final parsed = parseSelector('css:light=div');
      expect(parsed.parts.single.name, 'css');
      expect(parsed.parts.single.source, ':light(div)');
    });

    test('forceEngineName prints the engine of css and xpath', () {
      expect(stringifySelector(parseSelector('div'), forceEngineName: true),
          'css=div');
      expect(stringifySelector(parseSelector('//div'), forceEngineName: true),
          'xpath=//div');
      expect(stringifySelector(parseSelector('//div')), '//div');
    });

    test('capture', () {
      final parsed = parseSelector('*css=div >> span');
      expect(parsed.capture, 0);
      expect(stringifySelector(parsed), '*css=div >> span');
      // The "*" prefix only means capture in front of an explicit engine.
      expect(parseSelector('*div').capture, isNull);
      expect(() => parseSelector('*css=div >> *css=span'),
          throwsA(isA<InvalidSelectorError>()));
    });

    test('nested selectors parse their inner selector', () {
      final parsed = parseSelector(r'div >> internal:has="span >> article"');
      final body = parsed.parts[1].body as NestedSelectorBody;
      expect(stringifySelector(body.parsed), 'span >> article');
    });

    test('a nested selector cannot come first', () {
      expect(() => parseSelector('internal:has="div"'),
          throwsA(isA<InvalidSelectorError>()));
    });

    test('layout selectors carry a distance', () {
      final parsed = parseSelector('div >> right-of="span", 10');
      final body = parsed.parts[1].body as NestedSelectorBody;
      expect(body.distance, 10);
    });

    test('invalid css throws', () {
      expect(() => parseSelector('following-sibling::*[1]'),
          throwsA(isA<InvalidSelectorError>()));
      expect(() => parseSelector("getByTestId('Hello')"),
          throwsA(isA<InvalidSelectorError>()));
    });

    test('visitAllSelectorParts descends into nested selectors', () {
      final names = <String>[];
      visitAllSelectorParts(
          parseSelector(r'div >> internal:has="span >> article"'),
          (part, nested) => names.add('${part.name}${nested ? '*' : ''}'));
      expect(names, ['css', 'internal:has', 'css*', 'css*']);
    });
  });

  group('splitSelectorByFrame', () {
    test('splits on enter-frame', () {
      final split = splitSelectorByFrame(
          'iframe >> internal:control=enter-frame >> span');
      expect(split.anyFrame, isFalse);
      expect(split.chunks.length, 2);
      expect(stringifySelector(split.chunks[0]), 'iframe');
      expect(stringifySelector(split.chunks[1]), 'span');
    });

    test('reports the leading any-frame token', () {
      final split = splitSelectorByFrame('internal:control=any-frame >> span');
      expect(split.anyFrame, isTrue);
      expect(split.chunks.length, 1);
      expect(stringifySelector(split.chunks[0]), 'span');
    });

    test('rejects a dangling frame boundary', () {
      expect(() => splitSelectorByFrame('div >> internal:control=enter-frame'),
          throwsA(isA<InvalidSelectorError>()));
      expect(() => splitSelectorByFrame('internal:control=enter-frame >> div'),
          throwsA(isA<InvalidSelectorError>()));
    });
  });

  group('parseAttributeSelector', () {
    test('name and simple attributes', () {
      final parsed = parseAttributeSelector('button[name="Hello"i]', true);
      expect(parsed.name, 'button');
      expect(parsed.attributes.single.name, 'name');
      expect(parsed.attributes.single.value, 'Hello');
      expect(parsed.attributes.single.caseSensitive, isFalse);
    });

    test('truthy attributes and booleans', () {
      final parsed =
          parseAttributeSelector('checkbox[checked=true][disabled]', true);
      expect(parsed.attributes[0].value, true);
      expect(parsed.attributes[1].op, '<truthy>');
    });

    test('regular expression values', () {
      final parsed = parseAttributeSelector(r'row[name=/a\/b/i]', true);
      final value = parsed.attributes.single.value;
      expect(value, isA<JsRegExp>());
      expect((value as JsRegExp).source, r'a\/b');
      expect(value.flags, 'i');
    });

    test('unquoted values stay strings when allowed', () {
      expect(
          parseAttributeSelector('role[level=3]', true).attributes.single.value,
          '3');
      expect(
          parseAttributeSelector('role[level=3]', false)
              .attributes
              .single
              .value,
          3);
    });

    test('malformed input throws', () {
      expect(() => parseAttributeSelector('button[name=', true),
          throwsA(isA<InvalidSelectorError>()));
      expect(() => parseAttributeSelector('', true),
          throwsA(isA<InvalidSelectorError>()));
    });
  });

  group('string utils', () {
    test('escapeWithQuotes', () {
      expect(escapeWithQuotes("it's", "'"), r"'it\'s'");
      expect(escapeWithQuotes('say "hi"', '"'), r'"say \"hi\""');
      expect(escapeWithQuotes('a\nb'), r"'a\nb'");
      expect(() => escapeWithQuotes('x', '!'), throwsA(isA<ArgumentError>()));
    });

    test('toSnakeCase and toTitleCase', () {
      expect(toSnakeCase('ignoreHTTPSErrors'), 'ignore_https_errors');
      expect(toSnakeCase('includeHidden'), 'include_hidden');
      expect(toTitleCase('checked'), 'Checked');
    });

    test('escapeForTextSelector', () {
      expect(escapeForTextSelector('foo', false), '"foo"i');
      expect(escapeForTextSelector('foo', true), '"foo"s');
      expect(escapeForTextSelector(JsRegExp('foo', 'i'), false), '/foo/i');
      // Quotes in a regex are escaped so the selector can carry them.
      expect(escapeForTextSelector(JsRegExp('a"b'), false), r'/a\"b/');
      // ">>" would otherwise split the selector.
      expect(escapeForTextSelector(JsRegExp('a>>b'), false), r'/a\>\>b/');
    });

    test('escapeForAttributeSelector', () {
      expect(escapeForAttributeSelector('a"b', true), r'"a\"b"s');
      expect(escapeForAttributeSelector(r'a\b', false), r'"a\\b"i');
    });

    test('normalizeEscapedRegexQuotes undoes the selector escaping', () {
      expect(normalizeEscapedRegexQuotes(r'/a\"b/'), '/a"b/');
      expect(normalizeEscapedRegexQuotes(r'/a\\\"b/'), r'/a\\"b/');
    });

    test('formatObject sorts keys and drops timeout', () {
      expect(formatObject({'b': 1, 'a': 'x', 'timeout': 5}, mode: 'oneline'),
          "{ a: 'x', b: 1 }");
      expect(formatObjectOrVoid(<String, Object?>{}), '');
    });

    test('normalizeWhiteSpace', () {
      expect(normalizeWhiteSpace('  a \n  b  '), 'a b');
    });
  });

  group('JsRegExp', () {
    test('fromPattern escapes a slash the way JavaScript does', () {
      expect(JsRegExp.fromPattern('a/b').source, r'a\/b');
      expect(JsRegExp.fromPattern(r'a\/b').source, r'a\/b');
      expect(JsRegExp.fromPattern('[a/b]').source, '[a/b]');
      expect(JsRegExp.fromPattern('').source, '(?:)');
    });

    test('parse and toString round trip', () {
      expect(JsRegExp.parse('/a.b/im').source, 'a.b');
      expect(JsRegExp.parse('/a.b/im').flags, 'im');
      expect(JsRegExp('a.b', 'im').toString(), '/a.b/im');
      expect(() => JsRegExp.parse('a.b'), throwsFormatException);
    });

    test('toDart maps the flags it can', () {
      final re = JsRegExp('a', 'ims').toDart();
      expect(re.isCaseSensitive, isFalse);
      expect(re.isMultiLine, isTrue);
      expect(re.isDotAll, isTrue);
    });
  });
}

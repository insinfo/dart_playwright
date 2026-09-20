import 'package:playwright_isomorphic/playwright_isomorphic.dart';
import 'package:test/test.dart';

/// Transcription of upstream's `tests/page/interception.spec.ts`:
/// "should work with glob" and "should throw on unbalanced glob braces".
void main() {
  bool globMatches(String glob, String url) =>
      RegExp(globToRegexPattern(glob)).hasMatch(url);

  group('globToRegexPattern', () {
    test('Deve casar os globs do upstream', () {
      expect(globMatches('**/*.js', 'https://localhost:8080/foo.js'), isTrue);
      expect(globMatches('**/*.css', 'https://localhost:8080/foo.js'), isFalse);
      expect(globMatches('*.js', 'https://localhost:8080/foo.js'), isFalse);
      expect(globMatches('https://**/*.js', 'https://localhost:8080/foo.js'),
          isTrue);
      expect(
          globMatches('http://localhost:8080/simple/path.js',
              'http://localhost:8080/simple/path.js'),
          isTrue);
      expect(globMatches('**/{a,b}.js', 'https://localhost:8080/a.js'), isTrue);
      expect(globMatches('**/{a,b}.js', 'https://localhost:8080/b.js'), isTrue);
      expect(
          globMatches('**/{a,b}.js', 'https://localhost:8080/c.js'), isFalse);

      expect(globMatches('**/*.{png,jpg,jpeg}', 'https://localhost:8080/c.jpg'),
          isTrue);
      expect(
          globMatches('**/*.{png,jpg,jpeg}', 'https://localhost:8080/c.jpeg'),
          isTrue);
      expect(globMatches('**/*.{png,jpg,jpeg}', 'https://localhost:8080/c.png'),
          isTrue);
      expect(globMatches('**/*.{png,jpg,jpeg}', 'https://localhost:8080/c.css'),
          isFalse);
      expect(globMatches('foo*', 'foo.js'), isTrue);
      expect(globMatches('foo*', 'foo/bar.js'), isFalse);
      expect(
          globMatches('http://localhost:3000/signin-oidc*',
              'http://localhost:3000/signin-oidc/foo'),
          isFalse);
      expect(
          globMatches('http://localhost:3000/signin-oidc*',
              'http://localhost:3000/signin-oidcnice'),
          isTrue);

      expect(globMatches('**/*.js', '/foo.js'), isTrue);
      expect(globMatches('asd/**.js', '/foo.js'), isFalse);
      expect(globMatches('**/*.js', 'bar_foo.js'), isFalse);
    });

    test('Nao deve tratar [] como faixa', () {
      expect(globMatches('**/api/v[0-9]', 'http://example.com/api/v[0-9]'),
          isTrue);
      expect(globMatches('**/api/v[0-9]', 'http://example.com/api/version'),
          isFalse);
    });

    test('Deve tratar ? escapado como literal', () {
      expect(globMatches(r'**/api\?param', 'http://example.com/api?param'),
          isTrue);
      expect(globMatches(r'**/api\?param', 'http://example.com/api-param'),
          isFalse);
      expect(
          globMatches(
              r'**/three-columns/settings.html\?**id=settings-**',
              'http://mydomain:8080/blah/blah/three-columns/settings.html'
                  '?id=settings-e3c58efe-02e9-44b0-97ac-dd138100cf7c&blah'),
          isTrue);
    });

    test('Deve escapar os metacaracteres na fonte da regex', () {
      expect(globToRegexPattern(r'\?'), r'^\?$');
      expect(globToRegexPattern('\\'), r'^\\$');
      expect(globToRegexPattern(r'\\'), r'^\\$');
      expect(globToRegexPattern(r'\['), r'^\[$');
      expect(globToRegexPattern('[a-z]'), r'^\[a-z\]$');
      expect(globToRegexPattern(r'$^+.\*()|\?\{\}\[\]'),
          r'^\$\^\+\.\*\(\)\|\?\{\}\[\]$');
    });

    test('Deve recusar chaves desbalanceadas', () {
      expect(() => globToRegexPattern('{foo'),
          throwsA(predicate((e) => '$e'.contains("unmatched '{'"))));
      expect(() => globToRegexPattern('}foo'),
          throwsA(predicate((e) => '$e'.contains("unmatched '}'"))));
      expect(() => globToRegexPattern('http://*/foo{'),
          throwsA(predicate((e) => '$e'.contains("unmatched '{'"))));
      expect(() => globToRegexPattern('**/*.png?{'),
          throwsA(predicate((e) => '$e'.contains("unmatched '{'"))));
      expect(() => globToRegexPattern('https://example.com/{a'),
          throwsA(predicate((e) => '$e'.contains("unmatched '{'"))));
      expect(
          () => globToRegexPattern('{{foo}'),
          throwsA(
              predicate((e) => '$e'.contains("nested '{' is not supported"))));
      // Escaped braces remain literal and must not throw.
      expect(globToRegexPattern(r'\{foo'), r'^\{foo$');
      expect(globToRegexPattern(r'foo\}'), r'^foo\}$');
    });
  });

  group('urlMatches', () {
    test('Deve resolver o glob contra a URL antes de casar', () {
      expect(
          urlMatches(null, 'http://playwright.dev/', 'http://playwright.dev'),
          isTrue);
      expect(
          urlMatches(
              null, 'http://playwright.dev/?a=b', 'http://playwright.dev?a=b'),
          isTrue);
      expect(urlMatches(null, 'http://playwright.dev/', 'h*://playwright.dev'),
          isTrue);
      expect(
          urlMatches(null, 'http://api.playwright.dev/?x=y',
              'http://*.playwright.dev?x=y'),
          isTrue);
      expect(urlMatches(null, 'http://playwright.dev/foo/bar', '**/foo/**'),
          isTrue);
      expect(
          urlMatches(
              'http://playwright.dev', 'http://playwright.dev/?x=y', '?x=y'),
          isTrue);
      expect(
          urlMatches('http://playwright.dev/foo/',
              'http://playwright.dev/foo/bar?x=y', './bar?x=y'),
          isTrue);
    });

    test('Deve tratar \$\$ e \$& como literais na substituicao', () {
      expect(
          urlMatches(null, r'http://playwright.dev/foo$$bar',
              r'http://playwright.dev/foo$$bar'),
          isTrue);
      expect(
          urlMatches(null, r'http://playwright.dev/a$&b',
              r'http://playwright.dev/a$&b'),
          isTrue);
      expect(
          urlMatches('http://playwright.dev', r'http://playwright.dev/p$$q',
              r'./p$$q'),
          isTrue);
    });

    test('Deve casar esquema e host sem diferenciar maiusculas', () {
      expect(
          urlMatches(null, 'https://playwright.dev/fooBAR',
              'HtTpS://pLaYwRiGhT.dEv/fooBAR'),
          isTrue);
      expect(
          urlMatches('http://ignored', 'https://playwright.dev/fooBAR',
              'HtTpS://pLaYwRiGhT.dEv/fooBAR'),
          isTrue);
      // Path and search query are case-sensitive.
      expect(
          urlMatches(null, 'https://playwright.dev/foobar',
              'https://playwright.dev/fooBAR'),
          isFalse);
      expect(
          urlMatches(null, 'https://playwright.dev/foobar?a=b',
              'https://playwright.dev/foobar?A=B'),
          isFalse);
    });

    test('Deve normalizar porta padrao e percent-encoding', () {
      expect(
          urlMatches(
              null, 'http://example.com/path', 'http://example.com:80/path'),
          isTrue);
      expect(
          urlMatches(
              null, 'https://example.com/path', 'https://example.com:443/path'),
          isTrue);
      expect(
          urlMatches(null, 'http://example.com:8080/path',
              'http://example.com:8080/path'),
          isTrue);
      expect(urlMatches(null, 'http://localhost/', 'http://localhost:80/**'),
          isTrue);
      expect(
          urlMatches(null, 'http://example.com/foo%20bar',
              'http://example.com/foo bar'),
          isTrue);
    });

    // Documented divergence: `dart:core`'s Uri percent-encodes a Unicode host
    // instead of punycoding it, so upstream's IDN case cannot pass here. The
    // ASCII form of the same host does, which is the workaround.
    test('Host IDN em unicode nao casa; a forma xn-- casa', () {
      expect(
          urlMatches(null, 'http://xn--mnchen-3ya.de/', 'http://münchen.de/'),
          isFalse,
          reason: 'upstream matches here because `new URL()` punycodes');
      expect(
          urlMatches(
              null, 'http://xn--mnchen-3ya.de/', 'http://xn--mnchen-3ya.de/'),
          isTrue);
    });

    test('Deve casar consultas com **', () {
      expect(
          urlMatches(null, 'https://localhost:3000/?a=b', '**/?a=b'), isTrue);
      expect(urlMatches(null, 'https://localhost:3000/?a=b', '**?a=b'), isTrue);
      expect(urlMatches(null, 'https://localhost:3000/?a=b', '**=b'), isTrue);
    });

    test('Deve aceitar esquema customizado', () {
      expect(
          urlMatches(
              null, 'my.custom.protocol://foo', 'my.custom.protocol://**'),
          isTrue);
      expect(urlMatches(null, 'my.p://foo', 'my.{p,y}://**'), isFalse);
      expect(urlMatches(null, 'my.p://foo/', 'my.{p,y}://**'), isTrue);
      expect(urlMatches(null, 'file:///foo/', 'f*e://**'), isTrue);
    });

    test('? e separador de consulta, nao curinga de um caractere', () {
      expect(
          globMatches('http://localhost:8080/?imple/path.js',
              'http://localhost:8080/Simple/path.js'),
          isFalse);
      expect(
          urlMatches(null, 'http://playwright.dev/', 'http://playwright.?ev'),
          isFalse);
      expect(
          urlMatches(null, 'http://playwright./?ev', 'http://playwright.?ev'),
          isTrue);
      expect(
          urlMatches(
              null, 'http://playwright.dev/foo', 'http://playwright.dev/f??'),
          isFalse);
      expect(
          urlMatches(
              null, 'http://playwright.dev/f??', 'http://playwright.dev/f??'),
          isTrue);
      expect(
          urlMatches(null, 'http://playwright.dev/?x=y',
              r'http://playwright.dev\?x=y'),
          isTrue);
      expect(
          urlMatches(null, 'http://playwright.dev/?x=y',
              r'http://playwright.dev/\?x=y'),
          isTrue);
      expect(
          urlMatches('http://playwright.dev/foo',
              'http://playwright.dev/foo?bar', '?bar'),
          isTrue);
      expect(
          urlMatches('http://playwright.dev/foo',
              'http://playwright.dev/foo?bar', r'\\?bar'),
          isTrue);
    });

    test('Um glob ancorado ignora o baseURL', () {
      expect(
          urlMatches('http://first.host/', 'http://second.host/foo', '**/foo'),
          isTrue);
      expect(
          urlMatches(
              'http://playwright.dev/', 'http://localhost/', '*//localhost/'),
          isTrue);
    });

    test('/**/ deve casar uma barra so', () {
      expect(urlMatches(null, 'https://foo/bar.js', 'https://foo/**/bar.js'),
          isTrue);
      expect(urlMatches(null, 'https://foo/bar.js', 'https://foo/**/**/bar.js'),
          isTrue);
    });

    test('Esquemas que nao resolvem contra o baseURL', () {
      for (final prefix in ['about', 'data', 'chrome', 'edge', 'file']) {
        expect(
            urlMatches(
                'http://playwright.dev/', '$prefix:blank', '$prefix:blank'),
            isTrue,
            reason: prefix);
        expect(
            urlMatches('http://playwright.dev/', '$prefix:blank',
                'http://playwright.dev/'),
            isFalse,
            reason: prefix);
        expect(urlMatches(null, '$prefix:blank', '$prefix:blank'), isTrue,
            reason: prefix);
        expect(urlMatches(null, '$prefix:blank', '$prefix:*'), isTrue,
            reason: prefix);
        expect(urlMatches(null, 'not$prefix:blank', '$prefix:*'), isFalse,
            reason: prefix);
      }
    });

    test('Um matcher vazio ou nulo casa tudo', () {
      expect(urlMatches(null, 'http://example.com/', null), isTrue);
      expect(urlMatches(null, 'http://example.com/', ''), isTrue);
    });

    test('Deve aceitar RegExp e predicado', () {
      expect(urlMatches(null, 'http://example.com/a', RegExp(r'/a$')), isTrue);
      expect(urlMatches(null, 'http://example.com/a', RegExp(r'/b$')), isFalse);
      expect(
          urlMatches(null, 'http://example.com/a',
              (Uri url) => url.host == 'example.com'),
          isTrue);
    });

    test('baseURL http vira ws para casar um WebSocket', () {
      expect(
          urlMatches(
              'http://localhost:8080', 'ws://localhost:8080/chat', '/chat',
              webSocketUrl: true),
          isTrue);
      expect(
          urlMatches(
              'https://localhost:8080', 'wss://localhost:8080/chat', '/chat',
              webSocketUrl: true),
          isTrue);
    });
  });

  group('constructURLBasedOnBaseURL', () {
    test('Deve resolver relativo contra a base', () {
      expect(constructURLBasedOnBaseURL('http://example.com/a/', 'b'),
          'http://example.com/a/b');
      expect(constructURLBasedOnBaseURL(null, 'http://example.com/a'),
          'http://example.com/a');
      expect(constructURLBasedOnBaseURL('http://example.com', '/a'),
          'http://example.com/a');
    });
  });

  group('urlMatchesEqual', () {
    test('Deve comparar globs e regexes', () {
      expect(urlMatchesEqual('**/a', '**/a'), isTrue);
      expect(urlMatchesEqual('**/a', '**/b'), isFalse);
      expect(urlMatchesEqual(RegExp('a'), RegExp('a')), isTrue);
      expect(urlMatchesEqual(RegExp('a'), RegExp('a', caseSensitive: false)),
          isFalse);
    });
  });

  group('isHttpUrl', () {
    test('Deve reconhecer http e https', () {
      expect(isHttpUrl('http://example.com'), isTrue);
      expect(isHttpUrl('https://example.com'), isTrue);
      expect(isHttpUrl('ws://example.com'), isFalse);
      expect(isHttpUrl('/foo', base: 'http://example.com'), isTrue);
      expect(isHttpUrl('not a url'), isFalse);
    });
  });
}

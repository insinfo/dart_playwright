import 'dart:async';
import 'dart:convert';

import 'package:playwright/playwright.dart';
import 'package:test/test.dart' show Matcher, StringDescription, wrapMatcher;

import 'soft_failures.dart';

/// How long an assertion retries before giving up.
const kDefaultAssertionTimeout = Duration(seconds: 5);

/// Thrown when an assertion never came true within its timeout.
///
/// Carries what was expected and what was last seen, because "expected
/// visible" on its own does not tell you whether the element was hidden,
/// detached, or never there.
class AssertionFailure implements Exception {
  final String description;
  final String expected;
  final String actual;

  AssertionFailure({
    required this.description,
    required this.expected,
    required this.actual,
  });

  @override
  String toString() => 'Expected $description to $expected.\n'
      'Last seen: $actual';
}

/// Polls [probe] until it reports success or [timeout] elapses.
///
/// Every assertion here retries. That is the point: a locator assertion in a
/// browser is a race by nature, and an assertion that reads the page once is
/// a flaky test waiting to happen.
Future<void> _retry(
  String description,
  String expected,
  Duration timeout,
  Future<({bool ok, String actual})> Function() probe,
) async {
  final deadline = DateTime.now().add(timeout);
  var actual = '(never evaluated)';
  while (true) {
    try {
      final result = await probe();
      if (result.ok) return;
      actual = result.actual;
    } on ArgumentError {
      // Argumento errado e erro de quem escreveu o teste, nao condicao que
      // ainda nao valeu: esperar o prazo inteiro para depois dizer "nao bateu"
      // esconderia a causa real. Mesma regra que `Locator` ja usa para
      // seletor invalido.
      rethrow;
    } catch (error) {
      actual = 'error: $error';
    }
    if (!DateTime.now().isBefore(deadline)) {
      throw AssertionFailure(
          description: description, expected: expected, actual: actual);
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

bool _matches(Pattern pattern, String value) {
  if (pattern is RegExp) return pattern.hasMatch(value);
  return value == pattern.toString();
}

String _describe(Pattern pattern) =>
    pattern is RegExp ? 'match ${pattern.pattern}' : 'be "$pattern"';

/// Roda uma assertion, deixando a falha passar ou guardando-a.
///
/// No modo soft a falha nao interrompe o teste: ela e guardada e o teste
/// termina falhando com todas de uma vez.
Future<void> _report(bool soft, Future<void> Function() run) async {
  if (!soft) return run();
  try {
    await run();
  } on AssertionFailure catch (failure) {
    recordSoftFailure(failure);
  }
}

/// Compara dois valores vindos do navegador em profundidade.
///
/// JSON nao tem inteiros e doubles separados e os motores discordam sobre qual
/// dos dois devolvem, entao 1 e 1.0 sao o mesmo numero aqui.
bool _deepEquals(Object? a, Object? b) {
  if (a is num && b is num) return a.toDouble() == b.toDouble();
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key)) return false;
      if (!_deepEquals(a[key], b[key])) return false;
    }
    return true;
  }
  return a == b;
}

/// Retrying assertions about a [Locator].
///
/// Reached through [expectLocator].
class LocatorAssertions {
  final Locator _locator;
  final Duration _timeout;
  final bool _isNot;
  final bool _isSoft;

  LocatorAssertions(this._locator,
      {Duration timeout = kDefaultAssertionTimeout,
      bool isNot = false,
      bool isSoft = false})
      : _timeout = timeout,
        _isNot = isNot,
        _isSoft = isSoft;

  /// The negated form: `expectLocator(l).not.toBeVisible()`.
  LocatorAssertions get not => LocatorAssertions(_locator,
      timeout: _timeout, isNot: !_isNot, isSoft: _isSoft);

  /// A forma que nao interrompe o teste: `expectLocator(l).soft.toBeVisible()`.
  ///
  /// A falha e guardada e o teste segue; no fim ele falha com todas as falhas
  /// soft juntas. E o `expect.soft` do upstream — em Dart nao da para pendurar
  /// um membro no `expect` de `package:test`, entao ele vira um getter aqui.
  LocatorAssertions get soft => LocatorAssertions(_locator,
      timeout: _timeout, isNot: _isNot, isSoft: true);

  String get _what => 'locator';

  Future<void> _check(
      String expected, Future<({bool ok, String actual})> Function() probe) {
    return _report(_isSoft, () {
      if (!_isNot) return _retry(_what, expected, _timeout, probe);
      return _retry(_what, 'not $expected', _timeout, () async {
        final result = await probe();
        return (ok: !result.ok, actual: result.actual);
      });
    });
  }

  /// The element is attached and visible.
  Future<void> toBeVisible() => _check('be visible', () async {
        final visible = await _locator.isVisible();
        return (ok: visible, actual: visible ? 'visible' : 'hidden or absent');
      });

  /// The element is absent or not visible.
  Future<void> toBeHidden() => _check('be hidden', () async {
        final hidden = await _locator.isHidden();
        return (ok: hidden, actual: hidden ? 'hidden or absent' : 'visible');
      });

  /// The element exists in the DOM.
  Future<void> toBeAttached() => _check('be attached', () async {
        final count = await _locator.count();
        return (ok: count > 0, actual: '$count element(s)');
      });

  /// The element is enabled.
  Future<void> toBeEnabled() => _check('be enabled', () async {
        final enabled = await _locator.isEnabled();
        return (ok: enabled, actual: enabled ? 'enabled' : 'disabled');
      });

  /// The element is disabled.
  Future<void> toBeDisabled() => _check('be disabled', () async {
        final disabled = await _locator.isDisabled();
        return (ok: disabled, actual: disabled ? 'disabled' : 'enabled');
      });

  /// The element is editable.
  Future<void> toBeEditable() => _check('be editable', () async {
        final editable = await _locator.isEditable();
        return (ok: editable, actual: editable ? 'editable' : 'not editable');
      });

  /// The checkbox or radio is checked.
  Future<void> toBeChecked({bool checked = true}) =>
      _check(checked ? 'be checked' : 'be unchecked', () async {
        final isChecked = await _locator.isChecked();
        return (
          ok: isChecked == checked,
          actual: isChecked ? 'checked' : 'unchecked'
        );
      });

  /// The element is the active element of its document.
  Future<void> toBeFocused() => _check('be focused', () async {
        final focused = await _locator
            .evaluate('(el) => el.ownerDocument.activeElement === el');
        return (
          ok: focused == true,
          actual: focused == true ? 'focused' : 'not focused'
        );
      });

  /// The element has no text and no child elements.
  Future<void> toBeEmpty() => _check('be empty', () async {
        final text = await _locator.textContent();
        return (ok: text.trim().isEmpty, actual: '"$text"');
      });

  /// The element's text equals [expected], after whitespace normalization.
  Future<void> toHaveText(Pattern expected) =>
      _check('have text that would ${_describe(expected)}', () async {
        final text = _normalize(await _locator.textContent());
        return (ok: _matches(expected, text), actual: '"$text"');
      });

  /// The element's text contains [expected].
  Future<void> toContainText(Pattern expected) =>
      _check('contain "$expected"', () async {
        final text = _normalize(await _locator.textContent());
        final ok = expected is RegExp
            ? expected.hasMatch(text)
            : text.contains(expected.toString());
        return (ok: ok, actual: '"$text"');
      });

  /// The input's value equals [expected].
  Future<void> toHaveValue(Pattern expected) =>
      _check('have a value that would ${_describe(expected)}', () async {
        final value = await _locator.inputValue();
        return (ok: _matches(expected, value), actual: '"$value"');
      });

  /// The element has [name], optionally with [value].
  Future<void> toHaveAttribute(String name, [Pattern? value]) => _check(
        value == null
            ? 'have the attribute "$name"'
            : 'have $name that would ${_describe(value)}',
        () async {
          final actual = await _locator.getAttribute(name);
          if (actual == null) return (ok: false, actual: 'absent');
          return (
            ok: value == null || _matches(value, actual),
            actual: '"$actual"'
          );
        },
      );

  /// The element's class list contains [className].
  Future<void> toHaveClass(String className) =>
      _check('have the class "$className"', () async {
        final classes = await _locator.getAttribute('class') ?? '';
        return (
          ok: classes.split(RegExp(r'\s+')).contains(className),
          actual: '"$classes"'
        );
      });

  /// The locator resolves to exactly [count] elements.
  Future<void> toHaveCount(int count) =>
      _check('resolve to $count element(s)', () async {
        final actual = await _locator.count();
        return (ok: actual == count, actual: '$actual');
      });

  /// The element's accessibility tree matches the aria snapshot [template].
  ///
  /// ```dart
  /// await expectLocator(page.locator('nav')).toMatchAriaSnapshot('''
  ///   - navigation "Menu":
  ///     - link "Home"
  ///     - link "About"
  /// ''');
  /// ```
  ///
  /// The template is upstream's aria snapshot YAML, and matching follows
  /// upstream: children are *contained* in document order unless the template
  /// says `- /children: equal` or `deep-equal`, a bare role matches any name,
  /// and a name written as `/pattern/` is a regular expression. On failure the
  /// error carries the page's actual snapshot, which is what you paste back
  /// into the template.
  ///
  /// Upstream's `[active]` is rejected rather than ignored: this port does not
  /// compute the focused node, and quietly dropping the attribute would make
  /// the assertion pass on any node.
  Future<void> toMatchAriaSnapshot(String template) => _check(
      'match the aria snapshot',
      _ariaSnapshotProbe(
          template, _locator.accessibilitySnapshot, _locator.ariaSnapshot));

  // ------------------------------------------------------ novos matchers

  /// O valor computado da propriedade CSS [name].
  ///
  /// E o valor *computado*, como no upstream: quem escreveu `color: red`
  /// compara com `rgb(255, 0, 0)`. Nao ha normalizacao de espacos — um
  /// shorthand computado vem com os espacos que o motor escolheu, e esconder
  /// isso faria a assertion passar por acidente entre motores diferentes.
  Future<void> toHaveCSS(String name, Pattern expected) =>
      _check('have CSS $name that would ${_describe(expected)}', () async {
        final value = await _locator.evaluate(
            '(el) => getComputedStyle(el).getPropertyValue(${jsonEncode(name)})');
        final actual = value?.toString() ?? '';
        return (ok: _matches(expected, actual), actual: '"$actual"');
      });

  /// O atributo `id` do elemento.
  Future<void> toHaveId(Pattern expected) =>
      _check('have an id that would ${_describe(expected)}', () async {
        final value = await _locator.evaluate('(el) => el.id');
        final actual = value?.toString() ?? '';
        return (ok: _matches(expected, actual), actual: '"$actual"');
      });

  /// A propriedade JavaScript [name] do elemento vale [expected].
  ///
  /// [name] aceita caminho com pontos (`dataset.estado`), como no upstream. A
  /// comparacao e estrutural: listas e mapas sao comparados em profundidade, e
  /// o valor precisa sobreviver a viagem em JSON.
  Future<void> toHaveJSProperty(String name, Object? expected) =>
      _check('have the JS property $name equal to ${jsonEncode(expected)}',
          () async {
        final result = await _locator.evaluate('''
          (el) => {
            let current = el;
            for (const part of ${jsonEncode(name.split('.'))}) {
              if (current === null || current === undefined) return { found: false };
              current = current[part];
            }
            return { found: current !== undefined, value: current };
          }
        ''');
        final map = (result as Map?) ?? const {};
        if (map['found'] != true) return (ok: false, actual: 'undefined');
        final actual = map['value'];
        return (ok: _deepEquals(actual, expected), actual: jsonEncode(actual));
      });

  /// Os valores selecionados de um `<select multiple>`.
  ///
  /// A ordem e a do documento e a quantidade tem de bater exatamente, como no
  /// upstream. O elemento tem de ser um `select` com `multiple`: qualquer outra
  /// coisa e erro de quem escreveu o teste, nao assertion que falha.
  Future<void> toHaveValues(List<Pattern> expected) => _check(
        'have the selected values [${expected.map(_describe).join(', ')}]',
        () async {
          final result = await _locator.evaluate('''
            (el) => {
              if (el.nodeName !== 'SELECT' || !el.multiple)
                return { error: el.nodeName };
              return { values: Array.from(el.selectedOptions).map((o) => o.value) };
            }
          ''');
          final map = (result as Map?) ?? const {};
          if (map['error'] != null) {
            throw ArgumentError('toHaveValues espera um <select multiple>, e o '
                'locator resolveu para <${map['error']}>');
          }
          final values = (map['values'] as List).map((v) => '$v').toList();
          final ok = values.length == expected.length &&
              [
                for (var i = 0; i < values.length; i++)
                  _matches(expected[i], values[i])
              ].every((match) => match);
          return (ok: ok, actual: jsonEncode(values));
        },
      );

  /// O elemento aparece dentro da janela.
  ///
  /// [ratio] e a fracao minima da area do elemento que precisa estar visivel;
  /// sem ele basta qualquer pedaco. Um elemento de area zero nunca passa, nem
  /// com `ratio: 0`.
  ///
  /// O upstream usa `IntersectionObserver`. Aqui a conta sai de
  /// `getBoundingClientRect`, intersectada tambem com os ancestrais que cortam
  /// (`overflow` diferente de `visible`), porque avaliar uma expressao num
  /// locator neste port nao espera Promise — e o observer so responde por
  /// callback. O que a diferenca custa: `IntersectionObserver` tambem para em
  /// `visibility: hidden` e em `clip-path`, e esta conta nao.
  Future<void> toBeInViewport({double? ratio}) => _check(
        ratio == null
            ? 'be in the viewport'
            : 'be at least ${(ratio * 100).toStringAsFixed(0)}% in the viewport',
        () async {
          final result = await _locator.evaluate(r'''
            (el) => {
              const rect = el.getBoundingClientRect();
              const area = rect.width * rect.height;
              if (area <= 0) return 0;
              let left = rect.left, top = rect.top;
              let right = rect.right, bottom = rect.bottom;
              const clip = (l, t, r, b) => {
                left = Math.max(left, l); top = Math.max(top, t);
                right = Math.min(right, r); bottom = Math.min(bottom, b);
              };
              clip(0, 0,
                  window.innerWidth || document.documentElement.clientWidth,
                  window.innerHeight || document.documentElement.clientHeight);
              for (let node = el.parentElement; node; node = node.parentElement) {
                const style = getComputedStyle(node);
                if (style.overflow === 'visible' && style.overflowX === 'visible' &&
                    style.overflowY === 'visible')
                  continue;
                const box = node.getBoundingClientRect();
                clip(box.left, box.top, box.right, box.bottom);
              }
              const width = Math.max(0, right - left);
              const height = Math.max(0, bottom - top);
              return (width * height) / area;
            }
          ''');
          final visible = (result as num?)?.toDouble() ?? 0;
          // O epsilon e o do upstream: sem ele `ratio: 1` reprova por erro de
          // ponto flutuante num elemento que esta inteiro na tela.
          final ok = visible > 0 && visible > (ratio ?? 0) - 1e-9;
          return (ok: ok, actual: '${(visible * 100).toStringAsFixed(1)}%');
        },
      );

  /// O nome acessivel do elemento, com espacos normalizados.
  Future<void> toHaveAccessibleName(Pattern expected) =>
      _check('have an accessible name that would ${_describe(expected)}',
          () async {
        final name = await _locator.accessibleName();
        return (ok: _matches(expected, name), actual: '"$name"');
      });

  /// A descricao acessivel do elemento, com espacos normalizados.
  ///
  /// A ordem e a do upstream: `aria-describedby` (o texto de cada elemento
  /// referenciado, juntado por espaco), depois `aria-description`, depois
  /// `title`.
  ///
  /// O texto de um elemento referenciado sai de `aria-label`, senao do nome
  /// acessivel, senao do conteudo. Esse ultimo degrau existe porque o alvo de
  /// um `aria-describedby` quase sempre e um `<span>` ou `<p>`, cujo papel nao
  /// aceita nome vindo do conteudo — o nome acessivel dele e vazio, e so o
  /// conteudo diz o que a descricao e. O upstream chega ao mesmo lugar por
  /// dentro, com um passo de travessia que este port nao expoe.
  Future<void> toHaveAccessibleDescription(Pattern expected) =>
      _check('have an accessible description that would ${_describe(expected)}',
          () async {
        final value = await _locator.evaluate(r'''
          (el) => {
            const pw = window.__pwDart;
            const flat = (text) => pw.normalizeWhiteSpace(text || '');
            const textOf = (ref) => {
              const label = ref.getAttribute('aria-label');
              if (label && label.trim()) return label;
              return pw.accessibleName(ref, true) || ref.textContent || '';
            };
            if (el.hasAttribute('aria-describedby')) {
              const root = el.getRootNode();
              const parts = el.getAttribute('aria-describedby').split(/\s+/)
                  .filter(Boolean)
                  .map((id) => root.getElementById ? root.getElementById(id) : null)
                  .filter(Boolean)
                  .map(textOf);
              return flat(parts.join(' '));
            }
            if (el.hasAttribute('aria-description'))
              return flat(el.getAttribute('aria-description'));
            return flat(el.getAttribute('title'));
          }
        ''');
        final actual = value?.toString() ?? '';
        return (ok: _matches(expected, actual), actual: '"$actual"');
      });

  /// O papel ARIA computado do elemento.
  ///
  /// So aceita String, como no upstream: um papel ARIA sai de uma lista
  /// fechada, e uma expressao regular ali quase sempre e um `toHaveAttribute`
  /// escrito no lugar errado.
  Future<void> toHaveRole(String expected) =>
      _check('have the ARIA role "$expected"', () async {
        final role = await _locator.ariaRole() ?? '';
        return (ok: role == expected, actual: '"$role"');
      });

  static String _normalize(String value) =>
      value.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Shared body of `toMatchAriaSnapshot`.
///
/// The template is parsed once, up front: a typo in the YAML is the author's
/// mistake and should fail immediately, not retry for five seconds and then
/// report "the page never matched".
Future<({bool ok, String actual})> Function() _ariaSnapshotProbe(
  String template,
  Future<AccessibilitySnapshot> Function() snapshot,
  Future<String> Function() rendered,
) {
  final parsed = parseAriaTemplate(template);
  return () async {
    final tree = await snapshot();
    if (ariaTemplateMatches(tree.root, parsed)) {
      return (ok: true, actual: '(matched)');
    }
    return (ok: false, actual: await rendered());
  };
}

/// Retrying assertions about a [Page].
class PageAssertions {
  final Page _page;
  final Duration _timeout;
  final bool _isNot;

  final bool _isSoft;

  PageAssertions(this._page,
      {Duration timeout = kDefaultAssertionTimeout,
      bool isNot = false,
      bool isSoft = false})
      : _timeout = timeout,
        _isNot = isNot,
        _isSoft = isSoft;

  PageAssertions get not =>
      PageAssertions(_page, timeout: _timeout, isNot: !_isNot, isSoft: _isSoft);

  /// A forma que registra a falha e deixa o teste continuar.
  PageAssertions get soft =>
      PageAssertions(_page, timeout: _timeout, isNot: _isNot, isSoft: true);

  Future<void> _check(
      String expected, Future<({bool ok, String actual})> Function() probe) {
    return _report(_isSoft, () {
      if (!_isNot) return _retry('page', expected, _timeout, probe);
      return _retry('page', 'not $expected', _timeout, () async {
        final result = await probe();
        return (ok: !result.ok, actual: result.actual);
      });
    });
  }

  /// The page title matches [expected].
  Future<void> toHaveTitle(Pattern expected) =>
      _check('have a title that would ${_describe(expected)}', () async {
        final title = await _page.title();
        return (ok: _matches(expected, title), actual: '"$title"');
      });

  /// The page URL matches [expected].
  Future<void> toHaveURL(Pattern expected) =>
      _check('have a URL that would ${_describe(expected)}', () async {
        final url = await _page.url();
        return (ok: _matches(expected, url), actual: '"$url"');
      });

  /// The page body's accessibility tree matches the aria snapshot [template].
  ///
  /// See [LocatorAssertions.toMatchAriaSnapshot] for the format and the
  /// matching rules.
  Future<void> toMatchAriaSnapshot(String template) => _check(
      'match the aria snapshot',
      _ariaSnapshotProbe(
          template, _page.accessibilitySnapshot, _page.ariaSnapshot));
}

/// Assertions about an [APIResponse]. These do not retry: a response is
/// already settled by the time you hold one.
class APIResponseAssertions {
  final APIResponse _response;
  final bool _isNot;
  final bool _isSoft;

  APIResponseAssertions(this._response,
      {bool isNot = false, bool isSoft = false})
      : _isNot = isNot,
        _isSoft = isSoft;

  APIResponseAssertions get not =>
      APIResponseAssertions(_response, isNot: !_isNot, isSoft: _isSoft);

  /// A forma que registra a falha e deixa o teste continuar.
  APIResponseAssertions get soft =>
      APIResponseAssertions(_response, isNot: _isNot, isSoft: true);

  /// The status is in the 200-299 range.
  Future<void> toBeOK() => _report(_isSoft, () async {
        final ok = _response.ok();
        if (ok != _isNot) return;
        throw AssertionFailure(
          description: 'response ${_response.url()}',
          expected: _isNot ? 'not be OK' : 'be OK',
          actual: '${_response.status()} ${_response.statusText()}',
        );
      });
}

/// Assertions about a locator: `await expectLocator(l).toBeVisible()`.
LocatorAssertions expectLocator(Locator locator,
        {Duration timeout = kDefaultAssertionTimeout}) =>
    LocatorAssertions(locator, timeout: timeout);

/// Assertions about a page: `await expectPage(p).toHaveTitle('Home')`.
PageAssertions expectPage(Page page,
        {Duration timeout = kDefaultAssertionTimeout}) =>
    PageAssertions(page, timeout: timeout);

/// Assertions about an API response.
APIResponseAssertions expectResponse(APIResponse response) =>
    APIResponseAssertions(response);

/// Os intervalos entre tentativas de [expectPoll], em milissegundos.
///
/// Sao os do upstream: rapido no comeco, porque a maioria das condicoes fica
/// pronta quase de imediato, e o ultimo valor se repete ate o prazo acabar.
const kDefaultPollIntervals = [
  Duration(milliseconds: 100),
  Duration(milliseconds: 250),
  Duration(milliseconds: 500),
  Duration(seconds: 1),
];

/// Repete [actual] ate que [matcher] aceite o valor, ou ate o prazo acabar.
///
/// E o `expect.poll` do upstream. Serve para o que nao e um locator e mesmo
/// assim leva tempo para ficar pronto — uma API que ainda esta processando, um
/// arquivo que o app vai escrever, um contador que sobe:
///
/// ```dart
/// await expectPoll(
///   () async => (await t.context.request.get('/api/jobs/7')).status(),
///   equals(200),
/// );
/// ```
///
/// [matcher] e um `Matcher` de `package:test`, ou um valor simples (que vira
/// `equals`). Com [soft] a falha e guardada e o teste segue, falhando no fim.
Future<void> expectPoll<T>(
  FutureOr<T> Function() actual,
  Object? matcher, {
  Duration timeout = kDefaultAssertionTimeout,
  List<Duration> intervals = kDefaultPollIntervals,
  String? reason,
  bool soft = false,
}) {
  final Matcher wrapped = wrapMatcher(matcher);
  return _report(soft, () async {
    final deadline = DateTime.now().add(timeout);
    var attempt = 0;
    var last = '(never evaluated)';
    while (true) {
      try {
        final value = await actual();
        if (wrapped.matches(value, <Object?, Object?>{})) return;
        last = StringDescription().addDescriptionOf(value).toString();
      } catch (error) {
        // Uma funcao que ainda explode e uma condicao que ainda nao valeu: o
        // motivo entra na mensagem final e a proxima tentativa acontece.
        last = 'error: $error';
      }
      if (!DateTime.now().isBefore(deadline)) {
        throw AssertionFailure(
          description: reason ?? 'polled value',
          expected: StringDescription().addDescriptionOf(wrapped).toString(),
          actual: last,
        );
      }
      final interval = intervals.isEmpty
          ? const Duration(milliseconds: 100)
          : intervals[
              attempt < intervals.length ? attempt : intervals.length - 1];
      attempt++;
      await Future<void>.delayed(interval);
    }
  });
}

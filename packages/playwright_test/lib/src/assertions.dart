import 'dart:async';

import 'package:playwright/playwright.dart';

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

/// Retrying assertions about a [Locator].
///
/// Reached through [expectLocator].
class LocatorAssertions {
  final Locator _locator;
  final Duration _timeout;
  final bool _isNot;

  LocatorAssertions(this._locator,
      {Duration timeout = kDefaultAssertionTimeout, bool isNot = false})
      : _timeout = timeout,
        _isNot = isNot;

  /// The negated form: `expectLocator(l).not.toBeVisible()`.
  LocatorAssertions get not =>
      LocatorAssertions(_locator, timeout: _timeout, isNot: !_isNot);

  String get _what => 'locator';

  Future<void> _check(
      String expected, Future<({bool ok, String actual})> Function() probe) {
    if (!_isNot) return _retry(_what, expected, _timeout, probe);
    return _retry(_what, 'not $expected', _timeout, () async {
      final result = await probe();
      return (ok: !result.ok, actual: result.actual);
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

  PageAssertions(this._page,
      {Duration timeout = kDefaultAssertionTimeout, bool isNot = false})
      : _timeout = timeout,
        _isNot = isNot;

  PageAssertions get not =>
      PageAssertions(_page, timeout: _timeout, isNot: !_isNot);

  Future<void> _check(
      String expected, Future<({bool ok, String actual})> Function() probe) {
    if (!_isNot) return _retry('page', expected, _timeout, probe);
    return _retry('page', 'not $expected', _timeout, () async {
      final result = await probe();
      return (ok: !result.ok, actual: result.actual);
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

  APIResponseAssertions(this._response, {bool isNot = false}) : _isNot = isNot;

  APIResponseAssertions get not =>
      APIResponseAssertions(_response, isNot: !_isNot);

  /// The status is in the 200-299 range.
  Future<void> toBeOK() async {
    final ok = _response.ok();
    if (ok != _isNot) return;
    throw AssertionFailure(
      description: 'response ${_response.url()}',
      expected: _isNot ? 'not be OK' : 'be OK',
      actual: '${_response.status()} ${_response.statusText()}',
    );
  }
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

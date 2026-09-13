import 'dart:convert';

import 'package:playwright_protocol/playwright_protocol.dart'
    show PlaywrightException, TimeoutException;
import 'package:playwright_core/src/server/core_js_handle.dart';
import 'package:playwright_core/src/server/core_element_handle.dart';
import 'package:playwright_core/src/server/core_page.dart';
import 'package:playwright_core/src/server/selectors.dart';

import 'element_handle.dart';
import 'frame.dart';
import 'frame_locator.dart';
import 'js_handle.dart';
import 'page.dart';

export 'package:playwright_core/src/server/selectors.dart'
    show RoleOptions, Selectors, TextMatch;

/// The default timeout for locator actions and waits.
const Duration kDefaultLocatorTimeout = Duration(seconds: 30);

/// The element states a locator can wait for.
enum WaitForSelectorState { attached, detached, visible, hidden }

/// A rectangle in the top-level viewport's coordinates.
class BoundingBox {
  final double x;
  final double y;
  final double width;
  final double height;

  const BoundingBox(this.x, this.y, this.width, this.height);

  @override
  String toString() => 'BoundingBox($x, $y, $width, $height)';
}

/// Thrown when a locator resolves to more than one element while strict.
class StrictModeViolation extends PlaywrightException {
  StrictModeViolation(super.message);
  @override
  String toString() => 'StrictModeViolation: $message';
}

/// The `getBy*` family and `locator`, shared by [Page], [Frame], [Locator]
/// and [FrameLocator].
///
/// Every member is expressed through [byParts], which each class implements by
/// appending the parts to its own selector.
mixin LocatorFactory {
  /// Builds a locator from raw selector engine parts, relative to this root.
  Locator byParts(List<Map<String, dynamic>> parts);

  /// A locator for [selector], optionally narrowed the way
  /// `locator(selector, { hasText, has })` does upstream.
  Locator locator(String selector,
      {Pattern? hasText, Pattern? hasNotText, Locator? has, Locator? hasNot}) {
    final parts = <Map<String, dynamic>>[...Selectors.parse(selector).parts];
    if (hasText != null) parts.add(Selectors.hasText(hasText));
    if (hasNotText != null) parts.add(Selectors.hasNotText(hasNotText));
    if (has != null) parts.add(Selectors.has(has.selector));
    if (hasNot != null) parts.add(Selectors.hasNot(hasNot.selector));
    return byParts(parts);
  }

  /// Locates an element by its ARIA role, with the accessible-name and state
  /// filters of upstream's `getByRole`.
  Locator getByRole(String role,
      {Object? checked,
      bool? disabled,
      bool? expanded,
      bool? includeHidden,
      int? level,
      Pattern? name,
      Object? pressed,
      bool? selected,
      Pattern? description,
      bool exact = false}) {
    return byParts([
      Selectors.byRole(
          role,
          RoleOptions(
            checked: checked,
            disabled: disabled,
            expanded: expanded,
            includeHidden: includeHidden,
            level: level,
            name: name,
            pressed: pressed,
            selected: selected,
            description: description,
            exact: exact,
          ))
    ]);
  }

  /// Locates an element containing [text].
  ///
  /// Whitespace is normalised on both sides. Without `exact`, matching is a
  /// case-insensitive substring; with it, the whole normalised text must be
  /// equal. A [RegExp] is matched against the raw text, as upstream does.
  Locator getByText(Pattern text, {bool exact = false}) =>
      byParts([Selectors.byText(text, exact: exact)]);

  /// Locates a form control by its associated label or `aria-label`.
  Locator getByLabel(Pattern text, {bool exact = false}) =>
      byParts([Selectors.byLabel(text, exact: exact)]);

  /// Locates an input by its `placeholder`.
  Locator getByPlaceholder(Pattern text, {bool exact = false}) =>
      byParts([Selectors.byPlaceholder(text, exact: exact)]);

  /// Locates an element by its `alt` attribute.
  Locator getByAltText(Pattern text, {bool exact = false}) =>
      byParts([Selectors.byAltText(text, exact: exact)]);

  /// Locates an element by its `title` attribute.
  Locator getByTitle(Pattern text, {bool exact = false}) =>
      byParts([Selectors.byTitle(text, exact: exact)]);

  /// Locates an element by its test id attribute (`data-testid` by default).
  Locator getByTestId(Pattern testId,
          {String attributeName = Selectors.defaultTestIdAttribute}) =>
      byParts([Selectors.byTestId(testId, attributeName: attributeName)]);

  /// A [FrameLocator] for the iframe matched by [selector].
  FrameLocator frameLocator(String selector) =>
      FrameLocatorImpl(locator(selector) as LocatorImpl);
}

/// A way to find one or more elements, re-resolved on every use.
abstract class Locator with LocatorFactory {
  /// The selector this locator resolves.
  ParsedSelector get selector;

  /// The frame the selector is resolved against.
  Frame get frame;

  /// The page this locator belongs to.
  Page get page;

  // ------------------------------------------------------------ composition

  /// The first matching element.
  Locator get first;

  /// The last matching element.
  Locator get last;

  /// The [index]-th matching element (0-based; negative counts from the end).
  Locator nth(int index);

  /// Narrows this locator, as upstream's `locator.filter()` does.
  Locator filter(
      {Pattern? hasText, Pattern? hasNotText, Locator? has, Locator? hasNot});

  /// Matches elements matched by both this locator and [other].
  Locator and(Locator other);

  /// Matches elements matched by either this locator or [other].
  Locator or(Locator other);

  /// Only the visible (or, with `visible: false`, the hidden) matches.
  Locator visible({bool value = true});

  /// Treats this locator's element as an iframe and returns its content.
  FrameLocator contentFrame();

  /// The individual matches, as one locator each.
  Future<List<Locator>> all();

  // ---------------------------------------------------------------- actions

  /// Click the element.
  Future<void> click(
      {String button = 'left',
      int clickCount = 1,
      Duration? delay,
      ({double x, double y})? position,
      Duration? timeout,
      bool strict = true,
      bool force = false});

  /// Double-click the element.
  Future<void> dblclick(
      {String button = 'left',
      Duration? delay,
      ({double x, double y})? position,
      Duration? timeout,
      bool strict = true,
      bool force = false});

  /// Hover over the element.
  Future<void> hover(
      {({double x, double y})? position,
      Duration? timeout,
      bool strict = true,
      bool force = false});

  /// Fill an input field.
  Future<void> fill(String text,
      {Duration? timeout, bool strict = true, bool force = false});

  /// Clear the input field.
  Future<void> clear({Duration? timeout, bool strict = true, bool force = false});

  /// Focus the element.
  Future<void> focus({Duration? timeout, bool strict = true});

  /// Remove focus from the element.
  Future<void> blur({Duration? timeout, bool strict = true});

  /// Focus the element then press [key] (or a chord like 'Control+A').
  Future<void> press(String key,
      {Duration? timeout, bool strict = true, bool force = false});

  /// Focus the element then type [text] character by character, firing
  /// real keyboard events for each character.
  Future<void> pressSequentially(String text,
      {Duration? timeout, bool strict = true, bool force = false});

  /// Check a checkbox/radio element.
  Future<void> check(
      {Duration? timeout, bool strict = true, bool force = false});

  /// Uncheck a checkbox element.
  Future<void> uncheck(
      {Duration? timeout, bool strict = true, bool force = false});

  /// Check or uncheck depending on [checked].
  Future<void> setChecked(bool checked,
      {Duration? timeout, bool strict = true, bool force = false});

  /// Select option(s) in a `<select>` element.
  ///
  /// Values are matched against each option's `value`, then its label, as
  /// upstream's `selectOption` does. Returns the selected values.
  Future<List<String>> selectOption(dynamic value,
      {Duration? timeout, bool strict = true, bool force = false});

  /// Drag this element onto [target].
  ///
  /// Performs a real press-move-release with the protocol mouse, so pages
  /// relying on HTML5 drag events or on pointer tracking see a genuine drag.
  Future<void> dragTo(Locator target,
      {({double x, double y})? sourcePosition,
      ({double x, double y})? targetPosition,
      Duration? timeout,
      bool strict = true,
      bool force = false});

  /// Scroll the element into view if it is not already.
  Future<void> scrollIntoViewIfNeeded({Duration? timeout, bool strict = true});

  /// Select the element's text content.
  Future<void> selectText({Duration? timeout, bool strict = true});

  /// Dispatch a DOM event on the element.
  Future<void> dispatchEvent(String type,
      {Map<String, dynamic>? eventInit, Duration? timeout, bool strict = true});

  // ----------------------------------------------------------------- state

  /// Get the text content of the element.
  Future<String> textContent({Duration? timeout, bool strict = true});

  /// Get the rendered inner text of the element.
  Future<String> innerText({Duration? timeout, bool strict = true});

  /// Get the inner HTML of the element.
  Future<String> innerHTML({Duration? timeout, bool strict = true});

  /// Get the current value of an input/textarea/select element.
  Future<String> inputValue({Duration? timeout, bool strict = true});

  /// Get an attribute value, or null if absent.
  Future<String?> getAttribute(String name,
      {Duration? timeout, bool strict = true});

  /// Number of elements matching the selector.
  Future<int> count();

  /// Whether the first matching element is visible.
  Future<bool> isVisible();

  /// Whether the element is hidden (not visible or absent).
  Future<bool> isHidden();

  /// Whether the first matching element is enabled (not disabled).
  Future<bool> isEnabled({Duration? timeout, bool strict = true});

  /// Whether the element is disabled.
  Future<bool> isDisabled({Duration? timeout, bool strict = true});

  /// Whether the element accepts text editing.
  Future<bool> isEditable({Duration? timeout, bool strict = true});

  /// Whether a checkbox/radio element is checked.
  Future<bool> isChecked({Duration? timeout, bool strict = true});

  /// The element's box in the top-level viewport, or null when not rendered.
  Future<BoundingBox?> boundingBox({Duration? timeout, bool strict = true});

  /// The element's computed ARIA role, or null when it has none.
  Future<String?> ariaRole({Duration? timeout, bool strict = true});

  /// The element's accessible name.
  Future<String> accessibleName({Duration? timeout, bool strict = true});

  // ------------------------------------------------------------ evaluation

  /// Evaluate [expression], a function of the element.
  Future<dynamic> evaluate(String expression,
      {Duration? timeout, bool strict = true});

  /// Evaluate [expression], a function of the array of all matches.
  Future<dynamic> evaluateAll(String expression);

  /// Evaluate [expression] against the element, returning a handle.
  Future<JSHandle> evaluateHandle(String expression,
      {Duration? timeout, bool strict = true});

  /// A handle to the first matching element.
  Future<ElementHandle> elementHandle({Duration? timeout, bool strict = true});

  /// Handles for every matching element.
  Future<List<ElementHandle>> elementHandles();

  // --------------------------------------------------------------- waiting

  /// Wait until the selector reaches [state], or throw on timeout.
  Future<void> waitFor(
      {WaitForSelectorState state = WaitForSelectorState.visible,
      Duration timeout = kDefaultLocatorTimeout,
      bool strict = true});
}

class LocatorImpl extends Locator {
  final FrameImpl _frame;
  final ParsedSelector _selector;

  LocatorImpl(this._frame, this._selector);

  @override
  ParsedSelector get selector => _selector;

  @override
  Frame get frame => _frame;

  /// The frame implementation, for locators built from this one.
  FrameImpl get frameImpl => _frame;

  @override
  Page get page => _frame.page();

  @override
  Locator byParts(List<Map<String, dynamic>> parts) =>
      LocatorImpl(_frame, _selector.append(parts));

  @override
  String toString() => "Locator('${_selector.description}')";

  // ------------------------------------------------------------ composition

  @override
  Locator get first => byParts([Selectors.nth(0)]);

  @override
  Locator get last => byParts([Selectors.nth(-1)]);

  @override
  Locator nth(int index) => byParts([Selectors.nth(index)]);

  @override
  Locator visible({bool value = true}) =>
      byParts([Selectors.visible(value)]);

  @override
  Locator filter(
      {Pattern? hasText, Pattern? hasNotText, Locator? has, Locator? hasNot}) {
    final parts = <Map<String, dynamic>>[];
    if (hasText != null) parts.add(Selectors.hasText(hasText));
    if (hasNotText != null) parts.add(Selectors.hasNotText(hasNotText));
    if (has != null) parts.add(Selectors.has(has.selector));
    if (hasNot != null) parts.add(Selectors.hasNot(hasNot.selector));
    return byParts(parts);
  }

  @override
  Locator and(Locator other) => byParts([Selectors.and(other.selector)]);

  @override
  Locator or(Locator other) => byParts([Selectors.or(other.selector)]);

  @override
  FrameLocator contentFrame() => FrameLocatorImpl(this);

  @override
  Future<List<Locator>> all() async {
    final total = await count();
    return [for (var i = 0; i < total; i++) nth(i)];
  }

  // ------------------------------------------------------------- internals

  /// The JS expression resolving this locator's last selector group inside the
  /// frame the earlier groups landed in.
  static String _resolverJs(List<Map<String, dynamic>> parts, bool strict) =>
      'window.__pwDart.query(${jsonEncode(parts)}, $strict)';

  /// Walks the frame boundaries in the selector, returning the frame the last
  /// group must be resolved in together with that group.
  Future<({CoreFrame frame, List<Map<String, dynamic>> parts})> _resolveFrames(
      bool strict) async {
    final groups = _selector.splitOnFrames();
    var frame = _frame.coreFrame;
    for (var i = 0; i < groups.length - 1; i++) {
      final group = groups[i];
      final probe = await frame.evaluateInjected(
          '() => !!${_resolverJs(group, strict)}');
      if (probe != true) {
        throw _NotResolved(
            'frame locator ${ParsedSelector(group).description} did not match');
      }
      final handle =
          await frame.evaluateHandleInjected('() => ${_resolverJs(group, strict)}');
      final child = await frame.page.contentFrame(handle);
      await handle.dispose().catchError((_) {});
      if (child == null) {
        throw _NotResolved(
            '${ParsedSelector(group).description} is not an iframe');
      }
      frame = child;
    }
    return (frame: frame, parts: groups.last);
  }

  /// Polls [attempt] until it stops reporting "not ready yet".
  Future<T> _poll<T>(Duration timeout, Future<T> Function() attempt) async {
    final deadline = DateTime.now().add(timeout);
    Object? lastReason;
    while (true) {
      try {
        return await attempt();
      } on StrictModeViolation {
        // A strict violation is a test bug, not a timing problem.
        rethrow;
      } on _NotResolved catch (error) {
        lastReason = error.reason;
      } catch (error) {
        // Navigation tears the context down mid-poll; retry instead of
        // failing the action.
        lastReason = error;
      }
      if (!DateTime.now().isBefore(deadline)) {
        throw TimeoutException(
            'Timeout ${timeout.inMilliseconds}ms exceeded waiting for '
            '${_selector.description}: $lastReason',
            timeout: timeout);
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// Resolves the element and runs [body] (a JS function body with `el`
  /// bound), waiting for [states] first.
  Future<dynamic> _run(String body,
      {List<String> states = const [],
      Duration? timeout,
      bool strict = true,
      bool force = false}) {
    final effectiveStates = force ? const <String>[] : states;
    return _poll(timeout ?? kDefaultLocatorTimeout, () async {
      final resolved = await _resolveFrames(strict);
      final result = await resolved.frame.evaluateInjected('''
        () => window.__pwDart.run(${jsonEncode(resolved.parts)}, $strict,
            ${jsonEncode(effectiveStates)}, (el) => { $body })
      ''');
      return _unwrap(result);
    });
  }

  dynamic _unwrap(dynamic result) {
    final map = result as Map?;
    if (map == null) throw _NotResolved('evaluation returned nothing');
    if (map['ok'] == true) return map['value'];
    switch (map['error']) {
      case 'strict':
        throw StrictModeViolation(map['message']?.toString() ??
            'strict mode violation: ${_selector.description}');
      case 'notfound':
        throw _NotResolved('element not found');
      case 'state':
        final state = '${map['state']}';
        // The hit-target check reports what is in the way, so the timeout can
        // name the overlay instead of just saying "not actionable".
        if (state.startsWith('receivesEvents:')) {
          throw _NotResolved('element does not receive pointer events: '
              '${state.substring('receivesEvents:'.length)} intercepts them');
        }
        throw _NotResolved('element is not $state');
      default:
        throw _NotResolved('unknown result $map');
    }
  }

  /// Like [_run], but without retrying: used by the state getters that
  /// upstream answers immediately.
  Future<dynamic> _runOnce(String body,
      {bool strict = true, dynamic whenMissing}) async {
    final resolved = await _resolveFrames(strict);
    final result = await resolved.frame.evaluateInjected('''
      () => window.__pwDart.run(${jsonEncode(resolved.parts)}, $strict, [],
          (el) => { $body })
    ''');
    final map = result as Map?;
    if (map != null && map['ok'] == true) return map['value'];
    if (map != null && map['error'] == 'strict') {
      throw StrictModeViolation(map['message']?.toString() ??
          'strict mode violation: ${_selector.description}');
    }
    return whenMissing;
  }

  /// Waits until the element is actionable, then hands the engine the frame
  /// and the resolver expression it needs to dispatch real input.
  ///
  /// [position] only matters for the `receivesEvents` check, which has to hit
  /// test the exact point the action will aim at.
  Future<({CoreFrame frame, String resolver})> _waitForActionable(
      {required List<String> states,
      Duration? timeout,
      bool strict = true,
      bool force = false,
      ({double x, double y})? position}) {
    final effectiveStates = force ? const <String>[] : states;
    final options = position == null
        ? 'undefined'
        : '{ position: { x: ${position.x}, y: ${position.y} } }';
    return _poll(timeout ?? kDefaultLocatorTimeout, () async {
      final resolved = await _resolveFrames(strict);
      final result = await resolved.frame.evaluateInjected('''
        () => window.__pwDart.run(${jsonEncode(resolved.parts)}, $strict,
            ${jsonEncode(effectiveStates)}, (el) => true, undefined, $options)
      ''');
      _unwrap(result);
      return (
        frame: resolved.frame,
        resolver: _resolverJs(resolved.parts, strict),
      );
    });
  }

  CorePage get _corePage => _frame.coreFrame.page;

  /// The states upstream requires before a click: visible, not moving, not
  /// disabled, and actually reachable by a pointer at the action point.
  static const _clickStates = [
    'visible',
    'stable',
    'enabled',
    'receivesEvents'
  ];

  /// Hover does not need the element to be enabled, but it does need the
  /// pointer to reach it.
  static const _hoverStates = ['visible', 'stable', 'receivesEvents'];

  // ---------------------------------------------------------------- actions

  @override
  Future<void> click(
      {String button = 'left',
      int clickCount = 1,
      Duration? delay,
      ({double x, double y})? position,
      Duration? timeout,
      bool strict = true,
      bool force = false}) async {
    final target = await _waitForActionable(
        states: _clickStates,
        timeout: timeout,
        strict: strict,
        force: force,
        position: position);
    await _corePage.clickTarget(target.frame, target.resolver,
        button: button,
        clickCount: clickCount,
        delay: delay,
        position: position);
  }

  @override
  Future<void> dblclick(
      {String button = 'left',
      Duration? delay,
      ({double x, double y})? position,
      Duration? timeout,
      bool strict = true,
      bool force = false}) async {
    final target = await _waitForActionable(
        states: _clickStates,
        timeout: timeout,
        strict: strict,
        force: force,
        position: position);
    await _corePage.dblclickTarget(target.frame, target.resolver,
        button: button, delay: delay, position: position);
  }

  @override
  Future<void> hover(
      {({double x, double y})? position,
      Duration? timeout,
      bool strict = true,
      bool force = false}) async {
    final target = await _waitForActionable(
        states: _hoverStates,
        timeout: timeout,
        strict: strict,
        force: force,
        position: position);
    await _corePage.hoverTarget(target.frame, target.resolver,
        position: position);
  }

  @override
  Future<void> fill(String text,
      {Duration? timeout, bool strict = true, bool force = false}) async {
    final target = await _waitForActionable(
        states: const ['visible', 'stable', 'enabled', 'editable'],
        timeout: timeout,
        strict: strict,
        force: force);
    await _corePage.fillTarget(target.frame, target.resolver, text);
  }

  @override
  Future<void> clear(
          {Duration? timeout, bool strict = true, bool force = false}) =>
      fill('', timeout: timeout, strict: strict, force: force);

  @override
  Future<void> focus({Duration? timeout, bool strict = true}) async {
    final target = await _waitForActionable(
        states: const [], timeout: timeout, strict: strict);
    await _corePage.focusTarget(target.frame, target.resolver);
  }

  @override
  Future<void> blur({Duration? timeout, bool strict = true}) async {
    await _run('el.blur();', timeout: timeout, strict: strict);
  }

  @override
  Future<void> press(String key,
      {Duration? timeout, bool strict = true, bool force = false}) async {
    final target = await _waitForActionable(
        states: _clickStates, timeout: timeout, strict: strict, force: force);
    await _corePage.pressTarget(target.frame, target.resolver, key);
  }

  @override
  Future<void> pressSequentially(String text,
      {Duration? timeout, bool strict = true, bool force = false}) async {
    final target = await _waitForActionable(
        states: _clickStates, timeout: timeout, strict: strict, force: force);
    await _corePage.typeTarget(target.frame, target.resolver, text);
  }

  @override
  Future<void> check(
          {Duration? timeout, bool strict = true, bool force = false}) =>
      setChecked(true, timeout: timeout, strict: strict, force: force);

  @override
  Future<void> uncheck(
          {Duration? timeout, bool strict = true, bool force = false}) =>
      setChecked(false, timeout: timeout, strict: strict, force: force);

  @override
  Future<void> setChecked(bool checked,
      {Duration? timeout, bool strict = true, bool force = false}) async {
    final deadline = DateTime.now().add(timeout ?? kDefaultLocatorTimeout);
    Duration remaining() {
      final left = deadline.difference(DateTime.now());
      return left.isNegative ? Duration.zero : left;
    }

    final current = await _run(
        'return window.__pwDart.elementState(el, "checked").matches;',
        states: _clickStates,
        timeout: remaining(),
        strict: strict,
        force: force);
    if (current == checked) return;
    await click(timeout: remaining(), strict: strict, force: force);
    final after = await _run(
        'return window.__pwDart.elementState(el, "checked").matches;',
        states: _clickStates,
        timeout: remaining(),
        strict: strict,
        force: force);
    if (after != checked) {
      throw StateError('Clicking the element did not change its checked state');
    }
  }

  @override
  Future<List<String>> selectOption(dynamic value,
      {Duration? timeout, bool strict = true, bool force = false}) async {
    final requested = value is List ? value : [value];
    final encoded = jsonEncode(requested.map((v) => v.toString()).toList());
    final result = await _run('''
        const wanted = $encoded;
        const select = window.__pwDart.retarget(el, 'follow-label');
        if (!select || select.tagName !== 'SELECT')
          throw new Error('Element is not a <select>');
        const selected = [];
        for (const option of select.options) {
          const match = wanted.includes(option.value) ||
              wanted.includes(option.label) ||
              wanted.includes(option.textContent.trim());
          option.selected = match;
          if (match) selected.push(option.value);
        }
        if (selected.length !== wanted.length)
          throw new Error('Option not found: ' + JSON.stringify(wanted));
        select.dispatchEvent(new Event('input', { bubbles: true }));
        select.dispatchEvent(new Event('change', { bubbles: true }));
        return selected;
      ''',
        states: const ['visible', 'stable', 'enabled'],
        timeout: timeout,
        strict: strict,
        force: force);
    return (result as List).map((e) => e.toString()).toList();
  }

  @override
  Future<void> dragTo(Locator target,
      {({double x, double y})? sourcePosition,
      ({double x, double y})? targetPosition,
      Duration? timeout,
      bool strict = true,
      bool force = false}) async {
    final deadline = DateTime.now().add(timeout ?? kDefaultLocatorTimeout);
    Duration remaining() {
      final left = deadline.difference(DateTime.now());
      return left.isNegative ? Duration.zero : left;
    }

    final source = await _waitForActionable(
        states: const ['visible', 'stable'],
        timeout: remaining(),
        strict: strict,
        force: force);
    final from = await _corePage.clickPointForTarget(
        source.frame, source.resolver,
        position: sourcePosition);

    final targetImpl = target as LocatorImpl;
    final destination = await targetImpl._waitForActionable(
        states: const ['visible', 'stable'],
        timeout: remaining(),
        strict: strict,
        force: force);
    final to = await _corePage.clickPointForTarget(
        destination.frame, destination.resolver,
        position: targetPosition);

    final mouse = _corePage.mouse;
    await mouse.move(from.x, from.y);
    await mouse.down();
    // Upstream moves to the target twice: the first move starts the drag, the
    // second lets dragover/pointermove handlers settle on the final position.
    await mouse.move(to.x, to.y, steps: 5);
    await mouse.move(to.x, to.y);
    await mouse.up();
  }

  @override
  Future<void> scrollIntoViewIfNeeded(
      {Duration? timeout, bool strict = true}) async {
    await _run(
        "el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });",
        states: const ['stable'],
        timeout: timeout,
        strict: strict);
  }

  @override
  Future<void> selectText({Duration? timeout, bool strict = true}) async {
    await _run('''
        if (typeof el.select === 'function') {
          el.select();
        } else {
          const range = el.ownerDocument.createRange();
          range.selectNodeContents(el);
          const selection = el.ownerDocument.defaultView.getSelection();
          selection.removeAllRanges();
          selection.addRange(range);
        }
      ''', states: const ['visible'], timeout: timeout, strict: strict);
  }

  @override
  Future<void> dispatchEvent(String type,
      {Map<String, dynamic>? eventInit,
      Duration? timeout,
      bool strict = true}) async {
    final init = jsonEncode(eventInit ?? const <String, dynamic>{});
    await _run('''
        const init = Object.assign({ bubbles: true, cancelable: true, composed: true }, $init);
        el.dispatchEvent(new (window.Event)(${jsonEncode(type)}, init));
      ''', timeout: timeout, strict: strict);
  }

  // ----------------------------------------------------------------- state

  @override
  Future<String> textContent({Duration? timeout, bool strict = true}) async {
    final result = await _run('return el.textContent;',
        timeout: timeout, strict: strict);
    return result?.toString() ?? '';
  }

  @override
  Future<String> innerText({Duration? timeout, bool strict = true}) async {
    final result =
        await _run('return el.innerText;', timeout: timeout, strict: strict);
    return result?.toString() ?? '';
  }

  @override
  Future<String> innerHTML({Duration? timeout, bool strict = true}) async {
    final result =
        await _run('return el.innerHTML;', timeout: timeout, strict: strict);
    return result?.toString() ?? '';
  }

  @override
  Future<String> inputValue({Duration? timeout, bool strict = true}) async {
    final result = await _run(
        "const t = window.__pwDart.retarget(el, 'follow-label'); return t.value;",
        timeout: timeout,
        strict: strict);
    return result?.toString() ?? '';
  }

  @override
  Future<String?> getAttribute(String name,
      {Duration? timeout, bool strict = true}) async {
    final result = await _run('return el.getAttribute(${jsonEncode(name)});',
        timeout: timeout, strict: strict);
    return result as String?;
  }

  @override
  Future<int> count() async {
    final resolved = await _resolveFrames(false);
    final result = await resolved.frame.evaluateInjected(
        '() => window.__pwDart.count(${jsonEncode(resolved.parts)})');
    return (result as num).toInt();
  }

  @override
  Future<bool> isVisible() async {
    final result = await _runOnce(
        'return window.__pwDart.elementState(el, "visible").matches;',
        strict: false,
        whenMissing: false);
    return result == true;
  }

  @override
  Future<bool> isHidden() async => !await isVisible();

  @override
  Future<bool> isEnabled({Duration? timeout, bool strict = true}) async {
    final result = await _run(
        'return window.__pwDart.elementState(el, "enabled").matches;',
        timeout: timeout,
        strict: strict);
    return result == true;
  }

  @override
  Future<bool> isDisabled({Duration? timeout, bool strict = true}) async =>
      !await isEnabled(timeout: timeout, strict: strict);

  @override
  Future<bool> isEditable({Duration? timeout, bool strict = true}) async {
    final result = await _run('''
        try {
          return window.__pwDart.elementState(el, "editable").matches;
        } catch (e) {
          return false;
        }
      ''', timeout: timeout, strict: strict);
    return result == true;
  }

  @override
  Future<bool> isChecked({Duration? timeout, bool strict = true}) async {
    final result = await _run(
        'return window.__pwDart.elementState(el, "checked").matches;',
        timeout: timeout,
        strict: strict);
    return result == true;
  }

  @override
  Future<BoundingBox?> boundingBox({Duration? timeout, bool strict = true}) async {
    final result = await _run('''
        const rect = el.getBoundingClientRect();
        let x = rect.x, y = rect.y;
        let win = el.ownerDocument.defaultView;
        while (win && win !== win.parent) {
          let owner = null;
          try { owner = win.frameElement; } catch (e) { break; }
          if (!owner) break;
          const ownerRect = owner.getBoundingClientRect();
          const style = owner.ownerDocument.defaultView.getComputedStyle(owner);
          x += ownerRect.x + (parseFloat(style.borderLeftWidth) || 0) + (parseFloat(style.paddingLeft) || 0);
          y += ownerRect.y + (parseFloat(style.borderTopWidth) || 0) + (parseFloat(style.paddingTop) || 0);
          win = win.parent;
        }
        return { x, y, width: rect.width, height: rect.height };
      ''', timeout: timeout, strict: strict);
    if (result is! Map) return null;
    return BoundingBox(
      (result['x'] as num).toDouble(),
      (result['y'] as num).toDouble(),
      (result['width'] as num).toDouble(),
      (result['height'] as num).toDouble(),
    );
  }

  @override
  Future<String?> ariaRole({Duration? timeout, bool strict = true}) async {
    final result = await _run('return window.__pwDart.getAriaRole(el);',
        timeout: timeout, strict: strict);
    return result as String?;
  }

  @override
  Future<String> accessibleName({Duration? timeout, bool strict = true}) async {
    final result = await _run(
        'return window.__pwDart.normalizeWhiteSpace(window.__pwDart.accessibleName(el, false));',
        timeout: timeout,
        strict: strict);
    return result?.toString() ?? '';
  }

  // ------------------------------------------------------------ evaluation

  @override
  Future<dynamic> evaluate(String expression,
          {Duration? timeout, bool strict = true}) =>
      _run('return ($expression)(el);', timeout: timeout, strict: strict);

  @override
  Future<dynamic> evaluateAll(String expression) async {
    final resolved = await _resolveFrames(false);
    return resolved.frame.evaluateInjected(
        '() => ($expression)(window.__pwDart.queryAll(${jsonEncode(resolved.parts)}))');
  }

  @override
  Future<JSHandle> evaluateHandle(String expression,
      {Duration? timeout, bool strict = true}) async {
    // Wait for the element first so a handle is only taken once it exists.
    final target = await _waitForActionable(
        states: const [], timeout: timeout, strict: strict);
    final handle = await target.frame.evaluateHandleInjected(
        '() => ($expression)(${target.resolver})');
    return _wrapHandle(handle);
  }

  @override
  Future<ElementHandle> elementHandle(
      {Duration? timeout, bool strict = true}) async {
    final target = await _waitForActionable(
        states: const [], timeout: timeout, strict: strict);
    final handle =
        await target.frame.evaluateHandleInjected('() => ${target.resolver}');
    final wrapped = _wrapHandle(handle);
    if (wrapped is! ElementHandle) {
      throw StateError('${_selector.description} did not resolve to an element');
    }
    return wrapped;
  }

  @override
  Future<List<ElementHandle>> elementHandles() async {
    final total = await count();
    return [
      for (var i = 0; i < total; i++) await nth(i).elementHandle(),
    ];
  }

  JSHandle _wrapHandle(CoreJSHandle handle) {
    if (handle is CoreElementHandle) {
      return ElementHandleImpl(handle, frame: _frame);
    }
    return JSHandleImpl(handle);
  }

  // --------------------------------------------------------------- waiting

  @override
  Future<void> waitFor(
      {WaitForSelectorState state = WaitForSelectorState.visible,
      Duration timeout = kDefaultLocatorTimeout,
      bool strict = true}) async {
    switch (state) {
      case WaitForSelectorState.attached:
        await _waitForActionable(
            states: const [], timeout: timeout, strict: strict);
        return;
      case WaitForSelectorState.visible:
        await _waitForActionable(
            states: const ['visible'], timeout: timeout, strict: strict);
        return;
      case WaitForSelectorState.detached:
      case WaitForSelectorState.hidden:
        final wantDetached = state == WaitForSelectorState.detached;
        await _poll(timeout, () async {
          final resolved = await _resolveFrames(strict).catchError(
              (Object _) => (
                    frame: _frame.coreFrame,
                    parts: <Map<String, dynamic>>[]
                  ));
          if (resolved.parts.isEmpty) return null;
          final result = await resolved.frame.evaluateInjected('''
            () => {
              const els = window.__pwDart.queryAll(${jsonEncode(resolved.parts)});
              if (!els.length) return 'gone';
              if (${wantDetached ? 'true' : 'false'}) return 'present';
              return els.some(el => window.__pwDart.elementState(el, 'visible').matches)
                  ? 'present' : 'gone';
            }
          ''');
          if (result != 'gone') {
            throw _NotResolved(
                'element is still ${wantDetached ? 'attached' : 'visible'}');
          }
          return null;
        });
        return;
    }
  }
}

/// Signals "not there yet": the poll loop retries until its deadline.
class _NotResolved implements Exception {
  final Object reason;
  _NotResolved(this.reason);
  @override
  String toString() => reason.toString();
}

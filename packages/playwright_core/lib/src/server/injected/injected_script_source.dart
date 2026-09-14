// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/injected/src/{domUtils,selectorUtils,roleUtils,roleSelectorEngine,layoutSelectorUtils,selectorEvaluator,injectedScript}.ts and
// packages/isomorphic/{stringUtils,cssTokenizer,cssParser}.ts

// The in-page selector engine.
//
// This is a hand port of the pieces of upstream Playwright's injected script
// that the Dart port needs: `packages/injected/src/domUtils.ts`,
// `selectorUtils.ts`, `roleUtils.ts`, `roleSelectorEngine.ts`,
// `layoutSelectorUtils.ts`, `selectorEvaluator.ts` and the `internal:*`
// engines of `injectedScript.ts`, plus
// `packages/isomorphic/stringUtils.ts#normalizeWhiteSpace` and the
// `cssTokenizer.ts`/`cssParser.ts` pair.
//
// The `css` engine runs the ported evaluator, so it supports Playwright's CSS
// extensions (`:has-text()`, `:text()`, `:text-is()`, `:text-matches()`,
// `:visible`, `:has()`, `:is()`/`:where()`, `:not()`, `:scope`,
// `:nth-match()`, `:left-of()`, `:right-of()`, `:above()`, `:below()`,
// `:near()` and `:light()`) and pierces open shadow roots, the same as the
// `text`, `label` and `role` engines.
//
// Differences from upstream, all deliberate:
//
// * The selector *string* syntax (`>>` chaining, engine prefixes) is parsed in
//   Dart (see `selectors.dart`) and arrives as structured JSON; only the CSS
//   body of a `css=` part is parsed here. `selectorParser.ts` is therefore not
//   ported, and neither are the custom user-registered engines.
// * CSS tokens are plain objects with a `type` field instead of upstream's
//   class hierarchy, and `cssTokenSource` replaces `toSource()`. Line/column
//   tracking is dropped: upstream only fed it to a parse-error log that is a
//   no-op.
// * A bad selector (or an extension used with the wrong arguments) is reported
//   through the `{error: 'invalid'}` envelope so the Dart side can raise
//   InvalidSelectorError at once, instead of retrying until the locator times
//   out.
// * `getCSSContent` parses `content:` with a small hand-rolled scanner instead
//   of the CSS tokenizer; it handles quoted strings, `attr()` and the
//   `/ "alt text"` form, which is what the property is used for in practice.
// * Accessible-name computation returns plain text; upstream also collects the
//   contributing elements, which only its aria snapshots need.
library;

import 'injected_css_engine_source.dart';
import 'injected_dom_source.dart';

/// JavaScript source installing `window.__pwDart` in an execution context.
///
/// Evaluating it twice in the same context is harmless.
const String kInjectedScriptSource = _prologue +
    kInjectedDomSource +
    kInjectedCssEngineSource +
    _engineSource;

/// Opens the IIFE and bails out when the engine is already installed.
const String _prologue = r'''
// Playwright for Dart, injected selector engine. The leading comment matters:
// it keeps the source from looking like a bare arrow function to
// wrapEvaluationExpression, which would then wrap an already-invoked IIFE.
(() => {
if (window.__pwDart)
  return;

''';

/// The selector engines, the selector evaluation loop, the actionability
/// checks and the `window.__pwDart` surface, plus the closing of the IIFE.
const String _engineSource = r'''
// --------------------------------------------------------------- engines

// The `css` engine. As upstream does, it runs the ported evaluator rather than
// the native querySelectorAll: that is what brings Playwright's CSS extensions
// (`:has-text()`, `:visible`, `:nth-match()`, the layout selectors) and makes
// the engine pierce open shadow roots, like `text`, `label` and `role`.
const cssEvaluator = new SelectorEvaluatorImpl();
const parsedCSSCache = new Map();

function parseCSSCached(body) {
  let parsed = parsedCSSCache.get(body);
  if (parsed === undefined) {
    parsed = parseCSS(body, kCustomCSSNames).selector;
    // Only successful parses are cached; a bad selector must keep throwing.
    parsedCSSCache.set(body, parsed);
  }
  return parsed;
}

function queryCSS(root, body) {
  return cssEvaluator.query({ scope: root, pierceShadow: true }, parseCSSCached(body));
}

function queryXPath(root, body) {
  const document = root.nodeType === 9 ? root : root.ownerDocument;
  const result = [];
  const it = document.evaluate(body, root, null, XPathResult.ORDERED_NODE_ITERATOR_TYPE);
  for (let node = it.iterateNext(); node; node = it.iterateNext()) {
    if (node.nodeType === 1)
      result.push(node);
  }
  return result;
}

function queryText(cache, root, spec) {
  const { matcher, kind } = createTextMatcher(spec);
  const result = [];
  let lastDidNotMatchSelf = null;
  const appendElement = element => {
    if (kind === 'lax' && lastDidNotMatchSelf && lastDidNotMatchSelf.contains(element))
      return;
    const matches = elementMatchesText(cache, element, matcher);
    if (matches === 'none')
      lastDidNotMatchSelf = element;
    if (matches === 'self')
      result.push(element);
  };
  if (root.nodeType === 1)
    appendElement(root);
  for (const element of allElementsPiercing(root))
    appendElement(element);
  return result;
}

function queryLabel(cache, root, spec) {
  const { matcher } = createTextMatcher(spec);
  return allElementsPiercing(root).filter(element =>
      getElementLabels(cache, element).some(label => matcher(label)));
}

function queryAttr(root, name, spec) {
  const matcher = createAttributeMatcher(spec);
  return [...root.querySelectorAll('[' + name + ']')]
      .filter(e => matcher(e.getAttribute(name)));
}

function queryTestId(root, names, spec) {
  const matcher = createAttributeMatcher(spec);
  const cssQuery = names.map(n => '[' + n + ']').join(',');
  return [...root.querySelectorAll(cssQuery)].filter(e => names.some(n => {
    const actual = e.getAttribute(n);
    return actual !== null && matcher(actual);
  }));
}

function queryRole(root, options) {
  const result = [];
  for (const element of allElementsPiercing(root)) {
    if (getAriaRole(element) !== options.role)
      continue;
    if (options.selected !== undefined && getAriaSelected(element) !== options.selected)
      continue;
    if (options.checked !== undefined && getAriaChecked(element) !== options.checked)
      continue;
    if (options.pressed !== undefined && getAriaPressed(element) !== options.pressed)
      continue;
    if (options.expanded !== undefined && getAriaExpanded(element) !== options.expanded)
      continue;
    if (options.level !== undefined && getAriaLevel(element) !== options.level)
      continue;
    if (options.disabled !== undefined && getAriaDisabled(element) !== options.disabled)
      continue;
    if (!options.includeHidden && isElementHiddenForAria(element))
      continue;
    if (options.name !== undefined) {
      const accessibleName = normalizeWhiteSpace(getElementAccessibleName(element, !!options.includeHidden));
      const spec = options.name.regex
          ? options.name
          : { value: normalizeWhiteSpace(options.name.value), exact: options.name.exact };
      if (!createAttributeMatcher(spec)(accessibleName))
        continue;
    }
    if (options.description !== undefined) {
      const accessibleDescription = normalizeWhiteSpace(getElementAccessibleDescription(element, !!options.includeHidden));
      const spec = options.description.regex
          ? options.description
          : { value: normalizeWhiteSpace(options.description.value), exact: options.description.exact };
      if (!createAttributeMatcher(spec)(accessibleDescription))
        continue;
    }
    result.push(element);
  }
  return result;
}

// --------------------------------------------------------------- evaluation

function queryEngine(cache, scope, part) {
  switch (part.engine) {
    case 'css': return queryCSS(scope, part.body);
    case 'xpath': return queryXPath(scope, part.body);
    case 'text': return queryText(cache, scope, part.text);
    case 'label': return queryLabel(cache, scope, part.text);
    case 'attr': return queryAttr(scope, part.name, part.text);
    case 'testid': return queryTestId(scope, part.names, part.text);
    case 'role': return queryRole(scope, part);
    default: throw new Error('Unknown selector engine: ' + part.engine);
  }
}

function queryParts(root, parts) {
  const cache = new Map();
  let elements = [root];
  for (const part of parts) {
    if (part.engine === 'nth') {
      let index = part.index;
      if (index < 0)
        index += elements.length;
      elements = (index >= 0 && index < elements.length) ? [elements[index]] : [];
    } else if (part.engine === 'visible') {
      elements = elements.filter(e => e.nodeType === 1 && isElementVisible(e) === part.value);
    } else if (part.engine === 'has') {
      elements = elements.filter(e => e.nodeType === 1 && queryParts(e, part.parts).length > 0);
    } else if (part.engine === 'hasNot') {
      elements = elements.filter(e => e.nodeType === 1 && queryParts(e, part.parts).length === 0);
    } else if (part.engine === 'hasText') {
      const { matcher } = createTextMatcher(part.text);
      elements = elements.filter(e => e.nodeType === 1 && matcher(elementText(cache, e)));
    } else if (part.engine === 'hasNotText') {
      const { matcher } = createTextMatcher(part.text);
      elements = elements.filter(e => e.nodeType === 1 && !matcher(elementText(cache, e)));
    } else if (part.engine === 'and') {
      const others = queryParts(root, part.parts);
      elements = elements.filter(e => others.includes(e));
    } else if (part.engine === 'or') {
      const others = queryParts(root, part.parts);
      const merged = [...elements];
      for (const e of others) {
        if (!merged.includes(e))
          merged.push(e);
      }
      elements = sortInDOMOrder(merged);
    } else {
      const next = [];
      for (const scope of elements) {
        for (const element of queryEngine(cache, scope, part)) {
          if (!next.includes(element))
            next.push(element);
        }
      }
      elements = next;
    }
  }
  return elements;
}

// Upstream's selectorEvaluator.ts#sortInDOMOrder. compareDocumentPosition is
// not usable here: it is unordered across shadow roots, and `:is()` and
// `internal:or` mix light and shadow trees.
function sortInDOMOrder(elements) {
  const elementToEntry = new Map();
  const roots = [];
  const result = [];

  function append(element) {
    let entry = elementToEntry.get(element);
    if (entry)
      return entry;
    const parent = parentElementOrShadowHost(element);
    if (parent) {
      const parentEntry = append(parent);
      parentEntry.children.push(element);
    } else {
      roots.push(element);
    }
    entry = { children: [], taken: false };
    elementToEntry.set(element, entry);
    return entry;
  }
  for (const e of elements)
    append(e).taken = true;

  function visit(element) {
    const entry = elementToEntry.get(element);
    if (entry.taken)
      result.push(element);
    if (entry.children.length > 1) {
      const set = new Set(entry.children);
      entry.children = [];
      let child = element.firstElementChild;
      while (child && entry.children.length < set.size) {
        if (set.has(child))
          entry.children.push(child);
        child = child.nextElementSibling;
      }
      child = element.shadowRoot ? element.shadowRoot.firstElementChild : null;
      while (child && entry.children.length < set.size) {
        if (set.has(child))
          entry.children.push(child);
        child = child.nextElementSibling;
      }
    }
    entry.children.forEach(visit);
  }
  roots.forEach(visit);

  return result;
}

function describeSelector(parts) {
  return parts.map(part => {
    switch (part.engine) {
      case 'css': return part.body;
      case 'xpath': return 'xpath=' + part.body;
      case 'text': return 'internal:text=' + describeText(part.text);
      case 'label': return 'internal:label=' + describeText(part.text);
      case 'attr': return 'internal:attr=[' + part.name + '=' + describeText(part.text) + ']';
      case 'testid': return 'internal:testid=[' + part.names.join(',') + '=' + describeText(part.text) + ']';
      case 'role': return 'internal:role=' + part.role + (part.name ? '[name=' + describeText(part.name) + ']' : '');
      case 'nth': return 'nth=' + part.index;
      case 'visible': return 'visible=' + part.value;
      case 'has': return 'internal:has=' + JSON.stringify(describeSelector(part.parts));
      case 'hasNot': return 'internal:has-not=' + JSON.stringify(describeSelector(part.parts));
      case 'hasText': return 'internal:has-text=' + describeText(part.text);
      case 'hasNotText': return 'internal:has-not-text=' + describeText(part.text);
      case 'and': return 'internal:and=' + JSON.stringify(describeSelector(part.parts));
      case 'or': return 'internal:or=' + JSON.stringify(describeSelector(part.parts));
      default: return part.engine;
    }
  }).join(' >> ');
}

function describeText(spec) {
  if (!spec)
    return '';
  if (spec.regex)
    return '/' + spec.regex.source + '/' + spec.regex.flags;
  return JSON.stringify(spec.value) + (spec.exact ? 's' : 'i');
}

// ------------------------------------------------------- actionability

// Ports injectedScript.ts#retarget: a click on a label drives its control, and
// a click on the text inside a button drives the button.
function retarget(node, behavior) {
  let element = node.nodeType === 1 ? node : node.parentElement;
  if (!element)
    return null;
  if (behavior === 'none')
    return element;
  if (!element.matches('input, textarea, select') && !element.isContentEditable) {
    if (behavior === 'button-link')
      element = element.closest('button, [role=button], a, [role=link]') || element;
    else
      element = element.closest('button, [role=button], [role=checkbox], [role=radio]') || element;
  }
  if (behavior === 'follow-label') {
    if (!element.matches('a, input, textarea, button, select, [role=link], [role=button], [role=checkbox], [role=radio]') &&
        !element.isContentEditable) {
      const enclosingLabel = element.closest('label');
      if (enclosingLabel && enclosingLabel.control)
        element = enclosingLabel.control;
    }
  }
  return element;
}

function getCheckedWithoutMixed(element) {
  return getChecked(element, false);
}

function getCheckedAllowMixed(element) {
  return getChecked(element, true);
}

// Ports injectedScript.ts#elementState.
function elementState(node, state) {
  const element = retarget(node, ['visible', 'hidden'].includes(state) ? 'none' : 'follow-label');
  if (!element || !element.isConnected) {
    if (state === 'hidden')
      return { matches: true, received: 'hidden' };
    return { matches: false, received: 'error:notconnected' };
  }

  if (state === 'visible' || state === 'hidden') {
    const visible = isElementVisible(element);
    return { matches: state === 'visible' ? visible : !visible, received: visible ? 'visible' : 'hidden' };
  }

  if (state === 'disabled' || state === 'enabled') {
    const disabled = getAriaDisabled(element);
    return { matches: state === 'disabled' ? disabled : !disabled, received: disabled ? 'disabled' : 'enabled' };
  }

  if (state === 'editable') {
    const disabled = getAriaDisabled(element);
    const readonly = getReadonly(element);
    if (readonly === 'error')
      throw new Error('Element is not an <input>, <textarea>, <select> or [contenteditable] and does not have a role allowing [aria-readonly]');
    return {
      matches: !disabled && !readonly,
      received: disabled ? 'disabled' : (readonly ? 'readOnly' : 'editable'),
    };
  }

  if (state === 'checked' || state === 'unchecked') {
    const need = state === 'checked';
    const checked = getCheckedWithoutMixed(element);
    if (checked === 'error')
      throw new Error('Not a checkbox or radio button');
    return { matches: need === checked, received: checked ? 'checked' : 'unchecked' };
  }

  if (state === 'indeterminate') {
    const checked = getCheckedAllowMixed(element);
    if (checked === 'error')
      throw new Error('Not a checkbox or radio button');
    return {
      matches: checked === 'mixed',
      received: checked === true ? 'checked' : (checked === false ? 'unchecked' : 'mixed'),
    };
  }
  throw new Error('Unexpected element state "' + state + '"');
}

// Upstream samples the bounding box across animation frames inside one async
// call. We keep every injected call synchronous (Juggler does not await
// promises for us), so the samples are taken across successive polls of the
// Dart-side actionability loop instead: the element counts as stable once its
// box matches the box seen on the previous poll.
const stableRectCache = new WeakMap();

function checkElementIsStable(element) {
  const clientRect = element.getBoundingClientRect();
  const rect = {
    x: clientRect.left,
    y: clientRect.top,
    width: clientRect.width,
    height: clientRect.height,
  };
  const previous = stableRectCache.get(element);
  stableRectCache.set(element, rect);
  if (!previous)
    return false;
  return previous.x === rect.x && previous.y === rect.y &&
      previous.width === rect.width && previous.height === rect.height;
}

// Ports injectedScript.ts#expectHitTarget: does a click at the action point
// actually land on this element, or is something on top of it?
//
// The walk starts at the outermost root and descends through shadow roots,
// because elementFromPoint only ever reports the top node of the root it is
// called on. The element that finally answers counts as a hit when it is the
// target itself or one of its descendants.
function hitTargetAt(element, point) {
  const roots = [];
  let parentElement = element;
  while (parentElement) {
    const root = enclosingShadowRootOrDocument(parentElement);
    if (!root)
      break;
    roots.push(root);
    if (root.nodeType === 9 /* Node.DOCUMENT_NODE */)
      break;
    parentElement = root.host;
  }

  let hitElement;
  for (let index = roots.length - 1; index >= 0; index--) {
    const root = roots[index];
    // `display: contents` boxes are skipped by elementsFromPoint but are what
    // elementFromPoint answers, so put them back at the front.
    const elements = root.elementsFromPoint(point.x, point.y);
    const singleElement = root.elementFromPoint(point.x, point.y);
    if (singleElement && elements[0] &&
        parentElementOrShadowHost(singleElement) === elements[0]) {
      const style = document.defaultView.getComputedStyle(singleElement);
      if (style && style.display === 'contents')
        elements.unshift(singleElement);
    }
    if (elements[0] && elements[0].shadowRoot === root &&
        elements[1] === singleElement)
      elements.shift();
    const innerElement = elements[0];
    if (!innerElement)
      break;
    hitElement = innerElement;
    if (index && innerElement !== roots[index - 1].host)
      break;
  }

  let cursor = hitElement;
  while (cursor && cursor !== element)
    cursor = parentElementOrShadowHost(cursor);
  if (cursor === element)
    return null;

  // A label that forwards to the target is a legitimate hit: clicking it acts
  // on the control, which is what the caller asked for.
  if (hitElement && hitElement.closest) {
    const label = hitElement.closest('label');
    if (label && label.control === element)
      return null;
  }

  return hitElement ? describeNodeBriefly(hitElement) : 'nothing';
}

// A short, human-readable form of the element that intercepted the click, so
// the timeout says what is in the way instead of just "not actionable".
function describeNodeBriefly(node) {
  if (!node || node.nodeType !== 1 /* Node.ELEMENT_NODE */)
    return String(node);
  let description = node.nodeName.toLowerCase();
  if (node.id)
    description += '#' + node.id;
  else if (node.classList && node.classList.length)
    description += '.' + Array.from(node.classList).join('.');
  const text = normalizeWhiteSpace(node.textContent || '').slice(0, 30);
  return text ? '<' + description + '> "' + text + '"' : '<' + description + '>';
}

// The viewport point an action on this element would aim at: the centre of
// its box, or `position` measured from its top-left corner. Mirrors what the
// Dart side computes in clickPointForTarget, before the walk up through any
// owning iframes.
function actionPointFor(element, position) {
  element.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
  const rect = element.getBoundingClientRect();
  if (position)
    return { x: rect.left + position.x, y: rect.top + position.y };
  return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
}

// Returns the name of the first state the element does not satisfy, or null.
function checkStates(node, states, options) {
  for (const state of states) {
    if (state === 'stable') {
      const element = retarget(node, 'no-follow-label');
      if (!element || !element.isConnected)
        return 'attached';
      if (!checkElementIsStable(element))
        return 'stable';
      continue;
    }
    if (state === 'receivesEvents') {
      const element = retarget(node, 'no-follow-label');
      if (!element || !element.isConnected)
        return 'attached';
      const point = actionPointFor(element, options && options.position);
      const blocker = hitTargetAt(element, point);
      if (blocker)
        return 'receivesEvents:' + blocker;
      continue;
    }
    const result = elementState(node, state);
    if (result.received === 'error:notconnected')
      return 'attached';
    if (!result.matches)
      return state;
  }
  return null;
}

window.__pwDart = {
  normalizeWhiteSpace,
  isElementVisible,
  getAriaRole,
  getAriaDisabled,
  getAriaChecked,
  getReadonly,
  accessibleName: (element, includeHidden) => getElementAccessibleName(element, !!includeHidden),

  queryAll(parts, root) {
    return queryParts(root || document, parts);
  },

  // Resolves a selector to a single element, honouring Playwright's strict mode.
  // Returns null when nothing matches; throws when strict and several match.
  query(parts, strict, root) {
    const elements = queryParts(root || document, parts);
    if (!elements.length)
      return null;
    if (strict && elements.length > 1) {
      throw new Error('strict mode violation: ' + describeSelector(parts) +
          ' resolved to ' + elements.length + ' elements');
    }
    return elements[0];
  },

  count(parts, root) {
    return queryParts(root || document, parts).length;
  },

  /// Runs `body`, turning a bad selector into `{error: 'invalid'}` instead of
  /// a raw JS exception, so the Dart side can report it as
  /// InvalidSelectorError rather than retrying until the locator times out.
  guard(body) {
    try {
      return { ok: true, value: body() };
    } catch (e) {
      if (isInvalidSelectorError(e))
        return { error: 'invalid', message: e.message };
      throw e;
    }
  },

  retarget,
  elementState,
  checkStates,
  hitTargetAt,

  /// Resolves the selector, checks actionability and runs `body(el)`.
  ///
  /// Returns `{error}` instead of throwing so the Dart-side retry loop can
  /// tell "not there yet" apart from a real failure.
  run(parts, strict, states, body, root, options) {
    let element;
    try {
      element = this.query(parts, strict, root);
    } catch (e) {
      if (isInvalidSelectorError(e))
        return { error: 'invalid', message: e.message };
      return { error: 'strict', message: e.message };
    }
    if (!element)
      return { error: 'notfound' };
    if (states && states.length) {
      const missing = checkStates(element, states, options);
      if (missing)
        return { error: 'state', state: missing };
    }
    return { ok: true, value: body(element) };
  },

  describe: describeSelector,
};
})();
''';

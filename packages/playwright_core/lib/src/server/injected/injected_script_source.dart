// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/injected/src/{domUtils,selectorUtils,roleUtils,roleSelectorEngine,layoutSelectorUtils,selectorEvaluator,injectedScript,ariaSnapshot,ariaSnapshotDistiller}.ts,
// packages/playwright-core/src/server/screenshotter.ts and
// packages/isomorphic/{stringUtils,cssTokenizer,cssParser,yaml}.ts

// The in-page selector engine.
//
// This is a hand port of the pieces of upstream Playwright's injected script
// that the Dart port needs: `packages/injected/src/domUtils.ts`,
// `selectorUtils.ts`, `roleUtils.ts`, `roleSelectorEngine.ts`,
// `layoutSelectorUtils.ts`, `selectorEvaluator.ts`, the `internal:*` engines
// of `injectedScript.ts`, the aria tree of `ariaSnapshot.ts` with the
// `normalizePlugins` of `ariaSnapshotDistiller.ts`, plus
// `packages/isomorphic/stringUtils.ts#normalizeWhiteSpace`, the
// `cssTokenizer.ts`/`cssParser.ts` pair and the `yamlEscape*` helpers of
// `packages/isomorphic/yaml.ts`.
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
//   contributing elements, which only the `ai` mode of its aria snapshots
//   needs (to drop names that merely repeat rendered content).
// * The aria tree ports upstream's `default` mode only, and holds no element
//   references, so there are no `ref=` handles, no `box`/`cursor`, no
//   `[active]` marker and no descent into iframes. Upstream's per-call aria
//   caches are not ported either: the tree is built for a test page, not for
//   an editor's live outline.
library;

import 'injected_css_engine_source.dart';
import 'injected_dom_source.dart';
import 'injected_selector_generator_source.dart';

/// JavaScript source installing `window.__pwDart` in an execution context.
///
/// Evaluating it twice in the same context is harmless.
const String kInjectedScriptSource = _prologue +
    kInjectedDomSource +
    kInjectedCssEngineSource +
    kInjectedSelectorGeneratorSource +
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

// A plain CSS query that descends into open shadow roots, for the engines that
// upstream builds on _queryCSS with pierceShadow: true. begin()/end() bracket
// the call the way upstream's InjectedScript does: without it the evaluator's
// cache would never be dropped and a second query would see a stale DOM.
function queryCSSPiercing(root, body) {
  cssEvaluator.begin();
  try {
    return cssEvaluator._queryCSS({ scope: root, pierceShadow: true }, body);
  } finally {
    cssEvaluator.end();
  }
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
  return queryCSSPiercing(root, '[' + name + ']')
      .filter(e => matcher(e.getAttribute(name)));
}

function queryTestId(root, names, spec) {
  const matcher = createAttributeMatcher(spec);
  const cssQuery = names.map(n => '[' + n + ']').join(',');
  return queryCSSPiercing(root, cssQuery).filter(e => names.some(n => {
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

// ------------------------------------------------------------ aria snapshot
//
// Hand port of upstream `packages/injected/src/ariaSnapshot.ts` (tree building
// and YAML rendering), `ariaSnapshotDistiller.ts` (the two `normalizePlugins`)
// and `yamlEscapeKeyIfNeeded`/`yamlEscapeValueIfNeeded` from
// `packages/isomorphic/yaml.ts`.
//
// Only upstream's `default` mode is ported - the tree that
// `toMatchAriaSnapshot` compares against. The `ai`, `codegen` and `autoexpect`
// modes, element refs, `box`/`cursor`/`active`, iframe descent and the five
// extra `aiPlugins` of the distiller are not.

// https://www.w3.org/TR/wai-aria-1.2/#aria-invalid
const kAriaInvalidRoles = ['application', 'checkbox', 'columnheader', 'combobox', 'gridcell', 'listbox', 'radiogroup', 'rowheader', 'searchbox', 'slider', 'spinbutton', 'switch', 'textbox', 'tree'];

function getAriaInvalid(element) {
  const ariaInvalid = element.getAttribute('aria-invalid');
  if (!ariaInvalid || ariaInvalid.trim() === '' || ariaInvalid.toLocaleLowerCase() === 'false')
    return 'false';
  if (ariaInvalid === 'true' || ariaInvalid === 'grammar' || ariaInvalid === 'spelling')
    return ariaInvalid;
  return 'true';
}

// Data URLs carry megabytes of base64 that help nobody reading a snapshot.
function truncateDataUrl(url) {
  if (!url.startsWith('data:'))
    return url;
  const comma = url.indexOf(',');
  if (comma === -1)
    return url;
  return url.slice(0, comma + 1) + '…';
}

function toAriaNode(element, options) {
  if (element.nodeName === 'IFRAME' || element.nodeName === 'FRAME')
    return { role: 'iframe', name: '', children: [], props: {} };

  const defaultRole = options.includeGenericRole ? 'generic' : null;
  const role = getAriaRole(element) || defaultRole;
  if (!role || role === 'presentation' || role === 'none')
    return null;

  const name = normalizeWhiteSpace(getElementAccessibleName(element, false));
  const box = computeBox(element);
  if (role === 'generic' && box.inline && element.childNodes.length === 1 &&
      element.childNodes[0].nodeType === 3)
    return null;

  const result = { role, name, children: [], props: {} };

  if (kAriaCheckedRoles.includes(role))
    result.checked = getAriaChecked(element);
  if (kAriaDisabledRoles.includes(role))
    result.disabled = getAriaDisabled(element);
  if (kAriaExpandedRoles.includes(role))
    result.expanded = getAriaExpanded(element);
  if (kAriaInvalidRoles.includes(role)) {
    const invalid = getAriaInvalid(element);
    result.invalid = invalid === 'false' ? false : invalid === 'true' ? true : invalid;
  }
  if (kAriaLevelRoles.includes(role))
    result.level = getAriaLevel(element);
  if (kAriaPressedRoles.includes(role))
    result.pressed = getAriaPressed(element);
  if (kAriaSelectedRoles.includes(role))
    result.selected = getAriaSelected(element);

  const tagName = elementSafeTagName(element);
  if (tagName === 'INPUT' || tagName === 'TEXTAREA') {
    if (element.type !== 'checkbox' && element.type !== 'radio' && element.type !== 'file') {
      result.children = [element.value];
      // Not upstream's: upstream only has the text child, this port also has a
      // `value` field on `AccessibilityNode` and fills it from the same place.
      // The YAML renderer below ignores it and renders the text child.
      result.value = element.value;
    }
  }

  // Not upstream's: upstream keeps the description out of the aria node because
  // its YAML never renders one. This port's `AccessibilityNode` has carried a
  // `description` since before aria snapshots existed, and the value comes from
  // upstream's own `getElementAccessibleDescription`, the one behind
  // `getByRole(description:)`. The YAML renderer below ignores it.
  const description = getElementAccessibleDescription(element, false);
  if (description)
    result.description = description;

  return result;
}

// Builds upstream's aria tree rooted at `rootElement`. Returns the `fragment`
// root whose children are the real nodes; string children are text.
function generateAriaTree(rootElement, options) {
  const visited = new Set();
  const root = { role: 'fragment', name: '', children: [], props: {} };

  const visit = (ariaNode, node) => {
    if (visited.has(node))
      return;
    visited.add(node);

    if (node.nodeType === 3 && node.nodeValue) {
      const text = node.nodeValue;
      // <textarea>AAA</textarea> should not report AAA as a child of the textarea.
      if (ariaNode.role !== 'textbox' && text)
        ariaNode.children.push(text);
      return;
    }

    if (node.nodeType !== 1)
      return;

    const element = node;
    // Upstream's `visibility: 'aria'`: a subtree hidden for aria has no aria
    // nodes at all, so it can be skipped whole - and so `parentElementVisible`
    // is always true here, unlike in the modes that keep visually visible but
    // aria-hidden nodes.
    if (isElementHiddenForAria(element))
      return;

    const ariaChildren = [];
    if (element.hasAttribute('aria-owns')) {
      const ids = element.getAttribute('aria-owns').split(/\s+/);
      for (const id of ids) {
        const ownedElement = rootElement.ownerDocument.getElementById(id);
        if (ownedElement)
          ariaChildren.push(ownedElement);
      }
    }

    const childAriaNode = toAriaNode(element, options);
    if (childAriaNode)
      ariaNode.children.push(childAriaNode);
    processElement(childAriaNode || ariaNode, element, ariaChildren);
  };

  function processElement(ariaNode, element, ariaChildren) {
    // Surround every element with spaces for the sake of concatenated text nodes.
    const style = getElementComputedStyle(element);
    const display = (style && style.display) || 'inline';
    const treatAsBlock = (display !== 'inline' || element.nodeName === 'BR') ? ' ' : '';
    if (treatAsBlock)
      ariaNode.children.push(treatAsBlock);

    ariaNode.children.push(getCSSContent(element, '::before') || '');
    const assignedNodes = element.nodeName === 'SLOT' ? element.assignedNodes() : [];
    if (assignedNodes.length) {
      for (const child of assignedNodes)
        visit(ariaNode, child);
    } else {
      for (let child = element.firstChild; child; child = child.nextSibling) {
        if (!child.assignedSlot)
          visit(ariaNode, child);
      }
      if (element.shadowRoot) {
        for (let child = element.shadowRoot.firstChild; child; child = child.nextSibling)
          visit(ariaNode, child);
      }
    }

    for (const child of ariaChildren)
      visit(ariaNode, child);

    ariaNode.children.push(getCSSContent(element, '::after') || '');

    if (treatAsBlock)
      ariaNode.children.push(treatAsBlock);

    if (ariaNode.children.length === 1 && ariaNode.name === ariaNode.children[0])
      ariaNode.children = [];

    if (ariaNode.role === 'link' && element.hasAttribute('href'))
      ariaNode.props['url'] = truncateDataUrl(element.getAttribute('href'));

    if (ariaNode.role === 'textbox' && element.hasAttribute('placeholder') &&
        element.getAttribute('placeholder') !== ariaNode.name)
      ariaNode.props['placeholder'] = element.getAttribute('placeholder');
  }

  visit(root, rootElement);
  distillAriaNode(root);
  return root;
}

// The `mergeStringChildren` plugin: the tree builder emits raw text tokens -
// text nodes, CSS content, block spacing markers - as string children.
function mergeStringChildren(node) {
  const children = [];
  let buffer = [];
  const flush = () => {
    if (!buffer.length)
      return;
    const text = normalizeWhiteSpace(buffer.join(''));
    if (text)
      children.push(text);
    buffer = [];
  };
  for (const child of node.children) {
    if (typeof child === 'string') {
      buffer.push(child);
    } else {
      flush();
      children.push(child);
    }
  }
  flush();
  node.children = children;
  if (node.children.length === 1 && node.children[0] === node.name)
    node.children = [];
}

// The `unwrapSingleChildGenerics` plugin. This mode assigns no refs, so it only
// ever fires on a childless nameless generic, which can only show up when
// `includeGenericRole` is on.
function isUnwrappableGeneric(node) {
  return node.role === 'generic' && !node.name && node.children.length <= 1 &&
      node.children.every(child => typeof child !== 'string' && !!child.ref);
}

// Upstream's distiller with `normalizePlugins`: one post-order traversal where
// each node is merged first and then possibly unwrapped into its parent.
function distillAriaNode(node) {
  const children = [];
  for (const child of node.children) {
    if (typeof child === 'string') {
      children.push(child);
      continue;
    }
    distillAriaNode(child);
    if (isUnwrappableGeneric(child)) {
      for (const grandChild of child.children)
        children.push(grandChild);
      continue;
    }
    children.push(child);
  }
  node.children = children;
  mergeStringChildren(node);
}

function yamlStringNeedsQuotes(str) {
  if (str.length === 0)
    return true;
  // Strings with leading or trailing whitespace need quotes.
  if (/^\s|\s$/.test(str))
    return true;
  // Strings containing control characters need quotes.
  if (/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]/.test(str))
    return true;
  // Strings starting with '-' need quotes.
  if (/^-/.test(str))
    return true;
  // Strings containing ':' or '\n' followed by a space or at the end need quotes.
  if (/[\n:](\s|$)/.test(str))
    return true;
  // Strings containing '#' preceded by a space need quotes (comment indicator).
  if (/\s#/.test(str))
    return true;
  // Strings that contain line breaks need quotes.
  if (/[\n\r]/.test(str))
    return true;
  // Strings starting with indicator characters or quotes need quotes.
  if (/^[&*\],?!>|@"'#%]/.test(str))
    return true;
  // Strings containing special characters that could cause ambiguity.
  if (/[{}`]/.test(str))
    return true;
  // YAML array starts with [.
  if (/^\[/.test(str))
    return true;
  // Non-string types recognized by YAML.
  if (!isNaN(Number(str)) || ['y', 'n', 'yes', 'no', 'true', 'false', 'on', 'off', 'null'].includes(str.toLowerCase()))
    return true;
  return false;
}

function yamlEscapeKeyIfNeeded(str) {
  if (!yamlStringNeedsQuotes(str))
    return str;
  return "'" + str.replace(/'/g, "''") + "'";
}

function yamlEscapeValueIfNeeded(str) {
  if (!yamlStringNeedsQuotes(str))
    return str;
  return '"' + str.replace(/[\\"\x00-\x1f\x7f-\x9f]/g, c => {
    switch (c) {
      case '\\': return '\\\\';
      case '"': return '\\"';
      case '\b': return '\\b';
      case '\f': return '\\f';
      case '\n': return '\\n';
      case '\r': return '\\r';
      case '\t': return '\\t';
      default:
        return '\\x' + c.charCodeAt(0).toString(16).padStart(2, '0');
    }
  }) + '"';
}

function renderAriaTree(root) {
  const lines = [];
  const indent = depth => '  '.repeat(depth);

  const createKey = ariaNode => {
    let key = ariaNode.role;
    // Yaml has a limit of 1024 characters per key, and we leave some space for
    // role and attributes.
    if (ariaNode.name && ariaNode.name.length <= 900) {
      const name = ariaNode.name;
      const stringifiedName = name.startsWith('/') && name.endsWith('/') ? name : JSON.stringify(name);
      key += ' ' + stringifiedName;
    }
    if (ariaNode.checked === 'mixed')
      key += ' [checked=mixed]';
    if (ariaNode.checked === true)
      key += ' [checked]';
    if (ariaNode.disabled)
      key += ' [disabled]';
    if (ariaNode.expanded)
      key += ' [expanded]';
    if (ariaNode.invalid === 'grammar' || ariaNode.invalid === 'spelling')
      key += ' [invalid=' + ariaNode.invalid + ']';
    if (ariaNode.invalid === true)
      key += ' [invalid]';
    if (ariaNode.level)
      key += ' [level=' + ariaNode.level + ']';
    if (ariaNode.pressed === 'mixed')
      key += ' [pressed=mixed]';
    if (ariaNode.pressed === true)
      key += ' [pressed]';
    if (ariaNode.selected === true)
      key += ' [selected]';
    return key;
  };

  const getSingleTextChild = ariaNode =>
      ariaNode.children.length === 1 && typeof ariaNode.children[0] === 'string' &&
          !Object.keys(ariaNode.props).length ? ariaNode.children[0] : undefined;

  const visitText = (text, depth) => {
    const escaped = yamlEscapeValueIfNeeded(text);
    if (escaped)
      lines.push(indent(depth) + '- text: ' + escaped);
  };

  const visit = (ariaNode, depth) => {
    const escapedKey = indent(depth) + '- ' + yamlEscapeKeyIfNeeded(createKey(ariaNode));
    const singleTextChild = getSingleTextChild(ariaNode);
    const hasNoChildren = singleTextChild === undefined && !ariaNode.children.length;

    if (hasNoChildren && !Object.keys(ariaNode.props).length) {
      // Leaf node without children.
      lines.push(escapedKey);
    } else if (singleTextChild !== undefined) {
      // Leaf node with just some text inside.
      lines.push(escapedKey + ': ' + yamlEscapeValueIfNeeded(singleTextChild));
    } else {
      // Node with (optional) props and some children.
      lines.push(escapedKey + ':');
      for (const name of Object.keys(ariaNode.props))
        lines.push(indent(depth + 1) + '- /' + name + ': ' + yamlEscapeValueIfNeeded(ariaNode.props[name]));
      for (const child of ariaNode.children) {
        if (typeof child === 'string')
          visitText(child, depth + 1);
        else
          visit(child, depth + 1);
      }
    }
  };

  // Do not render the root fragment, just its children.
  const nodesToRender = root.role === 'fragment' ? root.children : [root];
  for (const nodeToRender of nodesToRender) {
    if (typeof nodeToRender === 'string')
      visitText(nodeToRender, 0);
    else
      visit(nodeToRender, 0);
  }
  return lines.join('\n');
}

// The element upstream snapshots a whole frame from: `body`, or the `frameset`
// that stands in for it on the old pages where `document.body` is one.
function ariaSnapshotRoot() {
  return document.body || document.querySelector('frameset') || document.documentElement;
}

// ------------------------------------------------------------- screenshots

// Port of `screenshotter.ts#inPagePrepareForScreenshots`, evaluated in every
// frame before a capture and undone after it. The cleanup handle is parked on
// `window` under upstream's own name, because the capture and the cleanup are
// two separate evaluations and nothing else survives between them.
function prepareForScreenshots(screenshotStyle, hideCaret, disableAnimations, syncAnimations) {
  // In WebKit, sync the animations.
  if (syncAnimations) {
    const style = document.createElement('style');
    style.textContent = 'body {}';
    document.head.appendChild(style);
    document.documentElement.getBoundingClientRect();
    style.remove();
  }

  if (!screenshotStyle && !hideCaret && !disableAnimations)
    return;

  const collectRoots = (root, roots = []) => {
    roots.push(root);
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
    do {
      const node = walker.currentNode;
      const shadowRoot = node instanceof Element ? node.shadowRoot : null;
      if (shadowRoot)
        collectRoots(shadowRoot, roots);
    } while (walker.nextNode());
    return roots;
  };

  const roots = collectRoots(document);
  const cleanupCallbacks = [];

  if (screenshotStyle) {
    for (const root of roots) {
      const styleTag = document.createElement('style');
      styleTag.textContent = screenshotStyle;
      if (root === document)
        document.documentElement.append(styleTag);
      else
        root.append(styleTag);
      cleanupCallbacks.push(() => styleTag.remove());
    }
  }

  if (hideCaret) {
    const elements = new Map();
    for (const root of roots) {
      root.querySelectorAll('input,textarea,[contenteditable]').forEach(element => {
        elements.set(element, {
          value: element.style.getPropertyValue('caret-color'),
          priority: element.style.getPropertyPriority('caret-color')
        });
        element.style.setProperty('caret-color', 'transparent', 'important');
      });
    }
    cleanupCallbacks.push(() => {
      for (const [element, value] of elements)
        element.style.setProperty('caret-color', value.value, value.priority);
    });
  }

  if (disableAnimations) {
    const infiniteAnimationsToResume = new Set();
    const handleAnimations = root => {
      for (const animation of root.getAnimations()) {
        if (!animation.effect || animation.playbackRate === 0 || infiniteAnimationsToResume.has(animation))
          continue;
        const endTime = animation.effect.getComputedTiming().endTime;
        if (Number.isFinite(endTime)) {
          try {
            animation.finish();
          } catch (e) {
            // animation.finish() should not throw for finite animations, but
            // we'd like to be on the safe side.
          }
        } else {
          try {
            animation.cancel();
            infiniteAnimationsToResume.add(animation);
          } catch (e) {
            // animation.cancel() should not throw for infinite animations, but
            // we'd like to be on the safe side.
          }
        }
      }
    };
    for (const root of roots) {
      const handleRootAnimations = handleAnimations.bind(null, root);
      handleRootAnimations();
      root.addEventListener('transitionrun', handleRootAnimations);
      root.addEventListener('animationstart', handleRootAnimations);
      cleanupCallbacks.push(() => {
        root.removeEventListener('transitionrun', handleRootAnimations);
        root.removeEventListener('animationstart', handleRootAnimations);
      });
    }
    cleanupCallbacks.push(() => {
      for (const animation of infiniteAnimationsToResume) {
        try {
          animation.play();
        } catch (e) {
          // animation.play() should never throw, but we'd like to be on the
          // safe side.
        }
      }
    });
  }

  window.__pwCleanupScreenshot = () => {
    for (const cleanupCallback of cleanupCallbacks)
      cleanupCallback();
    delete window.__pwCleanupScreenshot;
  };
}

// Paints an opaque box over every element the mask selectors resolve to.
//
// Upstream reuses the recorder's `Highlight`: a `popover` glass pane with a
// closed shadow root, which also drives the inspector's tooltips. That whole
// class is not ported, so the boxes go into a plain fixed-position container
// instead. Two consequences, both accepted: a page stylesheet with a universal
// selector can reach these nodes, and nothing re-positions a box if the layout
// moves between masking and capture — the capture is the very next protocol
// call, so there is nothing in between to move it.
const kMaskContainerTag = 'x-pw-dart-mask';

function maskElements(partsList, color) {
  unmaskElements();
  const container = document.createElement(kMaskContainerTag);
  container.style.position = 'fixed';
  container.style.left = '0';
  container.style.top = '0';
  container.style.right = '0';
  container.style.bottom = '0';
  container.style.pointerEvents = 'none';
  container.style.zIndex = '2147483647';
  let count = 0;
  for (const parts of partsList) {
    // `strict: false` upstream: a mask selector is allowed to hit many nodes.
    for (const element of queryParts(document, parts)) {
      const box = element.getBoundingClientRect();
      const boxElement = document.createElement('div');
      boxElement.style.position = 'absolute';
      boxElement.style.left = box.x + 'px';
      boxElement.style.top = box.y + 'px';
      boxElement.style.width = box.width + 'px';
      boxElement.style.height = box.height + 'px';
      boxElement.style.backgroundColor = color;
      container.appendChild(boxElement);
      count++;
    }
  }
  document.documentElement.appendChild(container);
  return count;
}

function unmaskElements() {
  for (const container of document.querySelectorAll(kMaskContainerTag))
    container.remove();
}

window.__pwDart = {
  normalizeWhiteSpace,
  isElementVisible,
  getAriaRole,
  getAriaDisabled,
  getAriaChecked,
  getReadonly,
  accessibleName: (element, includeHidden) => getElementAccessibleName(element, !!includeHidden),

  // The aria tree, rooted at `root` or at the frame's body, as plain JSON:
  // text children are strings, everything else is an aria node.
  ariaTree(root, options) {
    return generateAriaTree(root || ariaSnapshotRoot(), options || {});
  },

  // The same tree rendered as upstream's aria snapshot YAML.
  ariaSnapshot(root, options) {
    return renderAriaTree(generateAriaTree(root || ariaSnapshotRoot(), options || {}));
  },

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

  // The selector generator the recorder records with. `generateSelector`
  // returns the selector string plus the elements it currently matches, which
  // only an in-page caller (the recorder) can use; `generateSelectorSimple`
  // returns just the string and is what the driver calls to name an iframe.
  generateSelector,
  generateSelectorSimple,

  // What the injected recorder needs on top of the generator. Upstream reaches
  // these through `injectedScript.utils`; here the recorder is a separate
  // script and only sees `window.__pwDart`.
  isInsideScope,
  elementText: element => elementText(new Map(), element),

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

  prepareForScreenshots,
  cleanupScreenshot() {
    if (window.__pwCleanupScreenshot)
      window.__pwCleanupScreenshot();
  },
  maskElements,
  unmaskElements,
};
})();
''';

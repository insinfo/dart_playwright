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

/// JavaScript source installing `window.__pwDart` in an execution context.
///
/// Evaluating it twice in the same context is harmless.
const String kInjectedScriptSource = r'''
// Playwright for Dart, injected selector engine. The leading comment matters:
// it keeps the source from looking like a bare arrow function to
// wrapEvaluationExpression, which would then wrap an already-invoked IIFE.
(() => {
if (window.__pwDart)
  return;

// ---------------------------------------------------------------- dom utils

function parentElementOrShadowHost(element) {
  if (element.parentElement)
    return element.parentElement;
  if (!element.parentNode)
    return undefined;
  if (element.parentNode.nodeType === 11 && element.parentNode.host)
    return element.parentNode.host;
  return undefined;
}

function enclosingShadowHost(element) {
  while (element.parentElement)
    element = element.parentElement;
  return parentElementOrShadowHost(element);
}

function closestCrossShadow(element, css) {
  while (element) {
    const closest = element.closest(css);
    if (closest)
      return closest;
    element = enclosingShadowHost(element);
  }
  return undefined;
}

function enclosingShadowRootOrDocument(element) {
  let node = element;
  while (node.parentNode)
    node = node.parentNode;
  if (node.nodeType === 11 || node.nodeType === 9)
    return node;
  return undefined;
}

function elementSafeTagName(element) {
  const tagName = element.tagName;
  if (typeof tagName === 'string')
    return tagName.toUpperCase();
  if (window.HTMLFormElement && element instanceof HTMLFormElement)
    return 'FORM';
  return String(element.tagName).toUpperCase();
}

function getElementComputedStyle(element, pseudo) {
  const view = element.ownerDocument && element.ownerDocument.defaultView;
  return view ? view.getComputedStyle(element, pseudo) : undefined;
}

function isElementStyleVisibilityVisible(element, style) {
  style = style || getElementComputedStyle(element);
  if (!style)
    return true;
  // Upstream prefers Element.checkVisibility but skips it on WebKit because of
  // https://bugs.webkit.org/show_bug.cgi?id=264733. We cannot tell the engine
  // apart from inside the page, so we run the native check when it exists and
  // the manual details/summary workaround always.
  if (Element.prototype.checkVisibility && !element.checkVisibility())
    return false;
  const detailsOrSummary = element.closest('details,summary');
  if (detailsOrSummary !== element && detailsOrSummary &&
      detailsOrSummary.nodeName === 'DETAILS' && !detailsOrSummary.open)
    return false;
  return style.visibility === 'visible';
}

function isVisibleTextNode(node) {
  const range = node.ownerDocument.createRange();
  range.selectNode(node);
  const rect = range.getBoundingClientRect();
  return rect.width > 0 && rect.height > 0;
}

function computeBox(element) {
  const style = getElementComputedStyle(element);
  if (!style)
    return { visible: true, inline: false };
  if (style.display === 'contents') {
    for (let child = element.firstChild; child; child = child.nextSibling) {
      if (child.nodeType === 1 && isElementVisible(child))
        return { visible: true, inline: false };
      if (child.nodeType === 3 && isVisibleTextNode(child))
        return { visible: true, inline: true };
    }
    return { visible: false, inline: false };
  }
  if (!isElementStyleVisibilityVisible(element, style))
    return { visible: false, inline: false };
  const rect = element.getBoundingClientRect();
  return {
    visible: rect.width > 0 && rect.height > 0,
    inline: style.display === 'inline',
  };
}

function isElementVisible(element) {
  return computeBox(element).visible;
}

function normalizeWhiteSpace(text) {
  return text.replace(/[​­]/g, '').trim().replace(/\s+/g, ' ');
}

function asFlatString(s) {
  return s.split(' ').map(chunk =>
      chunk.replace(/\r\n/g, '\n').replace(/[​­]/g, '').replace(/\s\s*/g, ' ')
  ).join(' ').trim();
}

function trimFlatString(s) {
  return s.trim();
}

// Enumerates every element under `root`, descending into open shadow roots.
// Mirrors the `pierceShadow: true` scans upstream does for the text, label and
// role engines.
function allElementsPiercing(root) {
  const result = [];
  const visit = (scope) => {
    const shadows = [];
    if (scope.shadowRoot)
      shadows.push(scope.shadowRoot);
    for (const element of scope.querySelectorAll('*')) {
      result.push(element);
      if (element.shadowRoot)
        shadows.push(element.shadowRoot);
    }
    for (const shadow of shadows)
      visit(shadow);
  };
  visit(root);
  return result;
}

// ------------------------------------------------------------- text matching

function shouldSkipForTextMatching(element) {
  const document = element.ownerDocument;
  return element.nodeName === 'SCRIPT' || element.nodeName === 'NOSCRIPT' ||
      element.nodeName === 'STYLE' || (document.head && document.head.contains(element));
}

function elementText(cache, root) {
  let value = cache.get(root);
  if (value === undefined) {
    value = { full: '', normalized: '', immediate: [] };
    if (!shouldSkipForTextMatching(root)) {
      let currentImmediate = '';
      if ((window.HTMLInputElement && root instanceof HTMLInputElement) &&
          (root.type === 'submit' || root.type === 'button' || root.type === 'reset')) {
        value = { full: root.value, normalized: normalizeWhiteSpace(root.value), immediate: [root.value] };
      } else {
        for (let child = root.firstChild; child; child = child.nextSibling) {
          if (child.nodeType === 3) {
            value.full += child.nodeValue || '';
            currentImmediate += child.nodeValue || '';
          } else if (child.nodeType === 8) {
            continue;
          } else {
            if (currentImmediate)
              value.immediate.push(currentImmediate);
            currentImmediate = '';
            if (child.nodeType === 1)
              value.full += elementText(cache, child).full;
          }
        }
        if (currentImmediate)
          value.immediate.push(currentImmediate);
        if (root.shadowRoot)
          value.full += elementText(cache, root.shadowRoot).full;
        if (value.full)
          value.normalized = normalizeWhiteSpace(value.full);
      }
    }
    cache.set(root, value);
  }
  return value;
}

function elementMatchesText(cache, element, matcher) {
  if (shouldSkipForTextMatching(element))
    return 'none';
  if (!matcher(elementText(cache, element)))
    return 'none';
  for (let child = element.firstChild; child; child = child.nextSibling) {
    if (child.nodeType === 1 && matcher(elementText(cache, child)))
      return 'selfAndChildren';
  }
  if (element.shadowRoot && matcher(elementText(cache, element.shadowRoot)))
    return 'selfAndChildren';
  return 'self';
}

function getElementLabels(cache, element) {
  const labels = getAriaLabelledByElements(element);
  if (labels)
    return labels.map(label => elementText(cache, label));
  const ariaLabel = element.getAttribute('aria-label');
  if (ariaLabel !== null && !!ariaLabel.trim())
    return [{ full: ariaLabel, normalized: normalizeWhiteSpace(ariaLabel), immediate: [ariaLabel] }];
  const isNonHiddenInput = element.nodeName === 'INPUT' && element.type !== 'hidden';
  if (['BUTTON', 'METER', 'OUTPUT', 'PROGRESS', 'SELECT', 'TEXTAREA'].includes(element.nodeName) || isNonHiddenInput) {
    const nativeLabels = element.labels;
    if (nativeLabels)
      return [...nativeLabels].map(label => elementText(cache, label));
  }
  return [];
}

function toRegExp(spec) {
  return new RegExp(spec.source, spec.flags);
}

// `spec` is `{regex: {source, flags}}` or `{value: string, exact: bool}`.
// Mirrors createTextMatcher(selector, /* internal */ true).
function createTextMatcher(spec) {
  if (spec.regex) {
    const re = toRegExp(spec.regex);
    return { kind: 'regex', matcher: text => re.test(text.full) };
  }
  const value = normalizeWhiteSpace(spec.value);
  if (spec.exact)
    return { kind: 'strict', matcher: text => text.normalized === value };
  const lower = value.toLowerCase();
  return { kind: 'lax', matcher: text => text.normalized.toLowerCase().includes(lower) };
}

// Mirrors createAttributeMatcher: regex test, exact equality, or a
// case-insensitive substring.
function createAttributeMatcher(spec) {
  if (spec.regex) {
    const re = toRegExp(spec.regex);
    return s => !!String(s).match(re);
  }
  if (spec.exact)
    return s => s === spec.value;
  const lower = spec.value.toLowerCase();
  return s => String(s).toLowerCase().includes(lower);
}

// ------------------------------------------------------------------ aria

function hasExplicitAccessibleName(e) {
  return e.hasAttribute('aria-label') || e.hasAttribute('aria-labelledby');
}

const kAncestorPreventingLandmark = 'article:not([role]), aside:not([role]), main:not([role]), nav:not([role]), section:not([role]), [role=article], [role=complementary], [role=main], [role=navigation], [role=region]';

const kGlobalAriaAttributes = [
  ['aria-atomic', undefined],
  ['aria-busy', undefined],
  ['aria-controls', undefined],
  ['aria-current', undefined],
  ['aria-describedby', undefined],
  ['aria-details', undefined],
  ['aria-dropeffect', undefined],
  ['aria-flowto', undefined],
  ['aria-grabbed', undefined],
  ['aria-hidden', undefined],
  ['aria-keyshortcuts', undefined],
  ['aria-label', ['caption', 'code', 'deletion', 'emphasis', 'generic', 'insertion', 'paragraph', 'presentation', 'strong', 'subscript', 'superscript']],
  ['aria-labelledby', ['caption', 'code', 'deletion', 'emphasis', 'generic', 'insertion', 'paragraph', 'presentation', 'strong', 'subscript', 'superscript']],
  ['aria-live', undefined],
  ['aria-owns', undefined],
  ['aria-relevant', undefined],
  ['aria-roledescription', ['generic']],
];

function hasGlobalAriaAttribute(element, forRole) {
  return kGlobalAriaAttributes.some(([attr, prohibited]) => {
    return !(prohibited || []).includes(forRole || '') && element.hasAttribute(attr);
  });
}

function hasTabIndex(element) {
  return !Number.isNaN(Number(String(element.getAttribute('tabindex'))));
}

function isFocusable(element) {
  return !isNativelyDisabled(element) && (isNativelyFocusable(element) || hasTabIndex(element));
}

function isNativelyFocusable(element) {
  const tagName = elementSafeTagName(element);
  if (['BUTTON', 'DETAILS', 'SELECT', 'TEXTAREA'].includes(tagName))
    return true;
  if (tagName === 'A' || tagName === 'AREA')
    return element.hasAttribute('href');
  if (tagName === 'INPUT')
    return !element.hidden;
  return false;
}

const inputTypeToRole = {
  'button': 'button',
  'checkbox': 'checkbox',
  'image': 'button',
  'number': 'spinbutton',
  'radio': 'radio',
  'range': 'slider',
  'reset': 'button',
  'submit': 'button',
};

function isHeaderCell(element) {
  return !!element && elementSafeTagName(element) === 'TH';
}

function isNonEmptyDataCell(element) {
  if (!element || elementSafeTagName(element) !== 'TD')
    return false;
  return !!((element.textContent && element.textContent.trim()) || element.children.length > 0);
}

const kImplicitRoleByTagName = {
  'A': e => e.hasAttribute('href') ? 'link' : null,
  'AREA': e => e.hasAttribute('href') ? 'link' : null,
  'ARTICLE': () => 'article',
  'ASIDE': () => 'complementary',
  'BLOCKQUOTE': () => 'blockquote',
  'BUTTON': () => 'button',
  'CAPTION': () => 'caption',
  'CODE': () => 'code',
  'DATALIST': () => 'listbox',
  'DD': () => 'definition',
  'DEL': () => 'deletion',
  'DETAILS': () => 'group',
  'DFN': () => 'term',
  'DIALOG': () => 'dialog',
  'DT': () => 'term',
  'EM': () => 'emphasis',
  'FIELDSET': () => 'group',
  'FIGURE': () => 'figure',
  'FOOTER': e => closestCrossShadow(e, kAncestorPreventingLandmark) ? null : 'contentinfo',
  'FORM': e => hasExplicitAccessibleName(e) ? 'form' : null,
  'H1': () => 'heading',
  'H2': () => 'heading',
  'H3': () => 'heading',
  'H4': () => 'heading',
  'H5': () => 'heading',
  'H6': () => 'heading',
  'HEADER': e => closestCrossShadow(e, kAncestorPreventingLandmark) ? null : 'banner',
  'HR': () => 'separator',
  'HTML': () => 'document',
  'IMG': e => (e.getAttribute('alt') === '') && !e.getAttribute('title') && !hasGlobalAriaAttribute(e) && !hasTabIndex(e) ? 'presentation' : 'img',
  'INPUT': e => {
    const type = String(e.type).toLowerCase();
    if (type === 'search')
      return e.hasAttribute('list') ? 'combobox' : 'searchbox';
    if (['email', 'tel', 'text', 'url', ''].includes(type)) {
      const list = getIdRefs(e, e.getAttribute('list'))[0];
      return (list && elementSafeTagName(list) === 'DATALIST') ? 'combobox' : 'textbox';
    }
    if (type === 'hidden')
      return null;
    if (type === 'file')
      return 'button';
    return inputTypeToRole[type] || 'textbox';
  },
  'INS': () => 'insertion',
  'LI': () => 'listitem',
  'MAIN': () => 'main',
  'MARK': () => 'mark',
  'MATH': () => 'math',
  'MENU': () => 'list',
  'METER': () => 'meter',
  'NAV': () => 'navigation',
  'OL': () => 'list',
  'OPTGROUP': () => 'group',
  'OPTION': () => 'option',
  'OUTPUT': () => 'status',
  'P': () => 'paragraph',
  'PROGRESS': () => 'progressbar',
  'SEARCH': () => 'search',
  'SECTION': e => hasExplicitAccessibleName(e) ? 'region' : null,
  'SELECT': e => e.hasAttribute('multiple') || e.size > 1 ? 'listbox' : 'combobox',
  'STRONG': () => 'strong',
  'SUB': () => 'subscript',
  'SUP': () => 'superscript',
  'SVG': () => 'img',
  'TABLE': () => 'table',
  'TBODY': () => 'rowgroup',
  'TD': e => {
    const table = closestCrossShadow(e, 'table');
    const role = table ? getExplicitAriaRole(table) : '';
    return (role === 'grid' || role === 'treegrid') ? 'gridcell' : 'cell';
  },
  'TEXTAREA': () => 'textbox',
  'TFOOT': () => 'rowgroup',
  'TH': e => {
    const scope = e.getAttribute('scope');
    if (scope === 'col' || scope === 'colgroup')
      return 'columnheader';
    if (scope === 'row' || scope === 'rowgroup')
      return 'rowheader';
    const nextSibling = e.nextElementSibling;
    const prevSibling = e.previousElementSibling;
    const row = !!e.parentElement && elementSafeTagName(e.parentElement) === 'TR' ? e.parentElement : undefined;
    if (!nextSibling && !prevSibling) {
      if (row) {
        const table = closestCrossShadow(row, 'table');
        if (table && table.rows.length <= 1)
          return null;
      }
      return 'columnheader';
    }
    if (isHeaderCell(nextSibling) && isHeaderCell(prevSibling))
      return 'columnheader';
    if (isNonEmptyDataCell(nextSibling) || isNonEmptyDataCell(prevSibling))
      return 'rowheader';
    return 'columnheader';
  },
  'THEAD': () => 'rowgroup',
  'TIME': () => 'time',
  'TR': () => 'row',
  'UL': () => 'list',
};

const kPresentationInheritanceParents = {
  'DD': ['DL', 'DIV'],
  'DIV': ['DL'],
  'DT': ['DL', 'DIV'],
  'LI': ['OL', 'UL'],
  'TBODY': ['TABLE'],
  'TD': ['TR'],
  'TFOOT': ['TABLE'],
  'TH': ['TR'],
  'THEAD': ['TABLE'],
  'TR': ['THEAD', 'TBODY', 'TFOOT', 'TABLE'],
};

function getImplicitAriaRole(element) {
  const factory = kImplicitRoleByTagName[elementSafeTagName(element)];
  const implicitRole = (factory ? factory(element) : null) || '';
  if (!implicitRole)
    return null;
  let ancestor = element;
  while (ancestor) {
    const parent = parentElementOrShadowHost(ancestor);
    const parents = kPresentationInheritanceParents[elementSafeTagName(ancestor)];
    if (!parents || !parent || !parents.includes(elementSafeTagName(parent)))
      break;
    const parentExplicitRole = getExplicitAriaRole(parent);
    if ((parentExplicitRole === 'none' || parentExplicitRole === 'presentation') &&
        !hasPresentationConflictResolution(parent, parentExplicitRole))
      return parentExplicitRole;
    ancestor = parent;
  }
  return implicitRole;
}

const validRoles = ['alert', 'alertdialog', 'application', 'article', 'banner', 'blockquote', 'button', 'caption', 'cell', 'checkbox', 'code', 'columnheader', 'combobox',
  'complementary', 'contentinfo', 'definition', 'deletion', 'dialog', 'directory', 'document', 'emphasis', 'feed', 'figure', 'form', 'generic', 'grid',
  'gridcell', 'group', 'heading', 'img', 'insertion', 'link', 'list', 'listbox', 'listitem', 'log', 'main', 'mark', 'marquee', 'math', 'meter', 'menu',
  'menubar', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'navigation', 'none', 'note', 'option', 'paragraph', 'presentation', 'progressbar', 'radio', 'radiogroup',
  'region', 'row', 'rowgroup', 'rowheader', 'scrollbar', 'search', 'searchbox', 'separator', 'slider',
  'spinbutton', 'status', 'strong', 'subscript', 'superscript', 'switch', 'tab', 'table', 'tablist', 'tabpanel', 'term', 'textbox', 'time', 'timer',
  'toolbar', 'tooltip', 'tree', 'treegrid', 'treeitem'];

function getExplicitAriaRole(element) {
  const roles = (element.getAttribute('role') || '').split(' ').map(role => role.trim());
  return roles.find(role => validRoles.includes(role)) || null;
}

function hasPresentationConflictResolution(element, role) {
  return hasGlobalAriaAttribute(element, role) || isFocusable(element);
}

function getAriaRole(element) {
  const explicitRole = getExplicitAriaRole(element);
  if (!explicitRole)
    return getImplicitAriaRole(element);
  if (explicitRole === 'none' || explicitRole === 'presentation') {
    const implicitRole = getImplicitAriaRole(element);
    if (hasPresentationConflictResolution(element, implicitRole))
      return implicitRole;
  }
  return explicitRole;
}

function getAriaBoolean(attr) {
  return attr === null ? undefined : attr.toLowerCase() === 'true';
}

function isElementIgnoredForAria(element) {
  return ['STYLE', 'SCRIPT', 'NOSCRIPT', 'TEMPLATE'].includes(elementSafeTagName(element));
}

function isElementHiddenForAria(element) {
  if (isElementIgnoredForAria(element))
    return true;
  const style = getElementComputedStyle(element);
  const isSlot = element.nodeName === 'SLOT';
  if (style && style.display === 'contents' && !isSlot) {
    for (let child = element.firstChild; child; child = child.nextSibling) {
      if (child.nodeType === 1 && !isElementHiddenForAria(child))
        return false;
      if (child.nodeType === 3 && isVisibleTextNode(child))
        return false;
    }
    return true;
  }
  const isOptionInsideSelect = element.nodeName === 'OPTION' && !!element.closest('select');
  if (!isOptionInsideSelect && !isSlot && !isElementStyleVisibilityVisible(element, style))
    return true;
  return belongsToDisplayNoneOrAriaHiddenOrNonSlotted(element);
}

function belongsToDisplayNoneOrAriaHiddenOrNonSlotted(element) {
  let hidden = false;
  if (element.parentElement && element.parentElement.shadowRoot && !element.assignedSlot)
    hidden = true;
  if (!hidden) {
    const style = getElementComputedStyle(element);
    hidden = !style || style.display === 'none' ||
        getAriaBoolean(element.getAttribute('aria-hidden')) === true;
  }
  if (!hidden) {
    const parent = parentElementOrShadowHost(element);
    if (parent)
      hidden = belongsToDisplayNoneOrAriaHiddenOrNonSlotted(parent);
  }
  return hidden;
}

function getIdRefs(element, ref) {
  if (!ref)
    return [];
  const root = enclosingShadowRootOrDocument(element);
  if (!root)
    return [];
  try {
    const ids = ref.split(' ').filter(id => !!id);
    const result = [];
    for (const id of ids) {
      const firstElement = root.querySelector('#' + CSS.escape(id));
      if (firstElement && !result.includes(firstElement))
        result.push(firstElement);
    }
    return result;
  } catch (e) {
    return [];
  }
}

function queryInAriaOwned(element, selector) {
  const result = [...element.querySelectorAll(selector)];
  for (const owned of getIdRefs(element, element.getAttribute('aria-owns'))) {
    if (owned.matches(selector))
      result.push(owned);
    result.push(...owned.querySelectorAll(selector));
  }
  return result;
}

// A reduced stand-in for upstream's CSS-tokenizer-based content parser.
// Handles `content: "a" attr(x) "b"` and the `/ "alternative"` form.
function parseCSSContentPropertyAsString(element, content, isPseudo) {
  if (!content || content === 'none' || content === 'normal')
    return undefined;
  let rest = content;
  const slash = splitTopLevelSlash(rest);
  if (slash !== null)
    rest = slash;
  else if (!isPseudo)
    return undefined;
  const accumulated = [];
  let index = 0;
  while (index < rest.length) {
    const ch = rest[index];
    if (ch === ' ' || ch === '\t' || ch === '\n') {
      index++;
      continue;
    }
    if (ch === '"' || ch === "'") {
      let value = '';
      index++;
      while (index < rest.length && rest[index] !== ch) {
        if (rest[index] === '\\' && index + 1 < rest.length)
          index++;
        value += rest[index++];
      }
      if (index >= rest.length)
        return undefined;
      index++;
      accumulated.push(value);
      continue;
    }
    const attrMatch = /^attr\(\s*([-\w]+)\s*\)/.exec(rest.slice(index));
    if (attrMatch) {
      accumulated.push(element.getAttribute(attrMatch[1]) || '');
      index += attrMatch[0].length;
      continue;
    }
    return undefined;
  }
  return accumulated.join('');
}

// Returns the part after a top-level `/` (outside quotes), or null.
function splitTopLevelSlash(content) {
  let quote = null;
  for (let i = 0; i < content.length; i++) {
    const ch = content[i];
    if (quote) {
      if (ch === '\\')
        i++;
      else if (ch === quote)
        quote = null;
    } else if (ch === '"' || ch === "'") {
      quote = ch;
    } else if (ch === '/') {
      return content.slice(i + 1);
    }
  }
  return null;
}

function getCSSContent(element, pseudo) {
  const style = getElementComputedStyle(element, pseudo);
  let content;
  if (style) {
    const contentValue = style.content;
    if (contentValue && contentValue !== 'none' && contentValue !== 'normal') {
      if (style.display !== 'none' && style.visibility !== 'hidden')
        content = parseCSSContentPropertyAsString(element, contentValue, !!pseudo);
    }
  }
  if (pseudo && content !== undefined) {
    const display = (style && style.display) || 'inline';
    if (display !== 'inline')
      content = ' ' + content + ' ';
  }
  return content;
}

function getAriaLabelledByElements(element) {
  const ref = element.getAttribute('aria-labelledby');
  if (ref === null)
    return null;
  const refs = getIdRefs(element, ref);
  return refs.length ? refs : null;
}

function allowsNameFromContent(role, targetDescendant) {
  const alwaysAllowsNameFromContent = ['button', 'cell', 'checkbox', 'columnheader', 'gridcell', 'heading', 'link', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'option', 'radio', 'row', 'rowheader', 'switch', 'tab', 'tooltip', 'treeitem'].includes(role);
  const descendantAllowsNameFromContent = targetDescendant && ['', 'caption', 'code', 'contentinfo', 'definition', 'deletion', 'emphasis', 'insertion', 'list', 'listitem', 'mark', 'none', 'paragraph', 'presentation', 'region', 'row', 'rowgroup', 'section', 'strong', 'subscript', 'superscript', 'table', 'term', 'time'].includes(role);
  return alwaysAllowsNameFromContent || descendantAllowsNameFromContent;
}

function getElementAccessibleName(element, includeHidden) {
  const elementProhibitsNaming = ['caption', 'code', 'definition', 'deletion', 'emphasis', 'generic', 'insertion', 'mark', 'paragraph', 'presentation', 'strong', 'subscript', 'suggestion', 'superscript', 'term', 'time'].includes(getAriaRole(element) || '');
  if (elementProhibitsNaming)
    return '';
  return asFlatString(getTextAlternativeInternal(element, {
    includeHidden,
    visitedElements: new Set(),
    embeddedInTargetElement: 'self',
  }));
}

function getElementAccessibleDescription(element, includeHidden) {
  if (element.hasAttribute('aria-describedby')) {
    const describedBy = getIdRefs(element, element.getAttribute('aria-describedby'));
    return asFlatString(describedBy.map(ref => getTextAlternativeInternal(ref, {
      includeHidden,
      visitedElements: new Set(),
      embeddedInDescribedBy: { element: ref, hidden: isElementHiddenForAria(ref) },
    })).join(' '));
  }
  if (element.hasAttribute('aria-description'))
    return asFlatString(element.getAttribute('aria-description') || '');
  return asFlatString(element.getAttribute('title') || '');
}

function getAccessibleNameFromAssociatedLabels(labels, options) {
  return [...labels].map(label => getTextAlternativeInternal(label, {
    ...options,
    embeddedInLabel: { element: label, hidden: isElementHiddenForAria(label) },
    embeddedInNativeTextAlternative: undefined,
    embeddedInLabelledBy: undefined,
    embeddedInDescribedBy: undefined,
    embeddedInTargetElement: undefined,
  })).filter(name => !!name).join(' ');
}

function getTextAlternativeInternal(element, options) {
  if (options.visitedElements.has(element))
    return '';

  const childOptions = {
    ...options,
    embeddedInTargetElement: options.embeddedInTargetElement === 'self' ? 'descendant' : options.embeddedInTargetElement,
  };

  // step 2a.
  if (!options.includeHidden) {
    const isEmbeddedInHiddenReferenceTraversal =
      !!(options.embeddedInLabelledBy && options.embeddedInLabelledBy.hidden) ||
      !!(options.embeddedInDescribedBy && options.embeddedInDescribedBy.hidden) ||
      !!(options.embeddedInNativeTextAlternative && options.embeddedInNativeTextAlternative.hidden) ||
      !!(options.embeddedInLabel && options.embeddedInLabel.hidden);
    if (isElementIgnoredForAria(element) ||
        (!isEmbeddedInHiddenReferenceTraversal && isElementHiddenForAria(element))) {
      options.visitedElements.add(element);
      return '';
    }
  }

  const labelledBy = getAriaLabelledByElements(element);

  // step 2b.
  if (!options.embeddedInLabelledBy) {
    const accessibleName = (labelledBy || []).map(ref => getTextAlternativeInternal(ref, {
      ...options,
      embeddedInLabelledBy: { element: ref, hidden: isElementHiddenForAria(ref) },
      embeddedInDescribedBy: undefined,
      embeddedInTargetElement: undefined,
      embeddedInLabel: undefined,
      embeddedInNativeTextAlternative: undefined,
    })).join(' ');
    if (accessibleName)
      return accessibleName;
  }

  const role = getAriaRole(element) || '';
  const tagName = elementSafeTagName(element);

  // step 2c / 2d "embedded control".
  if (!!options.embeddedInLabel || !!options.embeddedInLabelledBy || options.embeddedInTargetElement === 'descendant') {
    const isOwnLabel = [...(element.labels || [])].includes(element);
    const isOwnLabelledBy = (labelledBy || []).includes(element);
    if (!isOwnLabel && !isOwnLabelledBy) {
      if (role === 'textbox') {
        options.visitedElements.add(element);
        if (tagName === 'INPUT' || tagName === 'TEXTAREA')
          return element.value || '';
        return element.textContent || '';
      }
      if (['combobox', 'listbox'].includes(role)) {
        options.visitedElements.add(element);
        let selectedOptions;
        if (tagName === 'SELECT') {
          selectedOptions = [...element.selectedOptions];
          if (!selectedOptions.length && element.options.length)
            selectedOptions.push(element.options[0]);
        } else {
          const listbox = role === 'combobox'
              ? queryInAriaOwned(element, '*').find(e => getAriaRole(e) === 'listbox')
              : element;
          selectedOptions = listbox ? queryInAriaOwned(listbox, '[aria-selected="true"]').filter(e => getAriaRole(e) === 'option') : [];
        }
        if (!selectedOptions.length && tagName === 'INPUT')
          return element.value || '';
        return selectedOptions.map(option => getTextAlternativeInternal(option, childOptions)).join(' ');
      }
      if (['progressbar', 'scrollbar', 'slider', 'spinbutton', 'meter'].includes(role)) {
        options.visitedElements.add(element);
        if (element.hasAttribute('aria-valuetext'))
          return element.getAttribute('aria-valuetext') || '';
        if (element.hasAttribute('aria-valuenow'))
          return element.getAttribute('aria-valuenow') || '';
        return element.getAttribute('value') || '';
      }
      if (role === 'menu') {
        options.visitedElements.add(element);
        return '';
      }
    }
  }

  // step 2d.
  const ariaLabel = element.getAttribute('aria-label') || '';
  if (trimFlatString(ariaLabel)) {
    options.visitedElements.add(element);
    return ariaLabel;
  }

  // step 2e.
  if (!['presentation', 'none'].includes(role)) {
    if (tagName === 'INPUT' && ['button', 'submit', 'reset'].includes(element.type)) {
      options.visitedElements.add(element);
      const value = element.value || '';
      if (trimFlatString(value))
        return value;
      if (element.type === 'submit')
        return 'Submit';
      if (element.type === 'reset')
        return 'Reset';
      return element.getAttribute('title') || '';
    }

    if (tagName === 'INPUT' && element.type === 'file') {
      options.visitedElements.add(element);
      const labels = element.labels || [];
      if (labels.length && !options.embeddedInLabelledBy)
        return getAccessibleNameFromAssociatedLabels(labels, options);
      return 'Choose File';
    }

    if (tagName === 'INPUT' && element.type === 'image') {
      options.visitedElements.add(element);
      const labels = element.labels || [];
      if (labels.length && !options.embeddedInLabelledBy)
        return getAccessibleNameFromAssociatedLabels(labels, options);
      const alt = element.getAttribute('alt') || '';
      if (trimFlatString(alt))
        return alt;
      const title = element.getAttribute('title') || '';
      if (trimFlatString(title))
        return title;
      return 'Submit';
    }

    if (!labelledBy && tagName === 'BUTTON') {
      options.visitedElements.add(element);
      const labels = element.labels || [];
      if (labels.length)
        return getAccessibleNameFromAssociatedLabels(labels, options);
      // Fall through to step 2f.
    }

    if (!labelledBy && tagName === 'OUTPUT') {
      options.visitedElements.add(element);
      const labels = element.labels || [];
      if (labels.length)
        return getAccessibleNameFromAssociatedLabels(labels, options);
      return element.getAttribute('title') || '';
    }

    if (!labelledBy && (tagName === 'TEXTAREA' || tagName === 'SELECT' || tagName === 'INPUT')) {
      options.visitedElements.add(element);
      const labels = element.labels || [];
      if (labels.length)
        return getAccessibleNameFromAssociatedLabels(labels, options);
      const usePlaceholder = (tagName === 'INPUT' && ['text', 'password', 'number', 'search', 'tel', 'email', 'url'].includes(element.type)) || tagName === 'TEXTAREA';
      const placeholder = element.getAttribute('placeholder') || '';
      const title = element.getAttribute('title') || '';
      if (!usePlaceholder || title)
        return title;
      return placeholder;
    }

    if (!labelledBy && tagName === 'FIELDSET') {
      options.visitedElements.add(element);
      for (let child = element.firstElementChild; child; child = child.nextElementSibling) {
        if (elementSafeTagName(child) === 'LEGEND') {
          return getTextAlternativeInternal(child, {
            ...childOptions,
            embeddedInNativeTextAlternative: { element: child, hidden: isElementHiddenForAria(child) },
          });
        }
      }
      return element.getAttribute('title') || '';
    }

    if (!labelledBy && tagName === 'FIGURE') {
      options.visitedElements.add(element);
      for (let child = element.firstElementChild; child; child = child.nextElementSibling) {
        if (elementSafeTagName(child) === 'FIGCAPTION') {
          return getTextAlternativeInternal(child, {
            ...childOptions,
            embeddedInNativeTextAlternative: { element: child, hidden: isElementHiddenForAria(child) },
          });
        }
      }
      return element.getAttribute('title') || '';
    }

    if (tagName === 'IMG') {
      options.visitedElements.add(element);
      const alt = element.getAttribute('alt') || '';
      if (trimFlatString(alt))
        return alt;
      return element.getAttribute('title') || '';
    }

    if (tagName === 'TABLE') {
      options.visitedElements.add(element);
      for (let child = element.firstElementChild; child; child = child.nextElementSibling) {
        if (elementSafeTagName(child) === 'CAPTION') {
          return getTextAlternativeInternal(child, {
            ...childOptions,
            embeddedInNativeTextAlternative: { element: child, hidden: isElementHiddenForAria(child) },
          });
        }
      }
      const summary = element.getAttribute('summary') || '';
      if (summary)
        return summary;
    }

    if (tagName === 'AREA') {
      options.visitedElements.add(element);
      const alt = element.getAttribute('alt') || '';
      if (trimFlatString(alt))
        return alt;
      return element.getAttribute('title') || '';
    }

    if (tagName === 'SVG' || element.ownerSVGElement) {
      options.visitedElements.add(element);
      for (let child = element.firstElementChild; child; child = child.nextElementSibling) {
        if (elementSafeTagName(child) === 'TITLE' && child.ownerSVGElement) {
          return getTextAlternativeInternal(child, {
            ...childOptions,
            embeddedInLabelledBy: { element: child, hidden: isElementHiddenForAria(child) },
          });
        }
      }
    }
    if (element.ownerSVGElement && tagName === 'A') {
      const title = element.getAttribute('xlink:title') || '';
      if (trimFlatString(title)) {
        options.visitedElements.add(element);
        return title;
      }
    }
  }

  const shouldNameFromContentForSummary = tagName === 'SUMMARY' && !['presentation', 'none'].includes(role);

  // step 2f + step 2h.
  if (allowsNameFromContent(role, options.embeddedInTargetElement === 'descendant') ||
      shouldNameFromContentForSummary ||
      !!options.embeddedInLabelledBy || !!options.embeddedInDescribedBy ||
      !!options.embeddedInLabel || !!options.embeddedInNativeTextAlternative) {
    options.visitedElements.add(element);
    const accessibleName = innerAccumulatedElementText(element, childOptions);
    const maybeTrimmed = options.embeddedInTargetElement === 'self' ? trimFlatString(accessibleName) : accessibleName;
    if (maybeTrimmed)
      return accessibleName;
  }

  // step 2i.
  if (!['presentation', 'none'].includes(role) || tagName === 'IFRAME' || tagName === 'FRAME') {
    options.visitedElements.add(element);
    const title = element.getAttribute('title') || '';
    if (trimFlatString(title))
      return title;
  }

  options.visitedElements.add(element);
  return '';
}

function innerAccumulatedElementText(element, options) {
  const tokens = [];
  const visit = (node, skipSlotted) => {
    if (skipSlotted && node.assignedSlot)
      return;
    if (node.nodeType === 1) {
      const style = getElementComputedStyle(node);
      const display = (style && style.display) || 'inline';
      let token = getTextAlternativeInternal(node, options);
      if (display !== 'inline' || node.nodeName === 'BR')
        token = ' ' + token + ' ';
      tokens.push(token);
    } else if (node.nodeType === 3) {
      tokens.push(node.textContent || '');
    }
  };
  tokens.push(getCSSContent(element, '::before') || '');
  const content = getCSSContent(element);
  if (content !== undefined) {
    tokens.push(content);
  } else {
    const assignedNodes = element.nodeName === 'SLOT' ? element.assignedNodes() : [];
    if (assignedNodes.length) {
      for (const child of assignedNodes)
        visit(child, false);
    } else {
      for (let child = element.firstChild; child; child = child.nextSibling)
        visit(child, true);
      if (element.shadowRoot) {
        for (let child = element.shadowRoot.firstChild; child; child = child.nextSibling)
          visit(child, true);
      }
      for (const owned of getIdRefs(element, element.getAttribute('aria-owns')))
        visit(owned, true);
    }
  }
  tokens.push(getCSSContent(element, '::after') || '');
  return tokens.join('');
}

const kAriaSelectedRoles = ['gridcell', 'option', 'row', 'tab', 'rowheader', 'columnheader', 'treeitem'];
function getAriaSelected(element) {
  if (elementSafeTagName(element) === 'OPTION')
    return element.selected;
  if (kAriaSelectedRoles.includes(getAriaRole(element) || ''))
    return getAriaBoolean(element.getAttribute('aria-selected')) === true;
  return false;
}

const kAriaCheckedRoles = ['checkbox', 'menuitemcheckbox', 'option', 'radio', 'switch', 'menuitemradio', 'treeitem'];
function getChecked(element, allowMixed) {
  const tagName = elementSafeTagName(element);
  if (allowMixed && tagName === 'INPUT' && element.indeterminate)
    return 'mixed';
  if (tagName === 'INPUT' && ['checkbox', 'radio'].includes(element.type))
    return element.checked;
  if (kAriaCheckedRoles.includes(getAriaRole(element) || '')) {
    const checked = element.getAttribute('aria-checked');
    if (checked === 'true')
      return true;
    if (allowMixed && checked === 'mixed')
      return 'mixed';
    return false;
  }
  return 'error';
}

function getAriaChecked(element) {
  const result = getChecked(element, true);
  return result === 'error' ? false : result;
}

const kAriaPressedRoles = ['button'];
function getAriaPressed(element) {
  if (kAriaPressedRoles.includes(getAriaRole(element) || '')) {
    const pressed = element.getAttribute('aria-pressed');
    if (pressed === 'true')
      return true;
    if (pressed === 'mixed')
      return 'mixed';
  }
  return false;
}

const kAriaExpandedRoles = ['application', 'button', 'checkbox', 'combobox', 'gridcell', 'link', 'listbox', 'menuitem', 'row', 'rowheader', 'tab', 'treeitem', 'columnheader', 'menuitemcheckbox', 'menuitemradio', 'switch'];
function getAriaExpanded(element) {
  if (elementSafeTagName(element) === 'DETAILS')
    return element.open;
  if (kAriaExpandedRoles.includes(getAriaRole(element) || '')) {
    const expanded = element.getAttribute('aria-expanded');
    if (expanded === null)
      return undefined;
    return expanded === 'true';
  }
  return undefined;
}

const kAriaLevelRoles = ['heading', 'listitem', 'row', 'treeitem'];
function getAriaLevel(element) {
  const native = { 'H1': 1, 'H2': 2, 'H3': 3, 'H4': 4, 'H5': 5, 'H6': 6 }[elementSafeTagName(element)];
  if (native)
    return native;
  if (kAriaLevelRoles.includes(getAriaRole(element) || '')) {
    const attr = element.getAttribute('aria-level');
    const value = attr === null ? Number.NaN : Number(attr);
    if (Number.isInteger(value) && value >= 1)
      return value;
  }
  return 0;
}

const kAriaDisabledRoles = ['application', 'button', 'composite', 'gridcell', 'group', 'input', 'link', 'menuitem', 'scrollbar', 'separator', 'tab', 'checkbox', 'columnheader', 'combobox', 'grid', 'listbox', 'menu', 'menubar', 'menuitemcheckbox', 'menuitemradio', 'option', 'radio', 'radiogroup', 'row', 'rowheader', 'searchbox', 'select', 'slider', 'spinbutton', 'switch', 'tablist', 'textbox', 'toolbar', 'tree', 'treegrid', 'treeitem'];

function isNativelyDisabled(element) {
  const isNativeFormControl = ['BUTTON', 'INPUT', 'SELECT', 'TEXTAREA', 'OPTION', 'OPTGROUP'].includes(elementSafeTagName(element));
  return isNativeFormControl && (element.hasAttribute('disabled') ||
      belongsToDisabledOptGroup(element) || belongsToDisabledFieldSet(element));
}

function belongsToDisabledOptGroup(element) {
  return elementSafeTagName(element) === 'OPTION' && !!element.closest('OPTGROUP[DISABLED]');
}

function belongsToDisabledFieldSet(element) {
  const fieldSetElement = element && element.closest('FIELDSET[DISABLED]');
  if (!fieldSetElement)
    return false;
  const legendElement = fieldSetElement.querySelector(':scope > LEGEND');
  return !legendElement || !legendElement.contains(element);
}

function hasExplicitAriaDisabled(element, isAncestor) {
  if (!element)
    return false;
  if (isAncestor || kAriaDisabledRoles.includes(getAriaRole(element) || '')) {
    const attribute = (element.getAttribute('aria-disabled') || '').toLowerCase();
    if (attribute === 'true')
      return true;
    if (attribute === 'false')
      return false;
    return hasExplicitAriaDisabled(parentElementOrShadowHost(element), true);
  }
  return false;
}

function getAriaDisabled(element) {
  return isNativelyDisabled(element) || hasExplicitAriaDisabled(element, false);
}

const kAriaReadonlyRoles = ['checkbox', 'combobox', 'grid', 'gridcell', 'listbox', 'radiogroup', 'slider', 'spinbutton', 'textbox', 'columnheader', 'rowheader', 'searchbox', 'switch', 'treegrid'];
function getReadonly(element) {
  const tagName = elementSafeTagName(element);
  if (['INPUT', 'TEXTAREA', 'SELECT'].includes(tagName))
    return element.hasAttribute('readonly');
  if (kAriaReadonlyRoles.includes(getAriaRole(element) || ''))
    return element.getAttribute('aria-readonly') === 'true';
  if (element.isContentEditable)
    return false;
  return 'error';
}

// --------------------------------------------------------- css tokenizer
//
// Port of upstream's packages/isomorphic/cssTokenizer.ts, itself derived from
// https://github.com/tabatkins/parse-css (CC0). Tokens are plain objects with
// a `type` instead of a class hierarchy; `cssTokenSource` replaces
// `toSource()`. Line/column tracking is dropped: upstream only used it for a
// parse-error log that is a no-op.

function cssBetween(num, first, last) { return num >= first && num <= last; }
function cssDigit(code) { return cssBetween(code, 0x30, 0x39); }
function cssHexDigit(code) { return cssDigit(code) || cssBetween(code, 0x41, 0x46) || cssBetween(code, 0x61, 0x66); }
function cssLetter(code) { return cssBetween(code, 0x41, 0x5a) || cssBetween(code, 0x61, 0x7a); }
function cssNameStartChar(code) { return cssLetter(code) || code >= 0x80 || code === 0x5f; }
function cssNameChar(code) { return cssNameStartChar(code) || cssDigit(code) || code === 0x2d; }
function cssNonPrintable(code) { return cssBetween(code, 0, 8) || code === 0xb || cssBetween(code, 0xe, 0x1f) || code === 0x7f; }
function cssNewline(code) { return code === 0xa; }
function cssWhitespace(code) { return cssNewline(code) || code === 9 || code === 0x20; }

const kMaximumAllowedCodepoint = 0x10ffff;

function cssPreprocess(str) {
  const codepoints = [];
  for (let i = 0; i < str.length; i++) {
    let code = str.charCodeAt(i);
    if (code === 0xd && str.charCodeAt(i + 1) === 0xa) {
      code = 0xa; i++;
    }
    if (code === 0xd || code === 0xc)
      code = 0xa;
    if (code === 0x0)
      code = 0xfffd;
    if (cssBetween(code, 0xd800, 0xdbff) && cssBetween(str.charCodeAt(i + 1), 0xdc00, 0xdfff)) {
      const lead = code - 0xd800;
      const trail = str.charCodeAt(i + 1) - 0xdc00;
      code = Math.pow(2, 16) + lead * Math.pow(2, 10) + trail;
      i++;
    }
    codepoints.push(code);
  }
  return codepoints;
}

function cssStringFromCode(code) {
  if (code <= 0xffff)
    return String.fromCharCode(code);
  code -= Math.pow(2, 16);
  const lead = Math.floor(code / Math.pow(2, 10)) + 0xd800;
  const trail = code % Math.pow(2, 10) + 0xdc00;
  return String.fromCharCode(lead) + String.fromCharCode(trail);
}

function cssEscapeIdent(string) {
  string = '' + string;
  let result = '';
  const firstcode = string.charCodeAt(0);
  for (let i = 0; i < string.length; i++) {
    const code = string.charCodeAt(i);
    if (code === 0x0)
      throw new Error('Invalid character: the input contains U+0000.');
    if (cssBetween(code, 0x1, 0x1f) || code === 0x7f ||
        (i === 0 && cssBetween(code, 0x30, 0x39)) ||
        (i === 1 && cssBetween(code, 0x30, 0x39) && firstcode === 0x2d))
      result += '\\' + code.toString(16) + ' ';
    else if (code >= 0x80 || code === 0x2d || code === 0x5f || cssDigit(code) || cssLetter(code))
      result += string[i];
    else
      result += '\\' + string[i];
  }
  return result;
}

function cssEscapeHash(string) {
  string = '' + string;
  let result = '';
  for (let i = 0; i < string.length; i++) {
    const code = string.charCodeAt(i);
    if (code === 0x0)
      throw new Error('Invalid character: the input contains U+0000.');
    if (code >= 0x80 || code === 0x2d || code === 0x5f || cssDigit(code) || cssLetter(code))
      result += string[i];
    else
      result += '\\' + code.toString(16) + ' ';
  }
  return result;
}

function cssEscapeString(string) {
  string = '' + string;
  let result = '';
  for (let i = 0; i < string.length; i++) {
    const code = string.charCodeAt(i);
    if (code === 0x0)
      throw new Error('Invalid character: the input contains U+0000.');
    if (cssBetween(code, 0x1, 0x1f) || code === 0x7f)
      result += '\\' + code.toString(16) + ' ';
    else if (code === 0x22 || code === 0x5c)
      result += '\\' + string[i];
    else
      result += string[i];
  }
  return result;
}

// Upstream's CSSParserToken#toSource(). Tokens that do not override it print
// their own type, which is exactly what the simple delimiters need.
function cssTokenSource(token) {
  switch (token.type) {
    case 'WHITESPACE': return ' ';
    case 'CDO': return '<!--';
    case 'CDC': return '-->';
    case 'EOF': return '';
    case 'DELIM': return token.value === '\\' ? '\\\n' : token.value;
    case 'IDENT': return cssEscapeIdent(token.value);
    case 'FUNCTION': return cssEscapeIdent(token.value) + '(';
    case 'AT-KEYWORD': return '@' + cssEscapeIdent(token.value);
    case 'HASH': return token.hashType === 'id'
        ? '#' + cssEscapeIdent(token.value)
        : '#' + cssEscapeHash(token.value);
    case 'STRING': return '"' + cssEscapeString(token.value) + '"';
    case 'URL': return 'url("' + cssEscapeString(token.value) + '")';
    case 'NUMBER': return token.repr;
    case 'PERCENTAGE': return token.repr + '%';
    case 'DIMENSION': {
      let unit = cssEscapeIdent(token.unit);
      if (unit[0] && unit[0].toLowerCase() === 'e' &&
          (unit[1] === '-' || cssBetween(unit.charCodeAt(1), 0x30, 0x39)))
        unit = '\\65 ' + unit.slice(1, unit.length);
      return token.repr + unit;
    }
    default: return token.type;
  }
}

function cssTokenize(str1) {
  const str = cssPreprocess(str1);
  let i = -1;
  const tokens = [];
  let code;

  const codepoint = function(index) {
    if (index >= str.length)
      return -1;
    return str[index];
  };
  const next = function(num) {
    if (num === undefined)
      num = 1;
    if (num > 3)
      throw new Error('Spec Error: no more than three codepoints of lookahead.');
    return codepoint(i + num);
  };
  const consume = function(num) {
    if (num === undefined)
      num = 1;
    i += num;
    code = codepoint(i);
    return true;
  };
  const reconsume = function() {
    i -= 1;
    return true;
  };
  const eof = function(cp) {
    if (cp === undefined)
      cp = code;
    return cp === -1;
  };
  const donothing = function() {};
  const parseerror = function() {};

  const consumeAToken = function() {
    consumeComments();
    consume();
    if (cssWhitespace(code)) {
      while (cssWhitespace(next()))
        consume();
      return { type: 'WHITESPACE' };
    } else if (code === 0x22) {
      return consumeAStringToken();
    } else if (code === 0x23) {
      if (cssNameChar(next()) || areAValidEscape(next(1), next(2))) {
        const token = { type: 'HASH', value: '', hashType: 'unrestricted' };
        if (wouldStartAnIdentifier(next(1), next(2), next(3)))
          token.hashType = 'id';
        token.value = consumeAName();
        return token;
      }
      return delim(code);
    } else if (code === 0x24) {
      if (next() === 0x3d) {
        consume();
        return { type: '$=' };
      }
      return delim(code);
    } else if (code === 0x27) {
      return consumeAStringToken();
    } else if (code === 0x28) {
      return { type: '(', value: '(' };
    } else if (code === 0x29) {
      return { type: ')', value: ')' };
    } else if (code === 0x2a) {
      if (next() === 0x3d) {
        consume();
        return { type: '*=' };
      }
      return delim(code);
    } else if (code === 0x2b) {
      if (startsWithANumber()) {
        reconsume();
        return consumeANumericToken();
      }
      return delim(code);
    } else if (code === 0x2c) {
      return { type: ',' };
    } else if (code === 0x2d) {
      if (startsWithANumber()) {
        reconsume();
        return consumeANumericToken();
      } else if (next(1) === 0x2d && next(2) === 0x3e) {
        consume(2);
        return { type: 'CDC' };
      } else if (startsWithAnIdentifier()) {
        reconsume();
        return consumeAnIdentlikeToken();
      }
      return delim(code);
    } else if (code === 0x2e) {
      if (startsWithANumber()) {
        reconsume();
        return consumeANumericToken();
      }
      return delim(code);
    } else if (code === 0x3a) {
      return { type: ':' };
    } else if (code === 0x3b) {
      return { type: ';' };
    } else if (code === 0x3c) {
      if (next(1) === 0x21 && next(2) === 0x2d && next(3) === 0x2d) {
        consume(3);
        return { type: 'CDO' };
      }
      return delim(code);
    } else if (code === 0x40) {
      if (wouldStartAnIdentifier(next(1), next(2), next(3)))
        return { type: 'AT-KEYWORD', value: consumeAName() };
      return delim(code);
    } else if (code === 0x5b) {
      return { type: '[', value: '[' };
    } else if (code === 0x5c) {
      if (startsWithAValidEscape()) {
        reconsume();
        return consumeAnIdentlikeToken();
      }
      parseerror();
      return delim(code);
    } else if (code === 0x5d) {
      return { type: ']', value: ']' };
    } else if (code === 0x5e) {
      if (next() === 0x3d) {
        consume();
        return { type: '^=' };
      }
      return delim(code);
    } else if (code === 0x7b) {
      return { type: '{', value: '{' };
    } else if (code === 0x7c) {
      if (next() === 0x3d) {
        consume();
        return { type: '|=' };
      } else if (next() === 0x7c) {
        consume();
        return { type: '||' };
      }
      return delim(code);
    } else if (code === 0x7d) {
      return { type: '}', value: '}' };
    } else if (code === 0x7e) {
      if (next() === 0x3d) {
        consume();
        return { type: '~=' };
      }
      return delim(code);
    } else if (cssDigit(code)) {
      reconsume();
      return consumeANumericToken();
    } else if (cssNameStartChar(code)) {
      reconsume();
      return consumeAnIdentlikeToken();
    } else if (eof()) {
      return { type: 'EOF' };
    }
    return delim(code);
  };

  const delim = function(c) {
    return { type: 'DELIM', value: cssStringFromCode(c) };
  };

  const consumeComments = function() {
    while (next(1) === 0x2f && next(2) === 0x2a) {
      consume(2);
      while (true) {
        consume();
        if (code === 0x2a && next() === 0x2f) {
          consume();
          break;
        } else if (eof()) {
          parseerror();
          return;
        }
      }
    }
  };

  const consumeANumericToken = function() {
    const num = consumeANumber();
    if (wouldStartAnIdentifier(next(1), next(2), next(3))) {
      return {
        type: 'DIMENSION',
        value: num.value,
        repr: num.repr,
        numberType: num.type,
        unit: consumeAName(),
      };
    } else if (next() === 0x25) {
      consume();
      return { type: 'PERCENTAGE', value: num.value, repr: num.repr };
    }
    return { type: 'NUMBER', value: num.value, repr: num.repr, numberType: num.type };
  };

  const consumeAnIdentlikeToken = function() {
    const name = consumeAName();
    if (name.toLowerCase() === 'url' && next() === 0x28) {
      consume();
      while (cssWhitespace(next(1)) && cssWhitespace(next(2)))
        consume();
      if (next() === 0x22 || next() === 0x27)
        return { type: 'FUNCTION', value: name };
      else if (cssWhitespace(next()) && (next(2) === 0x22 || next(2) === 0x27))
        return { type: 'FUNCTION', value: name };
      return consumeAURLToken();
    } else if (next() === 0x28) {
      consume();
      return { type: 'FUNCTION', value: name };
    }
    return { type: 'IDENT', value: name };
  };

  const consumeAStringToken = function(endingCodePoint) {
    if (endingCodePoint === undefined)
      endingCodePoint = code;
    let string = '';
    while (consume()) {
      if (code === endingCodePoint || eof())
        return { type: 'STRING', value: string };
      if (cssNewline(code)) {
        parseerror();
        reconsume();
        return { type: 'BADSTRING' };
      }
      if (code === 0x5c) {
        if (eof(next()))
          donothing();
        else if (cssNewline(next()))
          consume();
        else
          string += cssStringFromCode(consumeEscape());
      } else {
        string += cssStringFromCode(code);
      }
    }
    throw new Error('Internal error');
  };

  const consumeAURLToken = function() {
    const token = { type: 'URL', value: '' };
    while (cssWhitespace(next()))
      consume();
    if (eof(next()))
      return token;
    while (consume()) {
      if (code === 0x29 || eof()) {
        return token;
      } else if (cssWhitespace(code)) {
        while (cssWhitespace(next()))
          consume();
        if (next() === 0x29 || eof(next())) {
          consume();
          return token;
        }
        consumeTheRemnantsOfABadURL();
        return { type: 'BADURL' };
      } else if (code === 0x22 || code === 0x27 || code === 0x28 || cssNonPrintable(code)) {
        parseerror();
        consumeTheRemnantsOfABadURL();
        return { type: 'BADURL' };
      } else if (code === 0x5c) {
        if (startsWithAValidEscape()) {
          token.value += cssStringFromCode(consumeEscape());
        } else {
          parseerror();
          consumeTheRemnantsOfABadURL();
          return { type: 'BADURL' };
        }
      } else {
        token.value += cssStringFromCode(code);
      }
    }
    throw new Error('Internal error');
  };

  const consumeEscape = function() {
    consume();
    if (cssHexDigit(code)) {
      const digits = [code];
      for (let total = 0; total < 5; total++) {
        if (cssHexDigit(next())) {
          consume();
          digits.push(code);
        } else {
          break;
        }
      }
      if (cssWhitespace(next()))
        consume();
      let value = parseInt(digits.map(function(x) { return String.fromCharCode(x); }).join(''), 16);
      if (value > kMaximumAllowedCodepoint)
        value = 0xfffd;
      return value;
    } else if (eof()) {
      return 0xfffd;
    }
    return code;
  };

  const areAValidEscape = function(c1, c2) {
    if (c1 !== 0x5c)
      return false;
    if (cssNewline(c2))
      return false;
    return true;
  };
  const startsWithAValidEscape = function() {
    return areAValidEscape(code, next());
  };

  const wouldStartAnIdentifier = function(c1, c2, c3) {
    if (c1 === 0x2d)
      return cssNameStartChar(c2) || c2 === 0x2d || areAValidEscape(c2, c3);
    else if (cssNameStartChar(c1))
      return true;
    else if (c1 === 0x5c)
      return areAValidEscape(c1, c2);
    return false;
  };
  const startsWithAnIdentifier = function() {
    return wouldStartAnIdentifier(code, next(1), next(2));
  };

  const wouldStartANumber = function(c1, c2, c3) {
    if (c1 === 0x2b || c1 === 0x2d) {
      if (cssDigit(c2))
        return true;
      if (c2 === 0x2e && cssDigit(c3))
        return true;
      return false;
    } else if (c1 === 0x2e) {
      return cssDigit(c2);
    }
    return cssDigit(c1);
  };
  const startsWithANumber = function() {
    return wouldStartANumber(code, next(1), next(2));
  };

  const consumeAName = function() {
    let result = '';
    while (consume()) {
      if (cssNameChar(code)) {
        result += cssStringFromCode(code);
      } else if (startsWithAValidEscape()) {
        result += cssStringFromCode(consumeEscape());
      } else {
        reconsume();
        return result;
      }
    }
    throw new Error('Internal parse error');
  };

  const consumeANumber = function() {
    let repr = '';
    let type = 'integer';
    if (next() === 0x2b || next() === 0x2d) {
      consume();
      repr += cssStringFromCode(code);
    }
    while (cssDigit(next())) {
      consume();
      repr += cssStringFromCode(code);
    }
    if (next(1) === 0x2e && cssDigit(next(2))) {
      consume();
      repr += cssStringFromCode(code);
      consume();
      repr += cssStringFromCode(code);
      type = 'number';
      while (cssDigit(next())) {
        consume();
        repr += cssStringFromCode(code);
      }
    }
    const c1 = next(1);
    const c2 = next(2);
    const c3 = next(3);
    if ((c1 === 0x45 || c1 === 0x65) && cssDigit(c2)) {
      consume();
      repr += cssStringFromCode(code);
      consume();
      repr += cssStringFromCode(code);
      type = 'number';
      while (cssDigit(next())) {
        consume();
        repr += cssStringFromCode(code);
      }
    } else if ((c1 === 0x45 || c1 === 0x65) && (c2 === 0x2b || c2 === 0x2d) && cssDigit(c3)) {
      consume();
      repr += cssStringFromCode(code);
      consume();
      repr += cssStringFromCode(code);
      consume();
      repr += cssStringFromCode(code);
      type = 'number';
      while (cssDigit(next())) {
        consume();
        repr += cssStringFromCode(code);
      }
    }
    return { type: type, value: +repr, repr: repr };
  };

  const consumeTheRemnantsOfABadURL = function() {
    while (consume()) {
      if (code === 0x29 || eof()) {
        return;
      } else if (startsWithAValidEscape()) {
        consumeEscape();
        donothing();
      } else {
        donothing();
      }
    }
  };

  let iterationCount = 0;
  while (!eof(next())) {
    tokens.push(consumeAToken());
    iterationCount++;
    if (iterationCount > str.length * 2)
      throw new Error("I'm infinite-looping!");
  }
  return tokens;
}

// ------------------------------------------------------------ css parser
//
// Port of upstream's packages/isomorphic/cssParser.ts.

// Thrown for anything the caller wrote wrong: a selector that does not parse,
// or an extension used with the wrong arguments. The Dart side turns it into
// InvalidSelectorError and stops retrying, the way upstream fails fast instead
// of waiting for the locator to time out.
function invalidSelectorError(message) {
  const error = new Error(message);
  error.name = 'InvalidSelectorError';
  error.__pwInvalidSelector = true;
  return error;
}

function isInvalidSelectorError(error) {
  // A native querySelectorAll on a selector the browser rejects throws a
  // DOMException named SyntaxError; that is the same class of caller mistake.
  return !!error && (error.__pwInvalidSelector === true || error.name === 'SyntaxError');
}

const kCustomCSSNames = new Set(['not', 'is', 'where', 'has', 'scope', 'light',
  'visible', 'text', 'text-matches', 'text-is', 'has-text', 'above', 'below',
  'right-of', 'left-of', 'near', 'nth-match']);

const kUnsupportedCSSTokens = new Set(['AT-KEYWORD', 'BADSTRING', 'BADURL',
  '||', 'CDO', 'CDC', ';', '{', '}', 'URL', 'PERCENTAGE']);

function parseCSS(selector, customNames) {
  let tokens;
  try {
    tokens = cssTokenize(selector);
    if (!tokens.length || tokens[tokens.length - 1].type !== 'EOF')
      tokens.push({ type: 'EOF' });
  } catch (e) {
    throw invalidSelectorError(e.message + ' while parsing css selector "' +
        selector + '". Did you mean to CSS.escape it?');
  }
  const unsupportedToken = tokens.find(token => kUnsupportedCSSTokens.has(token.type));
  if (unsupportedToken) {
    throw invalidSelectorError('Unsupported token "' + cssTokenSource(unsupportedToken) +
        '" while parsing css selector "' + selector + '". Did you mean to CSS.escape it?');
  }

  let pos = 0;
  const names = new Set();

  function unexpected() {
    return invalidSelectorError('Unexpected token "' + cssTokenSource(tokens[pos]) +
        '" while parsing css selector "' + selector + '". Did you mean to CSS.escape it?');
  }

  function at(p) { return p === undefined ? pos : p; }
  function isType(type, p) { return tokens[at(p)].type === type; }
  function skipWhitespace() {
    while (isType('WHITESPACE'))
      pos++;
  }
  function isIdent(p) { return isType('IDENT', p); }
  function isString(p) { return isType('STRING', p); }
  function isNumber(p) { return isType('NUMBER', p); }
  function isComma(p) { return isType(',', p); }
  function isOpenParen(p) { return isType('(', p); }
  function isCloseParen(p) { return isType(')', p); }
  function isFunction(p) { return isType('FUNCTION', p); }
  function isStar(p) { return isType('DELIM', p) && tokens[at(p)].value === '*'; }
  function isEOF(p) { return isType('EOF', p); }
  function isClauseCombinator(p) {
    return isType('DELIM', p) && ['>', '+', '~'].includes(tokens[at(p)].value);
  }
  function isSelectorClauseEnd(p) {
    return isComma(p) || isCloseParen(p) || isEOF(p) || isClauseCombinator(p) || isType('WHITESPACE', p);
  }

  function consumeFunctionArguments() {
    const result = [consumeArgument()];
    while (true) {
      skipWhitespace();
      if (!isComma())
        break;
      pos++;
      result.push(consumeArgument());
    }
    return result;
  }

  function consumeArgument() {
    skipWhitespace();
    if (isNumber())
      return tokens[pos++].value;
    if (isString())
      return tokens[pos++].value;
    return consumeComplexSelector();
  }

  function consumeComplexSelector() {
    const result = { simples: [] };
    skipWhitespace();
    if (isClauseCombinator()) {
      // Implicit ":scope" at the start. https://drafts.csswg.org/selectors-4/#relative
      result.simples.push({ selector: { functions: [{ name: 'scope', args: [] }] }, combinator: '' });
    } else {
      result.simples.push({ selector: consumeSimpleSelector(), combinator: '' });
    }
    while (true) {
      skipWhitespace();
      if (isClauseCombinator()) {
        result.simples[result.simples.length - 1].combinator = tokens[pos++].value;
        skipWhitespace();
      } else if (isSelectorClauseEnd()) {
        break;
      }
      result.simples.push({ combinator: '', selector: consumeSimpleSelector() });
    }
    return result;
  }

  function consumeSimpleSelector() {
    let rawCSSString = '';
    const functions = [];

    while (!isSelectorClauseEnd()) {
      if (isIdent() || isStar()) {
        rawCSSString += cssTokenSource(tokens[pos++]);
      } else if (isType('HASH')) {
        rawCSSString += cssTokenSource(tokens[pos++]);
      } else if (isType('DELIM') && tokens[pos].value === '.') {
        pos++;
        if (isIdent())
          rawCSSString += '.' + cssTokenSource(tokens[pos++]);
        else
          throw unexpected();
      } else if (isType(':')) {
        pos++;
        if (isIdent()) {
          if (!customNames.has(tokens[pos].value.toLowerCase())) {
            rawCSSString += ':' + cssTokenSource(tokens[pos++]);
          } else {
            const name = tokens[pos++].value.toLowerCase();
            functions.push({ name: name, args: [] });
            names.add(name);
          }
        } else if (isFunction()) {
          const name = tokens[pos++].value.toLowerCase();
          if (!customNames.has(name)) {
            rawCSSString += ':' + name + '(' + consumeBuiltinFunctionArguments() + ')';
          } else {
            functions.push({ name: name, args: consumeFunctionArguments() });
            names.add(name);
          }
          skipWhitespace();
          if (!isCloseParen())
            throw unexpected();
          pos++;
        } else {
          throw unexpected();
        }
      } else if (isType('[')) {
        rawCSSString += '[';
        pos++;
        while (!isType(']') && !isEOF())
          rawCSSString += cssTokenSource(tokens[pos++]);
        if (!isType(']'))
          throw unexpected();
        rawCSSString += ']';
        pos++;
      } else {
        throw unexpected();
      }
    }
    if (!rawCSSString && !functions.length)
      throw unexpected();
    return { css: rawCSSString || undefined, functions: functions };
  }

  function consumeBuiltinFunctionArguments() {
    let s = '';
    let balance = 1; // First open paren is a part of a function token.
    while (!isEOF()) {
      if (isOpenParen() || isFunction())
        balance++;
      if (isCloseParen())
        balance--;
      if (!balance)
        break;
      s += cssTokenSource(tokens[pos++]);
    }
    return s;
  }

  const result = consumeFunctionArguments();
  if (!isEOF())
    throw unexpected();
  if (result.some(arg => typeof arg !== 'object' || !('simples' in arg))) {
    throw invalidSelectorError('Error while parsing css selector "' + selector +
        '". Did you mean to CSS.escape it?');
  }
  return { selector: result, names: Array.from(names) };
}

// ------------------------------------------------- layout selector scoring
//
// Port of upstream's packages/injected/src/layoutSelectorUtils.ts. The score
// is what orders the results of a layout selector: the closest match first.

function boxRightOf(box1, box2, maxDistance) {
  const distance = box1.left - box2.right;
  if (distance < 0 || (maxDistance !== undefined && distance > maxDistance))
    return undefined;
  return distance + Math.max(box2.bottom - box1.bottom, 0) + Math.max(box1.top - box2.top, 0);
}

function boxLeftOf(box1, box2, maxDistance) {
  const distance = box2.left - box1.right;
  if (distance < 0 || (maxDistance !== undefined && distance > maxDistance))
    return undefined;
  return distance + Math.max(box2.bottom - box1.bottom, 0) + Math.max(box1.top - box2.top, 0);
}

function boxAbove(box1, box2, maxDistance) {
  const distance = box2.top - box1.bottom;
  if (distance < 0 || (maxDistance !== undefined && distance > maxDistance))
    return undefined;
  return distance + Math.max(box1.left - box2.left, 0) + Math.max(box2.right - box1.right, 0);
}

function boxBelow(box1, box2, maxDistance) {
  const distance = box1.top - box2.bottom;
  if (distance < 0 || (maxDistance !== undefined && distance > maxDistance))
    return undefined;
  return distance + Math.max(box1.left - box2.left, 0) + Math.max(box2.right - box1.right, 0);
}

function boxNear(box1, box2, maxDistance) {
  const kThreshold = maxDistance === undefined ? 50 : maxDistance;
  let score = 0;
  if (box1.left - box2.right >= 0)
    score += box1.left - box2.right;
  if (box2.left - box1.right >= 0)
    score += box2.left - box1.right;
  if (box2.top - box1.bottom >= 0)
    score += box2.top - box1.bottom;
  if (box1.top - box2.bottom >= 0)
    score += box1.top - box2.bottom;
  return score > kThreshold ? undefined : score;
}

const kLayoutScorers = {
  'left-of': boxLeftOf,
  'right-of': boxRightOf,
  'above': boxAbove,
  'below': boxBelow,
  'near': boxNear,
};

function layoutSelectorScore(name, element, inner, maxDistance) {
  const box = element.getBoundingClientRect();
  const scorer = kLayoutScorers[name];
  let bestScore;
  for (const e of inner) {
    if (e === element)
      continue;
    const score = scorer(box, e.getBoundingClientRect(), maxDistance);
    if (score === undefined)
      continue;
    if (bestScore === undefined || score < bestScore)
      bestScore = score;
  }
  return bestScore;
}

// --------------------------------------------------------- css evaluator
//
// Port of upstream's packages/injected/src/selectorEvaluator.ts.

class SelectorEvaluatorImpl {
  constructor() {
    this._cacheText = new Map();
    this._cacheQueryCSS = new Map();
    this._cacheMatches = new Map();
    this._cacheQuery = new Map();
    this._cacheMatchesSimple = new Map();
    this._cacheMatchesParents = new Map();
    this._cacheCallMatches = new Map();
    this._cacheCallQuery = new Map();
    this._cacheQuerySimple = new Map();
    this._scoreMap = undefined;
    this._retainCacheCounter = 0;

    this._engines = new Map();
    this._engines.set('not', notEngine);
    this._engines.set('is', isEngine);
    this._engines.set('where', isEngine);
    this._engines.set('has', hasEngine);
    this._engines.set('scope', scopeEngine);
    this._engines.set('light', lightEngine);
    this._engines.set('visible', visibleEngine);
    this._engines.set('text', textEngine);
    this._engines.set('text-is', textIsEngine);
    this._engines.set('text-matches', textMatchesEngine);
    this._engines.set('has-text', hasTextEngine);
    this._engines.set('right-of', createLayoutEngine('right-of'));
    this._engines.set('left-of', createLayoutEngine('left-of'));
    this._engines.set('above', createLayoutEngine('above'));
    this._engines.set('below', createLayoutEngine('below'));
    this._engines.set('near', createLayoutEngine('near'));
    this._engines.set('nth-match', nthMatchEngine);
  }

  begin() {
    ++this._retainCacheCounter;
  }

  end() {
    --this._retainCacheCounter;
    if (!this._retainCacheCounter) {
      this._cacheQueryCSS.clear();
      this._cacheMatches.clear();
      this._cacheQuery.clear();
      this._cacheMatchesSimple.clear();
      this._cacheMatchesParents.clear();
      this._cacheCallMatches.clear();
      this._cacheCallQuery.clear();
      this._cacheQuerySimple.clear();
      this._cacheText.clear();
    }
  }

  _cached(cache, main, rest, cb) {
    if (!cache.has(main))
      cache.set(main, []);
    const entries = cache.get(main);
    const entry = entries.find(e => rest.every((value, index) => e.rest[index] === value));
    if (entry)
      return entry.result;
    const result = cb();
    entries.push({ rest: rest, result: result });
    return result;
  }

  _checkSelector(s) {
    const wellFormed = typeof s === 'object' && s &&
        (Array.isArray(s) || ('simples' in s) && s.simples.length);
    if (!wellFormed)
      throw invalidSelectorError('Malformed selector "' + s + '"');
    return s;
  }

  matches(element, s, context) {
    const selector = this._checkSelector(s);
    this.begin();
    try {
      return this._cached(this._cacheMatches, element, [selector, context.scope, context.pierceShadow, context.originalScope], () => {
        if (Array.isArray(selector))
          return this._matchesEngine(isEngine, element, selector, context);
        if (this._hasScopeClause(selector))
          context = this._expandContextForScopeMatching(context);
        if (!this._matchesSimple(element, selector.simples[selector.simples.length - 1].selector, context))
          return false;
        return this._matchesParents(element, selector, selector.simples.length - 2, context);
      });
    } finally {
      this.end();
    }
  }

  query(context, s) {
    const selector = this._checkSelector(s);
    this.begin();
    try {
      return this._cached(this._cacheQuery, selector, [context.scope, context.pierceShadow, context.originalScope], () => {
        if (Array.isArray(selector))
          return this._queryEngine(isEngine, context, selector);
        if (this._hasScopeClause(selector))
          context = this._expandContextForScopeMatching(context);

        // query() recurses, so this call gets its own score map.
        const previousScoreMap = this._scoreMap;
        this._scoreMap = new Map();
        let elements = this._querySimple(context, selector.simples[selector.simples.length - 1].selector);
        elements = elements.filter(element => this._matchesParents(element, selector, selector.simples.length - 2, context));
        if (this._scoreMap.size) {
          elements.sort((a, b) => {
            const aScore = this._scoreMap.get(a);
            const bScore = this._scoreMap.get(b);
            if (aScore === bScore)
              return 0;
            if (aScore === undefined)
              return 1;
            if (bScore === undefined)
              return -1;
            return aScore - bScore;
          });
        }
        this._scoreMap = previousScoreMap;

        return elements;
      });
    } finally {
      this.end();
    }
  }

  // Temporarily marks an element with a layout score, used to sort at the end
  // of query(). Upstream calls this a hack; it is how :right-of() and friends
  // return the closest match first.
  _markScore(element, score) {
    if (this._scoreMap)
      this._scoreMap.set(element, score);
  }

  _hasScopeClause(selector) {
    return selector.simples.some(simple => simple.selector.functions.some(f => f.name === 'scope'));
  }

  _expandContextForScopeMatching(context) {
    if (context.scope.nodeType !== 1)
      return context;
    const scope = parentElementOrShadowHost(context.scope);
    if (!scope)
      return context;
    return {
      scope: scope,
      pierceShadow: context.pierceShadow,
      originalScope: context.originalScope || context.scope,
    };
  }

  _matchesSimple(element, simple, context) {
    return this._cached(this._cacheMatchesSimple, element, [simple, context.scope, context.pierceShadow, context.originalScope], () => {
      if (element === context.scope)
        return false;
      if (simple.css && !this._matchesCSS(element, simple.css))
        return false;
      for (const func of simple.functions) {
        if (!this._matchesEngine(this._getEngine(func.name), element, func.args, context))
          return false;
      }
      return true;
    });
  }

  _querySimple(context, simple) {
    if (!simple.functions.length)
      return this._queryCSS(context, simple.css || '*');

    return this._cached(this._cacheQuerySimple, simple, [context.scope, context.pierceShadow, context.originalScope], () => {
      let css = simple.css;
      const funcs = simple.functions;
      if (css === '*' && funcs.length)
        css = undefined;

      let elements;
      let firstIndex = -1;
      if (css !== undefined) {
        elements = this._queryCSS(context, css);
      } else {
        firstIndex = funcs.findIndex(func => this._getEngine(func.name).query !== undefined);
        if (firstIndex === -1)
          firstIndex = 0;
        elements = this._queryEngine(this._getEngine(funcs[firstIndex].name), context, funcs[firstIndex].args);
      }
      for (let i = 0; i < funcs.length; i++) {
        if (i === firstIndex)
          continue;
        const engine = this._getEngine(funcs[i].name);
        if (engine.matches !== undefined)
          elements = elements.filter(e => this._matchesEngine(engine, e, funcs[i].args, context));
      }
      for (let i = 0; i < funcs.length; i++) {
        if (i === firstIndex)
          continue;
        const engine = this._getEngine(funcs[i].name);
        if (engine.matches === undefined)
          elements = elements.filter(e => this._matchesEngine(engine, e, funcs[i].args, context));
      }
      return elements;
    });
  }

  _matchesParents(element, complex, index, context) {
    if (index < 0)
      return true;
    return this._cached(this._cacheMatchesParents, element, [complex, index, context.scope, context.pierceShadow, context.originalScope], () => {
      const simple = complex.simples[index].selector;
      const combinator = complex.simples[index].combinator;
      if (combinator === '>') {
        const parent = parentElementOrShadowHostInContext(element, context);
        if (!parent || !this._matchesSimple(parent, simple, context))
          return false;
        return this._matchesParents(parent, complex, index - 1, context);
      }
      if (combinator === '+') {
        const previousSibling = previousSiblingInContext(element, context);
        if (!previousSibling || !this._matchesSimple(previousSibling, simple, context))
          return false;
        return this._matchesParents(previousSibling, complex, index - 1, context);
      }
      if (combinator === '') {
        let parent = parentElementOrShadowHostInContext(element, context);
        while (parent) {
          if (this._matchesSimple(parent, simple, context)) {
            if (this._matchesParents(parent, complex, index - 1, context))
              return true;
            if (complex.simples[index - 1].combinator === '')
              break;
          }
          parent = parentElementOrShadowHostInContext(parent, context);
        }
        return false;
      }
      if (combinator === '~') {
        let previousSibling = previousSiblingInContext(element, context);
        while (previousSibling) {
          if (this._matchesSimple(previousSibling, simple, context)) {
            if (this._matchesParents(previousSibling, complex, index - 1, context))
              return true;
            if (complex.simples[index - 1].combinator === '~')
              break;
          }
          previousSibling = previousSiblingInContext(previousSibling, context);
        }
        return false;
      }
      if (combinator === '>=') {
        let parent = element;
        while (parent) {
          if (this._matchesSimple(parent, simple, context)) {
            if (this._matchesParents(parent, complex, index - 1, context))
              return true;
            if (complex.simples[index - 1].combinator === '')
              break;
          }
          parent = parentElementOrShadowHostInContext(parent, context);
        }
        return false;
      }
      throw invalidSelectorError('Unsupported combinator "' + combinator + '"');
    });
  }

  _matchesEngine(engine, element, args, context) {
    if (engine.matches)
      return this._callMatches(engine, element, args, context);
    if (engine.query)
      return this._callQuery(engine, args, context).includes(element);
    throw invalidSelectorError('Selector engine should implement "matches" or "query"');
  }

  _queryEngine(engine, context, args) {
    if (engine.query)
      return this._callQuery(engine, args, context);
    if (engine.matches)
      return this._queryCSS(context, '*').filter(element => this._callMatches(engine, element, args, context));
    throw invalidSelectorError('Selector engine should implement "matches" or "query"');
  }

  _callMatches(engine, element, args, context) {
    return this._cached(this._cacheCallMatches, element,
        [engine, context.scope, context.pierceShadow, context.originalScope, ...args],
        () => engine.matches(element, args, context, this));
  }

  _callQuery(engine, args, context) {
    return this._cached(this._cacheCallQuery, engine,
        [context.scope, context.pierceShadow, context.originalScope, ...args],
        () => engine.query(context, args, this));
  }

  _matchesCSS(element, css) {
    return element.matches(css);
  }

  _queryCSS(context, css) {
    return this._cached(this._cacheQueryCSS, css, [context.scope, context.pierceShadow, context.originalScope], () => {
      let result = [];
      function query(root) {
        result = result.concat([...root.querySelectorAll(css)]);
        if (!context.pierceShadow)
          return;
        if (root.shadowRoot)
          query(root.shadowRoot);
        for (const element of root.querySelectorAll('*')) {
          if (element.shadowRoot)
            query(element.shadowRoot);
        }
      }
      query(context.scope);
      return result;
    });
  }

  _getEngine(name) {
    const engine = this._engines.get(name);
    if (!engine)
      throw invalidSelectorError('Unknown selector engine "' + name + '"');
    return engine;
  }
}

const isEngine = {
  matches(element, args, context, evaluator) {
    if (args.length === 0)
      throw invalidSelectorError('"is" engine expects non-empty selector list');
    return args.some(selector => evaluator.matches(element, selector, context));
  },

  query(context, args, evaluator) {
    if (args.length === 0)
      throw invalidSelectorError('"is" engine expects non-empty selector list');
    let elements = [];
    for (const arg of args)
      elements = elements.concat(evaluator.query(context, arg));
    return args.length === 1 ? elements : sortInDOMOrder(elements);
  },
};

const hasEngine = {
  matches(element, args, context, evaluator) {
    if (args.length === 0)
      throw invalidSelectorError('"has" engine expects non-empty selector list');
    return evaluator.query({
      scope: element,
      pierceShadow: context.pierceShadow,
      originalScope: context.originalScope,
    }, args).length > 0;
  },
};

const scopeEngine = {
  matches(element, args, context, evaluator) {
    if (args.length !== 0)
      throw invalidSelectorError('"scope" engine expects no arguments');
    const actualScope = context.originalScope || context.scope;
    if (actualScope.nodeType === 9)
      return element === actualScope.documentElement;
    return element === actualScope;
  },

  query(context, args, evaluator) {
    if (args.length !== 0)
      throw invalidSelectorError('"scope" engine expects no arguments');
    const actualScope = context.originalScope || context.scope;
    if (actualScope.nodeType === 9) {
      const root = actualScope.documentElement;
      return root ? [root] : [];
    }
    if (actualScope.nodeType === 1)
      return [actualScope];
    return [];
  },
};

const notEngine = {
  matches(element, args, context, evaluator) {
    if (args.length === 0)
      throw invalidSelectorError('"not" engine expects non-empty selector list');
    return !evaluator.matches(element, args, context);
  },
};

const lightEngine = {
  query(context, args, evaluator) {
    return evaluator.query({
      scope: context.scope,
      pierceShadow: false,
      originalScope: context.originalScope,
    }, args);
  },

  matches(element, args, context, evaluator) {
    return evaluator.matches(element, args, {
      scope: context.scope,
      pierceShadow: false,
      originalScope: context.originalScope,
    });
  },
};

const visibleEngine = {
  matches(element, args, context, evaluator) {
    if (args.length)
      throw invalidSelectorError('"visible" engine expects no arguments');
    return isElementVisible(element);
  },
};

const textEngine = {
  matches(element, args, context, evaluator) {
    if (args.length !== 1 || typeof args[0] !== 'string')
      throw invalidSelectorError('"text" engine expects a single string');
    const text = normalizeWhiteSpace(args[0]).toLowerCase();
    const matcher = elementText => elementText.normalized.toLowerCase().includes(text);
    return elementMatchesText(evaluator._cacheText, element, matcher) === 'self';
  },
};

const textIsEngine = {
  matches(element, args, context, evaluator) {
    if (args.length !== 1 || typeof args[0] !== 'string')
      throw invalidSelectorError('"text-is" engine expects a single string');
    const text = normalizeWhiteSpace(args[0]);
    const matcher = elementText => {
      if (!text && !elementText.immediate.length)
        return true;
      return elementText.immediate.some(s => normalizeWhiteSpace(s) === text);
    };
    return elementMatchesText(evaluator._cacheText, element, matcher) !== 'none';
  },
};

const textMatchesEngine = {
  matches(element, args, context, evaluator) {
    if (args.length === 0 || typeof args[0] !== 'string' || args.length > 2 ||
        (args.length === 2 && typeof args[1] !== 'string'))
      throw invalidSelectorError('"text-matches" engine expects a regexp body and optional regexp flags');
    const re = new RegExp(args[0], args.length === 2 ? args[1] : undefined);
    const matcher = elementText => re.test(elementText.full);
    return elementMatchesText(evaluator._cacheText, element, matcher) === 'self';
  },
};

const hasTextEngine = {
  matches(element, args, context, evaluator) {
    if (args.length !== 1 || typeof args[0] !== 'string')
      throw invalidSelectorError('"has-text" engine expects a single string');
    if (shouldSkipForTextMatching(element))
      return false;
    const text = normalizeWhiteSpace(args[0]).toLowerCase();
    return elementText(evaluator._cacheText, element).normalized.toLowerCase().includes(text);
  },
};

function createLayoutEngine(name) {
  return {
    matches(element, args, context, evaluator) {
      const maxDistance = args.length && typeof args[args.length - 1] === 'number'
          ? args[args.length - 1]
          : undefined;
      const queryArgs = maxDistance === undefined ? args : args.slice(0, args.length - 1);
      if (args.length < 1 + (maxDistance === undefined ? 0 : 1)) {
        throw invalidSelectorError('"' + name +
            '" engine expects a selector list and optional maximum distance in pixels');
      }
      const inner = evaluator.query(context, queryArgs);
      const score = layoutSelectorScore(name, element, inner, maxDistance);
      if (score === undefined)
        return false;
      evaluator._markScore(element, score);
      return true;
    },
  };
}

const nthMatchEngine = {
  query(context, args, evaluator) {
    let index = args[args.length - 1];
    if (args.length < 2)
      throw invalidSelectorError('"nth-match" engine expects non-empty selector list and an index argument');
    if (typeof index !== 'number' || index < 1)
      throw invalidSelectorError('"nth-match" engine expects a one-based index as the last argument');
    const elements = isEngine.query(context, args.slice(0, args.length - 1), evaluator);
    index--; // one-based
    return index < elements.length ? [elements[index]] : [];
  },
};

function parentElementOrShadowHostInContext(element, context) {
  if (element === context.scope)
    return undefined;
  if (!context.pierceShadow)
    return element.parentElement || undefined;
  return parentElementOrShadowHost(element);
}

function previousSiblingInContext(element, context) {
  if (element === context.scope)
    return undefined;
  return element.previousElementSibling || undefined;
}
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

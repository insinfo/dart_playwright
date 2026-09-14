// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/injected/src/{domUtils,selectorUtils,roleUtils,roleSelectorEngine,injectedScript,ariaSnapshot,ariaSnapshotDistiller}.ts and
// packages/isomorphic/{stringUtils,yaml}.ts

// The in-page selector engine.
//
// This is a hand port of the pieces of upstream Playwright's injected script
// that the Dart port needs: `packages/injected/src/domUtils.ts`,
// `selectorUtils.ts`, `roleUtils.ts`, `roleSelectorEngine.ts`, the
// `internal:*` engines of `injectedScript.ts`, the aria tree of
// `ariaSnapshot.ts` with the `normalizePlugins` of
// `ariaSnapshotDistiller.ts`, plus
// `packages/isomorphic/stringUtils.ts#normalizeWhiteSpace` and the
// `yamlEscape*` helpers of `packages/isomorphic/yaml.ts`.
//
// Differences from upstream, all deliberate:
//
// * Selectors arrive as structured JSON built in Dart (see `selectors.dart`),
//   not as Playwright's string selector syntax, so `selectorParser.ts` and the
//   CSS tokenizer are not ported. Everything downstream of parsing matches.
// * The `css` engine uses the native `querySelectorAll`, so it does not pierce
//   shadow roots and does not support Playwright's CSS extensions
//   (`:has-text()`, `:visible`, layout selectors). The `text`, `label` and
//   `role` engines do walk into open shadow roots, as upstream does.
// * `getCSSContent` parses `content:` with a small hand-rolled scanner instead
//   of upstream's CSS tokenizer; it handles quoted strings, `attr()` and the
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

// --------------------------------------------------------------- engines

function queryCSS(root, body) {
  const result = [];
  for (const element of root.querySelectorAll(body))
    result.push(element);
  return result;
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

function sortInDOMOrder(elements) {
  return elements.slice().sort((a, b) => {
    const position = a.compareDocumentPosition(b);
    if (position & Node.DOCUMENT_POSITION_FOLLOWING)
      return -1;
    if (position & Node.DOCUMENT_POSITION_PRECEDING)
      return 1;
    return 0;
  });
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

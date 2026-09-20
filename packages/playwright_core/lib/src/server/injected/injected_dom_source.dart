// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/injected/src/{domUtils,selectorUtils,roleUtils}.ts
// and packages/isomorphic/stringUtils.ts

/// The DOM, text-matching and ARIA half of the injected script.
///
/// Split out of [kInjectedScriptSource] only for size; it is not a valid
/// script on its own, it is one fragment of the single IIFE assembled in
/// `injected_script_source.dart`.
library;

/// Visibility, shadow-host walking, `elementText`, the accessible name and
/// the ARIA state getters.
const String kInjectedDomSource = r'''
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

function closestCrossShadow(element, css, scope) {
  while (element) {
    const closest = element.closest(css);
    if (scope && closest !== scope && closest && closest.contains(scope))
      return undefined;
    if (closest)
      return closest;
    element = enclosingShadowHost(element);
  }
  return undefined;
}

function isInsideScope(scope, element) {
  while (element) {
    if (scope.contains(element))
      return true;
    element = enclosingShadowHost(element);
  }
  return false;
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

function getElementLabels(cache, element, options) {
  let labels = getAriaLabelledByElements(element);
  if (labels) {
    if (options && options.skipRefsInsideElement)
      labels = labels.filter(label => label !== element && !element.contains(label));
    return labels.map(label => elementText(cache, label));
  }
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

// Upstream's `insideTargetElement`: whether the name being computed is the
// name of the element the caller asked about, rather than of a reference it
// pulled in. Only such a name can be "derived from content".
function insideTargetElement(options) {
  return options.embeddedInTargetElement === 'self' || options.embeddedInTargetElement === 'descendant';
}

// Upstream's `AccessibleName`, minus the contributing elements: the text plus
// whether it came from the element's own content. The selector generator needs
// the flag to drop a role name that merely repeats the text it was told not to
// use.
function getElementAccessibleNameComposite(element, includeHidden) {
  const elementProhibitsNaming = ['caption', 'code', 'definition', 'deletion', 'emphasis', 'generic', 'insertion', 'mark', 'paragraph', 'presentation', 'strong', 'subscript', 'suggestion', 'superscript', 'term', 'time'].includes(getAriaRole(element) || '');
  if (elementProhibitsNaming)
    return { text: '', derivedFromContent: false };
  const outDerivedFromContent = { value: false };
  const text = asFlatString(getTextAlternativeInternal(element, {
    includeHidden,
    visitedElements: new Set(),
    embeddedInTargetElement: 'self',
    outDerivedFromContent,
  }));
  return { text, derivedFromContent: outDerivedFromContent.value };
}

function getElementAccessibleName(element, includeHidden) {
  return getElementAccessibleNameComposite(element, includeHidden).text;
}

function getElementAccessibleDescriptionComposite(element, includeHidden) {
  if (element.hasAttribute('aria-describedby')) {
    const describedBy = getIdRefs(element, element.getAttribute('aria-describedby'));
    return {
      text: asFlatString(describedBy.map(ref => getTextAlternativeInternal(ref, {
        includeHidden,
        visitedElements: new Set(),
        embeddedInDescribedBy: { element: ref, hidden: isElementHiddenForAria(ref) },
      })).join(' ')),
      derivedFromContent: describedBy.some(ref => ref === element || element.contains(ref)),
    };
  }
  if (element.hasAttribute('aria-description'))
    return { text: asFlatString(element.getAttribute('aria-description') || ''), derivedFromContent: false };
  return { text: asFlatString(element.getAttribute('title') || ''), derivedFromContent: false };
}

function getElementAccessibleDescription(element, includeHidden) {
  return getElementAccessibleDescriptionComposite(element, includeHidden).text;
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
    if (accessibleName) {
      if (options.outDerivedFromContent && insideTargetElement(options) && (labelledBy || []).some(ref => ref === element || element.contains(ref)))
        options.outDerivedFromContent.value = true;
      return accessibleName;
    }
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
    if (maybeTrimmed) {
      if (options.outDerivedFromContent && insideTargetElement(options) && trimFlatString(accessibleName))
        options.outDerivedFromContent.value = true;
      return accessibleName;
    }
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

''';

// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/injected/src/selectorGenerator.ts and the
// escaping helpers of packages/isomorphic/stringUtils.ts.

/// The in-page selector generator: given an element, the best Playwright
/// selector for it.
///
/// This is what makes the recorder emit `getByRole('button', name: 'Sign in')`
/// instead of `div > div:nth-child(3) > button`. The preference order is
/// upstream's and lives in the scores at the top of the source: test id first,
/// then role with an accessible name, placeholder, label, alt text, text,
/// title, and only then CSS by id, role without a name, tag name and finally
/// the structural fallback.
///
/// Differences from upstream, all forced by this port's shape:
///
/// * Upstream builds a selector string for each candidate and parses it back
///   with `injectedScript.parseSelector` before querying. This port parses
///   selector strings in Dart (`server/selectors.dart`) and the page only ever
///   sees the structured parts, so each token carries **both** forms: `selector`
///   is upstream's string, used by `joinTokens` for the value that leaves the
///   page, and `part` is the JSON the ported evaluator queries with. Nothing is
///   parsed in the page, and the two forms are built from the same values, so
///   they cannot drift.
/// * `elementText`'s cache is created per `generateSelector` call instead of
///   living on the evaluator: this port's evaluator has no per-call `begin()`/
///   `end()` bracket, and neither do the aria/DOM caches upstream opens there.
///   The result is identical, the work is repeated.
library;

/// The generator. Not a standalone script: it is concatenated into
/// [kInjectedScriptSource] and relies on the DOM helpers and on `queryParts`
/// that live in the same IIFE.
const String kInjectedSelectorGeneratorSource = r'''
// ------------------------------------------------- selector generator

// packages/isomorphic/stringUtils.ts
function escapeRegExpForSelectorGenerator(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function quoteCSSAttributeValue(text) {
  return '"' + text.replace(/["\\]/g, char => '\\' + char) + '"';
}

function escapeRegexForSelector(re) {
  // Unicode mode does not allow "identity character escapes", so we do not
  // escape and hope that it does not contain quotes and/or >> signs.
  if (re.unicode || re.unicodeSets)
    return String(re);
  // Even number of backslashes followed by the quote -> insert a backslash.
  return String(re).replace(/(^|[^\\])(\\\\)*(["'`])/g, '$1$2\\$3').replace(/>>/g, '\\>\\>');
}

function escapeForTextSelector(text, exact) {
  if (typeof text !== 'string')
    return escapeRegexForSelector(text);
  return JSON.stringify(text) + (exact ? 's' : 'i');
}

function escapeForAttributeSelector(value, exact) {
  if (typeof value !== 'string')
    return escapeRegexForSelector(value);
  // Our attribute selectors do not conform to the CSS parsing spec, so they
  // are escaped differently from cssEscape().
  return '"' + value.replace(/\\/g, '\\\\').replace(/["]/g, '\\"') + '"' + (exact ? 's' : 'i');
}

// The JSON a text match travels as; mirrors `TextMatch.toJson` in
// server/selectors.dart.
function textMatchJson(text, exact) {
  if (typeof text !== 'string') {
    let flags = '';
    if (text.ignoreCase) flags += 'i';
    if (text.multiline) flags += 'm';
    if (text.dotAll) flags += 's';
    if (text.unicode) flags += 'u';
    return { regex: { source: text.source, flags } };
  }
  return { value: text, exact: !!exact };
}

// packages/isomorphic/locatorUtils.ts#splitTestIdAttributeNames
function splitTestIdAttributeNames(testIdAttributeName) {
  return testIdAttributeName.split(',').map(name => name.trim()).filter(name => !!name);
}

const kTextScoreRange = 10;
const kExactPenalty = kTextScoreRange / 2;

const kTestIdScore = 1;        // testIdAttributeName
const kOtherTestIdScore = 2;   // other data-test* attributes

const kIframeByAttributeScore = 10;

const kBeginPenalizedScore = 50;
const kRoleWithNameScore = 100;
const kPlaceholderScore = 120;
const kLabelScore = 140;
const kAltTextScore = 160;
const kTextScore = 180;
const kTitleScore = 200;
const kTextScoreRegex = 250;
const kPlaceholderScoreExact = kPlaceholderScore + kExactPenalty;
const kLabelScoreExact = kLabelScore + kExactPenalty;
const kRoleWithNameScoreExact = kRoleWithNameScore + kExactPenalty;
const kAltTextScoreExact = kAltTextScore + kExactPenalty;
const kTextScoreExact = kTextScore + kExactPenalty;
const kTitleScoreExact = kTitleScore + kExactPenalty;
const kEndPenalizedScore = 300;

const kCSSIdScore = 500;
const kRoleWithoutNameScore = 510;
const kCSSInputTypeNameScore = 520;
const kCSSTagNameScore = 530;
const kNthScore = 10000;
const kCSSFallbackScore = 10000000;

const kScoreThresholdForTextExpect = 1000;

// Token constructors. Each builds upstream's selector string and this port's
// query part from the same values.
function cssToken(body, score) {
  return { engine: 'css', selector: body, score, part: { engine: 'css', body } };
}

function nthToken(index) {
  return { engine: 'nth', selector: String(index), score: kNthScore, part: { engine: 'nth', index } };
}

function testIdToken(attributeName, value, score) {
  return {
    engine: 'internal:testid',
    selector: '[' + attributeName + '=' + escapeForAttributeSelector(value, true) + ']',
    score,
    part: { engine: 'testid', names: [attributeName], text: textMatchJson(value, true) },
  };
}

function attrToken(attributeName, value, exact, score) {
  return {
    engine: 'internal:attr',
    selector: '[' + attributeName + '=' + escapeForAttributeSelector(value, exact) + ']',
    score,
    part: { engine: 'attr', name: attributeName, text: textMatchJson(value, exact) },
  };
}

function labelToken(value, exact, score) {
  return {
    engine: 'internal:label',
    selector: escapeForTextSelector(value, exact),
    score,
    part: { engine: 'label', text: textMatchJson(value, exact) },
  };
}

function textToken(value, exact, score) {
  return {
    engine: 'internal:text',
    selector: escapeForTextSelector(value, exact),
    score,
    part: { engine: 'text', text: textMatchJson(value, exact) },
  };
}

function hasTextToken(value, exact, score) {
  return {
    engine: 'internal:has-text',
    selector: escapeForTextSelector(value, exact),
    score,
    part: { engine: 'hasText', text: textMatchJson(value, exact) },
  };
}

function roleToken(role, name, nameExact, description, descriptionExact, score) {
  let selector = role;
  const part = { engine: 'role', role };
  if (name !== undefined) {
    selector += '[name=' + escapeForAttributeSelector(name, nameExact) + ']';
    part.name = textMatchJson(name, nameExact);
  }
  if (description !== undefined) {
    selector += '[description=' + escapeForAttributeSelector(description, descriptionExact) + ']';
    part.description = textMatchJson(description, descriptionExact);
  }
  return { engine: 'internal:role', selector, score, part };
}

function queryTokens(tokens, root) {
  return queryParts(root, tokens.map(token => token.part));
}

function generateSelector(targetElement, options) {
  const cache = { allowText: new Map(), disallowText: new Map(), text: new Map() };
  let targetTokens;
  if (options.forTextExpect) {
    targetTokens = cssFallback(targetElement.ownerDocument.documentElement, options);
    for (let element = targetElement; element; element = parentElementOrShadowHost(element)) {
      const tokens = generateSelectorFor(cache, element, { ...options, noText: true });
      if (!tokens)
        continue;
      const score = combineScores(tokens);
      if (score <= kScoreThresholdForTextExpect) {
        targetTokens = tokens;
        break;
      }
    }
  } else {
    // Note: this matches retarget().
    if (!targetElement.matches('input,textarea,select') && !targetElement.isContentEditable) {
      const interactiveParent = closestCrossShadow(targetElement, 'button,select,input,[role=button],[role=checkbox],[role=radio],a,[role=link]', options.root);
      if (interactiveParent && isElementVisible(interactiveParent))
        targetElement = interactiveParent;
    }
    targetTokens = generateSelectorFor(cache, targetElement, options) || cssFallback(targetElement, options);
  }
  return {
    selector: joinTokens(targetTokens),
    elements: queryTokens(targetTokens, options.root || targetElement.ownerDocument),
  };
}

// Upstream's `generateSelectorSimple`: the shortest selector that pinpoints an
// element, used for the iframe chain of a cross-frame selector.
function generateSelectorSimple(element) {
  return generateSelector(element, { testIdAttributeName: 'data-testid', omitInternalEngines: true }).selector;
}

function generateSelectorFor(cache, targetElement, options) {
  if (options.root && !isInsideScope(options.root, targetElement))
    throw new Error("Target element must belong to the root's subtree");

  if (targetElement === options.root)
    return [cssToken(':scope', 1)];
  if (targetElement.ownerDocument.documentElement === targetElement)
    return [cssToken('html', 1)];

  let result = null;
  const updateResult = candidate => {
    if (!result || combineScores(candidate) < combineScores(result))
      result = candidate;
  };

  const candidates = [];
  for (const candidate of buildTextCandidates(cache, targetElement, !options.isRecursive, options))
    candidates.push({ candidate, isTextCandidate: true });
  for (const token of buildNoTextCandidates(cache, targetElement, options)) {
    if (options.omitInternalEngines && token.engine.startsWith('internal:'))
      continue;
    candidates.push({ candidate: [token], isTextCandidate: false });
  }
  candidates.sort((a, b) => combineScores(a.candidate) - combineScores(b.candidate));

  for (const { candidate, isTextCandidate } of candidates) {
    const elements = queryTokens(candidate, options.root || targetElement.ownerDocument);
    if (!elements.includes(targetElement)) {
      // Somehow this selector just does not match the target. Oh well.
      continue;
    }

    if (elements.length === 1) {
      // Perfect strict match. All other candidates are strictly worse because
      // they are sorted by score.
      updateResult(candidate);
      break;
    }

    const index = elements.indexOf(targetElement);
    if (index > 5) {
      // Do not generate locators with nth=6 or worse.
      continue;
    }
    updateResult([...candidate, nthToken(index)]);

    if (options.isRecursive) {
      // Limit nesting to two levels: parent >>> target.
      continue;
    }

    // Now try nested selectors: (best selector for parent) >>> (this candidate).
    for (let parent = parentElementOrShadowHost(targetElement); parent && parent !== options.root; parent = parentElementOrShadowHost(parent)) {
      const filtered = elements.filter(e => isInsideScope(parent, e) && e !== parent);
      const newIndex = filtered.indexOf(targetElement);
      if (filtered.length > 5 || newIndex === -1 || (newIndex === index && filtered.length > 1)) {
        // Filtering to this parent is not an improvement.
        continue;
      }

      const inParent = filtered.length === 1 ? candidate : [...candidate, nthToken(newIndex)];
      // Best theoretical score we could achieve for the parent.
      const idealSelectorForParent = { engine: '', selector: '', score: 1 };
      if (result && combineScores([idealSelectorForParent, ...inParent]) >= combineScores(result)) {
        // It is impossible to generate a better scoring selector through this parent.
        continue;
      }

      // Do not allow text in parent selector when using text in the target selector.
      const noText = !!options.noText || isTextCandidate;
      const cacheMap = noText ? cache.disallowText : cache.allowText;
      let parentTokens = cacheMap.get(parent);
      if (parentTokens === undefined) {
        parentTokens = generateSelectorFor(cache, parent, { ...options, isRecursive: true, noText }) || cssFallback(parent, options);
        cacheMap.set(parent, parentTokens);
      }
      if (!parentTokens)
        continue;

      updateResult([...parentTokens, ...inParent]);
    }
  }
  return result;
}

function buildNoTextCandidates(cache, element, options) {
  const candidates = [];
  const testIdAttributeNames = splitTestIdAttributeNames(options.testIdAttributeName);

  // CSS selectors are applicable to elements via locator() and iframes via frameLocator().
  {
    for (const attr of ['data-testid', 'data-test-id', 'data-test']) {
      if (!testIdAttributeNames.includes(attr) && element.getAttribute(attr))
        candidates.push(cssToken('[' + attr + '=' + quoteCSSAttributeValue(element.getAttribute(attr)) + ']', kOtherTestIdScore));
    }

    const idAttr = element.getAttribute('id');
    if (idAttr && !isGuidLike(idAttr))
      candidates.push(cssToken(makeSelectorForId(idAttr), kCSSIdScore));

    candidates.push(cssToken(escapeNodeName(element), kCSSTagNameScore));
  }

  if (element.nodeName === 'IFRAME' || element.nodeName === 'FRAME') {
    for (const attribute of ['name', 'title']) {
      if (element.getAttribute(attribute))
        candidates.push(cssToken(escapeNodeName(element) + '[' + attribute + '=' + quoteCSSAttributeValue(element.getAttribute(attribute)) + ']', kIframeByAttributeScore));
    }

    // Locate by testId via CSS selector.
    for (const testIdAttr of testIdAttributeNames) {
      if (element.getAttribute(testIdAttr))
        candidates.push(cssToken('[' + testIdAttr + '=' + quoteCSSAttributeValue(element.getAttribute(testIdAttr)) + ']', kTestIdScore));
    }

    penalizeScoreForLength([candidates]);
    return candidates;
  }

  // Everything below is not applicable to iframes (getBy* methods).
  for (const testIdAttr of testIdAttributeNames) {
    if (element.getAttribute(testIdAttr))
      candidates.push(testIdToken(testIdAttr, element.getAttribute(testIdAttr), kTestIdScore));
  }

  if (element.nodeName === 'INPUT' || element.nodeName === 'TEXTAREA') {
    if (element.placeholder) {
      candidates.push(attrToken('placeholder', element.placeholder, true, kPlaceholderScoreExact));
      for (const alternative of suitableTextAlternatives(element.placeholder))
        candidates.push(attrToken('placeholder', alternative.text, false, kPlaceholderScore - alternative.scoreBonus));
    }
  }

  const labels = getElementLabels(cache.text, element, { skipRefsInsideElement: options.noText });
  for (const label of labels) {
    const labelText = label.normalized;
    candidates.push(labelToken(labelText, true, kLabelScoreExact));
    for (const alternative of suitableTextAlternatives(labelText))
      candidates.push(labelToken(alternative.text, false, kLabelScore - alternative.scoreBonus));
  }

  const ariaRole = getAriaRole(element);
  if (ariaRole && !['none', 'presentation'].includes(ariaRole))
    candidates.push(roleToken(ariaRole, undefined, false, undefined, false, kRoleWithoutNameScore));

  if (element.getAttribute('name') && ['BUTTON', 'FORM', 'FIELDSET', 'FRAME', 'IFRAME', 'INPUT', 'KEYGEN', 'OBJECT', 'OUTPUT', 'SELECT', 'TEXTAREA', 'MAP', 'META', 'PARAM'].includes(element.nodeName))
    candidates.push(cssToken(escapeNodeName(element) + '[name=' + quoteCSSAttributeValue(element.getAttribute('name')) + ']', kCSSInputTypeNameScore));

  if (['INPUT', 'TEXTAREA'].includes(element.nodeName) && element.getAttribute('type') !== 'hidden') {
    if (element.getAttribute('type'))
      candidates.push(cssToken(escapeNodeName(element) + '[type=' + quoteCSSAttributeValue(element.getAttribute('type')) + ']', kCSSInputTypeNameScore));
  }

  if (['INPUT', 'TEXTAREA', 'SELECT'].includes(element.nodeName) && element.getAttribute('type') !== 'hidden')
    candidates.push(cssToken(escapeNodeName(element), kCSSInputTypeNameScore + 1));

  penalizeScoreForLength([candidates]);
  return candidates;
}

function buildTextCandidates(cache, element, isTargetNode, options) {
  if (element.nodeName === 'SELECT')
    return [];
  const candidates = [];

  if (!options.noText) {
    const title = element.getAttribute('title');
    if (title) {
      candidates.push([attrToken('title', title, true, kTitleScoreExact)]);
      for (const alternative of suitableTextAlternatives(title))
        candidates.push([attrToken('title', alternative.text, false, kTitleScore - alternative.scoreBonus)]);
    }

    const alt = element.getAttribute('alt');
    if (alt && ['APPLET', 'AREA', 'IMG', 'INPUT'].includes(element.nodeName)) {
      candidates.push([attrToken('alt', alt, true, kAltTextScoreExact)]);
      for (const alternative of suitableTextAlternatives(alt))
        candidates.push([attrToken('alt', alternative.text, false, kAltTextScore - alternative.scoreBonus)]);
    }
  }

  const text = options.noText ? '' : elementText(cache.text, element).normalized;
  const textAlternatives = text ? suitableTextAlternatives(text) : [];
  if (text) {
    if (isTargetNode) {
      if (text.length <= 80)
        candidates.push([textToken(text, true, kTextScoreExact)]);
      for (const alternative of textAlternatives)
        candidates.push([textToken(alternative.text, false, kTextScore - alternative.scoreBonus)]);
    }
    for (const alternative of textAlternatives)
      candidates.push([cssToken(escapeNodeName(element), kCSSTagNameScore), hasTextToken(alternative.text, false, kTextScore - alternative.scoreBonus)]);
    if (isTargetNode && text.length <= 80) {
      // Do not use regex for parent elements (for performance).
      const re = new RegExp('^' + escapeRegExpForSelectorGenerator(text) + '$');
      candidates.push([cssToken(escapeNodeName(element), kCSSTagNameScore), hasTextToken(re, false, kTextScoreRegex)]);
    }
  }

  const ariaRole = getAriaRole(element);
  if (ariaRole && !['none', 'presentation'].includes(ariaRole)) {
    const accessibleName = getElementAccessibleNameComposite(element, false);
    const ariaName = options.noText && accessibleName.derivedFromContent ? '' : accessibleName.text;
    const accessibleDescription = getElementAccessibleDescriptionComposite(element, false);
    const ariaDescription = options.noText && accessibleDescription.derivedFromContent ? '' : accessibleDescription.text;
    // \p{Co} means "Private Use" characters - these are often used for icon
    // fonts and make for bad locators.
    if (ariaName && !ariaName.match(/^\p{Co}+$/u)) {
      candidates.push([roleToken(ariaRole, ariaName, true, undefined, false, kRoleWithNameScoreExact)]);
      for (const alternative of suitableTextAlternatives(ariaName))
        candidates.push([roleToken(ariaRole, alternative.text, false, undefined, false, kRoleWithNameScore - alternative.scoreBonus)]);
      if (ariaDescription) {
        candidates.push([roleToken(ariaRole, ariaName, true, ariaDescription, true, kRoleWithNameScoreExact + 1)]);
        for (const alternative of suitableTextAlternatives(ariaName))
          candidates.push([roleToken(ariaRole, alternative.text, false, ariaDescription, false, kRoleWithNameScore - alternative.scoreBonus + 1)]);
      }
    } else {
      if (ariaDescription)
        candidates.push([roleToken(ariaRole, undefined, false, ariaDescription, true, kRoleWithoutNameScore + 1)]);
      for (const alternative of textAlternatives)
        candidates.push([roleToken(ariaRole, undefined, false, undefined, false, kRoleWithoutNameScore), hasTextToken(alternative.text, false, kTextScore - alternative.scoreBonus)]);
      if (!options.noText && isTargetNode && text.length <= 80) {
        // Do not use regex for parent elements (for performance).
        const re = new RegExp('^' + escapeRegExpForSelectorGenerator(text) + '$');
        candidates.push([roleToken(ariaRole, undefined, false, undefined, false, kRoleWithoutNameScore), hasTextToken(re, false, kTextScoreRegex)]);
      }
    }
  }

  penalizeScoreForLength(candidates);
  return candidates;
}

function makeSelectorForId(id) {
  return /^[a-zA-Z][a-zA-Z0-9\-\_]+$/.test(id) ? '#' + id : '[id=' + quoteCSSAttributeValue(id) + ']';
}

function cssFallback(targetElement, options) {
  const root = options.root || targetElement.ownerDocument;
  const tokens = [];

  function uniqueCSSSelector(prefix) {
    const path = tokens.slice();
    if (prefix)
      path.unshift(prefix);
    const selector = path.join(' > ');
    const nodes = queryParts(root, [{ engine: 'css', body: selector }]);
    return nodes.length && nodes[0] === targetElement ? selector : undefined;
  }

  function makeStrict(selector) {
    const token = cssToken(selector, kCSSFallbackScore);
    const elements = queryParts(root, [token.part]);
    if (elements.length === 1)
      return [token];
    return [token, nthToken(elements.indexOf(targetElement))];
  }

  for (let element = targetElement; element && element !== root; element = parentElementOrShadowHost(element)) {
    let bestTokenForLevel = '';

    // Element ID is the strongest signal, use it.
    if (element.id) {
      const token = makeSelectorForId(element.id);
      const selector = uniqueCSSSelector(token);
      if (selector)
        return makeStrict(selector);
      bestTokenForLevel = token;
    }

    const parent = element.parentNode;

    // Combine class names until unique.
    const classes = [...element.classList].map(escapeClassName);
    for (let i = 0; i < classes.length; ++i) {
      const token = '.' + classes.slice(0, i + 1).join('.');
      const selector = uniqueCSSSelector(token);
      if (selector)
        return makeStrict(selector);
      // Even if not unique, does this subset of classes uniquely identify node as a child?
      if (!bestTokenForLevel && parent) {
        const sameClassSiblings = parent.querySelectorAll(token);
        if (sameClassSiblings.length === 1)
          bestTokenForLevel = token;
      }
    }

    // Ordinal is the weakest signal.
    if (parent) {
      const siblings = [...parent.children];
      const nodeName = element.nodeName;
      const sameTagSiblings = siblings.filter(sibling => sibling.nodeName === nodeName);
      const token = sameTagSiblings.indexOf(element) === 0 ? escapeNodeName(element) : escapeNodeName(element) + ':nth-child(' + (1 + siblings.indexOf(element)) + ')';
      const selector = uniqueCSSSelector(token);
      if (selector)
        return makeStrict(selector);
      if (!bestTokenForLevel)
        bestTokenForLevel = token;
    } else if (!bestTokenForLevel) {
      bestTokenForLevel = escapeNodeName(element);
    }
    tokens.unshift(bestTokenForLevel);
  }
  return makeStrict(uniqueCSSSelector());
}

function penalizeScoreForLength(groups) {
  for (const group of groups) {
    for (const token of group) {
      if (token.score > kBeginPenalizedScore && token.score < kEndPenalizedScore)
        token.score += Math.min(kTextScoreRange, (token.selector.length / 10) | 0);
    }
  }
}

function joinTokens(tokens) {
  const parts = [];
  let lastEngine = '';
  for (const { engine, selector } of tokens) {
    if (parts.length && (lastEngine !== 'css' || engine !== 'css' || selector.startsWith(':nth-match(')))
      parts.push('>>');
    lastEngine = engine;
    if (engine === 'css')
      parts.push(selector);
    else
      parts.push(engine + '=' + selector);
  }
  return parts.join(' ');
}

function combineScores(tokens) {
  let score = 0;
  for (let i = 0; i < tokens.length; i++)
    score += tokens[i].score * (tokens.length - i);
  return score;
}

function isGuidLike(id) {
  let lastCharacterType;
  let transitionCount = 0;
  for (let i = 0; i < id.length; ++i) {
    const c = id[i];
    let characterType;
    if (c === '-' || c === '_')
      continue;
    if (c >= 'a' && c <= 'z')
      characterType = 'lower';
    else if (c >= 'A' && c <= 'Z')
      characterType = 'upper';
    else if (c >= '0' && c <= '9')
      characterType = 'digit';
    else
      characterType = 'other';

    if (characterType === 'lower' && lastCharacterType === 'upper') {
      lastCharacterType = characterType;
      continue;
    }

    if (lastCharacterType && lastCharacterType !== characterType)
      ++transitionCount;
    lastCharacterType = characterType;
  }
  return transitionCount >= id.length / 4;
}

function trimWordBoundary(text, maxLength) {
  if (text.length <= maxLength)
    return text;
  text = text.substring(0, maxLength);
  // Find last word boundary in the text.
  const match = text.match(/^(.*)\b(.+?)$/);
  if (!match)
    return '';
  return match[1].trimEnd();
}

function suitableTextAlternatives(text) {
  let result = [];

  {
    const match = text.match(/^([\d.,]+)[^.,\w]/);
    const leadingNumberLength = match ? match[1].length : 0;
    if (leadingNumberLength) {
      const alt = trimWordBoundary(text.substring(leadingNumberLength).trimStart(), 80);
      result.push({ text: alt, scoreBonus: alt.length <= 30 ? 2 : 1 });
    }
  }

  {
    const match = text.match(/[^.,\w]([\d.,]+)$/);
    const trailingNumberLength = match ? match[1].length : 0;
    if (trailingNumberLength) {
      const alt = trimWordBoundary(text.substring(0, text.length - trailingNumberLength).trimEnd(), 80);
      result.push({ text: alt, scoreBonus: alt.length <= 30 ? 2 : 1 });
    }
  }

  if (text.length <= 30) {
    result.push({ text, scoreBonus: 0 });
  } else {
    result.push({ text: trimWordBoundary(text, 80), scoreBonus: 0 });
    result.push({ text: trimWordBoundary(text, 30), scoreBonus: 1 });
  }

  result = result.filter(r => r.text);
  if (!result.length)
    result.push({ text: text.substring(0, 80), scoreBonus: 0 });

  return result;
}

function escapeNodeName(node) {
  // We are escaping it for document.querySelectorAll, not for usage in CSS file.
  return node.nodeName.toLocaleLowerCase().replace(/[:\.]/g, char => '\\' + char);
}

function escapeClassName(className) {
  // We are escaping class names for document.querySelectorAll by following
  // CSS.escape() rules.
  let result = '';
  for (let i = 0; i < className.length; i++)
    result += cssEscapeCharacter(className, i);
  return result;
}

function cssEscapeCharacter(s, i) {
  // https://drafts.csswg.org/cssom/#serialize-an-identifier
  const c = s.charCodeAt(i);
  if (c === 0x0000)
    return '\uFFFD';
  if ((c >= 0x0001 && c <= 0x001f) ||
      (c >= 0x0030 && c <= 0x0039 && (i === 0 || (i === 1 && s.charCodeAt(0) === 0x002d))))
    return '\\' + c.toString(16) + ' ';
  if (i === 0 && c === 0x002d && s.length === 1)
    return '\\' + s.charAt(i);
  if (c >= 0x0080 || c === 0x002d || c === 0x005f || (c >= 0x0030 && c <= 0x0039) ||
      (c >= 0x0041 && c <= 0x005a) || (c >= 0x0061 && c <= 0x007a))
    return s.charAt(i);
  return '\\' + s.charAt(i);
}
''';

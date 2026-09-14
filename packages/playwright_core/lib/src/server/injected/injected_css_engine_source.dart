// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/{cssTokenizer,cssParser}.ts and
// packages/injected/src/{layoutSelectorUtils,selectorEvaluator}.ts

/// The CSS half of the injected script: tokenizer, parser and evaluator.
///
/// Split out of [kInjectedScriptSource] only for size; it is not a valid
/// script on its own, it is one fragment of the single IIFE assembled in
/// `injected_script_source.dart`. It depends on `kInjectedDomSource` for
/// `isElementVisible`, `parentElementOrShadowHost`, `normalizeWhiteSpace`,
/// `elementText`, `elementMatchesText` and `shouldSkipForTextMatching`.
library;

/// What makes `css=` understand Playwright's extensions and pierce open
/// shadow roots.
const String kInjectedCssEngineSource = r'''
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
''';

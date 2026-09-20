// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/cssParser.ts

import 'css_tokenizer.dart';

/// Thrown for anything the caller wrote wrong: a selector that does not
/// parse, or an extension used with the wrong arguments.
class InvalidSelectorError implements Exception {
  final String message;
  InvalidSelectorError(this.message);
  @override
  String toString() => message;
}

/// Whether [error] is an [InvalidSelectorError].
bool isInvalidSelectorError(Object error) => error is InvalidSelectorError;

/// `''`, `>`, `+`, `~`, or `>=`, which the text engine uses internally.
typedef ClauseCombinator = String;

/// One simple selector: the raw CSS text plus the Playwright extensions
/// found in it.
class CssSimpleSelector {
  /// The plain CSS part, or null when the selector is only extensions.
  final String? css;

  /// The Playwright extensions, such as `:has-text()` or `:visible`.
  final List<CssFunction> functions;

  CssSimpleSelector({this.css, required this.functions});
}

/// A Playwright CSS extension and its arguments.
class CssFunction {
  final String name;

  /// Each argument is a [CssComplexSelector], a [num] or a [String].
  final List<Object> args;

  CssFunction(this.name, this.args);
}

/// A chain of simple selectors joined by combinators.
class CssComplexSelector {
  final List<({CssSimpleSelector selector, ClauseCombinator combinator})>
      simples;
  CssComplexSelector(this.simples);
}

/// The result of [parseCss]: the comma separated selector list, plus the
/// names of the Playwright extensions it uses.
class ParsedCss {
  final List<CssComplexSelector> selector;
  final List<String> names;
  ParsedCss(this.selector, this.names);
}

/// Parses [selector] as CSS, treating the names in [customNames] as
/// Playwright extensions rather than plain pseudo-classes.
///
/// Throws [InvalidSelectorError] for anything that is not a selector. That is
/// the whole point of calling it from `parseSelector`: it is what tells a
/// selector apart from, say, a locator expression that a human typed.
ParsedCss parseCss(String selector, Set<String> customNames) =>
    _CssParser(selector, customNames).parse();

class _CssParser {
  final String _selector;
  final Set<String> _customNames;
  late final List<CssToken> _tokens;
  int _pos = 0;
  final Set<String> _names = <String>{};

  _CssParser(this._selector, this._customNames);

  ParsedCss parse() {
    try {
      _tokens = tokenizeCss(_selector);
    } on InvalidCharacterError catch (e) {
      throw InvalidSelectorError(
          '${e.message} while parsing css selector "$_selector". '
          'Did you mean to CSS.escape it?');
    }
    if (_tokens.isEmpty || _tokens.last.type != CssTokenType.eof) {
      _tokens.add(const CssToken(CssTokenType.eof));
    }

    for (final token in _tokens) {
      switch (token.type) {
        case CssTokenType.atKeyword:
        case CssTokenType.badString:
        case CssTokenType.badUrl:
        case CssTokenType.column:
        case CssTokenType.cdo:
        case CssTokenType.cdc:
        case CssTokenType.semicolon:
        case CssTokenType.openCurly:
        case CssTokenType.closeCurly:
        case CssTokenType.url:
        case CssTokenType.percentage:
          throw InvalidSelectorError(
              'Unsupported token "${token.toSource()}" while parsing css '
              'selector "$_selector". Did you mean to CSS.escape it?');
        default:
          break;
      }
    }

    final result = _consumeFunctionArguments();
    if (!_isEOF()) throw _unexpected();
    for (final arg in result) {
      if (arg is! CssComplexSelector) {
        throw InvalidSelectorError(
            'Error while parsing css selector "$_selector". '
            'Did you mean to CSS.escape it?');
      }
    }
    return ParsedCss(result.cast<CssComplexSelector>(), _names.toList());
  }

  InvalidSelectorError _unexpected() => InvalidSelectorError(
      'Unexpected token "${_tokens[_pos].toSource()}" while parsing css '
      'selector "$_selector". Did you mean to CSS.escape it?');

  void _skipWhitespace() {
    while (_tokens[_pos].type == CssTokenType.whitespace) {
      _pos++;
    }
  }

  bool _isIdent([int? p]) => _tokens[p ?? _pos].type == CssTokenType.ident;
  bool _isString([int? p]) => _tokens[p ?? _pos].type == CssTokenType.string;
  bool _isNumber([int? p]) => _tokens[p ?? _pos].type == CssTokenType.number;
  bool _isComma([int? p]) => _tokens[p ?? _pos].type == CssTokenType.comma;
  bool _isCloseParen([int? p]) =>
      _tokens[p ?? _pos].type == CssTokenType.closeParen;
  bool _isOpenParen([int? p]) =>
      _tokens[p ?? _pos].type == CssTokenType.openParen;
  bool _isFunction([int? p]) =>
      _tokens[p ?? _pos].type == CssTokenType.function;
  bool _isStar([int? p]) {
    final token = _tokens[p ?? _pos];
    return token.type == CssTokenType.delim && token.value == '*';
  }

  bool _isEOF([int? p]) => _tokens[p ?? _pos].type == CssTokenType.eof;

  bool _isClauseCombinator([int? p]) {
    final token = _tokens[p ?? _pos];
    return token.type == CssTokenType.delim &&
        const ['>', '+', '~'].contains(token.value);
  }

  bool _isSelectorClauseEnd([int? p]) {
    final index = p ?? _pos;
    return _isComma(index) ||
        _isCloseParen(index) ||
        _isEOF(index) ||
        _isClauseCombinator(index) ||
        _tokens[index].type == CssTokenType.whitespace;
  }

  List<Object> _consumeFunctionArguments() {
    final result = <Object>[_consumeArgument()];
    while (true) {
      _skipWhitespace();
      if (!_isComma()) break;
      _pos++;
      result.add(_consumeArgument());
    }
    return result;
  }

  Object _consumeArgument() {
    _skipWhitespace();
    if (_isNumber()) return _tokens[_pos++].numericValue!;
    if (_isString()) return _tokens[_pos++].value!;
    return _consumeComplexSelector();
  }

  CssComplexSelector _consumeComplexSelector() {
    final simples =
        <({CssSimpleSelector selector, ClauseCombinator combinator})>[];
    _skipWhitespace();
    if (_isClauseCombinator()) {
      // Put an implicit ":scope" at the start.
      // https://drafts.csswg.org/selectors-4/#relative
      simples.add((
        selector: CssSimpleSelector(functions: [CssFunction('scope', [])]),
        combinator: ''
      ));
    } else {
      simples.add((selector: _consumeSimpleSelector(), combinator: ''));
    }
    while (true) {
      _skipWhitespace();
      if (_isClauseCombinator()) {
        final last = simples.removeLast();
        simples.add((
          selector: last.selector,
          combinator: _tokens[_pos++].value as ClauseCombinator
        ));
        _skipWhitespace();
      } else if (_isSelectorClauseEnd()) {
        break;
      }
      simples.add((selector: _consumeSimpleSelector(), combinator: ''));
    }
    return CssComplexSelector(simples);
  }

  CssSimpleSelector _consumeSimpleSelector() {
    final rawCSSString = StringBuffer();
    final functions = <CssFunction>[];

    while (!_isSelectorClauseEnd()) {
      final token = _tokens[_pos];
      if (_isIdent() || _isStar()) {
        rawCSSString.write(_tokens[_pos++].toSource());
      } else if (token.type == CssTokenType.hash) {
        rawCSSString.write(_tokens[_pos++].toSource());
      } else if (token.type == CssTokenType.delim && token.value == '.') {
        _pos++;
        if (_isIdent()) {
          rawCSSString.write('.${_tokens[_pos++].toSource()}');
        } else {
          throw _unexpected();
        }
      } else if (token.type == CssTokenType.colon) {
        _pos++;
        if (_isIdent()) {
          final name = _tokens[_pos].value!.toLowerCase();
          if (!_customNames.contains(name)) {
            rawCSSString.write(':${_tokens[_pos++].toSource()}');
          } else {
            _pos++;
            functions.add(CssFunction(name, []));
            _names.add(name);
          }
        } else if (_isFunction()) {
          final name = _tokens[_pos++].value!.toLowerCase();
          if (!_customNames.contains(name)) {
            rawCSSString.write(':$name(${_consumeBuiltinFunctionArguments()})');
          } else {
            functions.add(CssFunction(name, _consumeFunctionArguments()));
            _names.add(name);
          }
          _skipWhitespace();
          if (!_isCloseParen()) throw _unexpected();
          _pos++;
        } else {
          throw _unexpected();
        }
      } else if (token.type == CssTokenType.openSquare) {
        rawCSSString.write('[');
        _pos++;
        while (_tokens[_pos].type != CssTokenType.closeSquare && !_isEOF()) {
          rawCSSString.write(_tokens[_pos++].toSource());
        }
        if (_tokens[_pos].type != CssTokenType.closeSquare) {
          throw _unexpected();
        }
        rawCSSString.write(']');
        _pos++;
      } else {
        throw _unexpected();
      }
    }
    final css = rawCSSString.toString();
    if (css.isEmpty && functions.isEmpty) throw _unexpected();
    return CssSimpleSelector(
        css: css.isEmpty ? null : css, functions: functions);
  }

  String _consumeBuiltinFunctionArguments() {
    final s = StringBuffer();
    var balance = 1; // The first open paren is part of the function token.
    while (!_isEOF()) {
      if (_isOpenParen() || _isFunction()) balance++;
      if (_isCloseParen()) balance--;
      if (balance == 0) break;
      s.write(_tokens[_pos++].toSource());
    }
    return s.toString();
  }
}

/// Renders parsed arguments back to a CSS-ish string, as upstream's
/// `serializeSelector` does.
String serializeCssSelector(List<Object> args) => args.map((arg) {
      if (arg is String) return '"$arg"';
      if (arg is num) return '$arg';
      final complex = arg as CssComplexSelector;
      return complex.simples.map((entry) {
        var s = entry.selector.css ?? '';
        s += entry.selector.functions
            .map((func) => ':${func.name}(${serializeCssSelector(func.args)})')
            .join('');
        if (entry.combinator.isNotEmpty) s += ' ${entry.combinator}';
        return s;
      }).join(' ');
    }).join(', ');

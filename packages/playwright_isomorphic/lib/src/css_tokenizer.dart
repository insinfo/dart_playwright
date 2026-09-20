// The code in this file is licensed under the CC0 license.
// http://creativecommons.org/publicdomain/zero/1.0/
//
// Original at https://github.com/tabatkins/parse-css, by way of Playwright's
// packages/isomorphic/cssTokenizer.ts.
//
// Changes from upstream:
//   - TypeScript is replaced with Dart.
//   - The class hierarchy of tokens collapses into one [CssToken] carrying a
//     [CssTokenType]; `toSource()` becomes [CssToken.toSource].
//   - Line and column tracking is dropped: upstream only fed it to a parse
//     error log that is a no-op.

/// The token kinds the CSS tokenizer produces.
enum CssTokenType {
  whitespace,
  ident,
  function,
  atKeyword,
  hash,
  string,
  badString,
  url,
  badUrl,
  delim,
  number,
  percentage,
  dimension,
  includeMatch,
  dashMatch,
  prefixMatch,
  suffixMatch,
  substringMatch,
  column,
  colon,
  semicolon,
  comma,
  openSquare,
  closeSquare,
  openParen,
  closeParen,
  openCurly,
  closeCurly,
  cdo,
  cdc,
  eof,
}

/// One CSS token.
///
/// Upstream has a class per kind; here the kind is [type] and the payload
/// fields are nullable, which keeps the tokenizer a straight transcription
/// without thirty tiny classes.
class CssToken {
  final CssTokenType type;

  /// The text of an ident, function, at-keyword, hash, string or url token,
  /// or the single character of a delim token. Null for punctuation.
  final String? value;

  /// The numeric value of a number, percentage or dimension token.
  final num? numericValue;

  /// The number exactly as it was written, which is what [toSource] prints.
  final String? repr;

  /// `integer` or `number`, for number and dimension tokens.
  final String? numberType;

  /// The unit of a dimension token.
  final String? unit;

  /// `id` or `unrestricted`, for a hash token.
  final String? hashType;

  const CssToken(
    this.type, {
    this.value,
    this.numericValue,
    this.repr,
    this.numberType,
    this.unit,
    this.hashType,
  });

  /// Renders the token back to CSS source, as upstream's `toSource()` does.
  String toSource() {
    switch (type) {
      case CssTokenType.whitespace:
        return ' ';
      case CssTokenType.cdo:
        return '<!--';
      case CssTokenType.cdc:
        return '-->';
      case CssTokenType.eof:
        return '';
      case CssTokenType.delim:
        return value == '\\' ? '\\\n' : value!;
      case CssTokenType.ident:
        return _escapeIdent(value!);
      case CssTokenType.function:
        return '${_escapeIdent(value!)}(';
      case CssTokenType.atKeyword:
        return '@${_escapeIdent(value!)}';
      case CssTokenType.hash:
        return hashType == 'id'
            ? '#${_escapeIdent(value!)}'
            : '#${_escapeHash(value!)}';
      case CssTokenType.string:
        return '"${_escapeString(value!)}"';
      case CssTokenType.url:
        return 'url("${_escapeString(value!)}")';
      case CssTokenType.number:
        return repr!;
      case CssTokenType.percentage:
        return '$repr%';
      case CssTokenType.dimension:
        var unitSource = _escapeIdent(unit!);
        if (unitSource.isNotEmpty &&
            unitSource[0].toLowerCase() == 'e' &&
            unitSource.length > 1 &&
            (unitSource[1] == '-' ||
                _between(unitSource.codeUnitAt(1), 0x30, 0x39))) {
          unitSource = '\\65 ${unitSource.substring(1)}';
        }
        return '$repr$unitSource';
      case CssTokenType.badString:
        return 'BADSTRING';
      case CssTokenType.badUrl:
        return 'BADURL';
      case CssTokenType.includeMatch:
        return '~=';
      case CssTokenType.dashMatch:
        return '|=';
      case CssTokenType.prefixMatch:
        return '^=';
      case CssTokenType.suffixMatch:
        return r'$=';
      case CssTokenType.substringMatch:
        return '*=';
      case CssTokenType.column:
        return '||';
      case CssTokenType.colon:
        return ':';
      case CssTokenType.semicolon:
        return ';';
      case CssTokenType.comma:
        return ',';
      case CssTokenType.openSquare:
        return '[';
      case CssTokenType.closeSquare:
        return ']';
      case CssTokenType.openParen:
        return '(';
      case CssTokenType.closeParen:
        return ')';
      case CssTokenType.openCurly:
        return '{';
      case CssTokenType.closeCurly:
        return '}';
    }
  }

  @override
  String toString() => '$type(${value ?? ''})';
}

bool _between(int code, int first, int last) => code >= first && code <= last;
bool _digit(int code) => _between(code, 0x30, 0x39);
bool _hexDigit(int code) =>
    _digit(code) || _between(code, 0x41, 0x46) || _between(code, 0x61, 0x66);
bool _letter(int code) =>
    _between(code, 0x41, 0x5a) || _between(code, 0x61, 0x7a);
bool _nameStartChar(int code) => _letter(code) || code >= 0x80 || code == 0x5f;
bool _nameChar(int code) =>
    _nameStartChar(code) || _digit(code) || code == 0x2d;
bool _nonPrintable(int code) =>
    _between(code, 0, 8) ||
    code == 0xb ||
    _between(code, 0xe, 0x1f) ||
    code == 0x7f;
bool _newline(int code) => code == 0xa;
bool _whitespace(int code) => _newline(code) || code == 9 || code == 0x20;

const int _maximumAllowedCodepoint = 0x10ffff;

/// Thrown when the tokenizer meets something it cannot turn into a token.
class InvalidCharacterError implements Exception {
  final String message;
  InvalidCharacterError(this.message);
  @override
  String toString() => 'InvalidCharacterError: $message';
}

String _escapeIdent(String string) {
  final result = StringBuffer();
  final firstCode = string.isEmpty ? -1 : string.codeUnitAt(0);
  for (var i = 0; i < string.length; i++) {
    final code = string.codeUnitAt(i);
    if (code == 0x0) {
      throw InvalidCharacterError(
          'Invalid character: the input contains U+0000.');
    }
    if (_between(code, 0x1, 0x1f) ||
        code == 0x7f ||
        (i == 0 && _between(code, 0x30, 0x39)) ||
        (i == 1 && _between(code, 0x30, 0x39) && firstCode == 0x2d)) {
      result.write('\\${code.toRadixString(16)} ');
    } else if (code >= 0x80 ||
        code == 0x2d ||
        code == 0x5f ||
        _digit(code) ||
        _letter(code)) {
      result.write(string[i]);
    } else {
      result.write('\\${string[i]}');
    }
  }
  return result.toString();
}

String _escapeHash(String string) {
  final result = StringBuffer();
  for (var i = 0; i < string.length; i++) {
    final code = string.codeUnitAt(i);
    if (code == 0x0) {
      throw InvalidCharacterError(
          'Invalid character: the input contains U+0000.');
    }
    if (code >= 0x80 ||
        code == 0x2d ||
        code == 0x5f ||
        _digit(code) ||
        _letter(code)) {
      result.write(string[i]);
    } else {
      result.write('\\${code.toRadixString(16)} ');
    }
  }
  return result.toString();
}

String _escapeString(String string) {
  final result = StringBuffer();
  for (var i = 0; i < string.length; i++) {
    final code = string.codeUnitAt(i);
    if (code == 0x0) {
      throw InvalidCharacterError(
          'Invalid character: the input contains U+0000.');
    }
    if (_between(code, 0x1, 0x1f) || code == 0x7f) {
      result.write('\\${code.toRadixString(16)} ');
    } else if (code == 0x22 || code == 0x5c) {
      result.write('\\${string[i]}');
    } else {
      result.write(string[i]);
    }
  }
  return result.toString();
}

List<int> _preprocess(String str) {
  final codepoints = <int>[];
  for (var i = 0; i < str.length; i++) {
    var code = str.codeUnitAt(i);
    if (code == 0xd && i + 1 < str.length && str.codeUnitAt(i + 1) == 0xa) {
      code = 0xa;
      i++;
    }
    if (code == 0xd || code == 0xc) code = 0xa;
    if (code == 0x0) code = 0xfffd;
    if (_between(code, 0xd800, 0xdbff) &&
        i + 1 < str.length &&
        _between(str.codeUnitAt(i + 1), 0xdc00, 0xdfff)) {
      // Decode a surrogate pair into an astral codepoint.
      final lead = code - 0xd800;
      final trail = str.codeUnitAt(i + 1) - 0xdc00;
      code = 0x10000 + lead * 0x400 + trail;
      i++;
    }
    codepoints.add(code);
  }
  return codepoints;
}

String _stringFromCode(int code) {
  if (code <= 0xffff) return String.fromCharCode(code);
  final astral = code - 0x10000;
  final lead = (astral ~/ 0x400) + 0xd800;
  final trail = astral % 0x400 + 0xdc00;
  return String.fromCharCode(lead) + String.fromCharCode(trail);
}

class _NumberResult {
  final String type;
  final num value;
  final String repr;
  _NumberResult(this.type, this.value, this.repr);
}

/// Splits [input] into CSS tokens.
///
/// The returned list has no trailing EOF token; [parseCss] appends one.
List<CssToken> tokenizeCss(String input) => _Tokenizer(input).run();

class _Tokenizer {
  final List<int> _str;
  int _i = -1;
  int _code = -1;

  _Tokenizer(String input) : _str = _preprocess(input);

  List<CssToken> run() {
    final tokens = <CssToken>[];
    var iterationCount = 0;
    while (!_eof(_next())) {
      tokens.add(_consumeAToken());
      iterationCount++;
      if (iterationCount > _str.length * 2) {
        throw InvalidCharacterError("I'm infinite-looping!");
      }
    }
    return tokens;
  }

  int _codepoint(int index) =>
      index >= _str.length || index < 0 ? -1 : _str[index];

  int _next([int offset = 1]) {
    if (offset > 3) {
      throw InvalidCharacterError(
          'Spec Error: no more than three codepoints of lookahead.');
    }
    return _codepoint(_i + offset);
  }

  bool _consume([int count = 1]) {
    _i += count;
    _code = _codepoint(_i);
    return true;
  }

  bool _reconsume() {
    _i -= 1;
    return true;
  }

  bool _eof([int? cp]) => (cp ?? _code) == -1;

  CssToken _delim(int c) =>
      CssToken(CssTokenType.delim, value: _stringFromCode(c));

  CssToken _consumeAToken() {
    _consumeComments();
    _consume();
    final code = _code;
    if (_whitespace(code)) {
      while (_whitespace(_next())) {
        _consume();
      }
      return const CssToken(CssTokenType.whitespace);
    } else if (code == 0x22) {
      return _consumeAStringToken();
    } else if (code == 0x23) {
      if (_nameChar(_next()) || _areAValidEscape(_next(1), _next(2))) {
        final hashType = _wouldStartAnIdentifier(_next(1), _next(2), _next(3))
            ? 'id'
            : 'unrestricted';
        return CssToken(CssTokenType.hash,
            value: _consumeAName(), hashType: hashType);
      }
      return _delim(code);
    } else if (code == 0x24) {
      if (_next() == 0x3d) {
        _consume();
        return const CssToken(CssTokenType.suffixMatch);
      }
      return _delim(code);
    } else if (code == 0x27) {
      return _consumeAStringToken();
    } else if (code == 0x28) {
      return const CssToken(CssTokenType.openParen, value: '(');
    } else if (code == 0x29) {
      return const CssToken(CssTokenType.closeParen, value: ')');
    } else if (code == 0x2a) {
      if (_next() == 0x3d) {
        _consume();
        return const CssToken(CssTokenType.substringMatch);
      }
      return _delim(code);
    } else if (code == 0x2b) {
      if (_startsWithANumber()) {
        _reconsume();
        return _consumeANumericToken();
      }
      return _delim(code);
    } else if (code == 0x2c) {
      return const CssToken(CssTokenType.comma);
    } else if (code == 0x2d) {
      if (_startsWithANumber()) {
        _reconsume();
        return _consumeANumericToken();
      } else if (_next(1) == 0x2d && _next(2) == 0x3e) {
        _consume(2);
        return const CssToken(CssTokenType.cdc);
      } else if (_startsWithAnIdentifier()) {
        _reconsume();
        return _consumeAnIdentlikeToken();
      }
      return _delim(code);
    } else if (code == 0x2e) {
      if (_startsWithANumber()) {
        _reconsume();
        return _consumeANumericToken();
      }
      return _delim(code);
    } else if (code == 0x3a) {
      return const CssToken(CssTokenType.colon);
    } else if (code == 0x3b) {
      return const CssToken(CssTokenType.semicolon);
    } else if (code == 0x3c) {
      if (_next(1) == 0x21 && _next(2) == 0x2d && _next(3) == 0x2d) {
        _consume(3);
        return const CssToken(CssTokenType.cdo);
      }
      return _delim(code);
    } else if (code == 0x40) {
      if (_wouldStartAnIdentifier(_next(1), _next(2), _next(3))) {
        return CssToken(CssTokenType.atKeyword, value: _consumeAName());
      }
      return _delim(code);
    } else if (code == 0x5b) {
      return const CssToken(CssTokenType.openSquare, value: '[');
    } else if (code == 0x5c) {
      if (_startsWithAValidEscape()) {
        _reconsume();
        return _consumeAnIdentlikeToken();
      }
      return _delim(code);
    } else if (code == 0x5d) {
      return const CssToken(CssTokenType.closeSquare, value: ']');
    } else if (code == 0x5e) {
      if (_next() == 0x3d) {
        _consume();
        return const CssToken(CssTokenType.prefixMatch);
      }
      return _delim(code);
    } else if (code == 0x7b) {
      return const CssToken(CssTokenType.openCurly, value: '{');
    } else if (code == 0x7c) {
      if (_next() == 0x3d) {
        _consume();
        return const CssToken(CssTokenType.dashMatch);
      } else if (_next() == 0x7c) {
        _consume();
        return const CssToken(CssTokenType.column);
      }
      return _delim(code);
    } else if (code == 0x7d) {
      return const CssToken(CssTokenType.closeCurly, value: '}');
    } else if (code == 0x7e) {
      if (_next() == 0x3d) {
        _consume();
        return const CssToken(CssTokenType.includeMatch);
      }
      return _delim(code);
    } else if (_digit(code)) {
      _reconsume();
      return _consumeANumericToken();
    } else if (_nameStartChar(code)) {
      _reconsume();
      return _consumeAnIdentlikeToken();
    } else if (_eof()) {
      return const CssToken(CssTokenType.eof);
    }
    return _delim(code);
  }

  void _consumeComments() {
    while (_next(1) == 0x2f && _next(2) == 0x2a) {
      _consume(2);
      while (true) {
        _consume();
        if (_code == 0x2a && _next() == 0x2f) {
          _consume();
          break;
        } else if (_eof()) {
          return;
        }
      }
    }
  }

  CssToken _consumeANumericToken() {
    final parsed = _consumeANumber();
    if (_wouldStartAnIdentifier(_next(1), _next(2), _next(3))) {
      return CssToken(CssTokenType.dimension,
          numericValue: parsed.value,
          repr: parsed.repr,
          numberType: parsed.type,
          unit: _consumeAName());
    } else if (_next() == 0x25) {
      _consume();
      return CssToken(CssTokenType.percentage,
          numericValue: parsed.value, repr: parsed.repr);
    }
    return CssToken(CssTokenType.number,
        numericValue: parsed.value, repr: parsed.repr, numberType: parsed.type);
  }

  CssToken _consumeAnIdentlikeToken() {
    final name = _consumeAName();
    if (name.toLowerCase() == 'url' && _next() == 0x28) {
      _consume();
      while (_whitespace(_next(1)) && _whitespace(_next(2))) {
        _consume();
      }
      if (_next() == 0x22 || _next() == 0x27) {
        return CssToken(CssTokenType.function, value: name);
      } else if (_whitespace(_next()) &&
          (_next(2) == 0x22 || _next(2) == 0x27)) {
        return CssToken(CssTokenType.function, value: name);
      }
      return _consumeAURLToken();
    } else if (_next() == 0x28) {
      _consume();
      return CssToken(CssTokenType.function, value: name);
    }
    return CssToken(CssTokenType.ident, value: name);
  }

  CssToken _consumeAStringToken([int? endingCodePoint]) {
    final ending = endingCodePoint ?? _code;
    final string = StringBuffer();
    while (_consume()) {
      if (_code == ending || _eof()) {
        return CssToken(CssTokenType.string, value: string.toString());
      }
      if (_newline(_code)) {
        _reconsume();
        return const CssToken(CssTokenType.badString);
      }
      if (_code == 0x5c) {
        if (_eof(_next())) {
          // Do nothing.
        } else if (_newline(_next())) {
          _consume();
        } else {
          string.write(_stringFromCode(_consumeEscape()));
        }
      } else {
        string.write(_stringFromCode(_code));
      }
    }
    throw InvalidCharacterError('Internal error');
  }

  CssToken _consumeAURLToken() {
    final value = StringBuffer();
    while (_whitespace(_next())) {
      _consume();
    }
    if (_eof(_next())) {
      return CssToken(CssTokenType.url, value: value.toString());
    }
    while (_consume()) {
      if (_code == 0x29 || _eof()) {
        return CssToken(CssTokenType.url, value: value.toString());
      } else if (_whitespace(_code)) {
        while (_whitespace(_next())) {
          _consume();
        }
        if (_next() == 0x29 || _eof(_next())) {
          _consume();
          return CssToken(CssTokenType.url, value: value.toString());
        }
        _consumeTheRemnantsOfABadURL();
        return const CssToken(CssTokenType.badUrl);
      } else if (_code == 0x22 ||
          _code == 0x27 ||
          _code == 0x28 ||
          _nonPrintable(_code)) {
        _consumeTheRemnantsOfABadURL();
        return const CssToken(CssTokenType.badUrl);
      } else if (_code == 0x5c) {
        if (_startsWithAValidEscape()) {
          value.write(_stringFromCode(_consumeEscape()));
        } else {
          _consumeTheRemnantsOfABadURL();
          return const CssToken(CssTokenType.badUrl);
        }
      } else {
        value.write(_stringFromCode(_code));
      }
    }
    throw InvalidCharacterError('Internal error');
  }

  int _consumeEscape() {
    _consume();
    if (_hexDigit(_code)) {
      final digits = <int>[_code];
      for (var total = 0; total < 5; total++) {
        if (_hexDigit(_next())) {
          _consume();
          digits.add(_code);
        } else {
          break;
        }
      }
      if (_whitespace(_next())) _consume();
      var value = int.parse(String.fromCharCodes(digits), radix: 16);
      if (value > _maximumAllowedCodepoint) value = 0xfffd;
      return value;
    } else if (_eof()) {
      return 0xfffd;
    }
    return _code;
  }

  bool _areAValidEscape(int c1, int c2) {
    if (c1 != 0x5c) return false;
    if (_newline(c2)) return false;
    return true;
  }

  bool _startsWithAValidEscape() => _areAValidEscape(_code, _next());

  bool _wouldStartAnIdentifier(int c1, int c2, int c3) {
    if (c1 == 0x2d) {
      return _nameStartChar(c2) || c2 == 0x2d || _areAValidEscape(c2, c3);
    } else if (_nameStartChar(c1)) {
      return true;
    } else if (c1 == 0x5c) {
      return _areAValidEscape(c1, c2);
    }
    return false;
  }

  bool _startsWithAnIdentifier() =>
      _wouldStartAnIdentifier(_code, _next(1), _next(2));

  bool _wouldStartANumber(int c1, int c2, int c3) {
    if (c1 == 0x2b || c1 == 0x2d) {
      if (_digit(c2)) return true;
      if (c2 == 0x2e && _digit(c3)) return true;
      return false;
    } else if (c1 == 0x2e) {
      return _digit(c2);
    }
    return _digit(c1);
  }

  bool _startsWithANumber() => _wouldStartANumber(_code, _next(1), _next(2));

  String _consumeAName() {
    final result = StringBuffer();
    while (_consume()) {
      if (_nameChar(_code)) {
        result.write(_stringFromCode(_code));
      } else if (_startsWithAValidEscape()) {
        result.write(_stringFromCode(_consumeEscape()));
      } else {
        _reconsume();
        return result.toString();
      }
    }
    throw InvalidCharacterError('Internal parse error');
  }

  _NumberResult _consumeANumber() {
    final repr = StringBuffer();
    var type = 'integer';
    if (_next() == 0x2b || _next() == 0x2d) {
      _consume();
      repr.write(_stringFromCode(_code));
    }
    while (_digit(_next())) {
      _consume();
      repr.write(_stringFromCode(_code));
    }
    if (_next(1) == 0x2e && _digit(_next(2))) {
      _consume();
      repr.write(_stringFromCode(_code));
      _consume();
      repr.write(_stringFromCode(_code));
      type = 'number';
      while (_digit(_next())) {
        _consume();
        repr.write(_stringFromCode(_code));
      }
    }
    final c1 = _next(1);
    final c2 = _next(2);
    final c3 = _next(3);
    if ((c1 == 0x45 || c1 == 0x65) && _digit(c2)) {
      _consume();
      repr.write(_stringFromCode(_code));
      _consume();
      repr.write(_stringFromCode(_code));
      type = 'number';
      while (_digit(_next())) {
        _consume();
        repr.write(_stringFromCode(_code));
      }
    } else if ((c1 == 0x45 || c1 == 0x65) &&
        (c2 == 0x2b || c2 == 0x2d) &&
        _digit(c3)) {
      _consume();
      repr.write(_stringFromCode(_code));
      _consume();
      repr.write(_stringFromCode(_code));
      _consume();
      repr.write(_stringFromCode(_code));
      type = 'number';
      while (_digit(_next())) {
        _consume();
        repr.write(_stringFromCode(_code));
      }
    }
    final text = repr.toString();
    return _NumberResult(type, num.tryParse(text) ?? double.nan, text);
  }

  void _consumeTheRemnantsOfABadURL() {
    while (_consume()) {
      if (_code == 0x29 || _eof()) {
        return;
      } else if (_startsWithAValidEscape()) {
        _consumeEscape();
      }
    }
  }
}

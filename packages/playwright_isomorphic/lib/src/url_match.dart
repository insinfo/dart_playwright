// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/urlMatch.ts

/// URL matching for `route`, `unroute`, `waitForURL` and the HAR `urlFilter`.
///
/// This is a hand port of upstream's `packages/isomorphic/urlMatch.ts`. The
/// glob dialect is not the shell's: `*` stops at `/`, `**` crosses it, `?` is
/// a single character, `{a,b}` is an alternation, `[]` is *not* a range, and a
/// backslash escapes the next character. A glob that is not anchored with a
/// leading `*` is first resolved through a URL parse, which is what makes
/// `http://example.com:80/x` match a request whose URL reads
/// `http://example.com/x`.
///
/// Two deliberate differences from upstream, both forced by `dart:core`'s
/// [Uri] where upstream leans on the browser's `URL`:
///
/// * **No punycode.** `new URL('http://münchen.de/')` yields
///   `http://xn--mnchen-3ya.de/`, so upstream's glob matches a request URL
///   that the engine already reported in its ASCII form. [Uri] percent-encodes
///   the host instead (`http://m%C3%BCnchen.de/`), so an IDN host written in
///   Unicode in the glob does not match. Write the host in its `xn--` form, or
///   use a [RegExp]. There is a test that pins this divergence down.
/// * **`URLPattern` is not a match type.** Upstream additionally accepts a
///   `URLPattern` object, which is a browser/Node 24 global with no `dart:core`
///   equivalent. A [RegExp] or a predicate covers the same ground here.
library;

/// Characters that have to be backslash-escaped to become literal in a regular
/// expression. Upstream's `escapedChars`.
const _escapedChars = <String>{
  r'$',
  '^',
  '+',
  '.',
  '*',
  '(',
  ')',
  '|',
  r'\',
  '?',
  '{',
  '}',
  '[',
  ']',
};

/// Schemes for which `new URL()` forces a non-empty path and reports a real
/// `origin`. `Uri` does neither, so the two lists below restore it.
const _specialSchemes = <String>{'http', 'https', 'ws', 'wss', 'ftp', 'file'};

/// Schemes for which JavaScript's `URL.origin` is not the string `'null'`.
/// Upstream compares against `url.origin` to decide whether a glob token sits
/// in the case-insensitive part of the URL.
const _schemesWithOrigin = <String>{'http', 'https', 'ws', 'wss', 'ftp'};

/// Whether [url] is an `http:`/`https:` URL, resolving against [base].
bool isHttpUrl(String url, {String? base}) {
  try {
    final resolved =
        base == null ? Uri.parse(url) : Uri.parse(base).resolve(url);
    return resolved.scheme == 'http' || resolved.scheme == 'https';
  } catch (_) {
    return false;
  }
}

/// Translates a Playwright glob into an anchored regular expression source.
///
/// Port of upstream's `globToRegexPattern`. Throws [FormatException] on
/// unbalanced or nested `{}`, the same two errors upstream raises.
String globToRegexPattern(String glob) {
  final tokens = <String>['^'];
  var inGroup = false;
  for (var i = 0; i < glob.length; ++i) {
    final c = glob[i];
    if (c == r'\' && i + 1 < glob.length) {
      final char = glob[++i];
      tokens.add(_escapedChars.contains(char) ? '\\$char' : char);
      continue;
    }
    if (c == '*') {
      final charBefore = i > 0 ? glob[i - 1] : null;
      var starCount = 1;
      while (i + 1 < glob.length && glob[i + 1] == '*') {
        starCount++;
        i++;
      }
      if (starCount > 1) {
        final charAfter = i + 1 < glob.length ? glob[i + 1] : null;
        // Match either /..something../ or /.
        if (charAfter == '/') {
          if (charBefore == '/') {
            tokens.add('((.+/)|)');
          } else {
            tokens.add('(.*/)');
          }
          ++i;
        } else {
          tokens.add('(.*)');
        }
      } else {
        tokens.add('([^/]*)');
      }
      continue;
    }

    switch (c) {
      case '{':
        if (inGroup) {
          throw FormatException(
              'Invalid glob pattern "$glob": nested \'{\' is not supported');
        }
        inGroup = true;
        tokens.add('(');
      case '}':
        if (!inGroup) {
          throw FormatException(
              'Invalid glob pattern "$glob": unmatched \'}\'');
        }
        inGroup = false;
        tokens.add(')');
      case ',':
        if (inGroup) {
          tokens.add('|');
        } else {
          tokens.add('\\$c');
        }
      default:
        tokens.add(_escapedChars.contains(c) ? '\\$c' : c);
    }
  }
  if (inGroup) {
    throw FormatException('Invalid glob pattern "$glob": unmatched \'{\'');
  }
  tokens.add(r'$');
  return tokens.join();
}

/// Resolves [glob] against [baseURL] and translates it into a regex source.
String resolveGlobToRegexPattern(String? baseURL, String glob,
    {bool webSocketUrl = false}) {
  if (webSocketUrl) baseURL = _toWebSocketBaseUrl(baseURL);
  return globToRegexPattern(_resolveGlobBase(baseURL, glob));
}

/// Whether [urlString] is claimed by [match].
///
/// [match] is a [String] glob, a [RegExp], a `bool Function(Uri)` predicate, or
/// null/empty, which matches everything. Anything else throws [ArgumentError].
/// [webSocketUrl] rewrites an `http(s)` [baseURL] into `ws(s)` first, so a
/// relative glob reaches a WebSocket URL.
bool urlMatches(String? baseURL, String urlString, Object? match,
    {bool webSocketUrl = false}) {
  if (match == null || (match is String && match.isEmpty)) return true;
  if (match is String) {
    return RegExp(resolveGlobToRegexPattern(baseURL, match,
            webSocketUrl: webSocketUrl))
        .hasMatch(urlString);
  }
  if (match is RegExp) return match.hasMatch(urlString);
  final url = _parseURL(urlString);
  if (url == null) return false;
  if (match is bool Function(Uri)) return match(url);
  throw ArgumentError.value(match, 'match',
      'url parameter should be a String glob, a RegExp or a bool Function(Uri)');
}

/// Whether two matchers are the same one, which is what `unroute` needs to
/// find the handler to drop. Port of upstream's `urlMatchesEqual`.
bool urlMatchesEqual(Object? match1, Object? match2) {
  if (match1 is RegExp && match2 is RegExp) {
    return match1.pattern == match2.pattern &&
        match1.isCaseSensitive == match2.isCaseSensitive &&
        match1.isMultiLine == match2.isMultiLine &&
        match1.isDotAll == match2.isDotAll &&
        match1.isUnicode == match2.isUnicode;
  }
  return identical(match1, match2) || match1 == match2;
}

/// Resolves [givenURL] against [baseURL], returning [givenURL] unchanged when
/// it cannot be parsed. Port of upstream's `constructURLBasedOnBaseURL`.
String constructURLBasedOnBaseURL(String? baseURL, String givenURL) {
  try {
    return _resolveBaseURL(baseURL, givenURL).resolved;
  } catch (_) {
    return givenURL;
  }
}

String? _toWebSocketBaseUrl(String? baseURL) {
  // Allow an http(s) baseURL to match ws(s) urls. Schemes are case-insensitive,
  // same as elsewhere in this file, so 'HTTP://...' is rewritten too.
  if (baseURL != null &&
      RegExp(r'^https?://', caseSensitive: false).hasMatch(baseURL)) {
    return baseURL.replaceFirstMapped(RegExp(r'^https?', caseSensitive: false),
        (m) => m[0]!.toLowerCase() == 'https' ? 'wss' : 'ws');
  }
  return baseURL;
}

String _resolveGlobBase(String? baseURL, String match) {
  if (match.startsWith('*')) return match;

  final tokenMap = <String, String>{};
  String mapToken(String original, String replacement) {
    if (original.isEmpty) return '';
    tokenMap[replacement] = original;
    return replacement;
  }

  // An escaped `\\?` behaves the same as `?` in our glob patterns.
  match = match.replaceAll(r'\\?', '?');
  // Special case about: URLs as they are not relative to baseURL.
  if (match.startsWith('about:') ||
      match.startsWith('data:') ||
      match.startsWith('chrome:') ||
      match.startsWith('edge:') ||
      match.startsWith('file:')) {
    return match;
  }

  // Glob symbols may be escaped in the URL and some of them, such as `?`,
  // affect resolution, so they are replaced with safe components first.
  final segments = match.split('/');
  final relativePath = <String>[];
  for (var index = 0; index < segments.length; index++) {
    final token = segments[index];
    if (token == '.' || token == '..' || token.isEmpty) {
      relativePath.add(token);
      continue;
    }
    // Handle the special case of `http*://`; the stand-in scheme has to be a
    // web scheme so that slashes are properly inserted after the domain.
    if (index == 0 && token.endsWith(':')) {
      if (token.contains('*') || token.contains('{')) {
        relativePath.add(mapToken(token, 'http:'));
      } else {
        // Preserve an explicit scheme as is, as it may affect trailing slashes
        // after the domain.
        relativePath.add(token);
      }
      continue;
    }
    // Components without glob metacharacters are literal, so let them
    // round-trip through the URL parser to preserve normalization (default
    // ports such as :80/:443, percent-encoding). Only opaque tokens defeat it.
    if (!RegExp(r'[*?{}\\]').hasMatch(token)) {
      relativePath.add(token);
      continue;
    }
    final questionIndex = token.indexOf('?');
    if (questionIndex == -1) {
      relativePath.add(mapToken(token, '\$_${index}_\$'));
      continue;
    }
    final newPrefix =
        mapToken(token.substring(0, questionIndex), '\$_${index}_\$');
    final newSuffix =
        mapToken(token.substring(questionIndex), '?\$_${index}_\$');
    relativePath.add(newPrefix + newSuffix);
  }

  final result = _resolveBaseURL(baseURL, relativePath.join('/'));
  var resolved = result.resolved;
  for (final entry in tokenMap.entries) {
    final token = entry.key;
    final original = entry.value;
    final normalize = result.caseInsensitivePart?.contains(token) ?? false;
    resolved = resolved.replaceFirst(
        token, normalize ? original.toLowerCase() : original);
  }
  return resolved;
}

Uri? _parseURL(String url) {
  try {
    final uri = Uri.parse(url);
    // `new URL()` rejects a relative reference; `Uri.parse` happily accepts
    // one, so the scheme is what stands in for that check.
    if (!uri.hasScheme) return null;
    return uri;
  } catch (_) {
    return null;
  }
}

({String resolved, String? caseInsensitivePart}) _resolveBaseURL(
    String? baseURL, String givenURL) {
  try {
    final url = baseURL == null
        ? Uri.parse(givenURL)
        : Uri.parse(baseURL).resolve(givenURL);
    if (!url.hasScheme) return (resolved: givenURL, caseInsensitivePart: null);
    return (
      resolved: _serialize(url),
      // Scheme and domain are case-insensitive.
      caseInsensitivePart: _origin(url),
    );
  } catch (_) {
    return (resolved: givenURL, caseInsensitivePart: null);
  }
}

/// `Uri.toString()` plus the one thing `new URL()` does that it does not: a
/// special-scheme URL always carries at least a `/` path, so
/// `http://example.com` serializes as `http://example.com/`.
String _serialize(Uri url) {
  if (_specialSchemes.contains(url.scheme) &&
      url.path.isEmpty &&
      url.hasAuthority) {
    return url.replace(path: '/').toString();
  }
  return url.toString();
}

/// JavaScript's `URL.origin`, which is the literal string `'null'` for a
/// scheme the standard does not give an origin to.
String _origin(Uri url) {
  if (!_schemesWithOrigin.contains(url.scheme)) return 'null';
  final port = url.hasPort ? ':${url.port}' : '';
  return '${url.scheme}://${url.host}$port';
}

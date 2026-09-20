// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/protocolFormatter.ts

/// Turns a recorded call into the line the action list shows.
///
/// A trace records the protocol class and method (`Frame.click`) and the raw
/// params; the title the user reads (`Click`, and `getByRole('button')` under
/// it) is computed here, from the templates of [methodMetainfo]. Traces of
/// version 8 and newer may carry a pre-rendered `title`, which wins.
///
/// One dependency is deliberately not taken: rendering a selector as a
/// locator belongs to the code generator, which is a front of its own in this
/// port. It arrives as [LocatorDescriber]; without one, a selector is shown
/// as recorded.
library;

import 'protocol_metainfo.dart';

export 'protocol_metainfo.dart';

/// Renders a Playwright selector as a locator expression in [sdkLanguage].
///
/// Upstream's `asLocatorDescription` of `locatorGenerators.ts`. Until that is
/// ported, [passThroughLocatorDescriber] shows the selector as recorded,
/// which is what a trace of another language would show anyway.
typedef LocatorDescriber = String Function(String sdkLanguage, String selector);

/// The describer used when none is given: the selector, unchanged.
String passThroughLocatorDescriber(String sdkLanguage, String selector) =>
    selector;

/// `CallMetainfo`: what the formatter needs to know about one call.
class CallMetainfo {
  /// The protocol class, e.g. `Frame`.
  final String className;

  /// The protocol method, e.g. `click`.
  final String method;

  /// The recorded call params.
  final Map<String, dynamic>? params;

  /// A pre-rendered title, which takes precedence over the template.
  final String? title;

  /// A pre-rendered subtitle, which takes precedence over the template.
  final String? subtitle;

  const CallMetainfo({
    required this.className,
    required this.method,
    this.params,
    this.title,
    this.subtitle,
  });
}

/// `formatProtocolParam`: resolves one `{...}` placeholder, with newlines
/// flattened so a title stays on one line.
String? formatProtocolParam(
  Map<String, dynamic>? params,
  String alternatives, {
  String? sdkLanguage,
  LocatorDescriber describeLocator = passThroughLocatorDescriber,
}) =>
    _formatProtocolParam(params, alternatives,
            sdkLanguage: sdkLanguage, describeLocator: describeLocator)
        ?.replaceAll('\n', '\\n');

String? _formatProtocolParam(
  Map<String, dynamic>? params,
  String alternatives, {
  String? sdkLanguage,
  required LocatorDescriber describeLocator,
}) {
  if (params == null) return null;

  for (final name in alternatives.split('|')) {
    if (name == 'url') {
      final raw = params[name];
      final shortened = raw is String ? _shortenUrl(raw) : null;
      if (shortened != null) return shortened;
      if (raw != null) return '$raw';
    }
    if (name == 'timeNumber' && params[name] != null) {
      final millis = (params[name] as num).toInt();
      return DateTime.fromMillisecondsSinceEpoch(millis).toString();
    }

    final value = _deepParam(params, name);
    if (value == null) continue;
    if (name == 'selector' || name.endsWith('.selector')) {
      return describeLocator(sdkLanguage ?? 'javascript', value);
    }
    return value;
  }
  return null;
}

/// `new URL(url)` plus the three special cases upstream keeps, or null when
/// the value is not an absolute URL — which is `new URL` throwing.
String? _shortenUrl(String raw) {
  final Uri uri;
  try {
    uri = Uri.parse(raw);
  } on FormatException {
    return null;
  }
  if (!uri.hasScheme) return null;
  if (uri.scheme == 'data') return 'data:';
  if (uri.scheme == 'about' || uri.scheme == 'chrome' || uri.scheme == 'edge') {
    return raw;
  }
  final host = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  final search = uri.hasQuery ? '?${uri.query}' : '';
  return '$host${uri.path}$search';
}

/// Walks a dotted path into the params and stringifies whatever it lands on.
String? _deepParam(Map<String, dynamic> params, String name) {
  Object? current = params;
  for (final token in name.split('.')) {
    if (current is! Map) return null;
    current = current[token];
  }
  if (current == null) return null;
  return '$current';
}

final RegExp _placeholder = RegExp(r'\{([^}]+)\}');

/// `renderTitleForCall`: the first line of an action in the list.
String renderTitleForCall(
  CallMetainfo metadata, {
  String? sdkLanguage,
  LocatorDescriber describeLocator = passThroughLocatorDescriber,
}) {
  final titleFormat = metadata.title ??
      getMetainfo(metadata.className, metadata.method)?.title ??
      metadata.method;
  return titleFormat.replaceAllMapped(_placeholder, (match) {
    return formatProtocolParam(metadata.params, match[1]!,
            sdkLanguage: sdkLanguage, describeLocator: describeLocator) ??
        match[0]!;
  });
}

/// `renderSubtitleForCall`: the second line, and only when every placeholder
/// in it resolved — a half-filled subtitle is worse than none.
String? renderSubtitleForCall(
  CallMetainfo metadata, {
  String? sdkLanguage,
  LocatorDescriber describeLocator = passThroughLocatorDescriber,
}) {
  final subtitleFormat = metadata.subtitle ??
      getMetainfo(metadata.className, metadata.method)?.subtitle;
  if (subtitleFormat == null) return null;
  var allParamsResolved = true;
  final subtitle = subtitleFormat.replaceAllMapped(_placeholder, (match) {
    final param = formatProtocolParam(metadata.params, match[1]!,
        sdkLanguage: sdkLanguage, describeLocator: describeLocator);
    if (param == null) allParamsResolved = false;
    return param ?? match[0]!;
  });
  return allParamsResolved ? subtitle : null;
}

/// `renderFullTitleForCall`: title and subtitle joined by a space.
String renderFullTitleForCall(
  CallMetainfo metadata, {
  String? sdkLanguage,
  LocatorDescriber describeLocator = passThroughLocatorDescriber,
}) {
  final title = renderTitleForCall(metadata,
      sdkLanguage: sdkLanguage, describeLocator: describeLocator);
  final subtitle = renderSubtitleForCall(metadata,
      sdkLanguage: sdkLanguage, describeLocator: describeLocator);
  return subtitle != null ? '$title $subtitle' : title;
}

/// The groups the action list filters by.
class ActionGroup {
  static const String configuration = 'configuration';
  static const String route = 'route';
  static const String getter = 'getter';

  /// Every group, for a UI that offers them as toggles.
  static const List<String> values = [configuration, route, getter];
}

/// `getActionGroup`: the group a call belongs to, or null when it is a plain
/// action that is always shown.
String? getActionGroup(String className, String method) =>
    getMetainfo(className, method)?.group;

const int _kMaxParamLength = 200;

/// `truncateParam`: params are shown, not dumped.
String truncateParam(String value) => value.length > _kMaxParamLength
    ? '${value.substring(0, _kMaxParamLength)}…'
    : value;

/// `renderParamsForCall`: the curated params of one call, from the
/// `renderParams` list of [methodMetainfo].
///
/// Only the arguments that say what the call actually did are reported, and
/// only when they are bounded in size: page content, evaluated expressions and
/// request bodies never are.
Map<String, dynamic>? renderParamsForCall(
  CallMetainfo metadata, {
  String? sdkLanguage,
  LocatorDescriber describeLocator = passThroughLocatorDescriber,
}) {
  final params = metadata.params;
  if (params == null) return null;
  final result = <String, dynamic>{};
  final locator = _renderLocator(params['selector'],
      sdkLanguage: sdkLanguage, describeLocator: describeLocator);
  if (locator != null) result['locator'] = locator;
  for (final entry
      in getMetainfo(metadata.className, metadata.method)?.renderParams ??
          const <String>[]) {
    final rendered = _renderParamEntry(params, entry,
        sdkLanguage: sdkLanguage, describeLocator: describeLocator);
    if (rendered.value != null) result[rendered.key] = rendered.value;
  }
  return result.isNotEmpty ? result : null;
}

/// Each entry is `[key=]path[:selector]`: a dotted path into the call params,
/// reported under the last path segment unless an explicit key is given, with
/// selector values rendered as locators.
({String key, Object? value}) _renderParamEntry(
  Map<String, dynamic> params,
  String entry, {
  String? sdkLanguage,
  required LocatorDescriber describeLocator,
}) {
  final colon = entry.indexOf(':');
  final spec = colon == -1 ? entry : entry.substring(0, colon);
  final format = colon == -1 ? null : entry.substring(colon + 1);
  final eqIndex = spec.indexOf('=');
  final path = eqIndex == -1 ? spec : spec.substring(eqIndex + 1);
  final key = eqIndex == -1 ? path.split('.').last : spec.substring(0, eqIndex);
  Object? value = params;
  for (final token in path.split('.')) {
    if (value is! Map) {
      value = null;
      break;
    }
    value = value[token];
  }
  if (value == null) return (key: key, value: null);
  if (format == 'selector') {
    return (
      key: key,
      value: _renderLocator(value,
          sdkLanguage: sdkLanguage, describeLocator: describeLocator)
    );
  }
  if (value is String) return (key: key, value: truncateParam(value));
  return (key: key, value: value);
}

String? _renderLocator(
  Object? selector, {
  String? sdkLanguage,
  required LocatorDescriber describeLocator,
}) {
  if (selector is! String) return null;
  return truncateParam(describeLocator(sdkLanguage ?? 'javascript', selector));
}

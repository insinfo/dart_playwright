// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream counterpart: the `/contexts` route of
// packages/trace-viewer/src/sw/main.ts, which answers with `ContextEntry[]`.

/// Carrying a loaded trace from the process that read it to the one that
/// draws it.
///
/// Upstream reads the archive in a service worker and posts the resulting
/// `ContextEntry[]` to the page as structured-cloneable data. This port reads
/// the archive in the `show-trace` process instead, so the same list has to
/// cross an HTTP boundary — which is JSON, not structured clone.
///
/// Every trace event already knows how to write and read itself, so this file
/// is only the envelope: the fields of [ContextEntry] that the event types do
/// not cover. Rebuilding a [ContextEntry] on the far side gives the UI the
/// real model, with `filteredActions`, `eventsForAction` and `stats` on it,
/// rather than a flattened view that would have to re-derive them.
///
/// Nothing here imports `dart:io` or `package:web`: the server encodes and
/// the dart2js bundle decodes, so both sides share this one file.
library;

import 'package:playwright_trace_viewer/playwright_trace_viewer.dart';

/// The wire envelope version, bumped when a field below changes meaning.
///
/// The server sends it and the UI checks it, so a stale bundle served next to
/// a newer binary says so instead of drawing a half-decoded trace.
const int kWireVersion = 1;

/// Writes [contexts] as the JSON the UI decodes with [contextEntriesFromJson].
Map<String, dynamic> contextEntriesToJson(
  List<ContextEntry> contexts, {
  required String traceUri,
}) =>
    {
      'wireVersion': kWireVersion,
      'traceUri': traceUri,
      'contexts': contexts.map(_contextToJson).toList(),
    };

/// Reads back what [contextEntriesToJson] wrote.
///
/// Throws [WireVersionError] when the bundle and the server disagree.
({String traceUri, List<ContextEntry> contexts}) contextEntriesFromJson(
    Map<String, dynamic> json) {
  final version = (json['wireVersion'] as num?)?.toInt() ?? 0;
  if (version != kWireVersion) throw WireVersionError(version, kWireVersion);
  final contexts = (json['contexts'] as List? ?? const [])
      .cast<Map<String, dynamic>>()
      .map(_contextFromJson)
      .toList();
  return (traceUri: json['traceUri'] as String? ?? '', contexts: contexts);
}

/// The bundle was built against a different envelope than the server speaks.
class WireVersionError implements Exception {
  final int received;
  final int expected;

  const WireVersionError(this.received, this.expected);

  @override
  String toString() => 'Trace viewer bundle is out of date: the server speaks '
      'wire version $expected and the bundle speaks $received. Rebuild it '
      'with `dart run playwright_trace_viewer_ui:build_ui`.';
}

Map<String, dynamic> _contextToJson(ContextEntry context) => {
      'origin': context.origin,
      'startTime': context.startTime,
      'endTime': context.endTime,
      'browserName': context.browserName,
      if (context.channel != null) 'channel': context.channel,
      if (context.platform != null) 'platform': context.platform,
      if (context.playwrightVersion != null)
        'playwrightVersion': context.playwrightVersion,
      'wallTime': context.wallTime,
      'monotonicTime': context.monotonicTime,
      if (context.sdkLanguage != null) 'sdkLanguage': context.sdkLanguage,
      if (context.testIdAttributeName != null)
        'testIdAttributeName': context.testIdAttributeName,
      if (context.title != null) 'title': context.title,
      'options': context.options.toJson(),
      'pages': [
        for (final page in context.pages)
          {
            'pageId': page.pageId,
            'screencastFrames':
                page.screencastFrames.map((f) => f.toJson()).toList(),
          }
      ],
      'resources': context.resources.map((r) => r.toJson()).toList(),
      'actions': context.actions.map(_actionToJson).toList(),
      'screenshots': context.screenshots.map((s) => s.toJson()).toList(),
      'ariaSnapshots': context.ariaSnapshots.map((s) => s.toJson()).toList(),
      'domSnapshots': [
        for (final ref in context.domSnapshots)
          {'callId': ref.callId, 'phase': ref.phase.wire}
      ],
      'videos': context.videos.map((v) => v.toJson()).toList(),
      'events': context.events.map((e) => e.toJson()).toList(),
      'stdio': context.stdio.map((s) => s.toJson()).toList(),
      'errors': context.errors.map((e) => e.toJson()).toList(),
      'hasSource': context.hasSource,
      if (context.testTimeout != null) 'testTimeout': context.testTimeout,
      if (context.annotations != null)
        'annotations': context.annotations!.map((a) => a.toJson()).toList(),
    };

ContextEntry _contextFromJson(Map<String, dynamic> json) => ContextEntry(
      origin: json['origin'] as String? ?? kTraceOriginLibrary,
      startTime: _double(json['startTime']),
      endTime: _double(json['endTime']),
      browserName: json['browserName'] as String? ?? '',
      channel: json['channel'] as String?,
      platform: json['platform'] as String?,
      playwrightVersion: json['playwrightVersion'] as String?,
      wallTime: _double(json['wallTime']),
      monotonicTime: _double(json['monotonicTime']),
      sdkLanguage: json['sdkLanguage'] as String?,
      testIdAttributeName: json['testIdAttributeName'] as String?,
      title: json['title'] as String?,
      options: BrowserContextEventOptions.fromJson(
          _map(json['options']) ?? const {}),
      pages: [
        for (final page in _list(json['pages']))
          PageEntry(
            pageId: page['pageId'] as String? ?? '',
            frames: _list(page['screencastFrames'])
                .map(ScreencastFrameTraceEvent.fromJson)
                .toList(),
          )
      ],
      resources: _list(json['resources']).map(HarEntry.fromJson).toList(),
      actions: _list(json['actions']).map(_actionFromJson).toList(),
      screenshots:
          _list(json['screenshots']).map(ScreenshotTraceEvent.fromJson).toList(),
      ariaSnapshots: _list(json['ariaSnapshots'])
          .map(AriaSnapshotTraceEvent.fromJson)
          .toList(),
      domSnapshots: [
        for (final ref in _list(json['domSnapshots']))
          DomSnapshotRef(
            callId: ref['callId'] as String? ?? '',
            phase: ActionPhase.fromWire(ref['phase'] as String?) ??
                ActionPhase.before,
          )
      ],
      videos: _list(json['videos']).map(VideoTraceEvent.fromJson).toList(),
      events: _list(json['events']).map(_timelineEventFromJson).toList(),
      stdio: _list(json['stdio']).map(StdioTraceEvent.fromJson).toList(),
      errors: _list(json['errors']).map(ErrorTraceEvent.fromJson).toList(),
      hasSource: json['hasSource'] as bool? ?? false,
      testTimeout: (json['testTimeout'] as num?)?.toDouble(),
      annotations: json['annotations'] == null
          ? null
          : _list(json['annotations'])
              .map(TraceEventAnnotation.fromJson)
              .toList(),
    );

/// An action, plus the `log` lines the entry collected, which the underlying
/// action event does not carry.
Map<String, dynamic> _actionToJson(ActionEntry action) => {
      ...action.toJson(),
      'log': action.log.map((l) => l.toJson()).toList(),
    };

ActionEntry _actionFromJson(Map<String, dynamic> json) {
  final entry = ActionEntry.fromAction(ActionTraceEvent.fromJson(json));
  entry.log = [
    for (final line in _list(json['log']))
      ActionLogEntry(
        time: _double(line['time']),
        message: line['message'] as String? ?? '',
      )
  ];
  return entry;
}

/// The two shapes that share the one time-ordered list.
///
/// `TimelineTraceEvent` is sealed, so the tag each one writes in `toJson` is
/// what tells them apart on the way back.
TimelineTraceEvent _timelineEventFromJson(Map<String, dynamic> json) =>
    json['type'] == 'console'
        ? ConsoleMessageTraceEvent.fromJson(json)
        : EventTraceEvent.fromJson(json);

List<Map<String, dynamic>> _list(Object? value) =>
    (value as List? ?? const []).cast<Map<String, dynamic>>();

Map<String, dynamic>? _map(Object? value) =>
    value is Map ? value.cast<String, dynamic>() : null;

double _double(Object? value) => (value as num?)?.toDouble() ?? 0;

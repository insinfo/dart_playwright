// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/trace/entries.ts

/// The structures that carry one loaded trace context.
///
/// Upstream passes these between the service worker and the page, which is
/// why they are plain data. Here they are plain data for the same reason: the
/// UI will read them, from the same isolate or from another one.
library;

import 'trace.dart';

/// One line of an action's log.
class ActionLogEntry {
  final double time;
  final String message;

  const ActionLogEntry({required this.time, required this.message});

  Map<String, dynamic> toJson() => {'time': time, 'message': message};
}

/// `ActionEntry`: an action, with the log lines that arrived for it.
///
/// This is the `action` event of the format plus `log`, and it is mutable
/// because the reader fills it in over three separate events — `before` opens
/// it, `input` adds the point, `after` closes it — and then the model patches
/// `stack` and `group` onto it.
class ActionEntry extends ActionTraceEvent {
  List<ActionLogEntry> log;

  /// The action that ended just before this one.
  ///
  /// Upstream hangs these two links off the action with a `Symbol`, to keep
  /// them out of anything that serializes it; here they are plain fields that
  /// `toJson` does not write. [TraceModel] fills them in.
  ActionEntry? prevByEndTime;

  /// The action that started just after this one.
  ActionEntry? nextByStartTime;

  ActionEntry({
    required super.callId,
    required super.startTime,
    required super.endTime,
    super.title,
    super.subtitle,
    required super.className,
    required super.method,
    required super.params,
    super.stack,
    super.parentId,
    super.group,
    super.point,
    super.box,
    super.error,
    super.attachments,
    super.annotations,
    super.result,
    List<ActionLogEntry>? log,
  }) : log = log ?? <ActionLogEntry>[];

  /// Opens an entry from a `before` event, as upstream's
  /// `{ ...event, type: 'action', endTime: 0, log: [] }` does.
  factory ActionEntry.fromBefore(BeforeActionTraceEvent event) => ActionEntry(
        callId: event.callId,
        startTime: event.startTime,
        endTime: 0,
        title: event.title,
        subtitle: event.subtitle,
        className: event.className,
        method: event.method,
        params: event.params,
        stack: event.stack,
        parentId: event.parentId,
        group: event.group,
      );

  /// Opens an entry from a whole `action` event, as upstream's
  /// `{ ...event, log: [] }` does.
  factory ActionEntry.fromAction(ActionTraceEvent event) => ActionEntry(
        callId: event.callId,
        startTime: event.startTime,
        endTime: event.endTime,
        title: event.title,
        subtitle: event.subtitle,
        className: event.className,
        method: event.method,
        params: event.params,
        stack: event.stack,
        parentId: event.parentId,
        group: event.group,
        point: event.point,
        box: event.box,
        error: event.error,
        attachments: event.attachments,
        annotations: event.annotations,
        result: event.result,
      );

  /// A shallow copy, which is what upstream's `{ ...action }` produces when
  /// the model merges the library and test runner contexts.
  ActionEntry copy() => ActionEntry(
        callId: callId,
        startTime: startTime,
        endTime: endTime,
        title: title,
        subtitle: subtitle,
        className: className,
        method: method,
        params: params,
        stack: stack,
        parentId: parentId,
        group: group,
        point: point,
        box: box,
        error: error,
        attachments: attachments,
        annotations: annotations,
        result: result,
        log: log,
      );
}

/// `PageEntry`: a page of the trace and the filmstrip frames it produced.
class PageEntry {
  final String pageId;
  final List<ScreencastFrameTraceEvent> screencastFrames;

  PageEntry({required this.pageId, List<ScreencastFrameTraceEvent>? frames})
      : screencastFrames = frames ?? <ScreencastFrameTraceEvent>[];
}

/// A `frame-snapshot` of the main frame, remembered by call and phase so the
/// UI can ask whether a DOM snapshot exists before offering the tab.
class DomSnapshotRef {
  final String callId;
  final ActionPhase phase;

  const DomSnapshotRef({required this.callId, required this.phase});
}

/// `ContextEntry`: everything one `.trace` file of one context produced.
///
/// A trace archive can hold several — the library writes one and the test
/// runner another — and [TraceModel] merges them.
class ContextEntry {
  /// `testRunner` or `library`.
  String origin;
  double startTime;
  double endTime;
  String browserName;
  String? channel;
  String? platform;
  String? playwrightVersion;
  double wallTime;
  double monotonicTime;
  String? sdkLanguage;
  String? testIdAttributeName;
  String? title;
  BrowserContextEventOptions options;
  List<PageEntry> pages;
  List<ResourceSnapshot> resources;
  List<ActionEntry> actions;
  List<ScreenshotTraceEvent> screenshots;
  List<AriaSnapshotTraceEvent> ariaSnapshots;
  List<DomSnapshotRef> domSnapshots;
  List<VideoTraceEvent> videos;

  /// `event` and `console` lines, in one list, as upstream keeps them.
  List<TimelineTraceEvent> events;
  List<StdioTraceEvent> stdio;
  List<ErrorTraceEvent> errors;
  bool hasSource;
  double? testTimeout;
  List<TraceEventAnnotation>? annotations;

  ContextEntry({
    required this.origin,
    required this.startTime,
    required this.endTime,
    required this.browserName,
    this.channel,
    this.platform,
    this.playwrightVersion,
    required this.wallTime,
    required this.monotonicTime,
    this.sdkLanguage,
    this.testIdAttributeName,
    this.title,
    required this.options,
    required this.pages,
    required this.resources,
    required this.actions,
    required this.screenshots,
    required this.ariaSnapshots,
    required this.domSnapshots,
    required this.videos,
    required this.events,
    required this.stdio,
    required this.errors,
    required this.hasSource,
    this.testTimeout,
    this.annotations,
  });

  /// `createEmptyContext()` of `traceLoader.ts`: the context a modernizer
  /// starts from, including the 1280x800 viewport an old trace may never
  /// declare.
  factory ContextEntry.empty() => ContextEntry(
        origin: kTraceOriginTestRunner,
        // Upstream uses Number.MAX_SAFE_INTEGER as the "not seen yet" floor.
        startTime: 9007199254740991,
        wallTime: 9007199254740991,
        monotonicTime: 0,
        endTime: 0,
        browserName: '',
        options: BrowserContextEventOptions(
          deviceScaleFactor: 1,
          isMobile: false,
          viewport: TraceSize(width: 1280, height: 800),
        ),
        pages: <PageEntry>[],
        resources: <ResourceSnapshot>[],
        actions: <ActionEntry>[],
        screenshots: <ScreenshotTraceEvent>[],
        ariaSnapshots: <AriaSnapshotTraceEvent>[],
        domSnapshots: <DomSnapshotRef>[],
        videos: <VideoTraceEvent>[],
        events: <TimelineTraceEvent>[],
        stdio: <StdioTraceEvent>[],
        errors: <ErrorTraceEvent>[],
        hasSource: false,
      );
}

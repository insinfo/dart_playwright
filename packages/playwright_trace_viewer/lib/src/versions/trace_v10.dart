// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/trace/versions/traceV10.ts

/// Version 10 of the trace format: the shape every other version is
/// modernized into, and the only one this package models with parsers.
///
/// Versions 3 to 9 are ported as writers (`trace_v3.dart` .. `trace_v9.dart`)
/// because the modernizer reads them as raw JSON, exactly as upstream does —
/// TypeScript's types are erased at runtime, so `_modernize_N_to_M` mutates
/// plain objects. Those files exist so a fixture can be built from the real
/// shape of an old trace instead of from a hand-written map.
library;

import 'har.dart';

export 'har.dart';

/// The newest format version this reader understands.
///
/// A trace whose `context-options` carries a higher number is refused with a
/// `TraceVersionError`, because the reader cannot know what changed.
///
/// Upstream's history, from the comment in `traceV10.ts`:
///
/// - 6 => released in ~1.40
/// - 7 => released in ~1.45
/// - 8 => released in 1.53
/// - 9 => released in 1.63
/// - 10 => not released yet
const int kLatestTraceVersion = 10;

/// The version this port's own recorder writes
/// (`playwright_core/lib/src/server/trace/trace_events.dart`).
///
/// It is deliberately one behind [kLatestTraceVersion]: 10 exists only in
/// upstream's unreleased tree, and the newest viewer installable from npm
/// stops at 9. The reader still modernizes 9 to 10 like upstream, so both the
/// traces this port writes and the ones a future 1.64 writes land on the same
/// in-memory shape.
const int kRecorderTraceVersion = 9;

/// The phase of an action a snapshot, a screenshot or an aria snapshot
/// belongs to.
///
/// Traces older than version 9 named their snapshots instead
/// (`beforeSnapshot`, `inputSnapshot`, `afterSnapshot`); `_modernize_8_to_9`
/// turns those names back into phases.
enum ActionPhase {
  before('before'),
  action('action'),
  after('after');

  const ActionPhase(this.wire);

  /// The string this phase has on the wire.
  final String wire;

  /// Parses the wire form, returning null for anything else.
  static ActionPhase? fromWire(Object? value) {
    for (final phase in ActionPhase.values) {
      if (phase.wire == value) return phase;
    }
    return null;
  }

  @override
  String toString() => wire;
}

/// `origin` of a context: the library recorded it.
const String kTraceOriginLibrary = 'library';

/// `origin` of a context: the test runner recorded it.
const String kTraceOriginTestRunner = 'testRunner';

int? _int(Object? value) => (value as num?)?.toInt();
double? _double(Object? value) => (value as num?)?.toDouble();

Map<String, dynamic> _compact(Map<String, dynamic> map) {
  map.removeWhere((_, value) => value == null);
  return map;
}

Map<String, dynamic>? _map(Object? value) =>
    value == null ? null : (value as Map).cast<String, dynamic>();

/// `Size`.
class TraceSize {
  int width;
  int height;

  TraceSize({required this.width, required this.height});

  factory TraceSize.fromJson(Map<String, dynamic> json) => TraceSize(
        width: _int(json['width']) ?? 0,
        height: _int(json['height']) ?? 0,
      );

  Map<String, dynamic> toJson() => {'width': width, 'height': height};

  @override
  String toString() => '${width}x$height';
}

/// `Point`.
class TracePoint {
  double x;
  double y;

  TracePoint({required this.x, required this.y});

  factory TracePoint.fromJson(Map<String, dynamic> json) => TracePoint(
        x: _double(json['x']) ?? 0,
        y: _double(json['y']) ?? 0,
      );

  Map<String, dynamic> toJson() => {'x': x, 'y': y};
}

/// `Rect`, which is `Size & Point` in the format.
class TraceRect {
  double x;
  double y;
  int width;
  int height;

  TraceRect({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  factory TraceRect.fromJson(Map<String, dynamic> json) => TraceRect(
        x: _double(json['x']) ?? 0,
        y: _double(json['y']) ?? 0,
        width: _int(json['width']) ?? 0,
        height: _int(json['height']) ?? 0,
      );

  Map<String, dynamic> toJson() =>
      {'x': x, 'y': y, 'width': width, 'height': height};
}

/// `StackFrame`: one frame of the caller's stack, as the Source tab wants it.
class StackFrame {
  String file;
  int line;
  int column;
  String? function;

  StackFrame({
    required this.file,
    required this.line,
    required this.column,
    this.function,
  });

  factory StackFrame.fromJson(Map<String, dynamic> json) => StackFrame(
        file: json['file'] as String? ?? '',
        line: _int(json['line']) ?? 0,
        column: _int(json['column']) ?? 0,
        function: json['function'] as String?,
      );

  Map<String, dynamic> toJson() => _compact({
        'file': file,
        'line': line,
        'column': column,
        'function': function,
      });
}

/// `SerializedValue`: a JavaScript value as the protocol serializes it.
///
/// The model never looks inside one; it is parsed so the UI has a shape to
/// render instead of a bare map.
class SerializedValue {
  double? n;
  bool? b;
  String? s;

  /// One of `null`, `undefined`, `NaN`, `Infinity`, `-Infinity`, `-0`.
  String? v;
  String? d;
  String? u;
  String? bi;
  SerializedTypedArray? ta;
  SerializedValueError? e;
  SerializedValueRegExp? r;
  List<SerializedValue>? a;
  List<SerializedValueProperty>? o;
  double? h;
  int? id;
  int? ref;

  SerializedValue({
    this.n,
    this.b,
    this.s,
    this.v,
    this.d,
    this.u,
    this.bi,
    this.ta,
    this.e,
    this.r,
    this.a,
    this.o,
    this.h,
    this.id,
    this.ref,
  });

  factory SerializedValue.fromJson(Map<String, dynamic> json) =>
      SerializedValue(
        n: _double(json['n']),
        b: json['b'] as bool?,
        s: json['s'] as String?,
        v: json['v'] as String?,
        d: json['d'] as String?,
        u: json['u'] as String?,
        bi: json['bi'] as String?,
        ta: json['ta'] == null
            ? null
            : SerializedTypedArray.fromJson(_map(json['ta'])!),
        e: json['e'] == null
            ? null
            : SerializedValueError.fromJson(_map(json['e'])!),
        r: json['r'] == null
            ? null
            : SerializedValueRegExp.fromJson(_map(json['r'])!),
        a: (json['a'] as List?)
            ?.map((e) => SerializedValue.fromJson((e as Map).cast()))
            .toList(),
        o: (json['o'] as List?)
            ?.map((e) => SerializedValueProperty.fromJson((e as Map).cast()))
            .toList(),
        h: _double(json['h']),
        id: _int(json['id']),
        ref: _int(json['ref']),
      );

  Map<String, dynamic> toJson() => _compact({
        'n': n,
        'b': b,
        's': s,
        'v': v,
        'd': d,
        'u': u,
        'bi': bi,
        'ta': ta?.toJson(),
        'e': e?.toJson(),
        'r': r?.toJson(),
        'a': a?.map((e) => e.toJson()).toList(),
        'o': o?.map((e) => e.toJson()).toList(),
        'h': h,
        'id': id,
        'ref': ref,
      });
}

/// The `ta` member of a [SerializedValue]: a typed array, base64 in `b`.
class SerializedTypedArray {
  String b;

  /// One of `i8`, `ui8`, `ui8c`, `i16`, `ui16`, `i32`, `ui32`, `f32`, `f64`,
  /// `bi64`, `bui64`.
  String k;

  SerializedTypedArray({required this.b, required this.k});

  factory SerializedTypedArray.fromJson(Map<String, dynamic> json) =>
      SerializedTypedArray(
        b: json['b'] as String? ?? '',
        k: json['k'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {'b': b, 'k': k};
}

/// The `e` member of a [SerializedValue]: a serialized `Error`.
class SerializedValueError {
  String m;
  String n;
  String s;

  SerializedValueError({required this.m, required this.n, required this.s});

  factory SerializedValueError.fromJson(Map<String, dynamic> json) =>
      SerializedValueError(
        m: json['m'] as String? ?? '',
        n: json['n'] as String? ?? '',
        s: json['s'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {'m': m, 'n': n, 's': s};
}

/// The `r` member of a [SerializedValue]: a serialized `RegExp`.
class SerializedValueRegExp {
  String p;
  String f;

  SerializedValueRegExp({required this.p, required this.f});

  factory SerializedValueRegExp.fromJson(Map<String, dynamic> json) =>
      SerializedValueRegExp(
        p: json['p'] as String? ?? '',
        f: json['f'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {'p': p, 'f': f};
}

/// One entry of the `o` member of a [SerializedValue]: an object property.
class SerializedValueProperty {
  String k;
  SerializedValue v;

  SerializedValueProperty({required this.k, required this.v});

  factory SerializedValueProperty.fromJson(Map<String, dynamic> json) =>
      SerializedValueProperty(
        k: json['k'] as String? ?? '',
        v: SerializedValue.fromJson(_map(json['v']) ?? const {}),
      );

  Map<String, dynamic> toJson() => {'k': k, 'v': v.toJson()};
}

/// `SerializedError['error']`: the error an action failed with.
class TraceError {
  String message;
  String name;
  String? stack;

  TraceError({required this.message, required this.name, this.stack});

  factory TraceError.fromJson(Map<String, dynamic> json) => TraceError(
        message: json['message'] as String? ?? '',
        name: json['name'] as String? ?? '',
        stack: json['stack'] as String?,
      );

  Map<String, dynamic> toJson() =>
      _compact({'message': message, 'name': name, 'stack': stack});
}

/// `BrowserContextEventOptions`: the context options the viewer shows, and
/// uses to size the snapshot viewport.
class BrowserContextEventOptions {
  String? baseURL;
  TraceSize? viewport;
  double? deviceScaleFactor;
  bool? isMobile;
  String? userAgent;

  BrowserContextEventOptions({
    this.baseURL,
    this.viewport,
    this.deviceScaleFactor,
    this.isMobile,
    this.userAgent,
  });

  factory BrowserContextEventOptions.fromJson(Map<String, dynamic> json) =>
      BrowserContextEventOptions(
        baseURL: json['baseURL'] as String?,
        viewport: json['viewport'] == null
            ? null
            : TraceSize.fromJson(_map(json['viewport'])!),
        deviceScaleFactor: _double(json['deviceScaleFactor']),
        isMobile: json['isMobile'] as bool?,
        userAgent: json['userAgent'] as String?,
      );

  Map<String, dynamic> toJson() => _compact({
        'baseURL': baseURL,
        'viewport': viewport?.toJson(),
        'deviceScaleFactor': deviceScaleFactor,
        'isMobile': isMobile,
        'userAgent': userAgent,
      });
}

/// `TraceEventAnnotation`: an annotation the test runner attached.
class TraceEventAnnotation {
  String type;
  String? description;

  TraceEventAnnotation({required this.type, this.description});

  factory TraceEventAnnotation.fromJson(Map<String, dynamic> json) =>
      TraceEventAnnotation(
        type: json['type'] as String? ?? '',
        description: json['description'] as String?,
      );

  Map<String, dynamic> toJson() =>
      _compact({'type': type, 'description': description});
}

/// Base of every line of `trace.trace` and `trace.network`.
sealed class TraceEvent {
  const TraceEvent();

  /// The `type` discriminator on the wire.
  String get type;

  Map<String, dynamic> toJson();

  /// Parses one modernized (version 10) event.
  ///
  /// Returns null for a `type` this reader does not know, which is what
  /// upstream's `switch` does with an unhandled case. The caller keeps the raw
  /// map around for the bookkeeping that reads fields structurally.
  static TraceEvent? parse(Map<String, dynamic> json) {
    switch (json['type']) {
      case 'context-options':
        return ContextCreatedTraceEvent.fromJson(json);
      case 'screencast-frame':
        return ScreencastFrameTraceEvent.fromJson(json);
      case 'video':
        return VideoTraceEvent.fromJson(json);
      case 'screenshot':
        return ScreenshotTraceEvent.fromJson(json);
      case 'aria-snapshot':
        return AriaSnapshotTraceEvent.fromJson(json);
      case 'before':
        return BeforeActionTraceEvent.fromJson(json);
      case 'input':
        return InputActionTraceEvent.fromJson(json);
      case 'after':
        return AfterActionTraceEvent.fromJson(json);
      case 'action':
        return ActionTraceEvent.fromJson(json);
      case 'log':
        return LogTraceEvent.fromJson(json);
      case 'event':
        return EventTraceEvent.fromJson(json);
      case 'console':
        return ConsoleMessageTraceEvent.fromJson(json);
      case 'resource-snapshot':
        return ResourceSnapshotTraceEvent.fromJson(json);
      case 'frame-snapshot':
        return FrameSnapshotTraceEvent.fromJson(json);
      case 'stdout':
      case 'stderr':
        return StdioTraceEvent.fromJson(json);
      case 'error':
        return ErrorTraceEvent.fromJson(json);
      default:
        return null;
    }
  }
}

/// `context-options`: the first line of every chunk. Carries the version gate
/// and the clock origin.
class ContextCreatedTraceEvent extends TraceEvent {
  int version;

  /// `testRunner` or `library`.
  String origin;
  String browserName;
  String? channel;
  String platform;
  String? playwrightVersion;
  double wallTime;
  double monotonicTime;
  String? title;
  BrowserContextEventOptions options;
  String? sdkLanguage;
  String? testIdAttributeName;
  double? testTimeout;
  List<TraceEventAnnotation>? annotations;

  ContextCreatedTraceEvent({
    required this.version,
    required this.origin,
    required this.browserName,
    this.channel,
    required this.platform,
    this.playwrightVersion,
    required this.wallTime,
    required this.monotonicTime,
    this.title,
    required this.options,
    this.sdkLanguage,
    this.testIdAttributeName,
    this.testTimeout,
    this.annotations,
  });

  factory ContextCreatedTraceEvent.fromJson(Map<String, dynamic> json) =>
      ContextCreatedTraceEvent(
        version: _int(json['version']) ?? 0,
        origin: json['origin'] as String? ?? kTraceOriginTestRunner,
        browserName: json['browserName'] as String? ?? '',
        channel: json['channel'] as String?,
        platform: json['platform'] as String? ?? '',
        playwrightVersion: json['playwrightVersion'] as String?,
        wallTime: _double(json['wallTime']) ?? 0,
        monotonicTime: _double(json['monotonicTime']) ?? 0,
        title: json['title'] as String?,
        options: BrowserContextEventOptions.fromJson(
            _map(json['options']) ?? <String, dynamic>{}),
        sdkLanguage: json['sdkLanguage'] as String?,
        testIdAttributeName: json['testIdAttributeName'] as String?,
        testTimeout: _double(json['testTimeout']),
        annotations: (json['annotations'] as List?)
            ?.map((e) => TraceEventAnnotation.fromJson((e as Map).cast()))
            .toList(),
      );

  @override
  String get type => 'context-options';

  @override
  Map<String, dynamic> toJson() => _compact({
        'version': version,
        'type': type,
        'origin': origin,
        'browserName': browserName,
        'channel': channel,
        'platform': platform,
        'playwrightVersion': playwrightVersion,
        'wallTime': wallTime,
        'monotonicTime': monotonicTime,
        'title': title,
        'options': options.toJson(),
        'sdkLanguage': sdkLanguage,
        'testIdAttributeName': testIdAttributeName,
        'testTimeout': testTimeout,
        'annotations': annotations?.map((e) => e.toJson()).toList(),
      });
}

/// `screencast-frame`: one frame of the filmstrip.
class ScreencastFrameTraceEvent extends TraceEvent {
  String pageId;
  String file;
  int width;
  int height;
  double timestamp;
  double? frameSwapWallTime;

  ScreencastFrameTraceEvent({
    required this.pageId,
    required this.file,
    required this.width,
    required this.height,
    required this.timestamp,
    this.frameSwapWallTime,
  });

  factory ScreencastFrameTraceEvent.fromJson(Map<String, dynamic> json) =>
      ScreencastFrameTraceEvent(
        pageId: json['pageId'] as String? ?? '',
        file: json['file'] as String? ?? '',
        width: _int(json['width']) ?? 0,
        height: _int(json['height']) ?? 0,
        timestamp: _double(json['timestamp']) ?? 0,
        frameSwapWallTime: _double(json['frameSwapWallTime']),
      );

  @override
  String get type => 'screencast-frame';

  @override
  Map<String, dynamic> toJson() => _compact({
        'type': type,
        'pageId': pageId,
        'file': file,
        'width': width,
        'height': height,
        'timestamp': timestamp,
        'frameSwapWallTime': frameSwapWallTime,
      });
}

/// `video`: a video file recorded for a page.
class VideoTraceEvent extends TraceEvent {
  String pageId;
  String file;
  int width;
  int height;
  double timestamp;

  VideoTraceEvent({
    required this.pageId,
    required this.file,
    required this.width,
    required this.height,
    required this.timestamp,
  });

  factory VideoTraceEvent.fromJson(Map<String, dynamic> json) =>
      VideoTraceEvent(
        pageId: json['pageId'] as String? ?? '',
        file: json['file'] as String? ?? '',
        width: _int(json['width']) ?? 0,
        height: _int(json['height']) ?? 0,
        timestamp: _double(json['timestamp']) ?? 0,
      );

  @override
  String get type => 'video';

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'pageId': pageId,
        'file': file,
        'width': width,
        'height': height,
        'timestamp': timestamp,
      };
}

/// `screenshot`: a PNG taken at one phase of one action.
class ScreenshotTraceEvent extends TraceEvent {
  String callId;
  ActionPhase? phase;
  String pageId;
  double timestamp;
  String file;

  ScreenshotTraceEvent({
    required this.callId,
    required this.phase,
    required this.pageId,
    required this.timestamp,
    required this.file,
  });

  factory ScreenshotTraceEvent.fromJson(Map<String, dynamic> json) =>
      ScreenshotTraceEvent(
        callId: json['callId'] as String? ?? '',
        phase: ActionPhase.fromWire(json['phase']),
        pageId: json['pageId'] as String? ?? '',
        timestamp: _double(json['timestamp']) ?? 0,
        file: json['file'] as String? ?? '',
      );

  @override
  String get type => 'screenshot';

  @override
  Map<String, dynamic> toJson() => _compact({
        'type': type,
        'callId': callId,
        'phase': phase?.wire,
        'pageId': pageId,
        'timestamp': timestamp,
        'file': file,
      });
}

/// `aria-snapshot`: the accessibility tree at one phase of one action.
class AriaSnapshotTraceEvent extends TraceEvent {
  String callId;
  ActionPhase? phase;
  String pageId;
  double timestamp;
  String file;

  AriaSnapshotTraceEvent({
    required this.callId,
    required this.phase,
    required this.pageId,
    required this.timestamp,
    required this.file,
  });

  factory AriaSnapshotTraceEvent.fromJson(Map<String, dynamic> json) =>
      AriaSnapshotTraceEvent(
        callId: json['callId'] as String? ?? '',
        phase: ActionPhase.fromWire(json['phase']),
        pageId: json['pageId'] as String? ?? '',
        timestamp: _double(json['timestamp']) ?? 0,
        file: json['file'] as String? ?? '',
      );

  @override
  String get type => 'aria-snapshot';

  @override
  Map<String, dynamic> toJson() => _compact({
        'type': type,
        'callId': callId,
        'phase': phase?.wire,
        'pageId': pageId,
        'timestamp': timestamp,
        'file': file,
      });
}

/// `before`: an action started.
class BeforeActionTraceEvent extends TraceEvent {
  String callId;
  double startTime;
  String? title;
  String? subtitle;

  /// The protocol class, e.g. `Frame`.
  String className;

  /// The protocol method, e.g. `click`.
  String method;
  Map<String, dynamic> params;
  List<StackFrame>? stack;
  String? parentId;
  String? group;

  BeforeActionTraceEvent({
    required this.callId,
    required this.startTime,
    this.title,
    this.subtitle,
    required this.className,
    required this.method,
    required this.params,
    this.stack,
    this.parentId,
    this.group,
  });

  factory BeforeActionTraceEvent.fromJson(Map<String, dynamic> json) =>
      BeforeActionTraceEvent(
        callId: json['callId'] as String? ?? '',
        startTime: _double(json['startTime']) ?? 0,
        title: json['title'] as String?,
        subtitle: json['subtitle'] as String?,
        className: json['class'] as String? ?? '',
        method: json['method'] as String? ?? '',
        params: _map(json['params']) ?? <String, dynamic>{},
        stack: parseStackFrames(json['stack']),
        parentId: json['parentId'] as String?,
        group: json['group'] as String?,
      );

  @override
  String get type => 'before';

  @override
  Map<String, dynamic> toJson() => _compact({
        'type': type,
        'callId': callId,
        'startTime': startTime,
        'title': title,
        'subtitle': subtitle,
        'class': className,
        'method': method,
        'params': params,
        'stack': stack?.map((e) => e.toJson()).toList(),
        'parentId': parentId,
        'group': group,
      });
}

/// Parses a `stack` field, which is absent on most events.
List<StackFrame>? parseStackFrames(Object? value) => (value as List?)
    ?.map((e) => StackFrame.fromJson((e as Map).cast<String, dynamic>()))
    .toList();

/// `input`: the point and box an input action resolved to.
class InputActionTraceEvent extends TraceEvent {
  String callId;
  TracePoint? point;
  TraceRect? box;

  InputActionTraceEvent({required this.callId, this.point, this.box});

  factory InputActionTraceEvent.fromJson(Map<String, dynamic> json) =>
      InputActionTraceEvent(
        callId: json['callId'] as String? ?? '',
        point: json['point'] == null
            ? null
            : TracePoint.fromJson(_map(json['point'])!),
        box:
            json['box'] == null ? null : TraceRect.fromJson(_map(json['box'])!),
      );

  @override
  String get type => 'input';

  @override
  Map<String, dynamic> toJson() => _compact({
        'type': type,
        'callId': callId,
        'point': point?.toJson(),
        'box': box?.toJson(),
      });
}

/// `AfterActionTraceEventAttachment`: a file or blob attached to an action.
class AfterActionTraceEventAttachment {
  String name;
  String contentType;
  String? path;

  /// Trace-relative path of the blob; `sha1` in traces older than version 9.
  String? file;
  String? base64;

  AfterActionTraceEventAttachment({
    required this.name,
    required this.contentType,
    this.path,
    this.file,
    this.base64,
  });

  factory AfterActionTraceEventAttachment.fromJson(Map<String, dynamic> json) =>
      AfterActionTraceEventAttachment(
        name: json['name'] as String? ?? '',
        contentType: json['contentType'] as String? ?? '',
        path: json['path'] as String?,
        file: json['file'] as String?,
        base64: json['base64'] as String?,
      );

  Map<String, dynamic> toJson() => _compact({
        'name': name,
        'contentType': contentType,
        'path': path,
        'file': file,
        'base64': base64,
      });
}

/// `after`: an action finished, with its error and attachments.
class AfterActionTraceEvent extends TraceEvent {
  String callId;
  double endTime;
  TraceError? error;
  List<AfterActionTraceEventAttachment>? attachments;
  List<TraceEventAnnotation>? annotations;
  Object? result;
  TracePoint? point;

  AfterActionTraceEvent({
    required this.callId,
    required this.endTime,
    this.error,
    this.attachments,
    this.annotations,
    this.result,
    this.point,
  });

  factory AfterActionTraceEvent.fromJson(Map<String, dynamic> json) =>
      AfterActionTraceEvent(
        callId: json['callId'] as String? ?? '',
        endTime: _double(json['endTime']) ?? 0,
        error: json['error'] == null
            ? null
            : TraceError.fromJson(_map(json['error'])!),
        attachments: parseAttachments(json['attachments']),
        annotations: (json['annotations'] as List?)
            ?.map((e) => TraceEventAnnotation.fromJson((e as Map).cast()))
            .toList(),
        result: json['result'],
        point: json['point'] == null
            ? null
            : TracePoint.fromJson(_map(json['point'])!),
      );

  @override
  String get type => 'after';

  @override
  Map<String, dynamic> toJson() => _compact({
        'type': type,
        'callId': callId,
        'endTime': endTime,
        'error': error?.toJson(),
        'attachments': attachments?.map((e) => e.toJson()).toList(),
        'annotations': annotations?.map((e) => e.toJson()).toList(),
        'result': result,
        'point': point?.toJson(),
      });
}

/// Parses an `attachments` field, which is absent on most events.
List<AfterActionTraceEventAttachment>? parseAttachments(Object? value) =>
    (value as List?)
        ?.map((e) => AfterActionTraceEventAttachment.fromJson(
            (e as Map).cast<String, dynamic>()))
        .toList();

/// `log`: one line of the action log.
class LogTraceEvent extends TraceEvent {
  String callId;
  double time;
  String message;

  LogTraceEvent({
    required this.callId,
    required this.time,
    required this.message,
  });

  factory LogTraceEvent.fromJson(Map<String, dynamic> json) => LogTraceEvent(
        callId: json['callId'] as String? ?? '',
        time: _double(json['time']) ?? 0,
        message: json['message'] as String? ?? '',
      );

  @override
  String get type => 'log';

  @override
  Map<String, dynamic> toJson() =>
      {'type': type, 'callId': callId, 'time': time, 'message': message};
}

/// An event that sits on the timeline by its own `time`: `event` and
/// `console`.
///
/// Upstream keeps the two in one list typed
/// `(EventTraceEvent | ConsoleMessageTraceEvent)[]`, sorts it by `time` and
/// shifts every `time` when two traces are merged. Dart has no union, so the
/// two share a base instead.
sealed class TimelineTraceEvent extends TraceEvent {
  double time;

  TimelineTraceEvent({required this.time});
}

/// `event`: something the browser reported outside an action — a navigation,
/// a page error, a dialog.
class EventTraceEvent extends TimelineTraceEvent {
  /// The protocol class, e.g. `BrowserContext`.
  String className;
  String method;
  Object? params;
  String? pageId;

  EventTraceEvent({
    required super.time,
    required this.className,
    required this.method,
    this.params,
    this.pageId,
  });

  factory EventTraceEvent.fromJson(Map<String, dynamic> json) =>
      EventTraceEvent(
        time: _double(json['time']) ?? 0,
        className: json['class'] as String? ?? '',
        method: json['method'] as String? ?? '',
        params: json['params'],
        pageId: json['pageId'] as String?,
      );

  /// `params` as a map, or an empty map when the event carried something else.
  Map<String, dynamic> get paramsMap =>
      params is Map ? (params as Map).cast<String, dynamic>() : const {};

  @override
  String get type => 'event';

  @override
  Map<String, dynamic> toJson() => _compact({
        'type': type,
        'time': time,
        'class': className,
        'method': method,
        'params': params,
        'pageId': pageId,
      });
}

/// The source location of a console message.
class ConsoleMessageLocation {
  String url;
  int lineNumber;
  int columnNumber;

  ConsoleMessageLocation({
    required this.url,
    required this.lineNumber,
    required this.columnNumber,
  });

  factory ConsoleMessageLocation.fromJson(Map<String, dynamic> json) =>
      ConsoleMessageLocation(
        url: json['url'] as String? ?? '',
        lineNumber: _int(json['lineNumber']) ?? 0,
        columnNumber: _int(json['columnNumber']) ?? 0,
      );

  Map<String, dynamic> toJson() =>
      {'url': url, 'lineNumber': lineNumber, 'columnNumber': columnNumber};
}

/// One argument of a console message: a preview string and the raw value.
class ConsoleMessageArg {
  String preview;
  Object? value;

  ConsoleMessageArg({required this.preview, this.value});

  factory ConsoleMessageArg.fromJson(Map<String, dynamic> json) =>
      ConsoleMessageArg(
        preview: json['preview'] as String? ?? '',
        value: json['value'],
      );

  Map<String, dynamic> toJson() => {'preview': preview, 'value': value};
}

/// `console`: a message the page logged.
class ConsoleMessageTraceEvent extends TimelineTraceEvent {
  String? pageId;
  String messageType;
  String text;
  List<ConsoleMessageArg>? args;
  ConsoleMessageLocation location;

  ConsoleMessageTraceEvent({
    required super.time,
    this.pageId,
    required this.messageType,
    required this.text,
    this.args,
    required this.location,
  });

  factory ConsoleMessageTraceEvent.fromJson(Map<String, dynamic> json) =>
      ConsoleMessageTraceEvent(
        time: _double(json['time']) ?? 0,
        pageId: json['pageId'] as String?,
        messageType: json['messageType'] as String? ?? '',
        text: json['text'] as String? ?? '',
        args: (json['args'] as List?)
            ?.map((e) => ConsoleMessageArg.fromJson((e as Map).cast()))
            .toList(),
        location: ConsoleMessageLocation.fromJson(
            _map(json['location']) ?? <String, dynamic>{}),
      );

  @override
  String get type => 'console';

  @override
  Map<String, dynamic> toJson() => _compact({
        'type': type,
        'time': time,
        'pageId': pageId,
        'messageType': messageType,
        'text': text,
        'args': args?.map((e) => e.toJson()).toList(),
        'location': location.toJson(),
      });
}

/// `ResourceSnapshot` is a HAR entry.
typedef ResourceSnapshot = HarEntry;

/// `resource-snapshot`: one line of `trace.network`.
class ResourceSnapshotTraceEvent extends TraceEvent {
  ResourceSnapshot snapshot;

  ResourceSnapshotTraceEvent({required this.snapshot});

  factory ResourceSnapshotTraceEvent.fromJson(Map<String, dynamic> json) =>
      ResourceSnapshotTraceEvent(
        snapshot: HarEntry.fromJson(_map(json['snapshot'])!),
      );

  @override
  String get type => 'resource-snapshot';

  @override
  Map<String, dynamic> toJson() =>
      {'type': type, 'snapshot': snapshot.toJson()};
}

/// A node of a captured DOM tree.
///
/// Stays raw JSON, exactly as upstream keeps it, because the shape is a
/// three-way union that a typed tree would only have to unpack again:
///
/// - a `String` is a text node;
/// - a `[[n, i]]` is a subtree reference, "n snapshots ago, node #i", the
///   cache this port's own snapshotter emits;
/// - a `[name]` or `[name, attrs, ...children]` is an element.
typedef NodeSnapshot = Object;

/// True when [n] is a text node.
bool isTextNodeSnapshot(Object? n) => n is String;

/// True when [n] is a `[[n, i]]` subtree reference.
bool isSubtreeReferenceSnapshot(Object? n) =>
    n is List && n.isNotEmpty && n[0] is List;

/// True when [n] is `[name]` or `[name, attrs, ...children]`.
bool isNodeNameAttributesChildNodesSnapshot(Object? n) =>
    n is List && n.isNotEmpty && n[0] is String;

/// `ResourceOverride`: a resource whose body differs in this snapshot, either
/// by pointing at a blob (`file`) or at the body used `ref` snapshots ago.
class ResourceOverride {
  String url;
  String? file;
  int? ref;

  ResourceOverride({required this.url, this.file, this.ref});

  factory ResourceOverride.fromJson(Map<String, dynamic> json) =>
      ResourceOverride(
        url: json['url'] as String? ?? '',
        file: json['file'] as String?,
        ref: _int(json['ref']),
      );

  Map<String, dynamic> toJson() =>
      _compact({'url': url, 'file': file, 'ref': ref});
}

/// `FrameSnapshot`: one captured DOM tree of one frame.
class FrameSnapshot {
  ActionPhase? phase;

  /// Legacy, only present in traces recorded before `phase` was introduced.
  String? snapshotName;
  String callId;
  String pageId;
  String frameId;
  String frameUrl;
  double timestamp;
  double? wallTime;
  double collectionTime;
  String? doctype;
  NodeSnapshot html;
  List<ResourceOverride> resourceOverrides;
  TraceSize viewport;
  bool isMainFrame;

  /// The post-order list of nodes of [html], computed once and kept here.
  ///
  /// Upstream stashes the same list on the snapshot object as `_nodes`. It is
  /// what a `[[n, i]]` reference indexes into.
  List<NodeSnapshot>? cachedNodes;

  FrameSnapshot({
    this.phase,
    this.snapshotName,
    required this.callId,
    required this.pageId,
    required this.frameId,
    required this.frameUrl,
    required this.timestamp,
    this.wallTime,
    required this.collectionTime,
    this.doctype,
    required this.html,
    required this.resourceOverrides,
    required this.viewport,
    required this.isMainFrame,
  });

  factory FrameSnapshot.fromJson(Map<String, dynamic> json) => FrameSnapshot(
        phase: ActionPhase.fromWire(json['phase']),
        snapshotName: json['snapshotName'] as String?,
        callId: json['callId'] as String? ?? '',
        pageId: json['pageId'] as String? ?? '',
        frameId: json['frameId'] as String? ?? '',
        frameUrl: json['frameUrl'] as String? ?? '',
        timestamp: _double(json['timestamp']) ?? 0,
        wallTime: _double(json['wallTime']),
        collectionTime: _double(json['collectionTime']) ?? 0,
        doctype: json['doctype'] as String?,
        html: json['html'] as Object? ?? '',
        resourceOverrides: (json['resourceOverrides'] as List?)
                ?.map((e) => ResourceOverride.fromJson((e as Map).cast()))
                .toList() ??
            <ResourceOverride>[],
        viewport: TraceSize.fromJson(_map(json['viewport']) ?? const {}),
        isMainFrame: json['isMainFrame'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => _compact({
        'phase': phase?.wire,
        'snapshotName': snapshotName,
        'callId': callId,
        'pageId': pageId,
        'frameId': frameId,
        'frameUrl': frameUrl,
        'timestamp': timestamp,
        'wallTime': wallTime,
        'collectionTime': collectionTime,
        'doctype': doctype,
        'html': html,
        'resourceOverrides': resourceOverrides.map((e) => e.toJson()).toList(),
        'viewport': viewport.toJson(),
        'isMainFrame': isMainFrame,
      });
}

/// `frame-snapshot`: a captured DOM tree.
class FrameSnapshotTraceEvent extends TraceEvent {
  FrameSnapshot snapshot;

  FrameSnapshotTraceEvent({required this.snapshot});

  factory FrameSnapshotTraceEvent.fromJson(Map<String, dynamic> json) =>
      FrameSnapshotTraceEvent(
        snapshot: FrameSnapshot.fromJson(_map(json['snapshot'])!),
      );

  @override
  String get type => 'frame-snapshot';

  @override
  Map<String, dynamic> toJson() =>
      {'type': type, 'snapshot': snapshot.toJson()};
}

/// `action`: a whole action on one line.
///
/// This is `before`, `input` and `after` merged; the library writes the three
/// separately, but a trace modernized from version 3 produces these.
class ActionTraceEvent extends TraceEvent {
  String callId;
  double startTime;
  double endTime;
  String? title;
  String? subtitle;
  String className;
  String method;
  Map<String, dynamic> params;
  List<StackFrame>? stack;
  String? parentId;
  String? group;
  TracePoint? point;
  TraceRect? box;
  TraceError? error;
  List<AfterActionTraceEventAttachment>? attachments;
  List<TraceEventAnnotation>? annotations;
  Object? result;

  ActionTraceEvent({
    required this.callId,
    required this.startTime,
    required this.endTime,
    this.title,
    this.subtitle,
    required this.className,
    required this.method,
    required this.params,
    this.stack,
    this.parentId,
    this.group,
    this.point,
    this.box,
    this.error,
    this.attachments,
    this.annotations,
    this.result,
  });

  factory ActionTraceEvent.fromJson(Map<String, dynamic> json) =>
      ActionTraceEvent(
        callId: json['callId'] as String? ?? '',
        startTime: _double(json['startTime']) ?? 0,
        endTime: _double(json['endTime']) ?? 0,
        title: json['title'] as String?,
        subtitle: json['subtitle'] as String?,
        className: json['class'] as String? ?? '',
        method: json['method'] as String? ?? '',
        params: _map(json['params']) ?? <String, dynamic>{},
        stack: parseStackFrames(json['stack']),
        parentId: json['parentId'] as String?,
        group: json['group'] as String?,
        point: json['point'] == null
            ? null
            : TracePoint.fromJson(_map(json['point'])!),
        box:
            json['box'] == null ? null : TraceRect.fromJson(_map(json['box'])!),
        error: json['error'] == null
            ? null
            : TraceError.fromJson(_map(json['error'])!),
        attachments: parseAttachments(json['attachments']),
        annotations: (json['annotations'] as List?)
            ?.map((e) => TraceEventAnnotation.fromJson((e as Map).cast()))
            .toList(),
        result: json['result'],
      );

  @override
  String get type => 'action';

  @override
  Map<String, dynamic> toJson() => _compact({
        'type': type,
        'callId': callId,
        'startTime': startTime,
        'endTime': endTime,
        'title': title,
        'subtitle': subtitle,
        'class': className,
        'method': method,
        'params': params,
        'stack': stack?.map((e) => e.toJson()).toList(),
        'parentId': parentId,
        'group': group,
        'point': point?.toJson(),
        'box': box?.toJson(),
        'error': error?.toJson(),
        'attachments': attachments?.map((e) => e.toJson()).toList(),
        'annotations': annotations?.map((e) => e.toJson()).toList(),
        'result': result,
      });
}

/// `stdout` or `stderr`: output the test runner captured.
class StdioTraceEvent extends TraceEvent {
  /// `stdout` or `stderr`.
  String stream;
  double timestamp;
  String? text;
  String? base64;

  StdioTraceEvent({
    required this.stream,
    required this.timestamp,
    this.text,
    this.base64,
  });

  factory StdioTraceEvent.fromJson(Map<String, dynamic> json) =>
      StdioTraceEvent(
        stream: json['type'] as String? ?? 'stdout',
        timestamp: _double(json['timestamp']) ?? 0,
        text: json['text'] as String?,
        base64: json['base64'] as String?,
      );

  @override
  String get type => stream;

  @override
  Map<String, dynamic> toJson() => _compact({
        'type': stream,
        'timestamp': timestamp,
        'text': text,
        'base64': base64,
      });
}

/// `error`: a failure the test runner reported, outside any single action.
class ErrorTraceEvent extends TraceEvent {
  String message;
  List<StackFrame>? stack;

  ErrorTraceEvent({required this.message, this.stack});

  factory ErrorTraceEvent.fromJson(Map<String, dynamic> json) =>
      ErrorTraceEvent(
        message: json['message'] as String? ?? '',
        stack: parseStackFrames(json['stack']),
      );

  @override
  String get type => 'error';

  @override
  Map<String, dynamic> toJson() => _compact({
        'type': type,
        'message': message,
        'stack': stack?.map((e) => e.toJson()).toList(),
      });
}

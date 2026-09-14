// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/trace/versions/traceV9.ts (identical in
// traceV10.ts for every event this recorder emits).

/// The trace format version written into the `context-options` event.
///
/// Upstream numbers the format and ships a modernizer (`traceModernizer.ts`,
/// `_modernize_3_to_4` .. `_modernize_9_to_10`) so the viewer reads older
/// traces. That makes the *floor* stable, not the ceiling: a viewer refuses a
/// trace whose version is newer than the one it knows, with
/// `TraceVersionError`.
///
/// Version 10 exists only in upstream's unreleased tree (`1.64.0-next`); the
/// newest published viewer, `playwright@1.63.0`, stops at 9 and would reject a
/// 10. So this recorder writes 9, which is the current *released* format.
///
/// This is not a downgrade: `_modernize_9_to_10` only rewrites the `stepId`
/// side-channel that the test runner used to mint, and this recorder never
/// emits `stepId`. Run the 9 we write through the modernizer of a viewer that
/// knows 10 and nothing changes.
const int kTraceVersion = 9;

/// A monotonic clock shared by every trace event, in milliseconds.
///
/// The viewer maps monotonic times onto the wall clock using the
/// `wallTime`/`monotonicTime` pair of the `context-options` event, so every
/// timestamp in one trace has to come from the same clock.
class TraceClock {
  static final Stopwatch _stopwatch = Stopwatch()..start();

  /// Milliseconds since this process started tracing time, as a double.
  static double monotonicTime() => _stopwatch.elapsedMicroseconds / 1000.0;

  /// Milliseconds since the Unix epoch.
  static int wallTime() => DateTime.now().millisecondsSinceEpoch;
}

/// Drops the null-valued keys so the JSON matches what upstream writes, where
/// an absent optional field is simply not serialized.
Map<String, dynamic> _compact(Map<String, dynamic> map) {
  map.removeWhere((_, value) => value == null);
  return map;
}

/// One frame of the caller's stack, as the viewer's Source tab wants it.
class TraceStackFrame {
  final String file;
  final int line;
  final int column;
  final String? function;

  const TraceStackFrame({
    required this.file,
    required this.line,
    required this.column,
    this.function,
  });

  Map<String, dynamic> toJson() => _compact({
        'file': file,
        'line': line,
        'column': column,
        'function': function,
      });
}

/// `BrowserContextEventOptions` of the contract: the context options the
/// viewer shows and uses to size the snapshot viewport.
class TraceContextOptions {
  final String? baseURL;
  final ({int width, int height})? viewport;
  final double? deviceScaleFactor;
  final bool? isMobile;
  final String? userAgent;

  const TraceContextOptions({
    this.baseURL,
    this.viewport,
    this.deviceScaleFactor,
    this.isMobile,
    this.userAgent,
  });

  Map<String, dynamic> toJson() => _compact({
        'baseURL': baseURL,
        'viewport': viewport == null
            ? null
            : {'width': viewport!.width, 'height': viewport!.height},
        'deviceScaleFactor': deviceScaleFactor,
        'isMobile': isMobile,
        'userAgent': userAgent,
      });
}

/// Base of every line of `trace.trace` and `trace.network`.
abstract class TraceEvent {
  const TraceEvent();
  Map<String, dynamic> toJson();
}

/// `context-options`: the first line of every chunk. Carries the version gate
/// and the clock origin.
class ContextCreatedTraceEvent extends TraceEvent {
  final int version;
  final String origin;
  final String browserName;
  final String? channel;
  final String platform;
  final String? playwrightVersion;
  final int wallTime;
  final double monotonicTime;
  final String? title;
  final TraceContextOptions options;
  final String? sdkLanguage;
  final String? testIdAttributeName;

  const ContextCreatedTraceEvent({
    this.version = kTraceVersion,
    this.origin = 'library',
    required this.browserName,
    this.channel,
    required this.platform,
    this.playwrightVersion,
    required this.wallTime,
    required this.monotonicTime,
    this.title,
    this.options = const TraceContextOptions(),
    this.sdkLanguage,
    this.testIdAttributeName,
  });

  @override
  Map<String, dynamic> toJson() => _compact({
        'version': version,
        'type': 'context-options',
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
      });
}

/// `before`: an API call started. The viewer opens a row in the action list.
class BeforeActionTraceEvent extends TraceEvent {
  final String callId;
  final double startTime;
  final String? title;
  final String klass;
  final String method;
  final Map<String, dynamic> params;
  final List<TraceStackFrame>? stack;
  final String? parentId;

  const BeforeActionTraceEvent({
    required this.callId,
    required this.startTime,
    this.title,
    required this.klass,
    required this.method,
    this.params = const {},
    this.stack,
    this.parentId,
  });

  @override
  Map<String, dynamic> toJson() => _compact({
        'type': 'before',
        'callId': callId,
        'startTime': startTime,
        'title': title,
        'class': klass,
        'method': method,
        'params': params,
        'stack': stack?.map((frame) => frame.toJson()).toList(),
        'parentId': parentId,
      });
}

/// `input`: where an input action actually landed. Drives the red dot the
/// viewer draws over the snapshot.
class InputActionTraceEvent extends TraceEvent {
  final String callId;
  final ({double x, double y})? point;
  final ({double x, double y, double width, double height})? box;

  const InputActionTraceEvent({required this.callId, this.point, this.box});

  @override
  Map<String, dynamic> toJson() => _compact({
        'type': 'input',
        'callId': callId,
        'point': point == null ? null : {'x': point!.x, 'y': point!.y},
        'box': box == null
            ? null
            : {
                'x': box!.x,
                'y': box!.y,
                'width': box!.width,
                'height': box!.height,
              },
      });
}

/// `after`: the call finished, with its error when it threw.
class AfterActionTraceEvent extends TraceEvent {
  final String callId;
  final double endTime;
  final ({String message, String name, String? stack})? error;
  final Map<String, dynamic>? result;

  const AfterActionTraceEvent({
    required this.callId,
    required this.endTime,
    this.error,
    this.result,
  });

  @override
  Map<String, dynamic> toJson() => _compact({
        'type': 'after',
        'callId': callId,
        'endTime': endTime,
        'error': error == null
            ? null
            : _compact({
                'message': error!.message,
                'name': error!.name,
                'stack': error!.stack,
              }),
        'result': result,
      });
}

/// `log`: a line under an action, the way upstream's `api` log reads.
class LogTraceEvent extends TraceEvent {
  final String callId;
  final double time;
  final String message;

  const LogTraceEvent({
    required this.callId,
    required this.time,
    required this.message,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'log',
        'callId': callId,
        'time': time,
        'message': message,
      };
}

/// `event`: everything the context announced that is not an API call — pages
/// opening and closing, dialogs, downloads, page errors.
class EventTraceEvent extends TraceEvent {
  final double time;
  final String klass;
  final String method;
  final Map<String, dynamic> params;
  final String? pageId;

  const EventTraceEvent({
    required this.time,
    required this.klass,
    required this.method,
    this.params = const {},
    this.pageId,
  });

  @override
  Map<String, dynamic> toJson() => _compact({
        'type': 'event',
        'time': time,
        'class': klass,
        'method': method,
        'params': params,
        'pageId': pageId,
      });
}

/// `console`: one `console.*` call made by a page.
class ConsoleMessageTraceEvent extends TraceEvent {
  final double time;
  final String? pageId;
  final String messageType;
  final String text;
  final String url;
  final int lineNumber;
  final int columnNumber;

  const ConsoleMessageTraceEvent({
    required this.time,
    this.pageId,
    required this.messageType,
    required this.text,
    this.url = '',
    this.lineNumber = 0,
    this.columnNumber = 0,
  });

  @override
  Map<String, dynamic> toJson() => _compact({
        'type': 'console',
        'time': time,
        'pageId': pageId,
        'messageType': messageType,
        'text': text,
        'location': {
          'url': url,
          'lineNumber': lineNumber,
          'columnNumber': columnNumber,
        },
      });
}

/// `screenshot`: a PNG captured around an action, referenced by file name.
class ScreenshotTraceEvent extends TraceEvent {
  final String callId;
  final String phase;
  final String pageId;
  final double timestamp;
  final String file;

  const ScreenshotTraceEvent({
    required this.callId,
    required this.phase,
    required this.pageId,
    required this.timestamp,
    required this.file,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'screenshot',
        'callId': callId,
        'phase': phase,
        'pageId': pageId,
        'timestamp': timestamp,
        'file': file,
      };
}

/// `screencast-frame`: one frame of the filmstrip that runs along the top of
/// the viewer.
///
/// [file] names a resource inside the archive — a JPEG, because that is what
/// the engines' screencast domains produce and what upstream writes. The
/// viewer draws the strip from these and picks the frame nearest the cursor
/// by [timestamp], so the times have to come from the same monotonic clock as
/// the actions.
class ScreencastFrameTraceEvent extends TraceEvent {
  final String pageId;
  final String file;
  final int width;
  final int height;
  final double timestamp;

  /// When the browser swapped the frame, in wall-clock milliseconds. Only the
  /// engines that report it fill this in; the viewer treats it as optional.
  final int? frameSwapWallTime;

  const ScreencastFrameTraceEvent({
    required this.pageId,
    required this.file,
    required this.width,
    required this.height,
    required this.timestamp,
    this.frameSwapWallTime,
  });

  @override
  Map<String, dynamic> toJson() => _compact({
        'type': 'screencast-frame',
        'pageId': pageId,
        'file': file,
        'width': width,
        'height': height,
        'timestamp': timestamp,
        'frameSwapWallTime': frameSwapWallTime,
      });
}

/// `resource-snapshot`: one HAR entry, written to `trace.network`.
class ResourceSnapshotTraceEvent extends TraceEvent {
  final Map<String, dynamic> snapshot;

  const ResourceSnapshotTraceEvent(this.snapshot);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'resource-snapshot',
        'snapshot': snapshot,
      };
}

/// `frame-snapshot`: the serialized DOM of one frame at one phase of one
/// action. This is what the viewer renders in the snapshot pane.
class FrameSnapshotTraceEvent extends TraceEvent {
  final Map<String, dynamic> snapshot;

  const FrameSnapshotTraceEvent(this.snapshot);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'frame-snapshot',
        'snapshot': snapshot,
      };
}

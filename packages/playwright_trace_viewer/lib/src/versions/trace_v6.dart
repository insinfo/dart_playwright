// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/trace/versions/traceV6.ts

/// Version 6 of the trace format, released in ~1.40.
///
/// The action log leaves the `after` event and becomes its own `log` event,
/// one per line, so a long-running action can report progress while it runs.
/// `after` gains `point`, and a `error` event appears for failures the runner
/// reports outside any one action.
///
/// This is the version the modernizer assumes when a trace has no version at
/// all in its first entry — test traces before 7 did not write one.
library;

import 'trace_v3.dart' show StackFrameV3, PointV3;

export 'trace_v3.dart' show StackFrameV3, PointV3, ResourceOverrideV3;
export 'trace_v4.dart'
    show
        FrameSnapshotV4,
        BrowserContextEventOptionsV4,
        ScreencastFrameTraceEventV4,
        BeforeActionTraceEventV4,
        InputActionTraceEventV4,
        AfterActionTraceEventAttachmentV4,
        EventTraceEventV4,
        ResourceSnapshotTraceEventV4,
        FrameSnapshotTraceEventV4,
        StdioTraceEventV4;
export 'trace_v5.dart' show ConsoleMessageArgV5, ConsoleMessageTraceEventV5;

Map<String, dynamic> _compact(Map<String, dynamic> map) {
  map.removeWhere((_, value) => value == null);
  return map;
}

/// `context-options`, identical to version 5 but declaring version 6.
class ContextCreatedTraceEventV6 {
  final int version;
  final String browserName;
  final String? channel;
  final String platform;
  final num wallTime;
  final String? title;
  final Map<String, dynamic> options;
  final String? sdkLanguage;
  final String? testIdAttributeName;

  const ContextCreatedTraceEventV6({
    this.version = 6,
    required this.browserName,
    this.channel,
    required this.platform,
    required this.wallTime,
    this.title,
    this.options = const {},
    this.sdkLanguage,
    this.testIdAttributeName,
  });

  Map<String, dynamic> toJson() => _compact({
        'version': version,
        'type': 'context-options',
        'browserName': browserName,
        'channel': channel,
        'platform': platform,
        'wallTime': wallTime,
        'title': title,
        'options': options,
        'sdkLanguage': sdkLanguage,
        'testIdAttributeName': testIdAttributeName,
      });
}

/// `after`. `log` is gone, `point` arrives.
class AfterActionTraceEventV6 {
  final String callId;
  final double endTime;
  final String? afterSnapshot;
  final Map<String, dynamic>? error;
  final List<Map<String, dynamic>>? attachments;
  final Object? result;
  final PointV3? point;

  const AfterActionTraceEventV6({
    required this.callId,
    required this.endTime,
    this.afterSnapshot,
    this.error,
    this.attachments,
    this.result,
    this.point,
  });

  Map<String, dynamic> toJson() => _compact({
        'type': 'after',
        'callId': callId,
        'endTime': endTime,
        'afterSnapshot': afterSnapshot,
        'error': error,
        'attachments': attachments,
        'result': result,
        'point': point?.toJson(),
      });
}

/// `log`: one line of the action log, with a time of its own.
class LogTraceEventV6 {
  final String callId;
  final double time;
  final String message;

  const LogTraceEventV6({
    required this.callId,
    required this.time,
    required this.message,
  });

  Map<String, dynamic> toJson() =>
      {'type': 'log', 'callId': callId, 'time': time, 'message': message};
}

/// `error`: a failure outside any single action.
class ErrorTraceEventV6 {
  final String message;
  final List<StackFrameV3>? stack;

  const ErrorTraceEventV6({required this.message, this.stack});

  Map<String, dynamic> toJson() => _compact({
        'type': 'error',
        'message': message,
        'stack': stack?.map((e) => e.toJson()).toList(),
      });
}

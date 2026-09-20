// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/trace/versions/traceV8.ts

/// Version 8 of the trace format, released in 1.53.
///
/// `apiName` becomes `title`: the recorder stops sending a protocol name for
/// the viewer to prettify and sends the rendered string instead. `stepId`
/// stops being optional in practice — `_modernize_7_to_8` fills it with the
/// call id when the trace has none — which is what makes the version 10
/// merge of the two ids possible.
///
/// Version 8 also inlines the HAR types instead of importing them, freezing
/// the resource shape against later HAR changes; `har.dart` of this port
/// serves both, with the pre-9 `_sha1` fields handled by the modernizer.
library;

import 'trace_v3.dart' show StackFrameV3;

export 'trace_v3.dart' show StackFrameV3, PointV3, ResourceOverrideV3;
export 'trace_v4.dart'
    show
        AfterActionTraceEventAttachmentV4,
        EventTraceEventV4,
        InputActionTraceEventV4,
        ResourceSnapshotTraceEventV4,
        StdioTraceEventV4;
export 'trace_v5.dart' show ConsoleMessageArgV5, ConsoleMessageTraceEventV5;
export 'trace_v6.dart' show LogTraceEventV6, ErrorTraceEventV6;
export 'trace_v7.dart'
    show
        FrameSnapshotV7,
        FrameSnapshotTraceEventV7,
        BrowserContextEventOptionsV7,
        ScreencastFrameTraceEventV7,
        AfterActionTraceEventAnnotationV7,
        AfterActionTraceEventV7;

Map<String, dynamic> _compact(Map<String, dynamic> map) {
  map.removeWhere((_, value) => value == null);
  return map;
}

/// `context-options`, identical to version 7 but declaring version 8.
class ContextCreatedTraceEventV8 {
  final int version;

  /// `testRunner` or `library`.
  final String origin;
  final String browserName;
  final String? channel;
  final String platform;
  final num wallTime;
  final double monotonicTime;
  final String? title;
  final Map<String, dynamic> options;
  final String? sdkLanguage;
  final String? testIdAttributeName;
  final String? contextId;

  const ContextCreatedTraceEventV8({
    this.version = 8,
    required this.origin,
    required this.browserName,
    this.channel,
    required this.platform,
    required this.wallTime,
    required this.monotonicTime,
    this.title,
    this.options = const {},
    this.sdkLanguage,
    this.testIdAttributeName,
    this.contextId,
  });

  Map<String, dynamic> toJson() => _compact({
        'version': version,
        'type': 'context-options',
        'origin': origin,
        'browserName': browserName,
        'channel': channel,
        'platform': platform,
        'wallTime': wallTime,
        'monotonicTime': monotonicTime,
        'title': title,
        'options': options,
        'sdkLanguage': sdkLanguage,
        'testIdAttributeName': testIdAttributeName,
        'contextId': contextId,
      });
}

/// `before`. `apiName` becomes `title`.
class BeforeActionTraceEventV8 {
  final String callId;
  final double startTime;
  final String? title;

  /// The protocol class. Named `class` on the wire.
  final String className;
  final String method;
  final Map<String, dynamic> params;
  final String? stepId;
  final String? beforeSnapshot;
  final List<StackFrameV3>? stack;
  final String? pageId;
  final String? parentId;

  const BeforeActionTraceEventV8({
    required this.callId,
    required this.startTime,
    this.title,
    required this.className,
    required this.method,
    this.params = const {},
    this.stepId,
    this.beforeSnapshot,
    this.stack,
    this.pageId,
    this.parentId,
  });

  Map<String, dynamic> toJson() => _compact({
        'type': 'before',
        'callId': callId,
        'startTime': startTime,
        'title': title,
        'class': className,
        'method': method,
        'params': params,
        'stepId': stepId,
        'beforeSnapshot': beforeSnapshot,
        'stack': stack?.map((e) => e.toJson()).toList(),
        'pageId': pageId,
        'parentId': parentId,
      });
}

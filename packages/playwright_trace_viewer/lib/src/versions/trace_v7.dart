// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/trace/versions/traceV7.ts

/// Version 7 of the trace format, released in ~1.45.
///
/// Two traces can now be merged: the context declares an `origin` — the
/// library or the test runner — a `monotonicTime` that pairs with `wallTime`
/// to fix the clock origin, and a `contextId`. An action carries a `stepId`,
/// the side channel by which the runner's step and the library's call, each
/// with an id of its own, used to find each other.
///
/// `frame-snapshot` gains `wallTime`, `screencast-frame` gains
/// `frameSwapWallTime`, and the context options gain `baseURL`.
library;

import 'trace_v3.dart' show StackFrameV3, ResourceOverrideV3;

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

Map<String, dynamic> _compact(Map<String, dynamic> map) {
  map.removeWhere((_, value) => value == null);
  return map;
}

/// `FrameSnapshot`. Adds `wallTime`, which lets the filmstrip line a snapshot
/// up with a screencast frame across two processes.
class FrameSnapshotV7 {
  final String? snapshotName;
  final String callId;
  final String pageId;
  final String frameId;
  final String frameUrl;
  final double timestamp;
  final num? wallTime;
  final double collectionTime;
  final String? doctype;
  final Object html;
  final List<ResourceOverrideV3> resourceOverrides;
  final ({int width, int height}) viewport;
  final bool isMainFrame;

  const FrameSnapshotV7({
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
    this.resourceOverrides = const [],
    required this.viewport,
    required this.isMainFrame,
  });

  Map<String, dynamic> toJson() => _compact({
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
        'viewport': {'width': viewport.width, 'height': viewport.height},
        'isMainFrame': isMainFrame,
      });
}

/// `frame-snapshot`.
class FrameSnapshotTraceEventV7 {
  final FrameSnapshotV7 snapshot;

  const FrameSnapshotTraceEventV7({required this.snapshot});

  Map<String, dynamic> toJson() =>
      {'type': 'frame-snapshot', 'snapshot': snapshot.toJson()};
}

/// `BrowserContextEventOptions`. Adds `baseURL`.
class BrowserContextEventOptionsV7 {
  final String? baseURL;
  final ({int width, int height})? viewport;
  final double? deviceScaleFactor;
  final bool? isMobile;
  final String? userAgent;

  const BrowserContextEventOptionsV7({
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

/// `context-options`. Adds `origin`, `monotonicTime` and `contextId`.
class ContextCreatedTraceEventV7 {
  final int version;

  /// `testRunner` or `library`.
  final String origin;
  final String browserName;
  final String? channel;
  final String platform;
  final num wallTime;
  final double monotonicTime;
  final String? title;
  final BrowserContextEventOptionsV7 options;
  final String? sdkLanguage;
  final String? testIdAttributeName;
  final String? contextId;

  const ContextCreatedTraceEventV7({
    this.version = 7,
    required this.origin,
    required this.browserName,
    this.channel,
    required this.platform,
    required this.wallTime,
    required this.monotonicTime,
    this.title,
    this.options = const BrowserContextEventOptionsV7(),
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
        'options': options.toJson(),
        'sdkLanguage': sdkLanguage,
        'testIdAttributeName': testIdAttributeName,
        'contextId': contextId,
      });
}

/// `screencast-frame`. Adds `frameSwapWallTime`.
class ScreencastFrameTraceEventV7 {
  final String pageId;
  final String sha1;
  final int width;
  final int height;
  final double timestamp;
  final double? frameSwapWallTime;

  const ScreencastFrameTraceEventV7({
    required this.pageId,
    required this.sha1,
    required this.width,
    required this.height,
    required this.timestamp,
    this.frameSwapWallTime,
  });

  Map<String, dynamic> toJson() => _compact({
        'type': 'screencast-frame',
        'pageId': pageId,
        'sha1': sha1,
        'width': width,
        'height': height,
        'timestamp': timestamp,
        'frameSwapWallTime': frameSwapWallTime,
      });
}

/// `before`. `wallTime` is replaced by `stepId`.
class BeforeActionTraceEventV7 {
  final String callId;
  final double startTime;
  final String apiName;

  /// The protocol class. Named `class` on the wire.
  final String className;
  final String method;
  final Map<String, dynamic> params;
  final String? stepId;
  final String? beforeSnapshot;
  final List<StackFrameV3>? stack;
  final String? pageId;
  final String? parentId;

  const BeforeActionTraceEventV7({
    required this.callId,
    required this.startTime,
    required this.apiName,
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
        'apiName': apiName,
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

/// `AfterActionTraceEventAnnotation`.
class AfterActionTraceEventAnnotationV7 {
  final String type;
  final String? description;

  const AfterActionTraceEventAnnotationV7({
    required this.type,
    this.description,
  });

  Map<String, dynamic> toJson() =>
      _compact({'type': type, 'description': description});
}

/// `after`. Adds `annotations`.
class AfterActionTraceEventV7 {
  final String callId;
  final double endTime;
  final String? afterSnapshot;
  final Map<String, dynamic>? error;
  final List<Map<String, dynamic>>? attachments;
  final List<AfterActionTraceEventAnnotationV7>? annotations;
  final Object? result;
  final Map<String, dynamic>? point;

  const AfterActionTraceEventV7({
    required this.callId,
    required this.endTime,
    this.afterSnapshot,
    this.error,
    this.attachments,
    this.annotations,
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
        'annotations': annotations?.map((e) => e.toJson()).toList(),
        'result': result,
        'point': point,
      });
}

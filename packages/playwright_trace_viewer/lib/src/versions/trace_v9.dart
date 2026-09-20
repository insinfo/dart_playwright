// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/trace/versions/traceV9.ts

/// Version 9 of the trace format, released in 1.63, and the version this
/// port's own recorder writes.
///
/// It is the largest step of the chain:
///
/// - every blob stops being named by a bare `sha1` and becomes a
///   trace-relative `file` path (`resources/<sha1>`), on screencast frames,
///   attachments, resource overrides and HAR bodies alike;
/// - a snapshot stops being found by name and declares its own `phase`, so
///   `beforeSnapshot`, `inputSnapshot` and `afterSnapshot` leave the action;
/// - `screenshot`, `aria-snapshot` and `video` events appear;
/// - an action gains `subtitle`, `group` and `box`;
/// - a HAR entry marked with the boolean `_apiRequest` now references its
///   request context by `_apiRequestRef`, and a service worker by
///   `_serviceWorkerRef`;
/// - the context declares `playwrightVersion`, `testTimeout` and
///   `annotations`, and drops `contextId`.
///
/// `stepId` survives here and dies in version 10.
///
/// The typed reader for all of this lives in `trace_v10.dart`, which differs
/// from version 9 only by the absence of `stepId`; the classes here are
/// writers, for fixtures.
library;

import 'trace_v3.dart' show StackFrameV3, PointV3;

export 'trace_v3.dart' show StackFrameV3, PointV3;
export 'trace_v4.dart' show EventTraceEventV4, StdioTraceEventV4;
export 'trace_v5.dart' show ConsoleMessageArgV5, ConsoleMessageTraceEventV5;
export 'trace_v6.dart' show LogTraceEventV6, ErrorTraceEventV6;
export 'trace_v7.dart' show BrowserContextEventOptionsV7;

Map<String, dynamic> _compact(Map<String, dynamic> map) {
  map.removeWhere((_, value) => value == null);
  return map;
}

/// `TraceEventAnnotation`, renamed from `AfterActionTraceEventAnnotation`
/// because the context event carries these too.
class TraceEventAnnotationV9 {
  final String type;
  final String? description;

  const TraceEventAnnotationV9({required this.type, this.description});

  Map<String, dynamic> toJson() =>
      _compact({'type': type, 'description': description});
}

/// `context-options`. Adds `playwrightVersion`, `testTimeout` and
/// `annotations`; drops `contextId`.
class ContextCreatedTraceEventV9 {
  final int version;

  /// `testRunner` or `library`.
  final String origin;
  final String browserName;
  final String? channel;
  final String platform;
  final String? playwrightVersion;
  final num wallTime;
  final double monotonicTime;
  final String? title;
  final Map<String, dynamic> options;
  final String? sdkLanguage;
  final String? testIdAttributeName;
  final double? testTimeout;
  final List<TraceEventAnnotationV9>? annotations;

  const ContextCreatedTraceEventV9({
    this.version = 9,
    required this.origin,
    required this.browserName,
    this.channel,
    required this.platform,
    this.playwrightVersion,
    required this.wallTime,
    required this.monotonicTime,
    this.title,
    this.options = const {},
    this.sdkLanguage,
    this.testIdAttributeName,
    this.testTimeout,
    this.annotations,
  });

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
        'options': options,
        'sdkLanguage': sdkLanguage,
        'testIdAttributeName': testIdAttributeName,
        'testTimeout': testTimeout,
        'annotations': annotations?.map((e) => e.toJson()).toList(),
      });
}

/// `screencast-frame`. `sha1` becomes `file`.
class ScreencastFrameTraceEventV9 {
  final String pageId;
  final String file;
  final int width;
  final int height;
  final double timestamp;
  final double? frameSwapWallTime;

  const ScreencastFrameTraceEventV9({
    required this.pageId,
    required this.file,
    required this.width,
    required this.height,
    required this.timestamp,
    this.frameSwapWallTime,
  });

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

/// `video`.
class VideoTraceEventV9 {
  final String pageId;
  final String file;
  final int width;
  final int height;
  final double timestamp;

  const VideoTraceEventV9({
    required this.pageId,
    required this.file,
    required this.width,
    required this.height,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'type': 'video',
        'pageId': pageId,
        'file': file,
        'width': width,
        'height': height,
        'timestamp': timestamp,
      };
}

/// `screenshot`.
class ScreenshotTraceEventV9 {
  final String callId;

  /// `before`, `action` or `after`.
  final String phase;
  final String pageId;
  final double timestamp;
  final String file;

  const ScreenshotTraceEventV9({
    required this.callId,
    required this.phase,
    required this.pageId,
    required this.timestamp,
    required this.file,
  });

  Map<String, dynamic> toJson() => {
        'type': 'screenshot',
        'callId': callId,
        'phase': phase,
        'pageId': pageId,
        'timestamp': timestamp,
        'file': file,
      };
}

/// `aria-snapshot`.
class AriaSnapshotTraceEventV9 {
  final String callId;

  /// `before`, `action` or `after`.
  final String phase;
  final String pageId;
  final double timestamp;
  final String file;

  const AriaSnapshotTraceEventV9({
    required this.callId,
    required this.phase,
    required this.pageId,
    required this.timestamp,
    required this.file,
  });

  Map<String, dynamic> toJson() => {
        'type': 'aria-snapshot',
        'callId': callId,
        'phase': phase,
        'pageId': pageId,
        'timestamp': timestamp,
        'file': file,
      };
}

/// `before`. Adds `subtitle` and `group`; loses `beforeSnapshot` and
/// `pageId`; keeps `stepId`, which version 10 removes.
class BeforeActionTraceEventV9 {
  final String callId;
  final double startTime;
  final String? title;
  final String? subtitle;

  /// The protocol class. Named `class` on the wire.
  final String className;
  final String method;
  final Map<String, dynamic> params;
  final String? stepId;
  final List<StackFrameV3>? stack;
  final String? parentId;
  final String? group;

  const BeforeActionTraceEventV9({
    required this.callId,
    required this.startTime,
    this.title,
    this.subtitle,
    required this.className,
    required this.method,
    this.params = const {},
    this.stepId,
    this.stack,
    this.parentId,
    this.group,
  });

  Map<String, dynamic> toJson() => _compact({
        'type': 'before',
        'callId': callId,
        'startTime': startTime,
        'title': title,
        'subtitle': subtitle,
        'class': className,
        'method': method,
        'params': params,
        'stepId': stepId,
        'stack': stack?.map((e) => e.toJson()).toList(),
        'parentId': parentId,
        'group': group,
      });
}

/// `input`. Loses `inputSnapshot`, gains `box`.
class InputActionTraceEventV9 {
  final String callId;
  final PointV3? point;
  final ({double x, double y, int width, int height})? box;

  const InputActionTraceEventV9({required this.callId, this.point, this.box});

  Map<String, dynamic> toJson() => _compact({
        'type': 'input',
        'callId': callId,
        'point': point?.toJson(),
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

/// `AfterActionTraceEventAttachment`. `sha1` becomes `file`.
class AfterActionTraceEventAttachmentV9 {
  final String name;
  final String contentType;
  final String? path;
  final String? file;
  final String? base64;

  const AfterActionTraceEventAttachmentV9({
    required this.name,
    required this.contentType,
    this.path,
    this.file,
    this.base64,
  });

  Map<String, dynamic> toJson() => _compact({
        'name': name,
        'contentType': contentType,
        'path': path,
        'file': file,
        'base64': base64,
      });
}

/// `after`. Loses `afterSnapshot`.
class AfterActionTraceEventV9 {
  final String callId;
  final double endTime;
  final Map<String, dynamic>? error;
  final List<AfterActionTraceEventAttachmentV9>? attachments;
  final List<TraceEventAnnotationV9>? annotations;
  final Object? result;
  final PointV3? point;

  const AfterActionTraceEventV9({
    required this.callId,
    required this.endTime,
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
        'error': error,
        'attachments': attachments?.map((e) => e.toJson()).toList(),
        'annotations': annotations?.map((e) => e.toJson()).toList(),
        'result': result,
        'point': point?.toJson(),
      });
}

/// `ResourceOverride`. `sha1` becomes `file`.
class ResourceOverrideV9 {
  final String url;
  final String? file;
  final int? ref;

  const ResourceOverrideV9({required this.url, this.file, this.ref});

  Map<String, dynamic> toJson() =>
      _compact({'url': url, 'file': file, 'ref': ref});
}

/// `FrameSnapshot`. Declares its own `phase`; `snapshotName` stays only for
/// traces recorded before the phase existed.
class FrameSnapshotV9 {
  /// `before`, `action` or `after`.
  final String? phase;
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
  final List<ResourceOverrideV9> resourceOverrides;
  final ({int width, int height}) viewport;
  final bool isMainFrame;

  const FrameSnapshotV9({
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
    this.resourceOverrides = const [],
    required this.viewport,
    required this.isMainFrame,
  });

  Map<String, dynamic> toJson() => _compact({
        'phase': phase,
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
class FrameSnapshotTraceEventV9 {
  final FrameSnapshotV9 snapshot;

  const FrameSnapshotTraceEventV9({required this.snapshot});

  Map<String, dynamic> toJson() =>
      {'type': 'frame-snapshot', 'snapshot': snapshot.toJson()};
}

/// `resource-snapshot`. The HAR entry now names its bodies with `_file` and
/// its owner with `_apiRequestRef` or `_serviceWorkerRef`.
class ResourceSnapshotTraceEventV9 {
  final Map<String, dynamic> snapshot;

  const ResourceSnapshotTraceEventV9({required this.snapshot});

  Map<String, dynamic> toJson() =>
      {'type': 'resource-snapshot', 'snapshot': snapshot};
}

// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/trace/versions/traceV3.ts

/// Version 3 of the trace format: the oldest one the modernizer accepts.
///
/// Its distinguishing feature is `CallMetadata`: an action and an event are
/// both a `{ type, metadata }` pair, and everything about the call — the
/// timings, the params, the log, the snapshots, the error — lives inside
/// `metadata`. `_modernize_3_to_4` flattens it.
///
/// Reading a version 3 trace never builds these classes: the modernizer works
/// on raw JSON, as upstream does. They exist so a test can write the real
/// shape of an old trace instead of a hand-typed map.
library;

Map<String, dynamic> _compact(Map<String, dynamic> map) {
  map.removeWhere((_, value) => value == null);
  return map;
}

/// `Point`.
class PointV3 {
  final double x;
  final double y;

  const PointV3({required this.x, required this.y});

  Map<String, dynamic> toJson() => {'x': x, 'y': y};
}

/// `StackFrame`.
class StackFrameV3 {
  final String file;
  final int line;
  final int column;
  final String? function;

  const StackFrameV3({
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

/// `SerializedError['error']`.
class SerializedErrorValueV3 {
  final String message;
  final String name;
  final String? stack;

  const SerializedErrorValueV3({
    required this.message,
    required this.name,
    this.stack,
  });

  Map<String, dynamic> toJson() =>
      _compact({'message': message, 'name': name, 'stack': stack});
}

/// `SerializedError`.
///
/// `value` is a `SerializedValue`, which the model never inspects, so it stays
/// raw JSON here.
class SerializedErrorV3 {
  final SerializedErrorValueV3? error;
  final Object? value;

  const SerializedErrorV3({this.error, this.value});

  Map<String, dynamic> toJson() =>
      _compact({'error': error?.toJson(), 'value': value});
}

/// One entry of `CallMetadata.snapshots`.
class CallSnapshotV3 {
  /// `before`, `input` or `after`.
  final String title;
  final String snapshotName;

  const CallSnapshotV3({required this.title, required this.snapshotName});

  Map<String, dynamic> toJson() =>
      {'title': title, 'snapshotName': snapshotName};
}

/// `CallMetadata.location`.
class CallLocationV3 {
  final String file;
  final int? line;
  final int? column;

  const CallLocationV3({required this.file, this.line, this.column});

  Map<String, dynamic> toJson() =>
      _compact({'file': file, 'line': line, 'column': column});
}

/// `CallMetadata & { stack?: StackFrame[] }`: everything a version 3 trace
/// knows about one call.
class CallMetadataV3 {
  final String id;
  final double startTime;
  final double endTime;
  final double? pauseStartTime;
  final double? pauseEndTime;

  /// The protocol class, e.g. `Frame`. Named `type` on the wire.
  final String className;
  final String method;
  final Object? params;
  final String? apiName;
  final bool? internal;
  final bool? isServerSide;
  final num? wallTime;
  final CallLocationV3? location;
  final List<String> log;
  final String? afterSnapshot;
  final List<CallSnapshotV3> snapshots;
  final SerializedErrorV3? error;
  final Object? result;
  final PointV3? point;
  final String? objectId;
  final String? pageId;
  final String? frameId;
  final List<StackFrameV3>? stack;

  const CallMetadataV3({
    required this.id,
    required this.startTime,
    required this.endTime,
    this.pauseStartTime,
    this.pauseEndTime,
    required this.className,
    required this.method,
    this.params,
    this.apiName,
    this.internal,
    this.isServerSide,
    this.wallTime,
    this.location,
    this.log = const [],
    this.afterSnapshot,
    this.snapshots = const [],
    this.error,
    this.result,
    this.point,
    this.objectId,
    this.pageId,
    this.frameId,
    this.stack,
  });

  Map<String, dynamic> toJson() => _compact({
        'id': id,
        'startTime': startTime,
        'endTime': endTime,
        'pauseStartTime': pauseStartTime,
        'pauseEndTime': pauseEndTime,
        'type': className,
        'method': method,
        'params': params,
        'apiName': apiName,
        'internal': internal,
        'isServerSide': isServerSide,
        'wallTime': wallTime,
        'location': location?.toJson(),
        'log': log,
        'afterSnapshot': afterSnapshot,
        'snapshots': snapshots.map((e) => e.toJson()).toList(),
        'error': error?.toJson(),
        'result': result,
        'point': point?.toJson(),
        'objectId': objectId,
        'pageId': pageId,
        'frameId': frameId,
        'stack': stack?.map((e) => e.toJson()).toList(),
      });
}

/// `ResourceOverride`. The blob is named by `sha1` until version 9.
class ResourceOverrideV3 {
  final String url;
  final String? sha1;
  final int? ref;

  const ResourceOverrideV3({required this.url, this.sha1, this.ref});

  Map<String, dynamic> toJson() =>
      _compact({'url': url, 'sha1': sha1, 'ref': ref});
}

/// `FrameSnapshot`. There is no `phase` and no `wallTime` yet; snapshots are
/// found by `snapshotName`.
class FrameSnapshotV3 {
  final String callId;
  final String? snapshotName;
  final String pageId;
  final String frameId;
  final String frameUrl;
  final double timestamp;
  final double collectionTime;
  final String? doctype;
  final Object html;
  final List<ResourceOverrideV3> resourceOverrides;
  final ({int width, int height}) viewport;
  final bool isMainFrame;

  const FrameSnapshotV3({
    required this.callId,
    this.snapshotName,
    required this.pageId,
    required this.frameId,
    required this.frameUrl,
    required this.timestamp,
    required this.collectionTime,
    this.doctype,
    required this.html,
    this.resourceOverrides = const [],
    required this.viewport,
    required this.isMainFrame,
  });

  Map<String, dynamic> toJson() => _compact({
        'callId': callId,
        'snapshotName': snapshotName,
        'pageId': pageId,
        'frameId': frameId,
        'frameUrl': frameUrl,
        'timestamp': timestamp,
        'collectionTime': collectionTime,
        'doctype': doctype,
        'html': html,
        'resourceOverrides': resourceOverrides.map((e) => e.toJson()).toList(),
        'viewport': {'width': viewport.width, 'height': viewport.height},
        'isMainFrame': isMainFrame,
      });
}

/// `BrowserContextEventOptions`. No `baseURL` yet.
class BrowserContextEventOptionsV3 {
  final ({int width, int height})? viewport;
  final double? deviceScaleFactor;
  final bool? isMobile;
  final String? userAgent;

  const BrowserContextEventOptionsV3({
    this.viewport,
    this.deviceScaleFactor,
    this.isMobile,
    this.userAgent,
  });

  Map<String, dynamic> toJson() => _compact({
        'viewport': viewport == null
            ? null
            : {'width': viewport!.width, 'height': viewport!.height},
        'deviceScaleFactor': deviceScaleFactor,
        'isMobile': isMobile,
        'userAgent': userAgent,
      });
}

/// `context-options`. No `origin`, no `monotonicTime`, no `channel`.
class ContextCreatedTraceEventV3 {
  final int version;
  final String browserName;
  final String platform;
  final num wallTime;
  final String? title;
  final BrowserContextEventOptionsV3 options;

  /// `javascript`, `python`, `java` or `csharp`.
  final String? sdkLanguage;
  final String? testIdAttributeName;

  const ContextCreatedTraceEventV3({
    this.version = 3,
    required this.browserName,
    required this.platform,
    required this.wallTime,
    this.title,
    required this.options,
    this.sdkLanguage,
    this.testIdAttributeName,
  });

  Map<String, dynamic> toJson() => _compact({
        'version': version,
        'type': 'context-options',
        'browserName': browserName,
        'platform': platform,
        'wallTime': wallTime,
        'title': title,
        'options': options.toJson(),
        'sdkLanguage': sdkLanguage,
        'testIdAttributeName': testIdAttributeName,
      });
}

/// `screencast-frame`. The JPEG is named by `sha1` until version 9.
class ScreencastFrameTraceEventV3 {
  final String pageId;
  final String sha1;
  final int width;
  final int height;
  final double timestamp;

  const ScreencastFrameTraceEventV3({
    required this.pageId,
    required this.sha1,
    required this.width,
    required this.height,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'type': 'screencast-frame',
        'pageId': pageId,
        'sha1': sha1,
        'width': width,
        'height': height,
        'timestamp': timestamp,
      };
}

/// `action` or `event`: both are a `metadata` envelope in version 3.
class ActionTraceEventV3 {
  /// `action` or `event`.
  final String type;
  final CallMetadataV3 metadata;

  const ActionTraceEventV3({required this.type, required this.metadata});

  Map<String, dynamic> toJson() =>
      {'type': type, 'metadata': metadata.toJson()};
}

/// `resource-snapshot`. The snapshot is a HAR entry — except in traces so old
/// that `_modernize_2_to_3` had to build one, which is why the modernizer
/// tolerates an entry without `request`.
class ResourceSnapshotTraceEventV3 {
  final Map<String, dynamic> snapshot;

  const ResourceSnapshotTraceEventV3({required this.snapshot});

  Map<String, dynamic> toJson() =>
      {'type': 'resource-snapshot', 'snapshot': snapshot};
}

/// `frame-snapshot`.
class FrameSnapshotTraceEventV3 {
  final FrameSnapshotV3 snapshot;

  const FrameSnapshotTraceEventV3({required this.snapshot});

  Map<String, dynamic> toJson() =>
      {'type': 'frame-snapshot', 'snapshot': snapshot.toJson()};
}

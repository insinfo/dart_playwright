// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/trace/versions/traceV4.ts

/// Version 4 of the trace format: `CallMetadata` is gone.
///
/// One call is now three lines — `before`, `input`, `after` — or a single
/// `action` line, and a console message arrives as an `object` event carrying
/// the protocol initializer of a `ConsoleMessage`, to be joined later with the
/// `event` line that references its guid. `_modernize_4_to_5` does that join.
library;

import 'trace_v3.dart' show StackFrameV3, PointV3, ResourceOverrideV3;

export 'trace_v3.dart' show StackFrameV3, PointV3, ResourceOverrideV3;

Map<String, dynamic> _compact(Map<String, dynamic> map) {
  map.removeWhere((_, value) => value == null);
  return map;
}

/// `FrameSnapshot`. Unchanged from version 3 apart from field order.
class FrameSnapshotV4 {
  final String? snapshotName;
  final String callId;
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

  const FrameSnapshotV4({
    this.snapshotName,
    required this.callId,
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
        'snapshotName': snapshotName,
        'callId': callId,
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

/// `BrowserContextEventOptions`.
class BrowserContextEventOptionsV4 {
  final ({int width, int height})? viewport;
  final double? deviceScaleFactor;
  final bool? isMobile;
  final String? userAgent;

  const BrowserContextEventOptionsV4({
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

/// `context-options`. Adds `channel` over version 3.
class ContextCreatedTraceEventV4 {
  final int version;
  final String browserName;
  final String? channel;
  final String platform;
  final num wallTime;
  final String? title;
  final BrowserContextEventOptionsV4 options;

  /// `javascript`, `python`, `java`, `csharp` or `jsonl`.
  final String? sdkLanguage;
  final String? testIdAttributeName;

  const ContextCreatedTraceEventV4({
    this.version = 4,
    required this.browserName,
    this.channel,
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
        'channel': channel,
        'platform': platform,
        'wallTime': wallTime,
        'title': title,
        'options': options.toJson(),
        'sdkLanguage': sdkLanguage,
        'testIdAttributeName': testIdAttributeName,
      });
}

/// `screencast-frame`.
class ScreencastFrameTraceEventV4 {
  final String pageId;
  final String sha1;
  final int width;
  final int height;
  final double timestamp;

  const ScreencastFrameTraceEventV4({
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

/// `before`. Carries `apiName` and points at its snapshot by name.
class BeforeActionTraceEventV4 {
  final String callId;
  final double startTime;
  final String apiName;

  /// The protocol class. Named `class` on the wire.
  final String className;
  final String method;
  final Map<String, dynamic> params;
  final num wallTime;
  final String? beforeSnapshot;
  final List<StackFrameV3>? stack;
  final String? pageId;
  final String? parentId;

  const BeforeActionTraceEventV4({
    required this.callId,
    required this.startTime,
    required this.apiName,
    required this.className,
    required this.method,
    this.params = const {},
    required this.wallTime,
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
        'wallTime': wallTime,
        'beforeSnapshot': beforeSnapshot,
        'stack': stack?.map((e) => e.toJson()).toList(),
        'pageId': pageId,
        'parentId': parentId,
      });
}

/// `input`.
class InputActionTraceEventV4 {
  final String callId;
  final String? inputSnapshot;
  final PointV3? point;

  const InputActionTraceEventV4({
    required this.callId,
    this.inputSnapshot,
    this.point,
  });

  Map<String, dynamic> toJson() => _compact({
        'type': 'input',
        'callId': callId,
        'inputSnapshot': inputSnapshot,
        'point': point?.toJson(),
      });
}

/// `AfterActionTraceEventAttachment`. The blob is named by `sha1` until
/// version 9.
class AfterActionTraceEventAttachmentV4 {
  final String name;
  final String contentType;
  final String? path;
  final String? sha1;
  final String? base64;

  const AfterActionTraceEventAttachmentV4({
    required this.name,
    required this.contentType,
    this.path,
    this.sha1,
    this.base64,
  });

  Map<String, dynamic> toJson() => _compact({
        'name': name,
        'contentType': contentType,
        'path': path,
        'sha1': sha1,
        'base64': base64,
      });
}

/// `after`. The log is still a list of strings on this event;
/// `_modernize_5_to_6` splits it into `log` events.
class AfterActionTraceEventV4 {
  final String callId;
  final double endTime;
  final String? afterSnapshot;
  final List<String> log;
  final Map<String, dynamic>? error;
  final List<AfterActionTraceEventAttachmentV4>? attachments;
  final Object? result;

  const AfterActionTraceEventV4({
    required this.callId,
    required this.endTime,
    this.afterSnapshot,
    this.log = const [],
    this.error,
    this.attachments,
    this.result,
  });

  Map<String, dynamic> toJson() => _compact({
        'type': 'after',
        'callId': callId,
        'endTime': endTime,
        'afterSnapshot': afterSnapshot,
        'log': log,
        'error': error,
        'attachments': attachments?.map((e) => e.toJson()).toList(),
        'result': result,
      });
}

/// `event`.
class EventTraceEventV4 {
  final double time;

  /// The protocol class. Named `class` on the wire.
  final String className;
  final String method;
  final Object? params;
  final String? pageId;

  const EventTraceEventV4({
    required this.time,
    required this.className,
    required this.method,
    this.params,
    this.pageId,
  });

  Map<String, dynamic> toJson() => _compact({
        'type': 'event',
        'time': time,
        'class': className,
        'method': method,
        'params': params,
        'pageId': pageId,
      });
}

/// `object`: the protocol initializer of a created object.
///
/// Only `ConsoleMessage` matters to the reader; `_modernize_4_to_5` keeps the
/// initializer keyed by guid and drops the event, then turns the later
/// `event`/`console` line that references the guid into a `console` event.
class ConsoleMessageTraceEventV4 {
  /// The protocol class. Named `class` on the wire.
  final String className;
  final String messageType;
  final String text;
  final String locationUrl;
  final int locationLineNumber;
  final int locationColumnNumber;

  /// Console arguments, either `{ guid }` handles or `{ preview, value }`.
  final List<Object>? args;
  final String guid;

  const ConsoleMessageTraceEventV4({
    this.className = 'ConsoleMessage',
    required this.messageType,
    required this.text,
    required this.locationUrl,
    this.locationLineNumber = 0,
    this.locationColumnNumber = 0,
    this.args,
    required this.guid,
  });

  Map<String, dynamic> toJson() => {
        'type': 'object',
        'class': className,
        'initializer': _compact({
          'type': messageType,
          'text': text,
          'location': {
            'url': locationUrl,
            'lineNumber': locationLineNumber,
            'columnNumber': locationColumnNumber,
          },
          'args': args,
        }),
        'guid': guid,
      };
}

/// `resource-snapshot`.
class ResourceSnapshotTraceEventV4 {
  final Map<String, dynamic> snapshot;

  const ResourceSnapshotTraceEventV4({required this.snapshot});

  Map<String, dynamic> toJson() =>
      {'type': 'resource-snapshot', 'snapshot': snapshot};
}

/// `frame-snapshot`.
class FrameSnapshotTraceEventV4 {
  final FrameSnapshotV4 snapshot;

  const FrameSnapshotTraceEventV4({required this.snapshot});

  Map<String, dynamic> toJson() =>
      {'type': 'frame-snapshot', 'snapshot': snapshot.toJson()};
}

/// `stdout` or `stderr`.
class StdioTraceEventV4 {
  /// `stdout` or `stderr`.
  final String stream;
  final double timestamp;
  final String? text;
  final String? base64;

  const StdioTraceEventV4({
    required this.stream,
    required this.timestamp,
    this.text,
    this.base64,
  });

  Map<String, dynamic> toJson() => _compact({
        'type': stream,
        'timestamp': timestamp,
        'text': text,
        'base64': base64,
      });
}

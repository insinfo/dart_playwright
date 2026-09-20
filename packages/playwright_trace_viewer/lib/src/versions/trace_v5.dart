// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/trace/versions/traceV5.ts

/// Version 5 of the trace format.
///
/// The only change from version 4 is the console message: it is written as a
/// self-contained `console` event instead of an `object` initializer joined to
/// an `event` line by guid. Every other shape is the version 4 one, and is
/// re-exported here rather than copied.
library;

export 'trace_v3.dart' show StackFrameV3, PointV3, ResourceOverrideV3;
export 'trace_v4.dart'
    show
        FrameSnapshotV4,
        BrowserContextEventOptionsV4,
        ScreencastFrameTraceEventV4,
        BeforeActionTraceEventV4,
        InputActionTraceEventV4,
        AfterActionTraceEventAttachmentV4,
        AfterActionTraceEventV4,
        EventTraceEventV4,
        ResourceSnapshotTraceEventV4,
        FrameSnapshotTraceEventV4,
        StdioTraceEventV4;

Map<String, dynamic> _compact(Map<String, dynamic> map) {
  map.removeWhere((_, value) => value == null);
  return map;
}

/// `context-options`, identical to version 4 but declaring version 5.
class ContextCreatedTraceEventV5 {
  final int version;
  final String browserName;
  final String? channel;
  final String platform;
  final num wallTime;
  final String? title;
  final Map<String, dynamic> options;
  final String? sdkLanguage;
  final String? testIdAttributeName;

  const ContextCreatedTraceEventV5({
    this.version = 5,
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

/// One argument of a `console` event.
class ConsoleMessageArgV5 {
  final String preview;
  final Object? value;

  const ConsoleMessageArgV5({required this.preview, this.value});

  Map<String, dynamic> toJson() => {'preview': preview, 'value': value};
}

/// `console`: the console message, no longer split across two events.
class ConsoleMessageTraceEventV5 {
  final double time;
  final String? pageId;
  final String messageType;
  final String text;
  final List<ConsoleMessageArgV5>? args;
  final String locationUrl;
  final int locationLineNumber;
  final int locationColumnNumber;

  const ConsoleMessageTraceEventV5({
    required this.time,
    this.pageId,
    required this.messageType,
    required this.text,
    this.args,
    required this.locationUrl,
    this.locationLineNumber = 0,
    this.locationColumnNumber = 0,
  });

  Map<String, dynamic> toJson() => _compact({
        'type': 'console',
        'time': time,
        'pageId': pageId,
        'messageType': messageType,
        'text': text,
        'args': args?.map((e) => e.toJson()).toList(),
        'location': {
          'url': locationUrl,
          'lineNumber': locationLineNumber,
          'columnNumber': locationColumnNumber,
        },
      });
}

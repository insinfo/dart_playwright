// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/playwright-core/src/server/instrumentation.ts

import 'dart:async';

import '../core_page.dart';
import 'trace_events.dart';
import 'trace_utils.dart';

/// A file produced while a call was running, offered by the viewer next to
/// the action's row.
///
/// Upstream's counterpart is one entry of `testInfo.attachments`, which its
/// test runner drains into the `after` event of the enclosing step. The shape
/// is the same because the trace format is the same; what differs is only
/// where it comes from.
class CoreCallAttachment {
  final String name;

  /// MIME type the viewer uses to decide whether to render the body inline.
  final String contentType;

  /// Where the file came from, when it came from disk. Informational: the
  /// recorder always also puts the bytes into the archive, so the viewer can
  /// open the attachment from a trace carried to another machine.
  final String? path;

  /// The bytes. Read from [path] by the caller when the attachment came from
  /// a file, because the recorder itself runs in event handlers and cannot
  /// wait for a disk read.
  final List<int> body;

  const CoreCallAttachment({
    required this.name,
    required this.contentType,
    required this.body,
    this.path,
  });
}

/// One public API call, from the moment it starts until it returns.
///
/// This is the Dart counterpart of upstream's `CallMetadata`. Upstream mints
/// one per protocol message because every call crosses a wire; here the calls
/// are plain Dart, so the public API layer creates it and hands it to the
/// instrumentation directly.
class CoreCallMetadata {
  /// Stable id used to tie the `before`, `input`, `log` and `after` events of
  /// one call together.
  final String id;

  /// The API class the call belongs to: `Page`, `Locator`, `Frame`,
  /// `BrowserContext`. The viewer shows it next to the method.
  final String type;

  /// The method name, e.g. `goto` or `click`.
  final String method;

  /// Overrides the title the viewer renders, when the method name alone is
  /// not what the reader wants to see.
  final String? title;

  /// The arguments, as the viewer's Call tab shows them. A `selector` key is
  /// rendered as a locator.
  final Map<String, dynamic> params;

  /// The page the call acts on, when there is one. Snapshots and screenshots
  /// need it; a context-level call leaves it null.
  final CorePage? page;

  /// Where the caller was, for the Source tab. Null when `sources` is off.
  final List<TraceStackFrame>? stack;

  /// The call this one runs inside, when a public method calls another
  /// (`check` clicks, `clear` fills). The viewer nests the rows by it.
  final String? parentId;

  final double startTime;
  double endTime = 0;

  /// Filled in when the call threw.
  ({String message, String name, String? stack})? error;

  /// Files attached to this call while it ran. The recorder serializes them
  /// into the `after` event.
  final attachments = <CoreCallAttachment>[];

  CoreCallMetadata({
    required this.type,
    required this.method,
    this.title,
    Map<String, dynamic>? params,
    this.page,
    this.stack,
    this.parentId,
    String? id,
  })  : id = id ?? 'call@${createGuid()}',
        params = params ?? const <String, dynamic>{},
        startTime = TraceClock.monotonicTime();
}

/// What a recorder implements to observe API calls.
abstract class CoreInstrumentationListener {
  Future<void> onBeforeCall(CoreCallMetadata metadata);

  /// Called right before an input action lands, with the point it landed on.
  Future<void> onBeforeInputAction(
    CoreCallMetadata metadata, {
    ({double x, double y})? point,
    ({double x, double y, double width, double height})? box,
  });

  void onCallLog(CoreCallMetadata metadata, String message);

  Future<void> onAfterCall(CoreCallMetadata metadata);
}

/// The per-context registry the public API reports calls to.
///
/// With no listener attached this costs one `isEmpty` check per call, which is
/// what keeps the instrumentation free when tracing is off.
class CoreInstrumentation {
  final _listeners = <CoreInstrumentationListener>[];

  /// Whether a listener wants the caller's stack with each call.
  ///
  /// Walking `StackTrace.current` is not free, and nothing but the trace
  /// recorder's `sources` option ever looks at it, so the recorder turns this
  /// on only while it needs it.
  bool captureStacks = false;

  bool get hasListeners => _listeners.isNotEmpty;

  void addListener(CoreInstrumentationListener listener) {
    if (!_listeners.contains(listener)) _listeners.add(listener);
  }

  void removeListener(CoreInstrumentationListener listener) =>
      _listeners.remove(listener);

  Future<void> onBeforeCall(CoreCallMetadata metadata) async {
    for (final listener in List.of(_listeners)) {
      await listener.onBeforeCall(metadata);
    }
  }

  Future<void> onBeforeInputAction(
    CoreCallMetadata metadata, {
    ({double x, double y})? point,
    ({double x, double y, double width, double height})? box,
  }) async {
    for (final listener in List.of(_listeners)) {
      await listener.onBeforeInputAction(metadata, point: point, box: box);
    }
  }

  void onCallLog(CoreCallMetadata metadata, String message) {
    for (final listener in List.of(_listeners)) {
      listener.onCallLog(metadata, message);
    }
  }

  Future<void> onAfterCall(CoreCallMetadata metadata) async {
    for (final listener in List.of(_listeners)) {
      await listener.onAfterCall(metadata);
    }
  }
}

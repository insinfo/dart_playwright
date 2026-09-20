import 'dart:async';

import 'package:playwright_core/src/server/core_page.dart';
import 'package:playwright_core/src/server/trace/instrumentation.dart';
import 'package:playwright_core/src/server/trace/trace_events.dart';
import 'package:playwright_core/src/server/trace/trace_utils.dart';

/// Re-exported so `playwright_test` can name an attachment without taking a
/// dependency on `playwright_core` of its own: `step.dart` already imports
/// this file, for the instrumentation it cannot get anywhere else.
export 'package:playwright_core/src/server/trace/instrumentation.dart'
    show CoreCallAttachment;

/// Zone key holding the id of the call currently running.
///
/// A public method that calls another public method (`check` clicks, `clear`
/// fills) must not produce two unrelated rows: the viewer nests them when the
/// inner one carries the outer one's id as `parentId`. A zone value is what
/// survives the `await`s in between and stays correct when two calls run at
/// once, which a plain field would not.
const _callIdKey = #playwrightTraceCallId;

/// Zone key holding the metadata of the call currently running.
///
/// [currentCallMetadata] is the only way in for something that wants to add
/// to a call it did not start — an attachment, today. The id alone would not
/// do: the recorder holds no table of calls by id, on purpose, because a
/// table of every call that ever ran is a leak with a nicer name.
const _metadataKey = #playwrightTraceCallMetadata;

/// The public API call running in this zone, or null outside one.
CoreCallMetadata? get currentCallMetadata =>
    Zone.current[_metadataKey] as CoreCallMetadata?;

/// Reports one public API call to the context's instrumentation and runs it.
///
/// This is where the trace gets its actions. Upstream mints a `CallMetadata`
/// per protocol message because every call crosses a wire; here the calls are
/// plain Dart, so the public API layer is the only place that knows a call
/// happened, and it says so here.
///
/// [type] and [method] are upstream's protocol names (`Frame`/`click`,
/// `Page`/`reload`), not this port's Dart names, because the viewer looks the
/// pair up in its own table to decide what to call the row. An unknown pair
/// still renders — as the bare method name — so a method upstream does not
/// have is not a problem, just a plainer label.
///
/// With nothing listening this costs one boolean check, which is what makes it
/// safe to sprinkle over the API surface.
Future<T> instrumented<T>({
  required CorePage? page,
  required String type,
  required String method,
  Map<String, dynamic>? params,
  String? title,
  required Future<T> Function() body,
}) {
  return _report(
    page?.browserContext?.instrumentation,
    page: page,
    type: type,
    method: method,
    params: params,
    title: title,
    body: body,
  );
}

/// Same, for a call that has no page of its own (a context-level one).
Future<T> instrumentedOnContext<T>({
  required CoreInstrumentation? instrumentation,
  required String type,
  required String method,
  Map<String, dynamic>? params,
  String? title,
  required Future<T> Function() body,
}) {
  return _report(
    instrumentation,
    page: null,
    type: type,
    method: method,
    params: params,
    title: title,
    body: body,
  );
}

Future<T> _report<T>(
  CoreInstrumentation? instrumentation, {
  required CorePage? page,
  required String type,
  required String method,
  Map<String, dynamic>? params,
  String? title,
  required Future<T> Function() body,
}) {
  if (instrumentation == null || !instrumentation.hasListeners) return body();

  final metadata = CoreCallMetadata(
    type: type,
    method: method,
    title: title,
    params: params,
    page: page,
    parentId: Zone.current[_callIdKey] as String?,
    stack: instrumentation.captureStacks ? captureStack() : null,
  );

  return runZoned(() async {
    await instrumentation.onBeforeCall(metadata);
    try {
      final result = await body();
      metadata.endTime = TraceClock.monotonicTime();
      await instrumentation.onAfterCall(metadata);
      return result;
    } catch (error, stackTrace) {
      metadata.endTime = TraceClock.monotonicTime();
      metadata.error = (
        message: _messageOf(error),
        name: error.runtimeType.toString(),
        stack: stackTrace.toString(),
      );
      // The `after` event has to be written even when the call threw — that
      // red row is the whole reason someone opens a trace.
      await instrumentation.onAfterCall(metadata);
      rethrow;
    }
  }, zoneValues: {_callIdKey: metadata.id, _metadataKey: metadata});
}

/// `Exception: boom` reads badly in the viewer's error row; `boom` is what the
/// reader wants, with the class name already carried separately.
String _messageOf(Object error) {
  final text = error.toString();
  final name = error.runtimeType.toString();
  if (text.startsWith('$name: ')) return text.substring(name.length + 2);
  return text;
}

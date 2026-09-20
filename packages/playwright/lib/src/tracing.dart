import 'package:playwright_core/src/server/core_browser.dart';
import 'package:playwright_core/src/server/trace/trace_events.dart';
import 'package:playwright_core/src/server/trace/tracing.dart';

import 'har.dart';

/// Records a trace of a browser context that the official Playwright trace
/// viewer opens.
///
/// ```dart
/// await context.tracing.start(sources: true);
/// // ... drive the page ...
/// await context.tracing.stop(path: 'trace.zip');
/// ```
///
/// Then `npx playwright show-trace trace.zip`.
///
/// The archive holds `trace.trace` (the action and event stream, one JSON
/// object per line), `trace.network` (the HAR entries) and
/// `resources/<sha1>.<ext>` for the response bodies. With [start]'s `sources`
/// the Dart files the actions came from go in under `src/` as well.
abstract class Tracing {
  /// Starts recording and opens the first chunk.
  ///
  /// [name] names the trace files inside the temporary directory; a random
  /// name is used otherwise. [title] is what the viewer shows as the title of
  /// the run.
  ///
  /// [screenshots] records the filmstrip: the strip of frames the viewer runs
  /// along the top of its timeline, and the image it shows while you scrub
  /// through it. This is upstream's `screenshots: true`; the frames come from
  /// the page's screencast, which is shared with `recordVideo` when both are
  /// on.
  ///
  /// [actionScreenshots] is a different thing with a similar name: one PNG of
  /// the page before, during and after each action, which is upstream's
  /// internal `snapshots: { screen: true }`. Upstream's own `Tracing.start`
  /// does not expose it; it is here because the viewer reads it and it costs
  /// nothing to keep.
  ///
  /// [snapshots] captures the DOM of every frame before and after each action,
  /// which is what makes the viewer show the page as it was at that moment —
  /// rendered, selectable and inspectable, not a picture of it. Two things
  /// differ from upstream and are documented on `Snapshotter`: the streamer is
  /// installed on first capture instead of before the page's own scripts
  /// (`addInitScript` is not ported), and a capture has a deadline instead of
  /// being non-stalling.
  ///
  /// [sources] records the Dart stack of each action and puts the files it
  /// points at into the archive, which is what fills the viewer's Source tab.
  Future<void> start({
    String? name,
    String? title,
    bool screenshots = false,
    bool actionScreenshots = false,
    bool snapshots = false,
    bool sources = false,
  });

  /// Opens a new chunk while recording stays on.
  ///
  /// Everything recorded between [startChunk] and [stopChunk] lands in one
  /// archive; the network resources are shared across the chunks of one
  /// [start], so a body served before this chunk is still there to serve a
  /// snapshot inside it.
  Future<void> startChunk({String? name, String? title});

  /// Closes the current chunk and writes it to [path]. Without [path] the
  /// archive stays in the temporary directory and its path is returned.
  Future<String?> stopChunk({String? path});

  /// Closes the current chunk, writes it to [path] and stops recording,
  /// removing the temporary directory.
  Future<String?> stop({String? path});

  /// Opens a named row in the viewer's action tree. Everything recorded until
  /// the matching [groupEnd] is drawn nested under it.
  ///
  /// ```dart
  /// await context.tracing.group('login');
  /// await page.fill('#user', 'ana');
  /// await page.click('#enter');
  /// await context.tracing.groupEnd();
  /// ```
  ///
  /// Groups nest. A chunk that ends with groups still open closes them
  /// itself, so a `groupEnd` missed on an error path does not leave the
  /// viewer with rows that never finish.
  ///
  /// [location] is the source position the viewer's Source tab jumps to.
  /// Without one the caller's own line is used, but only while `sources` is
  /// on — a `stack` pointing at a file the archive does not carry would give
  /// the Source tab a line it cannot open.
  Future<void> group(String name, {TracingGroupLocation? location});

  /// Closes the innermost group opened by [group]. Doing this without an open
  /// group is not an error.
  Future<void> groupEnd();

  /// Starts recording every request of this context into a HAR document at
  /// [path], independent of any trace.
  ///
  /// A [path] ending in `.zip` produces an archive holding `har.har` plus the
  /// response bodies as separate files; any other path writes a plain `.har`
  /// with the bodies inside the document. [stopHar] writes it.
  ///
  /// This is `recordHar` of [Browser.newContext] with a start and an end of
  /// its own, for when only part of a session is worth recording.
  Future<void> startHar(
    String path, {
    HarMode mode = HarMode.full,
    HarContent? content,
    Object? urlFilter,
  });

  /// Writes the HAR document [startHar] has been filling.
  Future<void> stopHar();
}

/// Where in the source a [Tracing.group] was opened, for the viewer's Source
/// tab.
class TracingGroupLocation {
  final String file;
  final int line;
  final int column;

  const TracingGroupLocation({
    required this.file,
    this.line = 0,
    this.column = 0,
  });
}

class TracingImpl implements Tracing {
  final CoreBrowserContext _context;

  TracingImpl(this._context);

  CoreTracing get _tracing => _context.tracing;

  @override
  Future<void> start({
    String? name,
    String? title,
    bool screenshots = false,
    bool actionScreenshots = false,
    bool snapshots = false,
    bool sources = false,
  }) async {
    _tracing.start(CoreTracingOptions(
      name: name,
      screenshots: screenshots,
      actionScreenshots: actionScreenshots,
      snapshots: snapshots,
      sources: sources,
    ));
    _tracing.startChunk(name: name, title: title);
  }

  @override
  Future<void> startChunk({String? name, String? title}) async {
    _tracing.startChunk(name: name, title: title);
  }

  @override
  Future<void> group(String name, {TracingGroupLocation? location}) async {
    _tracing.group(
      name,
      location: location == null
          ? null
          : TraceStackFrame(
              file: location.file,
              line: location.line,
              column: location.column,
            ),
    );
  }

  @override
  Future<void> groupEnd() async => _tracing.groupEnd();

  @override
  Future<void> startHar(
    String path, {
    HarMode mode = HarMode.full,
    HarContent? content,
    Object? urlFilter,
  }) async {
    if (_context.harRecorder != null) {
      throw StateError('HAR recording has already been started');
    }
    _context.startHarRecording(CoreRecordHarOptions(
      path: path,
      mode: mode.toCore(),
      content: content?.toCore(),
      urlFilter: urlFilter,
    ));
  }

  @override
  Future<void> stopHar() async {
    final recorder = _context.harRecorder;
    if (recorder == null) {
      throw StateError('HAR recording has not been started');
    }
    _context.harRecorder = null;
    await recorder.flush();
  }

  @override
  Future<String?> stopChunk({String? path}) => _tracing.stopChunk(path: path);

  @override
  Future<String?> stop({String? path}) async {
    final result = await _tracing.stopChunk(path: path);
    await _tracing.stop();
    return result;
  }
}

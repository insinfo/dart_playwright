import 'package:playwright_core/src/server/core_browser.dart';
import 'package:playwright_core/src/server/trace/tracing.dart';

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
  /// [screenshots] captures a PNG of the page before, during and after each
  /// action. Note this is **not** upstream's `screenshots: true`, which
  /// records the screencast filmstrip; that needs `Page.startScreencast` and
  /// is not ported. It is upstream's `snapshots: { screen: true }`.
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
    bool snapshots = false,
    bool sources = false,
  }) async {
    _tracing.start(CoreTracingOptions(
      name: name,
      screenshots: screenshots,
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
  Future<String?> stopChunk({String? path}) => _tracing.stopChunk(path: path);

  @override
  Future<String?> stop({String? path}) async {
    final result = await _tracing.stopChunk(path: path);
    await _tracing.stop();
    return result;
  }
}

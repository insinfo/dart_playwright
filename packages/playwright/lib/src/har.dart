import 'package:playwright_core/src/server/trace/har_recorder.dart'
    show CoreRecordHarOptions, HarRecordMode;
import 'package:playwright_core/src/server/trace/har_tracer.dart'
    show HarContentPolicy;

/// How much of each request a recorded HAR keeps.
enum HarMode {
  /// Everything: cookies, timings, addresses, sizes and the page list.
  full,

  /// Only what a HAR is replayed from. Upstream's `minimal`.
  minimal;

  HarRecordMode toCore() =>
      this == HarMode.full ? HarRecordMode.full : HarRecordMode.minimal;
}

/// What a recorded HAR does with the response bodies.
enum HarContent {
  /// Keep the metadata and drop the bodies.
  omit,

  /// Put each body inside the document, base64 for anything not textual.
  embed,

  /// Write each body next to the document as its own file.
  attach;

  HarContentPolicy toCore() => switch (this) {
        HarContent.omit => HarContentPolicy.omit,
        HarContent.embed => HarContentPolicy.embed,
        HarContent.attach => HarContentPolicy.attach,
      };
}

/// `recordHar` of [Browser.newContext]: records every request of the context
/// into a HAR document, written when the context closes.
///
/// ```dart
/// final context = await browser.newContext(
///     recordHar: RecordHarOptions(path: 'session.har'));
/// // ... drive the pages ...
/// await context.close(); // the document is written here
/// ```
///
/// A HAR is what gets replayed and diffed; a trace zip is read by the viewer
/// and by nothing else. The two are independent and can be on at once — they
/// share the same tracer but not the same destination.
class RecordHarOptions {
  /// Where the document lands. A path ending in `.zip` produces an archive
  /// holding `har.har` plus the bodies as separate files; anything else is a
  /// plain `.har` with the resources written beside it.
  final String path;

  /// How much of each request to keep. Defaults to [HarMode.full].
  final HarMode mode;

  /// What to do with the bodies. Defaults to [HarContent.attach] for a `.zip`
  /// and [HarContent.embed] for a `.har`, because a lone `.har` has nowhere
  /// to put a sibling file that travels with it.
  final HarContent? content;

  /// Records only the requests whose URL matches: a glob [String] of the same
  /// small dialect `page.route` takes, or a [RegExp].
  final Object? urlFilter;

  const RecordHarOptions({
    required this.path,
    this.mode = HarMode.full,
    this.content,
    this.urlFilter,
  });

  CoreRecordHarOptions toCore() => CoreRecordHarOptions(
        path: path,
        mode: mode.toCore(),
        content: content?.toCore(),
        urlFilter: urlFilter,
      );
}

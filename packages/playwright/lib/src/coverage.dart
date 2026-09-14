import 'package:playwright_core/src/server/core_coverage.dart';

export 'package:playwright_core/src/server/core_coverage.dart'
    show
        CSSCoverageEntry,
        CoverageRange,
        JSCoverageEntry,
        JSCoverageFunction,
        JSCoverageRangeCount;

/// JavaScript and CSS coverage for a page.
///
/// **Chromium only.** The counts come from V8's `Profiler` domain and from
/// Blink's CSS rule-usage tracking; neither the Juggler protocol nor the
/// WebKit inspector protocol has an equivalent, so `page.coverage` throws
/// [UnsupportedError] on Firefox and WebKit rather than answering with an
/// empty list — an empty list would read as "nothing ran". Upstream
/// Playwright draws the same line: its `page.coverage` exists on the Chromium
/// page type alone.
///
/// Coverage is not a general-purpose profiler: it says which bytes of a
/// script or stylesheet were reached between `start` and `stop`, which is
/// what a bundle-size or dead-code question needs.
///
/// ```dart
/// await page.coverage.startJSCoverage();
/// await page.goto(url);
/// final entries = await page.coverage.stopJSCoverage();
/// ```
abstract class Coverage {
  /// Starts collecting JavaScript coverage.
  ///
  /// [reportAnonymousScripts] also reports scripts with no URL — inline
  /// `<script>` blocks and `eval` — which are left out otherwise.
  ///
  /// [resetOnNavigation] governs this side's bookkeeping: the script ids and
  /// the sources already read are dropped when the page navigates. It is not
  /// a way to accumulate coverage across documents, and turning it off does
  /// not make it one: V8 reports coverage only for scripts that are still
  /// alive, and the previous document's scripts become garbage as soon as it
  /// is gone. Measured on the Chromium this port ships against, a script from
  /// a document you have navigated away from is absent from the report either
  /// way. Start and stop around the document you want to measure.
  ///
  /// Starting twice without stopping throws.
  Future<void> startJSCoverage({
    bool resetOnNavigation = true,
    bool reportAnonymousScripts = false,
  });

  /// Stops collecting and returns one entry per script, each carrying V8's
  /// per-function, per-range execution counts and, when it could be read, the
  /// script source the offsets refer to.
  Future<List<JSCoverageEntry>> stopJSCoverage();

  /// Starts collecting CSS coverage.
  Future<void> startCSSCoverage({bool resetOnNavigation = true});

  /// Stops collecting and returns one entry per stylesheet, with the text and
  /// the disjoint ranges of it that were actually used.
  Future<List<CSSCoverageEntry>> stopCSSCoverage();
}

class CoverageImpl implements Coverage {
  final CoreCoverage _core;

  CoverageImpl(this._core);

  @override
  Future<void> startJSCoverage({
    bool resetOnNavigation = true,
    bool reportAnonymousScripts = false,
  }) =>
      _core.startJSCoverage(
        resetOnNavigation: resetOnNavigation,
        reportAnonymousScripts: reportAnonymousScripts,
      );

  @override
  Future<List<JSCoverageEntry>> stopJSCoverage() => _core.stopJSCoverage();

  @override
  Future<void> startCSSCoverage({bool resetOnNavigation = true}) =>
      _core.startCSSCoverage(resetOnNavigation: resetOnNavigation);

  @override
  Future<List<CSSCoverageEntry>> stopCSSCoverage() => _core.stopCSSCoverage();
}

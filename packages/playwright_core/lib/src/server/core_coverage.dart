/// JavaScript and CSS coverage.
///
/// **Chromium only, and that is not an omission of this port.** Coverage is
/// read straight out of V8 (`Profiler.takePreciseCoverage`) and Blink's CSS
/// engine (`CSS.stopRuleUsageTracking`). The Juggler protocol has neither
/// command, and neither does the WebKit inspector protocol: SpiderMonkey and
/// JavaScriptCore simply do not expose per-range execution counts to a
/// debugger client. Upstream Playwright answers the same way — its
/// `page.coverage` exists only on the Chromium page type — and the other two
/// engines here throw [UnsupportedError] instead of returning an empty list,
/// because an empty list would read as "nothing was covered".
library;

/// One half-open range of a source text, in characters.
class CoverageRange {
  final int start;
  final int end;

  const CoverageRange({required this.start, required this.end});

  @override
  String toString() => 'CoverageRange($start, $end)';
}

/// One range of a function's body, with how many times it ran.
class JSCoverageRangeCount {
  final int startOffset;
  final int endOffset;

  /// How many times this range executed. Zero means it never did.
  final int count;

  const JSCoverageRangeCount({
    required this.startOffset,
    required this.endOffset,
    required this.count,
  });
}

/// Coverage of one function of one script.
class JSCoverageFunction {
  final String functionName;

  /// Whether V8 reported per-block counts rather than a single count for the
  /// whole function. Without it the function has exactly one range.
  final bool isBlockCoverage;

  final List<JSCoverageRangeCount> ranges;

  const JSCoverageFunction({
    required this.functionName,
    required this.isBlockCoverage,
    required this.ranges,
  });
}

/// Coverage of one script.
class JSCoverageEntry {
  /// The script URL. Empty for an inline or an `eval`ed script, which is
  /// reported only when coverage was started with `reportAnonymousScripts`.
  final String url;

  /// V8's id for the script.
  final String scriptId;

  /// The script text, when the driver managed to read it before the page
  /// navigated away.
  final String? source;

  final List<JSCoverageFunction> functions;

  const JSCoverageEntry({
    required this.url,
    required this.scriptId,
    required this.source,
    required this.functions,
  });
}

/// Coverage of one stylesheet.
class CSSCoverageEntry {
  final String url;

  /// The stylesheet text, so the ranges can be resolved against it.
  final String text;

  /// The parts of [text] that were actually used, merged and disjoint.
  final List<CoverageRange> ranges;

  const CSSCoverageEntry({
    required this.url,
    required this.text,
    required this.ranges,
  });
}

/// The coverage API of a page. See the library doc for why only Chromium has
/// a real implementation.
abstract class CoreCoverage {
  /// Starts collecting JavaScript coverage.
  ///
  /// [reportAnonymousScripts] adds scripts with no URL — inline `<script>`
  /// blocks and `eval` — which are excluded otherwise.
  ///
  /// [resetOnNavigation] drops the driver's own bookkeeping (script ids and
  /// sources) on navigation. It cannot make coverage span documents: V8
  /// reports only scripts that are still alive, and the previous document's
  /// are collected with it.
  Future<void> startJSCoverage({
    bool resetOnNavigation = true,
    bool reportAnonymousScripts = false,
  });

  /// Stops collecting and returns what ran.
  Future<List<JSCoverageEntry>> stopJSCoverage();

  /// Starts collecting CSS coverage.
  Future<void> startCSSCoverage({bool resetOnNavigation = true});

  /// Stops collecting and returns which parts of each stylesheet were used.
  Future<List<CSSCoverageEntry>> stopCSSCoverage();
}

/// Merges the nested, per-rule ranges Chromium reports into a flat, disjoint,
/// ascending list of the parts that were used at least once.
///
/// Port of upstream's `convertToDisjointRanges` (crCoverage.ts). It is a
/// sweep line: every range contributes an opening and a closing point, the
/// points are sorted into a valid parenthesis sequence, and a stretch is kept
/// whenever the innermost open range has a non-zero count. Ranges of one
/// character or less are dropped, as upstream drops them.
List<CoverageRange> convertToDisjointRanges(
    List<JSCoverageRangeCount> nestedRanges) {
  final points = <({int offset, int type, JSCoverageRangeCount range})>[];
  for (final range in nestedRanges) {
    points.add((offset: range.startOffset, type: 0, range: range));
    points.add((offset: range.endOffset, type: 1, range: range));
  }
  points.sort((a, b) {
    if (a.offset != b.offset) return a.offset - b.offset;
    // Every "end" goes before every "start" at the same offset.
    if (a.type != b.type) return b.type - a.type;
    final aLength = a.range.endOffset - a.range.startOffset;
    final bLength = b.range.endOffset - b.range.startOffset;
    // Of two starts, the longer range opens first; of two ends, the shorter
    // one closes first. That is what keeps the sequence balanced.
    if (a.type == 0) return bLength - aLength;
    return aLength - bLength;
  });

  final hitCountStack = <int>[];
  final results = <({int start, int end})>[];
  var lastOffset = 0;
  for (final point in points) {
    if (hitCountStack.isNotEmpty &&
        lastOffset < point.offset &&
        hitCountStack.last > 0) {
      if (results.isNotEmpty && results.last.end == lastOffset) {
        results[results.length - 1] =
            (start: results.last.start, end: point.offset);
      } else {
        results.add((start: lastOffset, end: point.offset));
      }
    }
    lastOffset = point.offset;
    if (point.type == 0) {
      hitCountStack.add(point.range.count);
    } else if (hitCountStack.isNotEmpty) {
      hitCountStack.removeLast();
    }
  }

  return [
    for (final range in results)
      if (range.end - range.start > 1)
        CoverageRange(start: range.start, end: range.end),
  ];
}

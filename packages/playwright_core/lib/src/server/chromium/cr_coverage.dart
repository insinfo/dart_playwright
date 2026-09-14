import 'dart:async';

import 'package:playwright_protocol/playwright_protocol.dart';

import '../core_coverage.dart';

/// Chromium's coverage, over `Profiler.*` and `CSS.*`.
///
/// Port of upstream's `crCoverage.ts`. The one deliberate difference is that
/// stopping waits for the script and stylesheet *sources* still being
/// fetched. Reading a source is a round trip started from a protocol event,
/// so upstream can finish a run with a script whose source arrived one
/// message too late and report it without `source`. Here the pending reads
/// are tracked and awaited, which is also what keeps a failure inside an
/// event handler from going unnoticed.
class CrCoverage implements CoreCoverage {
  final dynamic session;

  CrCoverage(this.session);

  late final _JSCoverage _js = _JSCoverage(session);
  late final _CSSCoverage _css = _CSSCoverage(session);

  @override
  Future<void> startJSCoverage({
    bool resetOnNavigation = true,
    bool reportAnonymousScripts = false,
  }) =>
      _js.start(
        resetOnNavigation: resetOnNavigation,
        reportAnonymousScripts: reportAnonymousScripts,
      );

  @override
  Future<List<JSCoverageEntry>> stopJSCoverage() => _js.stop();

  @override
  Future<void> startCSSCoverage({bool resetOnNavigation = true}) =>
      _css.start(resetOnNavigation: resetOnNavigation);

  @override
  Future<List<CSSCoverageEntry>> stopCSSCoverage() => _css.stop();
}

/// Sends [method] and swallows a protocol failure.
///
/// A page that navigated away, or a script that was already collected, makes
/// these reads fail; that is not an error of the run, it only means the text
/// is not available.
Future<Map<String, dynamic>?> _sendMayFail(
    dynamic session, String method, Map<String, dynamic> params) async {
  try {
    return await session.send(method, params) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

class _JSCoverage {
  final dynamic session;

  _JSCoverage(this.session);

  bool _enabled = false;
  bool _resetOnNavigation = false;
  bool _reportAnonymousScripts = false;
  final _scriptIds = <String>{};
  final _scriptSources = <String, String>{};

  /// Source reads in flight. [stop] awaits them so the result does not depend
  /// on how the protocol messages happened to interleave.
  final _pendingSources = <Future<void>>[];

  void Function(Map<String, dynamic>)? _onScriptParsedListener;
  void Function(dynamic)? _onClearedListener;
  void Function(dynamic)? _onPausedListener;

  Future<void> start({
    required bool resetOnNavigation,
    required bool reportAnonymousScripts,
  }) async {
    if (_enabled) {
      throw PlaywrightException('JSCoverage is already enabled');
    }
    _resetOnNavigation = resetOnNavigation;
    _reportAnonymousScripts = reportAnonymousScripts;
    _enabled = true;
    _scriptIds.clear();
    _scriptSources.clear();
    _pendingSources.clear();

    _onScriptParsedListener = _onScriptParsed;
    _onClearedListener = (_) {
      if (!_resetOnNavigation) return;
      _scriptIds.clear();
      _scriptSources.clear();
    };
    // Coverage needs the Debugger domain to read script sources, and the
    // debugger would otherwise stop the page on a `debugger` statement or a
    // breakpoint. Skipping all pauses, and resuming anything that slips
    // through, keeps the page running.
    _onPausedListener = (_) {
      (session.send('Debugger.resume') as Future<dynamic>)
          .catchError((Object _) => <String, dynamic>{});
    };
    session.on('Debugger.scriptParsed', _onScriptParsedListener);
    session.on('Runtime.executionContextsCleared', _onClearedListener);
    session.on('Debugger.paused', _onPausedListener);

    await session.send('Profiler.enable');
    await session.send('Profiler.startPreciseCoverage',
        {'callCount': true, 'detailed': true});
    await session.send('Debugger.enable');
    await session.send('Debugger.setSkipAllPauses', {'skip': true});
  }

  void _onScriptParsed(Map<String, dynamic> event) {
    final scriptId = event['scriptId'] as String?;
    if (scriptId == null) return;
    _scriptIds.add(scriptId);
    final url = event['url'] as String? ?? '';
    if (url.isEmpty && !_reportAnonymousScripts) return;
    // Fire-and-forget by nature — this is an event handler — but the future
    // is remembered so that stop() can wait for it instead of racing it.
    _pendingSources.add(() async {
      final response = await _sendMayFail(
          session, 'Debugger.getScriptSource', {'scriptId': scriptId});
      final source = response?['scriptSource'] as String?;
      if (source != null) _scriptSources[scriptId] = source;
    }());
  }

  Future<List<JSCoverageEntry>> stop() async {
    if (!_enabled) return const <JSCoverageEntry>[];

    final profile = await session.send('Profiler.takePreciseCoverage')
        as Map<String, dynamic>;
    await session.send('Profiler.stopPreciseCoverage');
    await session.send('Profiler.disable');
    // The sources are read through the Debugger domain, so drain the pending
    // reads before disabling it.
    await Future.wait(_pendingSources);
    _pendingSources.clear();
    await session.send('Debugger.disable');

    session.off('Debugger.scriptParsed', _onScriptParsedListener);
    session.off('Runtime.executionContextsCleared', _onClearedListener);
    session.off('Debugger.paused', _onPausedListener);
    _enabled = false;

    final entries = <JSCoverageEntry>[];
    for (final raw in profile['result'] as List? ?? const []) {
      final entry = raw as Map<String, dynamic>;
      final scriptId = entry['scriptId'] as String? ?? '';
      if (!_scriptIds.contains(scriptId)) continue;
      final url = entry['url'] as String? ?? '';
      if (url.isEmpty && !_reportAnonymousScripts) continue;
      entries.add(JSCoverageEntry(
        url: url,
        scriptId: scriptId,
        source: _scriptSources[scriptId],
        functions: [
          for (final rawFunction in entry['functions'] as List? ?? const [])
            _functionFrom(rawFunction as Map<String, dynamic>),
        ],
      ));
    }
    return entries;
  }

  JSCoverageFunction _functionFrom(Map<String, dynamic> raw) {
    return JSCoverageFunction(
      functionName: raw['functionName'] as String? ?? '',
      isBlockCoverage: raw['isBlockCoverage'] == true,
      ranges: [
        for (final rawRange in raw['ranges'] as List? ?? const [])
          JSCoverageRangeCount(
            startOffset:
                ((rawRange as Map)['startOffset'] as num?)?.toInt() ?? 0,
            endOffset: (rawRange['endOffset'] as num?)?.toInt() ?? 0,
            count: (rawRange['count'] as num?)?.toInt() ?? 0,
          ),
      ],
    );
  }
}

class _CSSCoverage {
  final dynamic session;

  _CSSCoverage(this.session);

  bool _enabled = false;
  bool _resetOnNavigation = false;
  final _stylesheetURLs = <String, String>{};
  final _stylesheetSources = <String, String>{};
  final _pendingSources = <Future<void>>[];

  void Function(Map<String, dynamic>)? _onStyleSheetListener;
  void Function(dynamic)? _onClearedListener;

  Future<void> start({required bool resetOnNavigation}) async {
    if (_enabled) {
      throw PlaywrightException('CSSCoverage is already enabled');
    }
    _resetOnNavigation = resetOnNavigation;
    _enabled = true;
    _stylesheetURLs.clear();
    _stylesheetSources.clear();
    _pendingSources.clear();

    _onStyleSheetListener = _onStyleSheet;
    _onClearedListener = (_) {
      if (!_resetOnNavigation) return;
      _stylesheetURLs.clear();
      _stylesheetSources.clear();
    };
    session.on('CSS.styleSheetAdded', _onStyleSheetListener);
    session.on('Runtime.executionContextsCleared', _onClearedListener);

    await session.send('DOM.enable');
    await session.send('CSS.enable');
    await session.send('CSS.startRuleUsageTracking');
  }

  void _onStyleSheet(Map<String, dynamic> event) {
    final header = event['header'] as Map<String, dynamic>?;
    final styleSheetId = header?['styleSheetId'] as String?;
    final sourceURL = header?['sourceURL'] as String? ?? '';
    // A stylesheet with no URL — an inline <style> — has no text to line the
    // ranges up against, so upstream drops it and so does this.
    if (styleSheetId == null || sourceURL.isEmpty) return;
    _pendingSources.add(() async {
      final response = await _sendMayFail(
          session, 'CSS.getStyleSheetText', {'styleSheetId': styleSheetId});
      final text = response?['text'] as String?;
      if (text == null) return;
      _stylesheetURLs[styleSheetId] = sourceURL;
      _stylesheetSources[styleSheetId] = text;
    }());
  }

  Future<List<CSSCoverageEntry>> stop() async {
    if (!_enabled) return const <CSSCoverageEntry>[];

    final tracking = await session.send('CSS.stopRuleUsageTracking')
        as Map<String, dynamic>;
    await Future.wait(_pendingSources);
    _pendingSources.clear();
    await session.send('CSS.disable');
    await session.send('DOM.disable');

    session.off('CSS.styleSheetAdded', _onStyleSheetListener);
    session.off('Runtime.executionContextsCleared', _onClearedListener);
    _enabled = false;

    final byStyleSheet = <String, List<JSCoverageRangeCount>>{};
    for (final raw in tracking['ruleUsage'] as List? ?? const []) {
      final usage = raw as Map<String, dynamic>;
      final styleSheetId = usage['styleSheetId'] as String?;
      if (styleSheetId == null) continue;
      byStyleSheet.putIfAbsent(styleSheetId, () => []).add(JSCoverageRangeCount(
            startOffset: (usage['startOffset'] as num?)?.toInt() ?? 0,
            endOffset: (usage['endOffset'] as num?)?.toInt() ?? 0,
            count: usage['used'] == true ? 1 : 0,
          ));
    }

    return [
      for (final styleSheetId in _stylesheetURLs.keys)
        CSSCoverageEntry(
          url: _stylesheetURLs[styleSheetId]!,
          text: _stylesheetSources[styleSheetId]!,
          ranges: convertToDisjointRanges(
              byStyleSheet[styleSheetId] ?? const <JSCoverageRangeCount>[]),
        ),
    ];
  }
}

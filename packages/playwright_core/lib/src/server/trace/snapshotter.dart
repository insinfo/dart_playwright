// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/playwright-core/src/server/trace/recorder/
// snapshotter.ts

import 'dart:async';
import 'dart:convert';

import '../core_page.dart';
import 'snapshotter_injected.dart';
import 'trace_events.dart';
import 'trace_utils.dart';

/// Where a captured snapshot and the blobs it points at go.
abstract class SnapshotterDelegate {
  /// Stores a blob referenced by a snapshot and returns its path in the
  /// archive.
  String onSnapshotterBlob(String shortName, List<int> bytes);

  /// A frame snapshot is ready, in the shape of `FrameSnapshot` in the trace
  /// contract.
  void onFrameSnapshot(Map<String, dynamic> snapshot);
}

/// Captures the DOM of every frame of a page around an action.
///
/// The snapshot is not a screenshot: it is the document serialized by the
/// streamer in the page ([kSnapshotStreamerSource]), which the viewer renders
/// back into an iframe. That is what makes the rendered page in the viewer
/// selectable, inspectable and correct at the device pixel ratio the run used.
///
/// Two deliberate differences from upstream, both consequences of primitives
/// this port does not have yet:
///
/// * **The streamer is installed on first capture in a document, not before
///   the page's scripts.** Upstream uses `addInitScript`, which is not ported.
///   The snapshot itself is a full traversal, so what it captures is the same;
///   what is lost is the CSSOM interception for the window between the
///   document loading and the first capture, so a stylesheet a script edited
///   through `insertRule`/`replaceSync` in that window is not overridden in the
///   snapshot. Stylesheets served over the network are unaffected: they come
///   from the recorded network stream.
/// * **Capture is a normal evaluation with a deadline, not a non-stalling
///   one.** Upstream evaluates without stalling so a page blocked in `alert()`
///   or a synchronous XHR cannot hold up the capture. Here a blocked page loses
///   the snapshot after [captureTimeout] instead of blocking the action.
class Snapshotter {
  final SnapshotterDelegate _delegate;
  final String _streamerName = '__playwright_snapshot_streamer_${createGuid()}';

  /// How long one frame's capture may take. A page blocked in a modal dialog
  /// never answers; losing the snapshot is better than losing the action.
  static const captureTimeout = Duration(seconds: 5);

  /// The sentinel the fast path returns when the streamer is not in the
  /// document yet — the one navigation-proof way to notice, since a navigation
  /// replaces the document without telling us.
  static const _missing = '__playwright_no_streamer__';

  bool _started = false;
  final _markedFrames = <CoreFrame>{};

  Snapshotter(this._delegate);

  bool get started => _started;

  void start() => _started = true;

  void stop() {
    _started = false;
    _markedFrames.clear();
  }

  /// Captures every frame of [page] and hands the snapshots to the delegate.
  ///
  /// Best effort throughout: a frame that navigated away, detached or refused
  /// to answer is skipped, because an action must never fail because its
  /// snapshot did.
  Future<void> captureSnapshot(
    CorePage page,
    String callId,
    String phase, {
    required bool resetTargets,
  }) async {
    if (!_started) return;
    final frames = List<CoreFrame>.from(page.frames);
    if (frames.length > 1) await _markIframes(page, frames);
    await Future.wait([
      for (final frame in frames)
        _captureFrame(page, frame, callId, phase, resetTargets),
    ]);
  }

  Future<void> _captureFrame(
    CorePage page,
    CoreFrame frame,
    String callId,
    String phase,
    bool resetTargets,
  ) async {
    final data = await _capture(frame, resetTargets);
    if (data == null || !_started) return;

    final overrides = <Map<String, dynamic>>[];
    for (final override
        in (data['resourceOverrides'] as List? ?? const <dynamic>[])) {
      final map = override as Map<String, dynamic>;
      final content = map['content'];
      if (content is String) {
        final bytes = utf8.encode(content);
        final file = _delegate.onSnapshotterBlob(
            '${sha1Hex(bytes)}.${extensionForMimeType(map['contentType'] as String? ?? 'text/css')}',
            bytes);
        overrides.add({'url': map['url'], 'file': file});
      } else if (content is num) {
        // "x snapshots ago, same url" — the viewer walks back to the version
        // that was stored then instead of storing it again.
        overrides.add({'url': map['url'], 'ref': content});
      }
    }

    _delegate.onFrameSnapshot(<String, dynamic>{
      'callId': callId,
      'phase': phase,
      'pageId': page.guid,
      'frameId': frame.guid,
      'frameUrl': data['url'] ?? frame.url,
      if (data['doctype'] != null) 'doctype': data['doctype'],
      'html': data['html'],
      'viewport': data['viewport'],
      'timestamp': TraceClock.monotonicTime(),
      if (data['wallTime'] != null) 'wallTime': data['wallTime'],
      'collectionTime': data['collectionTime'] ?? 0,
      'resourceOverrides': overrides,
      'isMainFrame': identical(frame, page.mainFrame),
    });
  }

  Future<Map<String, dynamic>?> _capture(
      CoreFrame frame, bool resetTargets) async {
    final reset = jsonEncode(resetTargets ? 'targets' : null);
    final name = jsonEncode(_streamerName);
    final capture = '() => { const s = window[$name]; '
        'return s ? s.captureSnapshot($reset) : ${jsonEncode(_missing)}; }';
    try {
      var result = await frame.evaluate(capture).timeout(captureTimeout);
      if (result == _missing) {
        await frame
            .evaluate('() => { ($kSnapshotStreamerSource)($name, true); }')
            .timeout(captureTimeout);
        result = await frame.evaluate(capture).timeout(captureTimeout);
      }
      if (result is Map<String, dynamic>) return result;
      if (result is Map) return Map<String, dynamic>.from(result);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Tells the streamer in each parent frame which trace frame id its `iframe`
  /// elements point at, so the snapshot can reference the child's snapshot
  /// instead of rendering an empty box.
  ///
  /// The engines only report a frame's own id, never the element that owns it,
  /// so the mapping is built the other way round: take a handle to each iframe
  /// element and ask the page which frame it contains.
  Future<void> _markIframes(CorePage page, List<CoreFrame> frames) async {
    final pending =
        frames.where((frame) => !_markedFrames.contains(frame)).toList();
    if (pending.isEmpty) return;
    final parents = {
      for (final frame in pending)
        if (frame.parentFrame != null) frame.parentFrame!
    };
    for (final parent in parents) {
      try {
        await _markIframesIn(page, parent);
      } catch (_) {
        // A frame that went away mid-walk simply keeps its empty box.
      }
    }
    _markedFrames.addAll(pending);
  }

  /// Installs the streamer if this document does not have it yet.
  ///
  /// Only the iframe walk needs this as a separate step: marking has to reach
  /// a streamer that already exists, while [_capture] installs on demand from
  /// its own sentinel.
  Future<void> _ensureStreamer(CoreFrame frame) async {
    final name = jsonEncode(_streamerName);
    await frame
        .evaluate('() => { if (!window[$name]) '
            '($kSnapshotStreamerSource)($name, true); }')
        .timeout(captureTimeout);
  }

  Future<void> _markIframesIn(CorePage page, CoreFrame parent) async {
    await _ensureStreamer(parent);
    final count = await parent
        .evaluate("() => document.querySelectorAll('iframe,frame').length")
        .timeout(captureTimeout);
    if (count is! num) return;
    for (var i = 0; i < count.toInt(); i++) {
      final handle = await parent
          .evaluateHandle("() => document.querySelectorAll('iframe,frame')[$i]")
          .timeout(captureTimeout);
      try {
        final child = await page.contentFrame(handle).timeout(captureTimeout);
        if (child == null) continue;
        await handle
            .evaluate(
                '(el) => { const s = window[${jsonEncode(_streamerName)}];'
                ' if (s) s.markIframe(el, ${jsonEncode(child.guid)}); }')
            .timeout(captureTimeout);
      } finally {
        await handle.dispose().catchError((Object _) {});
      }
    }
  }
}

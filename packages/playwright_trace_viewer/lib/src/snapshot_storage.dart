// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/trace/snapshotStorage.ts

/// Every snapshot of every frame of one trace, indexed for the two questions
/// the viewer asks: "what did this frame look like at this point of this
/// call", and "what was this URL serving then".
library;

import 'lru_cache.dart';
import 'snapshot_renderer.dart';
import 'trace.dart';

/// 100MB of rendered HTML per trace.
const int kSnapshotHtmlCacheSize = 100000000;

/// The snapshots and resources of one trace.
class SnapshotStorage {
  final Map<String, List<FrameSnapshot>> _snapshotsByFrameId =
      <String, List<FrameSnapshot>>{};
  final Map<String, List<SnapshotRenderer>> _renderersByCallIdAndPhase =
      <String, List<SnapshotRenderer>>{};
  final LruCache<SnapshotRenderer, RenderedSnapshotHtml> _cache =
      LruCache<SnapshotRenderer, RenderedSnapshotHtml>(kSnapshotHtmlCacheSize);
  final List<ResourceSnapshot> _resources = <ResourceSnapshot>[];
  final Set<String> _resourceUrlsWithOverrides = <String>{};

  /// Records a `resource-snapshot`.
  ///
  /// The URL is rewritten the same way the DOM's URLs are, so a request the
  /// rendered snapshot makes matches the resource that answered it.
  void addResource(ResourceSnapshot resource) {
    resource.request.url = rewriteUrlForCustomProtocol(resource.request.url);
    _resources.add(resource);
  }

  /// Records a `frame-snapshot` and returns the renderer built for it.
  SnapshotRenderer addFrameSnapshot(
    FrameSnapshot snapshot,
    List<ScreencastFrameTraceEvent> screencastFrames,
  ) {
    for (final override in snapshot.resourceOverrides) {
      override.url = rewriteUrlForCustomProtocol(override.url);
    }
    final frameSnapshots =
        _snapshotsByFrameId.putIfAbsent(snapshot.frameId, () => []);
    frameSnapshots.add(snapshot);
    final renderer = SnapshotRenderer(
      _cache,
      _resources,
      frameSnapshots,
      screencastFrames,
      frameSnapshots.length - 1,
    );
    final phase = snapshot.phase;
    if (phase != null) {
      _renderersByCallIdAndPhase
          .putIfAbsent(_callIdAndPhase(snapshot.callId, phase), () => [])
          .add(renderer);
    }
    return renderer;
  }

  /// The snapshot of one call at one phase.
  ///
  /// Without [frameId] the main frame's snapshot is returned, which is what
  /// the panel shows; with one, the snapshot of that frame, which is what a
  /// nested `<iframe>` of the rendered page asks for.
  SnapshotRenderer? snapshotForCall(
    String callId,
    ActionPhase? phase, [
    String? frameId,
  ]) {
    if (phase == null) return null;
    final renderers =
        _renderersByCallIdAndPhase[_callIdAndPhase(callId, phase)] ??
            const <SnapshotRenderer>[];
    for (final renderer in renderers) {
      if (frameId != null
          ? renderer.snapshot().frameId == frameId
          : renderer.snapshot().isMainFrame) {
        return renderer;
      }
    }
    return null;
  }

  /// Every `callId/phase` key that has a snapshot, for tests.
  List<String> snapshotsForTest() => _renderersByCallIdAndPhase.keys.toList();

  /// Called once the whole trace has been read.
  void finalizeStorage() {
    // Resources are not necessarily sorted in the trace file, so sort them
    // now. The renderer walks them in time order and stops at the snapshot.
    _resources
        .sort((a, b) => (a.monotonicTime ?? 0).compareTo(b.monotonicTime ?? 0));
    // Resources that have overrides should not be cached, otherwise we might
    // get stale content while serving snapshots with different override
    // values.
    for (final frameSnapshots in _snapshotsByFrameId.values) {
      for (final snapshot in frameSnapshots) {
        for (final override in snapshot.resourceOverrides) {
          _resourceUrlsWithOverrides.add(override.url);
        }
      }
    }
  }

  /// True when some snapshot serves a different body for this URL, which is
  /// what stops the browser from caching it.
  bool hasResourceOverride(String url) =>
      _resourceUrlsWithOverrides.contains(url);

  static String _callIdAndPhase(String callId, ActionPhase phase) =>
      '$callId/${phase.wire}';
}

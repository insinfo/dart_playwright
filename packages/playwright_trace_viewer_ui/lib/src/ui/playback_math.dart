// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/trace-viewer/src/ui/playbackControl.tsx

/// The arithmetic behind the playback scrubber, with no DOM in sight.
///
/// Split out of `playback_control.dart` on purpose. This is the part that can
/// be wrong without anything *looking* wrong -- the panel still fills in, just
/// with the neighbouring action's data -- and keeping it free of `package:web`
/// is what lets it be tested at all, since the rest of the viewer only runs in
/// a browser.
///
/// The span type is spelled structurally rather than imported: `TimeSpan` is
/// declared in `timeline.dart`, which pulls in the DOM, and a record type is
/// structural in Dart so the shapes match anyway.
library;

import 'package:playwright_trace_viewer/playwright_trace_viewer.dart';

/// The index of the action whose start time is nearest [time].
///
/// Upstream's binary search finds the last action starting at or before the
/// moment, then looks one further and takes whichever is nearer -- so a
/// scrubber dropped between two actions lands on the closer one instead of
/// always falling back. The tie at the exact midpoint goes to the earlier
/// action, because the swap only happens when the next one is strictly closer.
///
/// [firstIndex] and [lastIndex] are the ends of the window the timeline has
/// selected: playback never leaves it.
///
/// Returns -1 for an empty list, which no caller should reach.
int actionIndexAtTime(
  List<ActionEntry> actions,
  double time, {
  required int firstIndex,
  required int lastIndex,
}) {
  if (actions.isEmpty) return -1;
  var lo = 0;
  var hi = actions.length - 1;
  while (lo < hi) {
    final mid = (lo + hi + 1) >> 1;
    if (actions[mid].startTime <= time) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  if (lo < actions.length - 1) {
    final distPrev = time - actions[lo].startTime;
    final distNext = actions[lo + 1].startTime - time;
    if (distNext < distPrev) lo = lo + 1;
  }
  return lo.clamp(firstIndex, lastIndex);
}

/// Where each action sits on the scrubber, as a percentage of the span.
///
/// Null past two hundred actions: upstream stops drawing ticks there, because
/// past that they stop being marks and become a solid bar.
///
/// A span of zero duration is treated as one, so a trace holding a single
/// action yields `0`, not `NaN`. `left: NaN%` is not an error a browser
/// reports -- the tick simply never appears.
List<double>? playbackTicks(
  List<ActionEntry> actions,
  ({double minimum, double maximum}) boundaries,
) {
  if (actions.isEmpty || actions.length > 200) return null;
  final duration = boundaries.maximum - boundaries.minimum;
  final span = duration == 0 ? 1.0 : duration;
  return [
    for (final action in actions)
      (action.startTime - boundaries.minimum) / span * 100,
  ];
}

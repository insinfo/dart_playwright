// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/trace-viewer/src/ui/timeline.tsx and
// packages/trace-viewer/src/ui/filmStrip.tsx

/// The strip above the workbench: a time grid and the frames the screencast
/// captured.
///
/// The film strip is worth having in this port specifically because all three
/// engines now record screencast frames, so the lane is never empty for a
/// trace this library wrote.
library;

import 'dart:js_interop';
import 'dart:math' as math;

import 'package:playwright_trace_viewer/playwright_trace_viewer.dart';
import 'package:web/web.dart' as web;

import 'dom.dart';
import 'format.dart';

/// The window of time the viewer is showing.
typedef TimeSpan = ({double minimum, double maximum});

/// `Timeline`: the grid, the film strip and the selection window.
class Timeline {
  final web.HTMLElement element;
  late final web.HTMLElement _view;
  late final web.HTMLElement _grid;
  late final FilmStrip filmStrip;
  late final web.HTMLElement _window;

  TraceModel? _model;
  TimeSpan _boundaries = (minimum: 0, maximum: 30000);
  TimeSpan? selectedTime;

  /// Called when the user drags a window, or clicks to pick an action.
  void Function(TimeSpan? span)? onSelectedTimeChanged;
  void Function(ActionEntry action)? onActionSelected;

  Timeline() : element = div(className: 'timeline-view-container') {
    _grid = div(className: 'timeline-grid');
    filmStrip = FilmStrip();
    _window = div(className: 'timeline-window');
    _view = div(
        className: 'timeline-view',
        children: [_grid, filmStrip.element, _window]);
    element.append(_view);
    _installDrag();
    web.window.addEventListener('resize', ((web.Event _) => redraw()).toJS);
    // The grid and the lanes are laid out against the width they were given,
    // and at construction time that width is zero because nothing is in the
    // document yet. Without this the first paint draws an empty strip and
    // never corrects itself.
    final observer = web.ResizeObserver(((JSArray _, web.ResizeObserver __) {
      redraw();
    }).toJS);
    observer.observe(_view);
  }

  /// Redraws the grid and the film strip against the current width.
  void redraw() {
    _draw();
    filmStrip.redraw();
  }

  /// The whole span of the trace, with the five percent of slack upstream
  /// leaves on the right so the last action is not flush with the edge.
  TimeSpan get boundaries => _boundaries;

  void update(TraceModel? model) {
    _model = model;
    if (model != null) {
      var minimum = model.startTime;
      var maximum = model.endTime;
      if (minimum > maximum) {
        minimum = 0;
        maximum = 30000;
      }
      maximum += (maximum - minimum) / 20;
      _boundaries = (minimum: minimum, maximum: maximum);
    }
    filmStrip.boundaries = _boundaries;
    filmStrip.update(model);
    _draw();
  }

  double _timeToPosition(double width, double time) =>
      (time - _boundaries.minimum) /
      (_boundaries.maximum - _boundaries.minimum) *
      width;

  double _positionToTime(double width, double x) =>
      x / width * (_boundaries.maximum - _boundaries.minimum) +
      _boundaries.minimum;

  void _draw() {
    final width = _view.getBoundingClientRect().width;
    removeChildren(_grid);
    if (width <= 0) return;
    for (final offset in _dividers(width)) {
      _grid.append(div(
        className: 'timeline-divider',
        style: {'left': '${offset.position}px'},
        children: [
          div(
              className: 'timeline-time',
              text: msToString(offset.time - _boundaries.minimum))
        ],
      ));
    }

    removeChildren(_window);
    final span = selectedTime;
    if (span == null) {
      setHidden(_window, true);
      return;
    }
    setHidden(_window, false);
    final left = _timeToPosition(width, span.minimum);
    final right = width - _timeToPosition(width, span.maximum);
    _window.append(div(
        className: 'timeline-window-curtain left',
        style: {'width': '${left}px'}));
    _window.append(div(
        className: 'timeline-window-resizer', style: {'left': '-5px'}));
    _window.append(div(
        className: 'timeline-window-center',
        children: [div(className: 'timeline-window-drag')]));
    _window.append(
        div(className: 'timeline-window-resizer', style: {'left': '5px'}));
    _window.append(div(
        className: 'timeline-window-curtain right',
        style: {'width': '${right}px'}));
  }

  /// Where to put the time labels so they are at least 64 pixels apart and
  /// land on a round number of milliseconds.
  List<({double time, double position})> _dividers(double width) {
    const minimumGap = 64.0;
    final span = _boundaries.maximum - _boundaries.minimum;
    if (span <= 0 || width <= 0) return const [];
    final pixelsPerMillisecond = width / span;
    var sectionTime = span / (width / minimumGap);
    sectionTime =
        math.pow(10, (math.log(sectionTime) / math.ln10).ceil()).toDouble();
    if (sectionTime * pixelsPerMillisecond >= 5 * minimumGap) {
      sectionTime /= 5;
    }
    if (sectionTime * pixelsPerMillisecond >= 2 * minimumGap) {
      sectionTime /= 2;
    }
    if (sectionTime == 0) return const [];
    final first = _boundaries.minimum;
    final last = _boundaries.maximum + minimumGap / pixelsPerMillisecond;
    final count = ((last - first) / sectionTime).ceil();
    return [
      for (var i = 0; i < count; i++)
        (
          time: first + sectionTime * i,
          position: _timeToPosition(width, first + sectionTime * i),
        )
    ];
  }

  void _installDrag() {
    double? startX;
    _view.addEventListener('mousedown', ((web.Event event) {
      final rect = _view.getBoundingClientRect();
      startX = (event as web.MouseEvent).clientX - rect.left;
    }).toJS);
    _view.addEventListener('mouseup', ((web.Event event) {
      final begin = startX;
      startX = null;
      if (begin == null) return;
      final rect = _view.getBoundingClientRect();
      final endX = (event as web.MouseEvent).clientX - rect.left;
      final width = rect.width;
      if ((endX - begin).abs() < 2) {
        // A click, not a drag: clear the window and select the last action
        // that had started by then, which is what the user pointed at.
        selectedTime = null;
        onSelectedTimeChanged?.call(null);
        final time = _positionToTime(width, endX);
        ActionEntry? found;
        for (final action in _model?.actions ?? const <ActionEntry>[]) {
          if (action.startTime <= time) found = action;
        }
        if (found != null) onActionSelected?.call(found);
        _draw();
        return;
      }
      final t1 = _positionToTime(width, begin);
      final t2 = _positionToTime(width, endX);
      selectedTime =
          (minimum: math.min(t1, t2), maximum: math.max(t1, t2));
      onSelectedTimeChanged?.call(selectedTime);
      _draw();
    }).toJS);
    // Double-clicking anywhere clears the window, which is the way back out
    // of a zoom without hunting for an edge.
    _view.addEventListener('dblclick', ((web.Event _) {
      selectedTime = null;
      onSelectedTimeChanged?.call(null);
      _draw();
    }).toJS);
  }
}

/// `FilmStrip`: one lane of screenshots per page, laid out on the timeline.
class FilmStrip {
  final web.HTMLElement element;
  late final web.HTMLElement _lanes;

  TimeSpan boundaries = (minimum: 0, maximum: 30000);
  TraceModel? _model;

  /// The tile a frame is scaled into, which fixes the lane height at 50px
  /// including margins — the number the hover hit-test depends on.
  static const double _tileWidth = 200;
  static const double _tileHeight = 45;
  static const double _frameMargin = 2.5;

  FilmStrip() : element = div(className: 'film-strip') {
    _lanes = div(className: 'film-strip-lanes');
    element.append(_lanes);
  }

  void update(TraceModel? model) {
    _model = model;
    redraw();
  }

  /// Redraws the lanes against the current width.
  void redraw() => _draw();

  void _draw() {
    removeChildren(_lanes);
    final model = _model;
    if (model == null) return;
    final width = element.getBoundingClientRect().width;
    if (width <= 0) return;
    for (final page in model.pages) {
      if (page.screencastFrames.isEmpty) continue;
      _lanes.append(_lane(page.screencastFrames, width));
    }
  }

  web.HTMLElement _lane(List<ScreencastFrameTraceEvent> frames, double width) {
    var viewportWidth = 0.0;
    var viewportHeight = 0.0;
    for (final frame in frames) {
      viewportWidth = math.max(viewportWidth, frame.width.toDouble());
      viewportHeight = math.max(viewportHeight, frame.height.toDouble());
    }
    final size = _inscribe(viewportWidth, viewportHeight);

    final startTime = frames.first.timestamp;
    final endTime = frames.last.timestamp;
    final span = boundaries.maximum - boundaries.minimum;
    final gapLeft = (startTime - boundaries.minimum) / span * width;
    final gapRight = (boundaries.maximum - endTime) / span * width;
    final effectiveWidth = (endTime - startTime) / span * width;
    final count =
        (effectiveWidth / (size.width + 2 * _frameMargin)).truncate();

    final lane = div(className: 'film-strip-lane', style: {
      'margin-left': '${gapLeft}px',
      'margin-right': '${gapRight}px',
    });
    final frameDuration = count > 0 ? (endTime - startTime) / count : 0.0;
    for (var i = 0; i < count; i++) {
      final time = startTime + frameDuration * i;
      final index = upperBound<ScreencastFrameTraceEvent>(
              frames, time, (t, frame) => t - frame.timestamp) -
          1;
      if (index < 0) continue;
      lane.append(_frame(frames[index], size));
    }
    // Upstream always appends one more frame, the last one, so the lane ends
    // on what the page actually looked like when the recording stopped.
    lane.append(_frame(frames.last, size));
    return lane;
  }

  web.HTMLElement _frame(
      ScreencastFrameTraceEvent frame, ({double width, double height}) size) {
    final url = 'file/${Uri.encodeComponent(frame.file)}';
    return div(className: 'film-strip-frame', style: {
      'width': '${size.width}px',
      'height': '${size.height}px',
      'background-image': 'url($url)',
      'background-size': '${size.width}px ${size.height}px',
      'margin': '${_frameMargin}px',
    });
  }

  /// Scales a viewport into the tile, filling one axis exactly.
  ({double width, double height}) _inscribe(double width, double height) {
    if (width <= 0 || height <= 0) {
      return (width: _tileWidth, height: _tileHeight);
    }
    final scale =
        math.max(width / _tileWidth, height / _tileHeight);
    return (
      width: (width / scale).truncateToDouble(),
      height: (height / scale).truncateToDouble(),
    );
  }
}

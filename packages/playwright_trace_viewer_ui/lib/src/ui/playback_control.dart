// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/trace-viewer/src/ui/playbackControl.tsx

/// Playing a trace back: the transport buttons and the scrubber.
///
/// Upstream keeps the state in a React hook (`usePlayback`) and the chrome in
/// two components. A hook has no equivalent here, so the state lives in one
/// object that owns both — but the arithmetic that decides *which action a
/// moment in time belongs to* is kept apart, in [actionIndexAtTime], because
/// it is the part that can be wrong without anything looking wrong, and the
/// only part testable without a browser.
library;

import 'dart:js_interop';

import 'package:playwright_trace_viewer/playwright_trace_viewer.dart';
import 'package:web/web.dart' as web;

import 'dom.dart';
import 'playback_math.dart';
import 'timeline.dart' show TimeSpan;

export 'playback_math.dart' show actionIndexAtTime, playbackTicks;

/// The speeds the button cycles through, in upstream's order.
const List<double> kPlaybackSpeeds = [0.5, 1, 2];

/// `usePlayback` plus `PlaybackButtons` and `PlaybackScrubber`, in one object.
class PlaybackControl {
  /// The transport buttons, for a toolbar.
  final web.HTMLElement buttons;

  /// The scrubber, for the strip above the timeline.
  final web.HTMLElement scrubber;

  late final web.HTMLButtonElement _prevButton;
  late final web.HTMLButtonElement _playButton;
  late final web.HTMLButtonElement _stopButton;
  late final web.HTMLButtonElement _nextButton;
  late final web.HTMLButtonElement _speedButton;
  late final web.HTMLElement _filled;
  late final web.HTMLElement _thumb;
  late final web.HTMLElement _ticksLayer;

  List<ActionEntry> _actions = const [];
  TimeSpan _boundaries = (minimum: 0, maximum: 1);

  /// The range the timeline has selected, if any: playback stays inside it.
  TimeSpan? timeWindow;

  bool _playing = false;
  int _speedIndex = 1;
  bool _dragging = false;
  double? _dragFraction;
  double? _cursorTime;
  int? _rafId;
  double? _lastFrameTime;
  double _traceTime = 0;
  int _lastSelectedIndex = -1;

  /// The action the workbench considers selected, and how to change it.
  ActionEntry? selectedAction;
  void Function(ActionEntry action)? onActionSelected;

  PlaybackControl()
      : buttons = span(className: 'playback-buttons'),
        scrubber = div(className: 'playback-scrubber', attrs: {
          'tabindex': '0',
          'role': 'slider',
          'aria-label': 'Playback position',
          'aria-valuemin': '0',
          'aria-valuemax': '100',
        }) {
    _prevButton = toolbarButton(
        icon: 'chevron-left', title: 'Previous action', onClick: prev);
    _playButton = toolbarButton(icon: 'play', title: 'Play', onClick: toggle);
    _stopButton =
        toolbarButton(icon: 'debug-stop', title: 'Stop', onClick: stop);
    _nextButton = toolbarButton(
        icon: 'chevron-right', title: 'Next action', onClick: next);
    _speedButton = el('button',
        className: 'playback-speed',
        text: '1x',
        attrs: {'title': 'Playback speed'}) as web.HTMLButtonElement;
    _speedButton.onClick.listen((_) => cycleSpeed());
    buttons.append(_prevButton);
    buttons.append(_playButton);
    buttons.append(_stopButton);
    buttons.append(_nextButton);
    buttons.append(_speedButton);

    _ticksLayer = div(className: 'playback-ticks');
    _filled = div(className: 'playback-track-filled');
    _thumb = div(className: 'playback-thumb');
    scrubber.append(div(className: 'playback-track'));
    scrubber.append(_filled);
    scrubber.append(_ticksLayer);
    scrubber.append(_thumb);

    scrubber.onMouseDown.listen(_onScrubberMouseDown);
    scrubber.onKeyDown.listen((event) {
      if (event.key == 'ArrowLeft') {
        event.preventDefault();
        prev();
      } else if (event.key == 'ArrowRight') {
        event.preventDefault();
        next();
      }
    });
  }

  double get speed => kPlaybackSpeeds[_speedIndex];

  bool get playing => _playing;

  /// The actions currently listed, and the span the timeline is showing.
  void update(List<ActionEntry> actions, TimeSpan boundaries) {
    // Upstream stops playback whenever the action list changes; a new list
    // means the indices the loop is walking no longer mean what they meant.
    if (!identical(actions, _actions)) _setPlaying(false);
    _actions = actions;
    _boundaries = boundaries;
    render();
  }

  List<ActionEntry> get _windowActions {
    final window = timeWindow;
    if (window == null) return _actions;
    return _actions
        .where((a) =>
            a.startTime >= window.minimum && a.startTime <= window.maximum)
        .toList();
  }

  int get _firstWindowIndex {
    final window = _windowActions;
    return window.isEmpty ? 0 : _actions.indexOf(window.first);
  }

  int get _lastWindowIndex {
    final window = _windowActions;
    return window.isEmpty ? _actions.length - 1 : _actions.indexOf(window.last);
  }

  int get _currentIndex {
    final action = selectedAction;
    return action == null ? -1 : _actions.indexOf(action);
  }

  int _indexAtTime(double time) => actionIndexAtTime(_actions, time,
      firstIndex: _firstWindowIndex, lastIndex: _lastWindowIndex);

  void _select(int index) {
    if (index < 0 || index >= _actions.length) return;
    onActionSelected?.call(_actions[index]);
  }

  void toggle() {
    if (_actions.isEmpty) return;
    // At the end, playing again starts over rather than doing nothing.
    final atEnd = _currentIndex >= _lastWindowIndex;
    if (!_playing && atEnd) _select(_firstWindowIndex);
    _setPlaying(!_playing);
  }

  void stop() {
    _setPlaying(false);
    if (_actions.isNotEmpty) _select(_firstWindowIndex);
  }

  void prev() {
    final target =
        (_currentIndex - 1).clamp(_firstWindowIndex, _actions.length);
    if (target != _currentIndex) _select(target);
  }

  void next() {
    final target = (_currentIndex + 1).clamp(0, _lastWindowIndex);
    if (target != _currentIndex) _select(target);
  }

  void cycleSpeed() {
    _speedIndex = (_speedIndex + 1) % kPlaybackSpeeds.length;
    render();
  }

  void _setPlaying(bool value) {
    if (_playing == value) return;
    _playing = value;
    if (value) {
      final window = timeWindow;
      final windowMin = window?.minimum ?? _boundaries.minimum;
      _traceTime = selectedAction?.startTime ?? _boundaries.minimum;
      if (_traceTime < windowMin) _traceTime = windowMin;
      _lastSelectedIndex = _currentIndex;
      _lastFrameTime = null;
      _cursorTime = _traceTime;
      _rafId = web.window.requestAnimationFrame(_tick.toJS);
    } else {
      final id = _rafId;
      if (id != null) web.window.cancelAnimationFrame(id);
      _rafId = null;
      _cursorTime = null;
    }
    render();
  }

  void _tick(num now) {
    if (!_playing) return;
    final window = timeWindow;
    final windowMax = window?.maximum ?? _boundaries.maximum;
    final last = _lastFrameTime;
    if (last != null) {
      // Wall-clock delta scaled by the speed: the trace's own clock advances
      // at whatever rate the button says, not at the frame rate.
      final delta = (now.toDouble() - last) * speed;
      _traceTime = (_traceTime + delta).clamp(_boundaries.minimum, windowMax);
    }
    _lastFrameTime = now.toDouble();
    _cursorTime = _traceTime;

    final index = _indexAtTime(_traceTime);
    if (index != _lastSelectedIndex) {
      _lastSelectedIndex = index;
      _select(index);
    }
    if (_traceTime >= windowMax) {
      _setPlaying(false);
      return;
    }
    render();
    _rafId = web.window.requestAnimationFrame(_tick.toJS);
  }

  double _fractionFromEvent(web.MouseEvent event) {
    final rect = scrubber.getBoundingClientRect();
    if (rect.width == 0) return 0;
    return ((event.clientX - rect.left) / rect.width).clamp(0.0, 1.0);
  }

  void _selectAtFraction(double fraction) {
    if (_actions.isEmpty) return;
    final duration = _boundaries.maximum - _boundaries.minimum;
    final span = duration == 0 ? 1.0 : duration;
    _select(_indexAtTime(_boundaries.minimum + fraction * span));
  }

  void _onScrubberMouseDown(web.MouseEvent event) {
    if (_actions.isEmpty || event.button != 0) return;
    event.preventDefault();
    event.stopPropagation();
    scrubber.focus();
    _dragging = true;
    _setPlaying(false);
    _dragFraction = _fractionFromEvent(event);
    _selectAtFraction(_dragFraction!);
    render();

    late final JSFunction onMove;
    late final JSFunction onUp;
    onMove = ((web.MouseEvent moveEvent) {
      _dragFraction = _fractionFromEvent(moveEvent);
      _selectAtFraction(_dragFraction!);
      render();
    }).toJS;
    onUp = ((web.MouseEvent upEvent) {
      web.document.removeEventListener('mousemove', onMove);
      web.document.removeEventListener('mouseup', onUp);
      _selectAtFraction(_fractionFromEvent(upEvent));
      _dragFraction = null;
      _dragging = false;
      render();
    }).toJS;
    web.document.addEventListener('mousemove', onMove);
    web.document.addEventListener('mouseup', onUp);
  }

  /// Where the thumb sits, as a percentage of the whole span.
  double get percent {
    final duration = _boundaries.maximum - _boundaries.minimum;
    final span = duration == 0 ? 1.0 : duration;
    final fraction = _dragFraction;
    if (_dragging && fraction != null) return fraction * 100;
    final cursor = _cursorTime;
    if (_playing && cursor != null) {
      return ((cursor - _boundaries.minimum) / span * 100).clamp(0.0, 100.0);
    }
    final selected = selectedAction?.startTime ?? _boundaries.minimum;
    return ((selected - _boundaries.minimum) / span * 100).clamp(0.0, 100.0);
  }

  /// Repaints the buttons and the scrubber against the current state.
  void render() {
    final index = _currentIndex;
    _prevButton.disabled = !(index > _firstWindowIndex);
    _nextButton.disabled = !(index < _lastWindowIndex);
    _stopButton.disabled = !(_playing || index > _firstWindowIndex);
    _playButton.disabled = _actions.isEmpty;
    _playButton.className = clsx([
      'toolbar-button',
      _playing ? 'debug-pause' : 'play',
    ]);
    _playButton.title = _playing ? 'Pause' : 'Play';
    _speedButton.textContent = '${_formatSpeed(speed)}x';

    // Animated only when nothing is driving the position frame by frame: a
    // CSS transition during playback or a drag fights the thing moving it.
    final animating = !_playing && !_dragging;
    final value = percent;
    _filled.className =
        clsx(['playback-track-filled', animating ? 'animated' : null]);
    _filled.style.width = '$value%';
    _thumb.className = clsx(['playback-thumb', animating ? 'animated' : null]);
    _thumb.style.left = '$value%';
    scrubber.setAttribute('aria-valuenow', '${value.round()}');

    removeChildren(_ticksLayer);
    final ticks = playbackTicks(_actions, _boundaries);
    if (ticks != null) {
      for (final tick in ticks) {
        _ticksLayer.append(div(className: 'playback-tick', style: {
          'left': '$tick%',
        }));
      }
    }
  }
}

/// `0.5x`, `1x`, `2x`: no trailing zero on a whole number.
String _formatSpeed(double speed) =>
    speed == speed.roundToDouble() ? '${speed.round()}' : '$speed';

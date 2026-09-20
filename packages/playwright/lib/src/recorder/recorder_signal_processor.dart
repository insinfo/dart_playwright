// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source:
// packages/playwright-core/src/server/recorder/recorderSignalProcessor.ts.

import 'dart:async';

import 'package:playwright_isomorphic/playwright_isomorphic.dart';

/// How long an action is held back, waiting for a superseding action to merge
/// with it: a double click after a click, another navigation after a
/// navigation.
const Duration _kActionBufferTimeout = Duration(milliseconds: 500);

/// Where the processed actions and signals go.
abstract class ProcessorDelegate {
  void addAction(ActionInContext actionInContext);
  void addSignal(SignalInContext signalInContext);
}

/// A signal held back with its action.
class _BufferedSignal {
  final String pageGuid;
  final bool isMainFrame;
  final String frameUrl;
  final Signal signal;
  final int timestamp;

  _BufferedSignal(this.pageGuid, this.isMainFrame, this.frameUrl, this.signal,
      this.timestamp);
}

class _PendingAction {
  ActionInContext actionInContext;
  int receivedAt;
  final List<_BufferedSignal> signals = [];
  Timer timeout;

  _PendingAction(this.actionInContext, this.receivedAt, this.timeout);
}

/// Turns the raw stream of actions and signals into the sequence the code
/// generators consume.
///
/// Two jobs, both upstream's: it merges an action with the one that supersedes
/// it (a double click arriving right after a click, a second navigation right
/// after the first), and it decides when a main-frame navigation becomes a
/// `goto` of its own instead of a signal attached to the action that caused it.
///
/// Difference from upstream: a signal arrives as a `(pageGuid, isMainFrame,
/// frameUrl)` triple instead of a `Frame`. This port's recorder runs on the
/// public API, where a frame object is not a stable key and reading its url is
/// a different call; the three values are everything upstream reads off the
/// frame, captured at the moment the signal happened.
class RecorderSignalProcessor {
  final ProcessorDelegate _delegate;

  /// Under test the threshold that turns a navigation into its own `goto` is
  /// shortened, exactly as upstream's `isUnderTest()` does.
  final bool isUnderTest;

  ActionInContext? _lastAction;
  int _lastActionTimestamp = 0;
  _PendingAction? _pendingAction;

  RecorderSignalProcessor(this._delegate, {this.isUnderTest = false});

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  void addAction(ActionInContext actionInContext) {
    final timestamp = _now();
    final pending = _pendingAction;
    if (pending != null) {
      if (_supersedes(actionInContext, pending.actionInContext)) {
        pending.actionInContext = actionInContext;
        pending.receivedAt = timestamp;
        _resetPendingTimeout();
        return;
      }
      flush();
    }

    if (_shouldBuffer(actionInContext)) {
      _pendingAction = _PendingAction(
          actionInContext, timestamp, Timer(_kActionBufferTimeout, flush));
      return;
    }

    _emitAction(actionInContext, timestamp);
  }

  /// [frameUrl] is the url of the frame the signal happened in, read at the
  /// moment it happened.
  void signal(
      String pageGuid, bool isMainFrame, String frameUrl, Signal signal) {
    final timestamp = _now();
    final isMainFrameNavigation = signal is NavigationSignal && isMainFrame;
    final pending = _pendingAction;
    if (pending != null &&
        pending.actionInContext.action is NavigateAction &&
        isMainFrameNavigation &&
        pending.actionInContext.pageGuid == pageGuid) {
      pending.actionInContext = ActionInContext(
        pageGuid: pending.actionInContext.pageGuid,
        action: NavigateAction(url: frameUrl),
        signals: pending.actionInContext.signals,
      );
      _resetPendingTimeout();
      return;
    }
    if (pending != null) {
      pending.signals.add(
          _BufferedSignal(pageGuid, isMainFrame, frameUrl, signal, timestamp));
    } else {
      _processSignal(pageGuid, isMainFrame, frameUrl, signal, timestamp);
    }
  }

  bool _shouldBuffer(ActionInContext actionInContext) {
    final action = actionInContext.action;
    return (action is ClickAction && action.button == 'left') ||
        action is NavigateAction;
  }

  bool _supersedes(ActionInContext actionInContext, ActionInContext pending) {
    final action = actionInContext.action;
    final pendingAction = pending.action;
    if (actionInContext.pageGuid != pending.pageGuid) return false;
    // A higher click count on the same target is a double (or triple) click.
    if (action is ClickAction && pendingAction is ClickAction) {
      return action.selector == pendingAction.selector &&
          action.clickCount > pendingAction.clickCount;
    }
    // Another navigation on the same page supersedes the previous url.
    if (action is NavigateAction && pendingAction is NavigateAction)
      return true;
    return false;
  }

  void _resetPendingTimeout() {
    final pending = _pendingAction;
    if (pending == null) return;
    pending.timeout.cancel();
    pending.timeout = Timer(_kActionBufferTimeout, flush);
  }

  void _emitAction(ActionInContext actionInContext, int timestamp) {
    _lastAction = actionInContext;
    _lastActionTimestamp = timestamp;
    _delegate.addAction(actionInContext);
  }

  /// Releases the buffered action, if any, with the signals that arrived while
  /// it was held back.
  void flush() {
    final pending = _pendingAction;
    if (pending == null) return;
    pending.timeout.cancel();
    _pendingAction = null;
    _emitAction(pending.actionInContext, pending.receivedAt);
    // Replay the signals with their original timestamps, so that they attach
    // to the emitted action.
    for (final buffered in pending.signals) {
      _processSignal(buffered.pageGuid, buffered.isMainFrame, buffered.frameUrl,
          buffered.signal, buffered.timestamp);
    }
  }

  void _processSignal(String pageGuid, bool isMainFrame, String frameUrl,
      Signal signal, int timestamp) {
    if (signal is NavigationSignal && isMainFrame) {
      final lastAction = _lastAction;
      final signalThreshold = isUnderTest ? 500 : 5000;

      // A duplicate navigation signal to the url we already recorded a goto
      // for must not produce a second identical goto.
      final lastNavigate = lastAction?.action;
      if (lastNavigate is NavigateAction &&
          lastAction!.pageGuid == pageGuid &&
          lastNavigate.url == frameUrl) {
        return;
      }

      var generateGoto = false;
      if (lastAction == null) {
        generateGoto = true;
      } else if (lastAction.action is! ClickAction &&
          lastAction.action is! PressAction &&
          lastAction.action is! FillAction) {
        generateGoto = true;
      } else if (timestamp - _lastActionTimestamp > signalThreshold) {
        generateGoto = true;
      }

      if (generateGoto) {
        addAction(ActionInContext(
          pageGuid: pageGuid,
          action: NavigateAction(url: frameUrl),
        ));
      }
      return;
    }

    _delegate.addSignal(SignalInContext(pageGuid: pageGuid, signal: signal));
  }
}

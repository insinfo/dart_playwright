// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/playwright-core/src/server/recorder.ts and
// packages/playwright-core/src/server/recorder/recorderRunner.ts.

import 'dart:async';

import 'package:playwright_core/src/server/injected/injected_recorder_source.dart';
import 'package:playwright_core/src/server/injected/injected_script_source.dart';
import 'package:playwright_isomorphic/playwright_isomorphic.dart';

import '../binding_source.dart';
import '../browser_context.dart';
import '../frame.dart';
import '../page.dart';
import 'recorder_actions.dart';
import 'recorder_signal_processor.dart';
import 'recorder_types.dart';
import 'recorder_utils.dart';

/// Turns what the user does in the browser into [ActionInContext]s.
///
/// This is upstream's `Recorder` — the context-side half, not the app. It
/// installs the injected recorder in every frame of the context, answers the
/// bindings that script calls, and feeds a [RecorderSignalProcessor] whose
/// output is this class's two streams.
///
/// Differences from upstream, all because the machinery it leans on is not in
/// this port:
///
/// * **No debugger.** Upstream's recorder doubles as the inspector: it pauses
///   on `page.pause()`, tracks call metadata, highlights the selector of the
///   call in flight and renders a call log. This port has no `Debugger` and no
///   call-metadata instrumentation, so `pause`, `resume`, `step`, the call log
///   and the user-source list are all absent. What is left is the recorder
///   proper.
/// * **Signals carry values, not frames.** See [RecorderSignalProcessor].
/// * **Page identity is the public [Page] object.** Upstream keys actions by
///   `page.guid`; this port's public API has no guid, so the recorder assigns
///   one (`page@1`, `page@2`, ...) in the order pages appear. The generators
///   only use the guid to tell pages apart and to name the popup aliases, so
///   the numbering is all they need.
class Recorder implements ProcessorDelegate {
  final BrowserContext context;

  /// What `asLocator` is asked for when the page wants a tooltip.
  String language;

  /// The attribute `getByTestId` reads, handed to the in-page generator.
  final String testIdAttributeName;

  /// Upstream's `isUnderTest()`: shortens the navigation threshold and turns
  /// on the page-side console traces the tests read.
  final bool isUnderTest;

  final bool hideToolbar;

  final _actions = StreamController<ActionInContext>.broadcast();
  final _signals = StreamController<SignalInContext>.broadcast();
  final _elementPicked = StreamController<ElementInfo>.broadcast();

  late final RecorderSignalProcessor _signalProcessor =
      RecorderSignalProcessor(this, isUnderTest: isUnderTest);

  final Map<Page, String> _pageGuids = {};
  final List<StreamSubscription<Object?>> _subscriptions = [];

  String _mode = RecorderMode.none;
  OverlayState _overlayState = const OverlayState();
  var _enabled = false;
  var _nextPageOrdinal = 0;
  var _lastDialogOrdinal = -1;
  var _lastDownloadOrdinal = -1;
  var _installed = false;

  Recorder(
    this.context, {
    this.language = Languages.dart,
    this.testIdAttributeName = 'data-testid',
    this.isUnderTest = false,
    this.hideToolbar = false,
  }) {
    // Most test pages put their elements at the top left, where the floating
    // toolbar would sit; get out of the way, as upstream does.
    if (isUnderTest) _overlayState = const OverlayState(offsetX: 200);
  }

  /// Every action the user performed, in the order the generators want them.
  Stream<ActionInContext> get onAction => _actions.stream;

  /// Navigations, popups, downloads and dialogs, attached to the action that
  /// caused them by the consumer.
  Stream<SignalInContext> get onSignal => _signals.stream;

  /// A selector the user picked with the locator picker.
  Stream<ElementInfo> get onElementPicked => _elementPicked.stream;

  String get mode => _mode;

  /// Installs the bindings and the injected script, then starts watching the
  /// pages the context already has.
  Future<void> install() async {
    if (_installed) return;
    _installed = true;

    await context.exposeBinding(
        kRecorderStateBinding, (source, args) => _uiState().toJson());
    await context.exposeBinding(kDescribeSelectorBinding, (source, args) {
      final selector = args.isEmpty ? null : args.first as String?;
      if (selector == null || selector.isEmpty) return null;
      try {
        return asLocator(language, selector);
      } catch (_) {
        // A selector with no locator spelling: the page keeps showing the raw
        // selector, which is what upstream's `asLocator` fallback does too.
        return selector;
      }
    });
    await context.exposeBinding(kRecorderSetModeBinding, (source, args) async {
      if (source.frame?.parentFrame() != null) return null;
      await setMode(args.isEmpty ? RecorderMode.none : '${args.first}');
      return null;
    });
    await context.exposeBinding(kRecorderSetOverlayStateBinding,
        (source, args) {
      if (source.frame?.parentFrame() != null) return null;
      _overlayState =
          OverlayState.fromJson(asJsonMap(args.isEmpty ? null : args.first));
      return null;
    });
    await context.exposeBinding(kRecorderElementPickedBinding,
        (source, args) async {
      final info = asJsonMap(args.isEmpty ? null : args.first);
      final frame = source.frame;
      var selector = info['selector'] as String? ?? '';
      if (frame != null) {
        selector = await buildFullSelectorForFrame(frame, selector);
      }
      _elementPicked.add(ElementInfo(
          selector: selector, ariaSnapshot: info['ariaSnapshot'] as String?));
      return null;
    });
    await context.exposeBinding(kRecorderRecordActionBinding,
        (source, args) async {
      await _recordAction(source, asJsonMap(args.isEmpty ? null : args.first));
      return null;
    });
    await context.exposeBinding(kRecorderPerformActionBinding,
        (source, args) async {
      await _performAction(source, asJsonMap(args.isEmpty ? null : args.first));
      return null;
    });

    await context.addInitScript(kInjectedScriptSource);
    await context.addInitScript(recorderInstallSource(
        hideToolbar: hideToolbar, isUnderTest: isUnderTest));

    _subscriptions.add(context.onPage.listen(_onPage));
    for (final page in context.pages()) {
      _onPage(page);
    }
  }

  /// Switches the mode, and pushes it to the pages at once instead of waiting
  /// for their next poll.
  Future<void> setMode(String mode) async {
    if (_mode == mode) return;
    _mode = mode;
    _setEnabled(RecorderMode.isRecording(mode) ||
        mode == RecorderMode.recordingInspecting);
    await _refreshOverlay();
  }

  /// Releases the action the signal processor is holding back.
  void flushPendingActions() => _signalProcessor.flush();

  Future<void> dispose() async {
    _signalProcessor.flush();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _actions.close();
    await _signals.close();
    await _elementPicked.close();
  }

  @override
  void addAction(ActionInContext actionInContext) {
    if (_enabled && !_actions.isClosed) _actions.add(actionInContext);
  }

  @override
  void addSignal(SignalInContext signalInContext) {
    if (_enabled && !_signals.isClosed) _signals.add(signalInContext);
  }

  void _setEnabled(bool enabled) {
    if (_enabled && !enabled) _signalProcessor.flush();
    _enabled = enabled;
  }

  RecorderUiState _uiState() => RecorderUiState(
        mode: _mode,
        language: language,
        testIdAttributeName: testIdAttributeName,
        overlay: _overlayState,
      );

  Future<void> _refreshOverlay() async {
    await Future.wait([
      for (final page in context.pages()) _refreshOverlayOnPage(page),
    ]);
  }

  Future<void> _refreshOverlayOnPage(Page page) async {
    for (final frame in page.frames()) {
      try {
        await frame.evaluate(
            '() => window.$kRefreshOverlayFunction && window.$kRefreshOverlayFunction()');
      } catch (_) {
        // A frame that is navigating or gone; the next poll catches up.
      }
    }
  }

  String _guidFor(Page page) =>
      _pageGuids.putIfAbsent(page, () => 'page@${++_nextPageOrdinal}');

  void _onPage(Page page) {
    final guid = _guidFor(page);

    _subscriptions.add(page.onClose.listen((_) {
      _signalProcessor.addAction(
          ActionInContext(pageGuid: guid, action: ClosesPageAction()));
    }));

    _subscriptions.add(page.onFrameNavigated.listen((frame) {
      _signalProcessor.signal(guid, frame.parentFrame() == null, frame.url(),
          NavigationSignal(url: frame.url()));
    }));

    _subscriptions.add(page.onDownload.listen((_) {
      ++_lastDownloadOrdinal;
      _signalProcessor.signal(
          guid,
          true,
          '',
          DownloadSignal(
              downloadAlias:
                  _lastDownloadOrdinal > 0 ? '$_lastDownloadOrdinal' : ''));
    }));

    _subscriptions.add(page.onDialog.listen((dialog) {
      ++_lastDialogOrdinal;
      _signalProcessor.signal(
          guid,
          true,
          '',
          DialogSignal(
              dialogAlias:
                  _lastDialogOrdinal > 0 ? '$_lastDialogOrdinal' : ''));
      // Not handling the dialog, let it close by itself, as upstream does.
    }));

    // A popup is already named by the `popup` signal its opener emitted; only
    // a page with no opener starts a recording of its own.
    final opener = page.opener();
    if (opener != null) {
      _signalProcessor.signal(
          _guidFor(opener), true, '', PopupSignal(popupPageGuid: guid));
    } else {
      _signalProcessor.addAction(ActionInContext(
          pageGuid: guid, action: OpenPageAction(url: page.mainFrame().url())));
    }
  }

  Future<void> _recordAction(
      BindingSource source, Map<String, Object?> json) async {
    final action = actionFromJson(json);
    if (action == null) return;
    final frame = source.frame;
    var recorded = action;
    if (action is ActionWithSelector && frame != null) {
      recorded = withSelector(
          action, await buildFullSelectorForFrame(frame, action.selector));
    }
    _signalProcessor.addAction(ActionInContext(
        pageGuid: _guidFor(source.page), action: recorded, signals: []));
  }

  Future<void> _performAction(
      BindingSource source, Map<String, Object?> json) async {
    final action = actionFromJson(json);
    if (action is! ClickAction) return;
    final frame = source.frame;
    if (frame == null) return;
    final selector = await buildFullSelectorForFrame(frame, action.selector);
    await performClick(source.page.mainFrame(), action, selector);
  }
}

/// Runs the action the page asked the driver to perform on its behalf.
///
/// Upstream's `recorderRunner.ts`. Only a click can be performed: it is what
/// the right-click action list offers, and it is what the page cannot do
/// itself because a synthetic click would not be trusted.
/// Modifiers are dropped: this port's `click` does not take them, which the
/// codegen round already recorded for the generated source.
Future<void> performClick(
    Frame mainFrame, ClickAction action, String selector) async {
  final position = action.position;
  await mainFrame.click(
    selector,
    button: action.button,
    clickCount: action.clickCount,
    position: position == null
        ? null
        : (x: position.x.toDouble(), y: position.y.toDouble()),
    strict: true,
  );
}

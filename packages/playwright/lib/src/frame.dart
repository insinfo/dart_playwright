import 'package:playwright_core/src/server/core_page.dart';
import 'page.dart';
import 'locator.dart';

/// A frame within a page.
abstract class Frame {
  /// The frame's name.
  String name();

  /// The frame's URL.
  String url();

  /// Parent frame, if any.
  Frame? parentFrame();

  /// Child frames.
  List<Frame> childFrames();

  /// Evaluate JavaScript expression in the frame.
  Future<dynamic> evaluate(String expression);

  /// Wait for this frame to reach a load state.
  Future<void> waitForLoadState(
      {WaitUntilState state = WaitUntilState.load, Duration? timeout});

  /// Wait for this frame to navigate.
  Future<void> waitForNavigation(
      {WaitUntilState? waitUntil, Duration? timeout});

  /// Create a locator for an element within the frame.
  Locator locator(String selector);

  /// Get the page containing this frame.
  Page page();
}

class FrameImpl implements Frame {
  final CoreFrame _coreFrame;
  final Page _page;

  FrameImpl(this._coreFrame, this._page);

  @override
  String name() => _coreFrame.name;

  @override
  String url() => _coreFrame.url;

  @override
  Frame? parentFrame() {
    final parent = _coreFrame.parentFrame;
    return parent == null ? null : FrameImpl(parent, _page);
  }

  @override
  List<Frame> childFrames() =>
      _coreFrame.childFrames.map((frame) => FrameImpl(frame, _page)).toList();

  @override
  Future<dynamic> evaluate(String expression) =>
      _coreFrame.page.evaluate(expression);

  @override
  Future<void> waitForLoadState(
          {WaitUntilState state = WaitUntilState.load, Duration? timeout}) =>
      _coreFrame.waitForLoadState(state, timeout: timeout);

  @override
  Future<void> waitForNavigation(
          {WaitUntilState? waitUntil, Duration? timeout}) =>
      _coreFrame.waitForNavigation(waitUntil: waitUntil, timeout: timeout);

  @override
  Locator locator(String selector) => LocatorImpl(_page, selector);

  @override
  Page page() => _page;
}

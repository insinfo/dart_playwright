import 'package:playwright_protocol/playwright_protocol.dart';
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

  /// Create a locator for an element within the frame.
  Locator locator(String selector);

  /// Get the page containing this frame.
  Page page();
}

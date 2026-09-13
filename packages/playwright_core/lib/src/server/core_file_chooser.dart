import 'core_js_handle.dart';

/// A file chooser the page opened, intercepted instead of shown.
///
/// The engines only report it while interception is on; with it off the
/// native dialog opens and the automation has nothing to do with it.
class CoreFileChooser {
  /// A handle to the `<input type=file>` that asked for the files.
  final CoreJSHandle element;

  /// Whether the input accepts more than one file.
  final bool isMultiple;

  const CoreFileChooser({required this.element, required this.isMultiple});
}

import 'package:playwright_core/src/server/core_element_handle.dart';
import 'package:playwright_core/src/server/core_page.dart' show CoreFileChooser;
import 'package:playwright_protocol/playwright_protocol.dart';

import 'element_handle.dart';
import 'page.dart';

/// A file chooser the page opened.
///
/// Reaching one at all means interception is on; see [Page.onFileChooser].
/// With interception off the browser shows its own dialog and automation has
/// no say in it.
abstract class FileChooser {
  /// The page that opened the chooser.
  Page page();

  /// A handle to the `<input type=file>` that asked for the files.
  ElementHandle element();

  /// Whether the input accepts more than one file.
  ///
  /// True for `multiple` and for `webkitdirectory`, as upstream counts it.
  bool isMultiple();

  /// Point the input at these files.
  ///
  /// The paths are resolved by the browser process, so the files have to
  /// exist where the browser runs. Pass an empty list to clear the input.
  Future<void> setFiles(List<String> paths);
}

class FileChooserImpl implements FileChooser {
  final Page _page;
  final CoreFileChooser _chooser;
  final Future<void> Function(List<String> paths) _setFiles;

  FileChooserImpl(this._page, this._chooser, this._setFiles);

  @override
  Page page() => _page;

  @override
  ElementHandle element() {
    final element = _chooser.element;
    if (element is! CoreElementHandle) {
      throw PlaywrightException(
          'The file chooser did not report a DOM element');
    }
    return ElementHandleImpl(element);
  }

  @override
  bool isMultiple() => _chooser.isMultiple;

  @override
  Future<void> setFiles(List<String> paths) => _setFiles(paths);
}

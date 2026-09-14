import 'dart:async';

import 'package:playwright_core/src/server/core_page.dart'
    show CoreBindingCallback, CoreBindingSource;

import 'browser_context.dart';
import 'frame.dart';
import 'page.dart';

/// Where a call to an exposed binding came from.
///
/// This is upstream's binding `source`: `exposeBinding` hands it to the
/// callback, `exposeFunction` hides it. [frame] is the frame whose script
/// called the binding, which is not necessarily the main frame.
class BindingSource {
  /// The context the calling page belongs to, or null for a page built
  /// outside a context.
  final BrowserContext? context;

  /// The page whose script called the binding.
  final Page page;

  /// The frame whose script called the binding.
  ///
  /// Null only when the call arrived from an execution context the driver
  /// never saw announced — a frame that was torn down while the call was in
  /// flight, for instance.
  final Frame? frame;

  const BindingSource({required this.context, required this.page, this.frame});
}

/// The callback behind `exposeBinding`.
typedef BindingCallback = FutureOr<dynamic> Function(
    BindingSource source, List<dynamic> args);

/// The callback behind `exposeFunction`, which is a binding that ignores its
/// source.
typedef ExposedFunction = FutureOr<dynamic> Function(List<dynamic> args);

/// Adapts a public [BindingCallback] to the core one, wrapping the engine
/// objects it is handed in their public counterparts.
CoreBindingCallback adaptBindingCallback(BindingCallback callback) {
  return (CoreBindingSource source, List<dynamic> args) {
    final page = PageImpl.forCore(source.page);
    final coreContext = source.context;
    final coreFrame = source.frame;
    return callback(
      BindingSource(
        context:
            coreContext == null ? null : BrowserContextImpl.forCore(coreContext),
        page: page,
        frame: coreFrame == null ? null : FrameImpl(coreFrame, page),
      ),
      args,
    );
  };
}

import '../core_page.dart';
import 'page_screencast.dart';
import 'screencast_stub.dart';

/// Builds the [PageScreencast] for one page.
typedef PageScreencastBuilder = PageScreencast Function(CorePage page);

PageScreencast _stubBuilder(CorePage page) => ScreenshotPollingScreencast(page);

/// The single place that decides which screencast backend a page gets.
///
/// The layers above the screencast — video recording and the trace filmstrip —
/// only ever go through here, so the engine backends can land without any of
/// them moving. Until they do, every page gets
/// [ScreenshotPollingScreencast].
class ScreencastFactory {
  /// Replaced by the engine backends; overridable in tests.
  static PageScreencastBuilder builder = _stubBuilder;

  /// Whether pages are still getting the stand-in backend. A caller that must
  /// not silently record a fake — a proof script, say — can check this
  /// instead of guessing.
  static bool get isStub => identical(builder, _stubBuilder);

  static PageScreencast create(CorePage page) => builder(page);
}

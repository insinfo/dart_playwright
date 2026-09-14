import '../core_page.dart';
import 'page_screencast.dart';
import 'screencast_factory.dart';
import 'screencast_stub.dart';

/// Builds the [PageScreencast] for one page.
typedef PageScreencastBuilder = PageScreencast Function(CorePage page);

PageScreencast _stubBuilder(CorePage page) => ScreenshotPollingScreencast(page);

/// The single place that decides which screencast backend a page gets.
///
/// The layers above the screencast — video recording and the trace filmstrip —
/// only ever go through here, so the engine backends landed without any of
/// them moving.
///
/// The engine backends now sit behind `createPageScreencast`, which is what
/// [builder] defaults to. The indirection stays because it is what lets a test
/// install a backend that misbehaves on purpose, and what
/// [ScreenshotPollingScreencast] can still be swapped in for.
class ScreencastProvider {
  /// The engine backends. Overridable in tests.
  static PageScreencastBuilder builder = createPageScreencast;

  /// Whether pages are getting the stand-in backend instead of the engine's
  /// own. A caller that must not silently record a fake — a proof script,
  /// say — can check this instead of guessing.
  static bool get isStub => identical(builder, _stubBuilder);

  static PageScreencast create(CorePage page) => builder(page);
}

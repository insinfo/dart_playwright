import 'package:playwright_core/src/server/core_browser.dart'
    show CoreRecordVideoOptions, CoreVideo;

/// `recordVideo` of [Browser.newContext] and
/// [BrowserType.launchPersistentContext]: films every page of the context.
///
/// ```dart
/// final context = await browser.newContext(
///     recordVideo: RecordVideoOptions(dir: 'videos/'));
/// final page = await context.newPage();
/// await page.goto('https://example.com');
/// await context.close();
/// print(await page.video()!.path());
/// ```
///
/// [dir] is a directory, not a file: each page gets its own video inside it,
/// named after the page. It is created if it does not exist.
///
/// [size] is the size of the recorded frames. Left out, the context viewport
/// is scaled down to fit in 800 pixels, which is upstream's rule; the aspect
/// ratio is kept either way, and both sides are rounded down to even numbers
/// because the encoder refuses odd ones.
class RecordVideoOptions {
  final String dir;
  final ({int width, int height})? size;

  const RecordVideoOptions({required this.dir, this.size});

  /// The shape the core layer takes. Internal.
  CoreRecordVideoOptions toCore() =>
      CoreRecordVideoOptions(dir: dir, size: size);
}

/// The video recorded for one page.
///
/// Reachable as [Page.video], and only when the context was created with
/// `recordVideo`.
///
/// **The file is not finished until the page is.** A video is written while
/// the page runs and only closed when the page closes — or when its context or
/// browser does. Every method here waits for that, so the path you get back
/// always names a complete file; none of them requires you to have closed
/// anything yourself first.
abstract class Video {
  /// The path of the finished video file.
  ///
  /// Waits for the page to close and the file to be written. Throws, with the
  /// reason, when the recording failed.
  Future<String> path();

  /// Copy the video to [target], creating the directories above it.
  ///
  /// Safe both while the page is still running and long after its context has
  /// been closed, which is the normal way to use it: close the context, then
  /// save the video.
  Future<void> saveAs(String target);

  /// Delete the video file, waiting for the recording to end first.
  ///
  /// Save before deleting: [saveAs] throws afterwards rather than quietly
  /// writing nothing.
  Future<void> delete();
}

class VideoImpl implements Video {
  final CoreVideo _video;

  VideoImpl(this._video);

  @override
  Future<String> path() => _video.pathAfterFinished();

  @override
  Future<void> saveAs(String target) => _video.saveAs(target);

  @override
  Future<void> delete() => _video.delete();
}

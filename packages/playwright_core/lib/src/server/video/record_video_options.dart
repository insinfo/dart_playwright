/// `recordVideo` of the context options: record a video of every page.
///
/// [dir] is a directory, not a file: each page gets its own video, named after
/// the page, exactly as upstream does. [size] is the video frame size; it
/// defaults to the context viewport scaled to fit in 800 pixels, which is
/// upstream's rule.
class CoreRecordVideoOptions {
  final String dir;
  final ({int width, int height})? size;

  const CoreRecordVideoOptions({required this.dir, this.size});
}

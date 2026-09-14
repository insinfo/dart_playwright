import 'dart:async';
import 'dart:typed_data';

import '../core_page.dart';
import 'page_screencast.dart';
import 'video_frame.dart';

/// A [PageScreencast] that polls [CorePage.screenshot] instead of subscribing
/// to the engine's screencast domain.
///
/// This exists so that everything above the screencast — the video artifact
/// lifecycle and the trace filmstrip — can be written and tested before the
/// engine backends land. It produces real JPEG frames of the real page, so
/// the pipeline is exercised end to end rather than faked; what it does not
/// have is the engine's frame-swap timing, so the frames are evenly spaced
/// rather than tied to actual repaints, and a page that is busy in JavaScript
/// simply yields fewer of them.
class ScreenshotPollingScreencast implements PageScreencast {
  final CorePage _page;

  /// Deliberately coarse: a screenshot round-trip costs far more than a
  /// screencast frame, and this is a stand-in, not a recorder to ship.
  static const _interval = Duration(milliseconds: 250);

  /// Long enough for a busy page, short enough that a wedged one still yields
  /// frames afterwards.
  static const _captureTimeout = Duration(seconds: 5);

  final _controller = StreamController<VideoFrame>.broadcast();
  final _stopwatch = Stopwatch();

  Timer? _timer;
  int _quality = 90;
  int _width = 0;
  int _height = 0;
  bool _capturing = false;
  bool _stopped = false;

  ScreenshotPollingScreencast(this._page);

  @override
  ScreencastKind get kind => ScreencastKind.frames;

  @override
  Stream<VideoFrame> get frames => _controller.stream;

  @override
  Future<void> start(
      {required int width, required int height, int quality = 90}) async {
    _width = width;
    _height = height;
    _quality = quality;
    _stopwatch.start();
    // The first frame waits for the timer rather than being taken here.
    // `start()` runs while the page is still being attached — upstream is
    // explicit that the screencast has to be armed before `Target.resume` —
    // and a screenshot of a target that has not been resumed never answers.
    // Awaiting one here wedged the whole recording: the artifact could not be
    // finished, and `video.path()` failed on the finalization timeout.
    _timer = Timer.periodic(_interval, (_) => _capture());
  }

  Future<void> _capture() async {
    // Overlapping captures would reorder timestamps, and a slow page must not
    // build up a queue of them.
    if (_capturing || _stopped || _page.isClosed) return;
    _capturing = true;
    final timestamp = _stopwatch.elapsed;
    try {
      // Bounded, for the same reason the first frame is not taken inline: one
      // screenshot that never answers must not stop every later frame, which
      // is what the `_capturing` guard would otherwise guarantee.
      final bytes = await _page
          .screenshot(
              options: CoreScreenshotOptions(
                  type: 'jpeg', quality: _quality, scale: 'css'))
          .timeout(_captureTimeout);
      if (_stopped || _controller.isClosed) return;
      _controller.add(VideoFrame(
        data: Uint8List.fromList(bytes),
        format: VideoFrameFormat.jpeg,
        width: _width,
        height: _height,
        timestamp: timestamp,
      ));
    } catch (_) {
      // A page that navigated away, closed or crashed mid-capture ends the
      // recording; it does not fail it. Upstream's screencast drops frames
      // the same way.
    } finally {
      _capturing = false;
    }
  }

  @override
  Future<String> stop() async {
    if (_stopped) return '';
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    _stopwatch.stop();
    await _controller.close();
    // [ScreencastKind.frames]: there is no file, and the caller knows not to
    // look at this.
    return '';
  }
}

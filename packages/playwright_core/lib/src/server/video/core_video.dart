// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream sources: packages/playwright-core/src/server/artifact.ts and
// packages/playwright-core/src/server/videoRecorder.ts
// (`startAutomaticVideoRecording`).

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core_page.dart';
import 'page_screencast.dart';
import 'screencast_hub.dart';
import 'video_recorder.dart';

/// How long the finalization of one video may take before it is declared
/// failed.
///
/// Upstream leaves this unbounded, and can afford to: its artifact lives
/// behind a dispatcher whose `Progress` carries the caller's own timeout. Here
/// `video.path()` is a plain future, so an encoder that never answers — a
/// wedged ffmpeg, an engine that swallowed `stopScreencast` — would leave the
/// caller waiting forever with nothing to show for it. Failing loudly is worse
/// than hanging only in the sense that it is visible.
const Duration kVideoFinalizeTimeout = Duration(seconds: 30);

/// The video of one page.
///
/// This is upstream's `Artifact`, narrowed to what a video needs. The file it
/// names is only complete once the page (or its context, or the browser)
/// closes, so every method here waits for that first: handing back a path to a
/// half-written file is the one failure mode this class exists to prevent.
class CoreVideo {
  /// Where the finished file will be. Known from the start; do not read the
  /// file at this path before [pathAfterFinished] has returned it.
  final String path;

  final Completer<void> _finished = Completer<void>();
  Future<void> Function()? _stopper;
  Future<void>? _finishing;
  Object? _failure;
  bool _deleted = false;

  CoreVideo(this.path);

  /// Whether the file is written and closed.
  bool get isFinished => _finished.isCompleted;

  /// Completes when the recording is over, successfully or not.
  Future<void> get finished => _finished.future;

  /// Installs what actually stops the recording. Called by [VideoRecording]
  /// the moment the recording is created, so that a page closing immediately
  /// after still has something to stop.
  void attachRecording(Future<void> Function() stopper) {
    _stopper = stopper;
  }

  /// The path of the finished file.
  ///
  /// Waits for the recording to end. Throws when it failed, carrying the
  /// reason — a caller must never be left with a path to a file that was never
  /// written and no idea why.
  Future<String> pathAfterFinished() async {
    await _finished.future;
    final failure = _failure;
    if (failure != null) throw failure;
    return path;
  }

  /// Copies the finished video to [target], creating the directories above it.
  ///
  /// Safe to call while the recording is still running and safe to call after
  /// the context has closed: it waits for the file either way. That second
  /// case is the one upstream calls out explicitly, because it is the normal
  /// way to use this — you close the context, *then* you save the video.
  Future<void> saveAs(String target) async {
    if (_deleted) {
      throw StateError('File already deleted. Save before deleting.');
    }
    final source = await pathAfterFinished();
    final destination = File(p.normalize(File(target).absolute.path));
    await destination.parent.create(recursive: true);
    await File(source).copy(destination.path);
  }

  /// Deletes the video file, waiting for the recording to end first.
  ///
  /// Deleting a file that is still being written is how you get a recorder
  /// writing into a deleted inode, so this waits like everything else here.
  Future<void> delete() async {
    await _finished.future;
    if (_deleted) return;
    _deleted = true;
    if (_failure != null) return;
    final file = File(path);
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Someone else got there first, or the file is locked. Either way the
      // caller asked for it to be gone, and it is not this method's business
      // to fail the test over it.
    }
  }

  /// Whether [delete] has already run.
  bool get isDeleted => _deleted;

  /// Stops the recording and waits for the file to be closed. Idempotent, and
  /// safe to call from several places at once — the page closing, the context
  /// closing and the browser dying all race to be the one that ends it.
  Future<void> finish() {
    if (_finished.isCompleted) return Future<void>.value();
    return _finishing ??= _runFinish();
  }

  Future<void> _runFinish() async {
    final stopper = _stopper;
    if (stopper == null) {
      // Nothing ever started: the recording failed to be created at all, and
      // whoever failed it has already reported why.
      reportFinished(StateError('Video recording was never started'));
      return;
    }
    try {
      await stopper().timeout(kVideoFinalizeTimeout);
      reportFinished();
    } catch (error) {
      reportFinished(error);
    }
  }

  /// Marks the recording over. [error] makes [pathAfterFinished] and [saveAs]
  /// throw it.
  void reportFinished([Object? error]) {
    if (_finished.isCompleted) return;
    _failure = error;
    _finished.complete();
  }
}

/// Drives one page's screencast into one [VideoRecorder].
///
/// Created synchronously when the page appears, because
/// [CoreVideo.attachRecording] has to be in place before anything can close
/// the page — a page that closes during startup would otherwise find nothing
/// to stop and hang forever.
class VideoRecording {
  final CorePage page;
  final CoreVideo video;
  final ({int width, int height}) size;

  late final Future<void> _started;
  ScreencastSubscription? _subscription;
  VideoRecorder? _recorder;
  StreamSubscription<void>? _frames;

  VideoRecording._(this.page, this.video, this.size) {
    video.attachRecording(_stop);
    _started = _start();
    // The failure is delivered through [_stop]; nothing awaits [_started]
    // until then, and an unawaited future that throws takes the isolate down.
    _started.catchError((Object _) {});
  }

  /// Starts recording [page] when its context asked for `recordVideo`, and
  /// returns null when it did not.
  static VideoRecording? maybeStart(CorePage page) {
    final options = page.browserContext?.options.recordVideo;
    if (options == null) return null;
    final size =
        ScreencastHub.defaultSizeFor(page, requested: options.size);
    // Upstream names the file after the page and nothing else, so two videos
    // of the same URL in the same directory cannot collide.
    final video = CoreVideo(p.join(options.dir, '${page.guid}.webm'));
    page.video = video;
    return VideoRecording._(page, video, size);
  }

  Future<void> _start() async {
    final subscription = await ScreencastHub.forPage(page)
        .addClient(size: size, quality: 90);
    _subscription = subscription;
    if (subscription.kind == ScreencastKind.directFile) {
      // The engine is writing the file itself; there is nothing to mux.
      return;
    }
    final recorder = await VideoRecorder.start(
      outputPath: video.path,
      width: size.width,
      height: size.height,
    );
    _recorder = recorder;
    _frames = subscription.frames.listen(recorder.writeFrame);
  }

  Future<void> _stop() async {
    // A startup that blew up has to blow up here, where [CoreVideo.finish]
    // turns it into the error `path()` throws.
    await _started;
    await _frames?.cancel();
    _frames = null;
    final produced = await _subscription?.close();
    _subscription = null;
    await _recorder?.stop();
    _recorder = null;
    if (produced != null) await _adoptDirectFile(produced);
  }

  /// Moves the file a [ScreencastKind.directFile] backend wrote into the place
  /// this port promised the caller it would be.
  Future<void> _adoptDirectFile(String produced) async {
    if (p.equals(produced, video.path)) return;
    final source = File(produced);
    if (!await source.exists()) {
      throw StateError(
          'Screencast reported a video at "$produced", but there is no file '
          'there.');
    }
    await Directory(p.dirname(video.path)).create(recursive: true);
    try {
      await source.rename(video.path);
    } on FileSystemException {
      // Across devices rename fails; copy and drop the original.
      await source.copy(video.path);
      await source.delete();
    }
  }
}

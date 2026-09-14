// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/playwright-core/src/server/videoRecorder.ts
//
// STUB. The real muxer (ffmpeg + Matroska framing) is being written in
// parallel and replaces the body of this file; the signatures below are the
// agreed contract and must not change. Everything above the muxer — the
// `recordVideo` option, `page.video()`, the artifact lifecycle — is written
// against this contract and is exercised end to end by
// `packages/playwright/test/integration/video_test.dart` with this stub in
// place.

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'video_frame.dart';

/// Muxes a stream of [VideoFrame]s into a single video file.
class VideoRecorder {
  final String outputPath;
  final int width;
  final int height;
  final int fps;

  final IOSink _sink;
  bool _stopped = false;

  VideoRecorder._(
    this.outputPath,
    this.width,
    this.height,
    this.fps,
    this._sink,
  );

  /// Opens [outputPath] for writing, creating the directories above it.
  static Future<VideoRecorder> start({
    required String outputPath,
    required int width,
    required int height,
    int fps = 25,
  }) async {
    await Directory(p.dirname(outputPath)).create(recursive: true);
    final file = File(outputPath);
    final sink = file.openWrite();
    return VideoRecorder._(outputPath, width, height, fps, sink);
  }

  /// Queues [frame] for muxing. Fire and forget by contract: a frame arrives
  /// from a protocol event handler, which has nobody to hand a future to.
  void writeFrame(VideoFrame frame) {
    if (_stopped) return;
    // The stub keeps the raw payloads so the file grows with the recording and
    // an empty recording is still a non-empty file, which is what the
    // lifecycle tests observe. The real muxer writes a webm here.
    _sink.add(frame.data);
  }

  /// Finishes the file. The recording is only complete once this returns.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    await _sink.flush();
    await _sink.close();
  }
}

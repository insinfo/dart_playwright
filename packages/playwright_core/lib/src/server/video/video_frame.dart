// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/playwright-core/src/server/types.ts
// (`ScreencastFrame`).

import 'dart:typed_data';

/// Encoding of the bytes in a [VideoFrame].
///
/// All three engine backends deliver JPEG, and so must anything else that
/// feeds this pipeline: the ffmpeg build Playwright publishes decodes only
/// `mjpeg` and `libvpx` — `png` is an encoder there, not a decoder — so a PNG
/// frame produces a video that does not open. The format travels with the
/// frame anyway, because the trace filmstrip names its resource by extension
/// and silently writing the wrong one would hide the mistake.
enum VideoFrameFormat { png, jpeg }

/// One painted frame of a page, as the engine delivered it.
class VideoFrame {
  final Uint8List data;
  final VideoFrameFormat format;
  final int width;
  final int height;

  /// Desde o início da gravação.
  final Duration timestamp;

  const VideoFrame({
    required this.data,
    required this.format,
    required this.width,
    required this.height,
    required this.timestamp,
  });
}

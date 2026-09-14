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
/// The engines hand out JPEG (Chromium `Page.screencastFrame`, WebKit) or PNG
/// (Firefox `Page.screencastFrame`), and the consumer has to know which:
/// ffmpeg is told the container format, and the trace filmstrip names the
/// resource file by extension.
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

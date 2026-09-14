// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/playwright-core/src/server/types.ts (ScreencastFrame)

import 'dart:typed_data';

/// Formato em que o quadro chega do screencast.
///
/// Na pratica so [jpeg] atravessa o ffmpeg: a build que a Playwright publica e
/// compilada apenas com o decodificador MJPEG — `ffmpeg -decoders` lista
/// somente `mjpeg` e `libvpx` —, entao um quadro [png] nao tem decodificador do
/// outro lado do pipe. O valor continua no enum porque o lado do screencast do
/// contrato o nomeia.
enum VideoFrameFormat { png, jpeg }

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

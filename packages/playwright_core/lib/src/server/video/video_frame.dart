import 'dart:typed_data';

enum VideoFrameFormat { png, jpeg }

class VideoFrame {
  final Uint8List data;
  final VideoFrameFormat format;
  final int width;
  final int height;

  /// Desde o início da gravação.
  final Duration timestamp;
  const VideoFrame(
      {required this.data,
      required this.format,
      required this.width,
      required this.height,
      required this.timestamp});
}

import 'dart:convert';
import 'dart:typed_data';

/// Reassembles null-byte-delimited protocol messages from raw pipe chunks.
///
/// Firefox (Juggler) and WebKit both frame their inspector messages as
/// UTF-8 JSON terminated by a single `\0` byte. Chunks read from the pipe
/// can split messages at arbitrary boundaries; this class buffers partial
/// data and emits each complete message.
class NullDelimitedFramer {
  final _pendingBuffers = <List<int>>[];

  /// Feeds a raw [buffer] read from the pipe; invokes [onMessage] once per
  /// complete null-terminated message.
  void feed(List<int> buffer, void Function(String message) onMessage) {
    int start = 0;
    while (true) {
      final end = buffer.indexOf(0, start);
      if (end == -1) {
        if (start < buffer.length) {
          _pendingBuffers.add(buffer.sublist(start));
        }
        break;
      }

      _pendingBuffers.add(buffer.sublist(start, end));

      final totalLen = _pendingBuffers.fold<int>(0, (len, b) => len + b.length);
      final fullMessage = Uint8List(totalLen);
      int offset = 0;
      for (final b in _pendingBuffers) {
        fullMessage.setAll(offset, b);
        offset += b.length;
      }
      _pendingBuffers.clear();

      onMessage(utf8.decode(fullMessage));
      start = end + 1;
    }
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:logging/logging.dart';
import 'package:playwright_protocol/playwright_protocol.dart';

import 'transport.dart';

final _logger = Logger('PipeTransport');

/// Transport implementation that communicates over standard I/O pipes.
///
/// This is used when launching local browsers. Chromium uses
/// `--remote-debugging-pipe`, while Firefox (Juggler) and WebKit
/// use standard stdio pipes.
///
/// Messages are serialized as JSON and separated by the null byte (`\0`).
class PipeTransport implements ConnectionTransport {
  final IOSink _pipeWrite;
  final Stream<List<int>> _pipeRead;

  final _messageController = StreamController<ProtocolResponse>.broadcast();
  final _closeController = StreamController<String?>.broadcast();

  final _pendingChunks = <List<int>>[];
  bool _closed = false;
  late final StreamSubscription<List<int>> _readSubscription;

  PipeTransport({
    required IOSink pipeWrite,
    required Stream<List<int>> pipeRead,
  })  : _pipeWrite = pipeWrite,
        _pipeRead = pipeRead {
    _readSubscription = _pipeRead.listen(
      _dispatch,
      onDone: () {
        _closed = true;
        _closeController.add(null);
        _closeController.close();
        _messageController.close();
      },
      onError: (error) {
        _logger.warning('Pipe read error: $error');
      },
    );
  }

  /// Create a PipeTransport from a spawned browser [Process].
  factory PipeTransport.fromProcess(Process process) {
    return PipeTransport(
      pipeWrite: process.stdin,
      pipeRead: process.stdout,
    );
  }

  @override
  void send(ProtocolRequest message) {
    if (_closed) throw StateError('Pipe has been closed');

    final jsonStr = message.toJsonString();
    _pipeWrite.write(jsonStr);
    _pipeWrite.write('\x00'); // null byte separator
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _readSubscription.cancel();
    await _pipeWrite.close();
    _closeController.add(null);
    await _closeController.close();
    await _messageController.close();
  }

  @override
  Stream<ProtocolResponse> get onMessage => _messageController.stream;

  @override
  Stream<String?> get onClose => _closeController.stream;

  /// Dispatch received buffer, separating messages by null bytes.
  void _dispatch(List<int> buffer) {
    int start = 0;

    for (int i = 0; i < buffer.length; i++) {
      if (buffer[i] == 0) {
        // null byte found
        if (i > start) {
          _pendingChunks.add(buffer.sublist(start, i));
        }

        final completeMessage = _concatenateChunks();
        _pendingChunks.clear();

        if (completeMessage.isNotEmpty) {
          _processMessage(completeMessage);
        }

        start = i + 1; // skip null byte
      }
    }

    if (start < buffer.length) {
      _pendingChunks.add(buffer.sublist(start));
    }
  }

  List<int> _concatenateChunks() {
    if (_pendingChunks.isEmpty) return [];
    if (_pendingChunks.length == 1) return _pendingChunks.first;

    final totalLength =
        _pendingChunks.fold<int>(0, (sum, chunk) => sum + chunk.length);
    final result = Uint8List(totalLength);
    var offset = 0;
    for (final chunk in _pendingChunks) {
      result.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return result;
  }

  void _processMessage(List<int> bytes) {
    try {
      final jsonStr = utf8.decode(bytes);
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      final response = ProtocolResponse.fromJson(json);

      // scheduleMicrotask to avoid blocking the read stream and allow
      // async events to resolve before the next message
      scheduleMicrotask(() {
        if (!_messageController.isClosed) {
          _messageController.add(response);
        }
      });
    } catch (e, st) {
      _logger.severe('Failed to parse protocol message', e, st);
    }
  }
}

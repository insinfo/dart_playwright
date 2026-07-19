import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:playwright_protocol/playwright_protocol.dart';
import 'package:stdlibc/stdlibc.dart' as libc;

import 'message_framer.dart';
import 'posix_process.dart';
import 'transport.dart';

/// fd3/fd4 pipe transport for Linux/macOS, mirroring the Windows
/// [PipeTransport] design: a helper isolate blocks on read() and streams
/// chunks back; writes go straight to the child's fd3.
///
/// When the browser process dies its end of the fd4 FIFO closes, read()
/// returns EOF and the reader isolate exits on its own — which is also how
/// [close] unblocks the reader (kill process first, EOF follows).
class PosixPipeTransport implements ConnectionTransport {
  final PosixProcess _process;
  final _messageController = StreamController<ProtocolResponse>.broadcast();
  final _closeController = StreamController<String?>.broadcast();
  final _framer = NullDelimitedFramer();
  bool _closed = false;

  late final Isolate _readerIsolate;
  late final ReceivePort _receivePort;

  PosixPipeTransport(this._process);

  @override
  Stream<ProtocolResponse> get onMessage => _messageController.stream;

  @override
  Stream<String?> get onClose => _closeController.stream;

  Future<void> init() async {
    _receivePort = ReceivePort();

    _readerIsolate = await Isolate.spawn(
      _pipeReaderLoop,
      [_process.jugglerReadFd, _receivePort.sendPort],
    );

    _receivePort.listen((message) {
      if (message is List<int>) {
        _dispatch(message);
      } else if (message == 'closed' || message == 'error') {
        _handleClose(message as String);
      }
    });
  }

  void _dispatch(List<int> buffer) {
    _framer.feed(buffer, (messageStr) {
      try {
        final json = jsonDecode(messageStr) as Map<String, dynamic>;
        _messageController.add(ProtocolResponse.fromJson(json));
      } catch (e) {
        print('Error decoding pipe message: $e');
      }
    });
  }

  void _handleClose(String reason) {
    if (_closed) return;
    _closed = true;
    _receivePort.close();
    _readerIsolate.kill();
    _messageController.close();
    _closeController.add(reason);
    _closeController.close();
  }

  @override
  void send(ProtocolRequest message) {
    if (_closed) throw Exception('Pipe has been closed');

    final bytes = utf8.encode(message.toJsonString());
    final framed = <int>[...bytes, 0];

    var offset = 0;
    while (offset < framed.length) {
      final written =
          libc.write(_process.jugglerWriteFd, framed.sublist(offset));
      if (written <= 0) {
        throw Exception(
            'Failed to write to inspector pipe: errno ${libc.errno}');
      }
      offset += written;
    }
  }

  @override
  Future<void> close() async {
    // Kill the browser first: its death closes the fd4 FIFO, read() returns
    // EOF and the reader isolate unblocks and exits.
    _process.kill();
    _handleClose('User initiated close');
  }
}

void _pipeReaderLoop(List<dynamic> args) {
  final int fd = args[0];
  final SendPort sendPort = args[1];

  while (true) {
    final chunk = libc.read(fd, 65536);
    if (chunk.isEmpty) {
      // EOF or error: the browser exited or the fd was closed.
      sendPort.send('closed');
      break;
    }
    sendPort.send(chunk);
  }
}

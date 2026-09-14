import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:playwright_protocol/playwright_protocol.dart';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'message_framer.dart';
import 'transport.dart';
import 'win32_process.dart';

class PipeTransport implements ConnectionTransport {
  final Win32Process _process;
  final _messageController = StreamController<ProtocolResponse>.broadcast();
  final _closeController = StreamController<String?>.broadcast();
  final _framer = NullDelimitedFramer();
  bool _closed = false;
  
  late final Isolate _readerIsolate;
  late final ReceivePort _receivePort;

  PipeTransport(this._process);

  @override
  Stream<ProtocolResponse> get onMessage => _messageController.stream;

  @override
  Stream<String?> get onClose => _closeController.stream;

  Future<void> init() async {
    _receivePort = ReceivePort();
    
    _readerIsolate = await Isolate.spawn(
      _pipeReaderLoop,
      [_process.jugglerReadHandle, _receivePort.sendPort],
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
        stderr.writeln('Error decoding pipe message: $e');
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
    
    final messageStr = message.toJsonString();
    final bytes = utf8.encode(messageStr);
    
    final buffer = calloc<Uint8>(bytes.length + 1);
    buffer.asTypedList(bytes.length).setAll(0, bytes);
    buffer[bytes.length] = 0; // Null byte terminator
    
    final bytesWritten = calloc<DWORD>();
    
    final success = WriteFile(
      _process.jugglerWriteHandle,
      buffer,
      bytes.length + 1,
      bytesWritten,
      nullptr,
    );
    
    calloc.free(buffer);
    calloc.free(bytesWritten);
    
    if (success == 0) {
      throw Exception('Failed to write to Juggler pipe: ${GetLastError()}');
    }
  }

  @override
  Future<void> close() async {
    _handleClose('User initiated close');
    _process.kill();
  }
}

void _pipeReaderLoop(List<dynamic> args) {
  final int handle = args[0];
  final SendPort sendPort = args[1];

  final bufferSize = 65536;
  final buffer = calloc<Uint8>(bufferSize);
  final bytesRead = calloc<DWORD>();

  while (true) {
    final success = ReadFile(handle, buffer, bufferSize, bytesRead, nullptr);
    if (success == 0 || bytesRead.value == 0) {
      sendPort.send('closed');
      break;
    }
    
    // Copy the bytes and send
    final chunk = buffer.asTypedList(bytesRead.value).toList();
    // print('Read \${chunk.length} bytes from pipe');
    sendPort.send(chunk);
  }

  calloc.free(buffer);
  calloc.free(bytesRead);
}

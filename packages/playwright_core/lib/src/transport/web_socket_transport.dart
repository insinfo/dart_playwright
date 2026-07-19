import 'dart:async';
import 'dart:convert';
import 'package:logging/logging.dart';
import 'package:playwright_protocol/playwright_protocol.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;

import 'transport.dart';

final _logger = Logger('WebSocketTransport');

/// Transport implementation that communicates over WebSocket.
///
/// This is used when connecting to an existing remote browser
/// via `connectOverCDP` or Playwright Server.
class WebSocketTransport implements ConnectionTransport {
  final WebSocketChannel _channel;
  final String wsEndpoint;

  final _messageController = StreamController<ProtocolResponse>.broadcast();
  final _closeController = StreamController<String?>.broadcast();

  bool _closed = false;
  late final StreamSubscription _subscription;

  WebSocketTransport._(this._channel, this.wsEndpoint) {
    _subscription = _channel.stream.listen(
      _onData,
      onDone: () {
        _onClose(_channel.closeReason);
      },
      onError: (error) {
        _logger.warning('WebSocket error: $error');
      },
    );
  }

  /// Connect to a WebSocket endpoint.
  static Future<WebSocketTransport> connect(
    String url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    final uri = Uri.parse(url);
    final channel = WebSocketChannel.connect(uri);

    try {
      await channel.ready.timeout(timeout ?? const Duration(seconds: 30));
    } catch (e) {
      await channel.sink.close();
      throw PlaywrightException('Failed to connect to WebSocket: $url', stack: e.toString());
    }

    return WebSocketTransport._(channel, url);
  }

  void _onData(dynamic data) {
    if (data is String) {
      try {
        final json = jsonDecode(data) as Map<String, dynamic>;
        final response = ProtocolResponse.fromJson(json);

        scheduleMicrotask(() {
          if (!_messageController.isClosed) {
            _messageController.add(response);
          }
        });
      } catch (e, st) {
        _logger.severe('Failed to parse WebSocket message', e, st);
      }
    }
  }

  void _onClose(String? reason) {
    if (_closed) return;
    _closed = true;
    _closeController.add(reason);
    _closeController.close();
    _messageController.close();
  }

  @override
  void send(ProtocolRequest message) {
    if (_closed) throw StateError('WebSocket has been closed');
    _channel.sink.add(message.toJsonString());
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription.cancel();
    await _channel.sink.close(status.normalClosure);
    _onClose(null);
  }

  @override
  Stream<ProtocolResponse> get onMessage => _messageController.stream;

  @override
  Stream<String?> get onClose => _closeController.stream;
}

import 'package:playwright_protocol/playwright_protocol.dart';

/// Tracks network requests and responses in Chromium.
class CrNetworkManager extends EventEmitter {
  final dynamic session;

  CrNetworkManager(this.session) {
    session.on('Network.requestWillBeSent', _onRequestWillBeSent);
    session.on('Network.responseReceived', _onResponseReceived);
    session.on('Network.loadingFinished', _onLoadingFinished);
    session.on('Network.loadingFailed', _onLoadingFailed);
  }

  void _onRequestWillBeSent(Map<String, dynamic> params) {
    emit('request', params);
  }

  void _onResponseReceived(Map<String, dynamic> params) {
    emit('response', params);
  }

  void _onLoadingFinished(Map<String, dynamic> params) {
    emit('requestFinished', params);
  }

  void _onLoadingFailed(Map<String, dynamic> params) {
    emit('requestFailed', params);
  }
}

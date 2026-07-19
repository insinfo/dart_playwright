import 'dart:async';
import 'package:playwright_protocol/playwright_protocol.dart';
import 'cr_connection.dart';

/// Manages frames in a Chromium page.
class FrameManager extends EventEmitter {
  final CDPSession session;
  final _frames = <String, Map<String, dynamic>>{};
  
  String? _mainFrameId;

  FrameManager(this.session) {
    session.on('Page.frameAttached', _onFrameAttached);
    session.on('Page.frameNavigated', _onFrameNavigated);
    session.on('Page.frameDetached', _onFrameDetached);
  }

  void _onFrameAttached(Map<String, dynamic> params) {
    final frameId = params['frameId'] as String;
    final parentFrameId = params['parentFrameId'] as String?;
    
    _frames[frameId] = {
      'id': frameId,
      'parentId': parentFrameId,
      'url': '',
    };
    
    emit('frameAttached', frameId);
  }

  void _onFrameNavigated(Map<String, dynamic> params) {
    final frame = params['frame'] as Map<String, dynamic>;
    final frameId = frame['id'] as String;
    
    _frames[frameId] ??= {};
    _frames[frameId]!['url'] = frame['url'];
    
    if (frame['parentId'] == null) {
      _mainFrameId = frameId;
    }
    
    emit('frameNavigated', frame);
  }

  void _onFrameDetached(Map<String, dynamic> params) {
    final frameId = params['frameId'] as String;
    _frames.remove(frameId);
    emit('frameDetached', frameId);
  }

  /// Get the main frame ID.
  String? get mainFrameId => _mainFrameId;
}

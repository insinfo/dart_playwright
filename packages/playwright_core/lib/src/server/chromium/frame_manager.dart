import 'package:playwright_protocol/playwright_protocol.dart';
import '../frames.dart';
import 'cr_connection.dart';

/// Manages frames in a Chromium page.
class FrameManager extends EventEmitter {
  final CDPSession session;
  final CoreFrameManager core;

  FrameManager(this.session, this.core) {
    session.on('Page.frameAttached', _onFrameAttached);
    session.on('Page.frameNavigated', _onFrameNavigated);
    session.on('Page.frameDetached', _onFrameDetached);
    session.on('Page.lifecycleEvent', _onLifecycleEvent);
  }

  void _onFrameAttached(Map<String, dynamic> params) {
    final frameId = params['frameId'] as String;
    final parentFrameId = params['parentFrameId'] as String?;
    core.frameAttached(frameId, parentFrameId);
    emit('frameAttached', frameId);
  }

  void _onFrameNavigated(Map<String, dynamic> params) {
    final frame = params['frame'] as Map<String, dynamic>;
    final frameId = frame['id'] as String;
    core.frameNavigated(
      frameId,
      frame['url'] as String? ?? '',
      frame['name'] as String? ?? '',
      frame['loaderId'] as String? ?? '',
      parentId: frame['parentId'] as String?,
    );
    emit('frameNavigated', frame);
  }

  void _onFrameDetached(Map<String, dynamic> params) {
    final frameId = params['frameId'] as String;
    core.frameDetached(frameId);
    emit('frameDetached', frameId);
  }

  void _onLifecycleEvent(Map<String, dynamic> params) {
    final frameId = params['frameId'] as String?;
    final name = params['name'] as String?;
    if (frameId != null && name != null) {
      core.frameLifecycleEvent(
        frameId,
        name,
        loaderId: params['loaderId'] as String?,
      );
    }
  }

  /// Get the main frame ID.
  String? get mainFrameId => core.mainFrame?.id;
}

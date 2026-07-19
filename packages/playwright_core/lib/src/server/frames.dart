import 'dart:async';
import 'package:playwright_protocol/playwright_protocol.dart';
import 'core_page.dart';

class CoreFrame {
  final CorePage page;
  final CoreFrameManager manager;
  final String id;
  final String? parentId;
  String url = '';
  String name = '';
  String currentLoaderId = '';
  int _navigationOrdinal = 0;
  final Set<String> _lifecycleEvents = {};

  final EventEmitter _emitter = EventEmitter();

  CoreFrame({
    required this.page,
    required this.manager,
    required this.id,
    this.parentId,
  });

  CoreFrame? get parentFrame =>
      parentId == null ? null : manager.frame(parentId!);

  List<CoreFrame> get childFrames =>
      manager.frames.where((frame) => frame.parentId == id).toList();

  bool onLifecycleEvent(String eventName) {
    if (eventName == 'init') {
      _lifecycleEvents.clear();
    }
    if (eventName == 'networkidle') {
      eventName = 'networkIdle';
    }
    // Chromium can report the same lifecycle transition through both
    // Page.lifecycleEvent and its legacy Page.*EventFired counterpart.
    if (_lifecycleEvents.contains(eventName)) return false;
    _lifecycleEvents.add(eventName);
    _emitter.emit('lifecycle', eventName);
    return true;
  }

  void onNavigated(String newUrl, String newName, String newLoaderId) {
    final isNewDocument =
        newLoaderId.isNotEmpty && newLoaderId != currentLoaderId;
    url = newUrl;
    name = newName;
    if (isNewDocument || currentLoaderId.isEmpty) {
      _navigationOrdinal++;
      currentLoaderId = newLoaderId;
      _lifecycleEvents.clear();
    }
    onLifecycleEvent('commit');
  }

  void onNavigatedWithinDocument(String newUrl) {
    url = newUrl;
  }

  /// Waits for a specific WaitUntilState for this frame's current navigation.
  Future<void> waitForLoadState(WaitUntilState state,
      {Duration? timeout}) async {
    final targetEvent = _eventForState(state);

    // If we already have the event, we are done!
    if (_lifecycleEvents.contains(targetEvent)) {
      return;
    }

    await _waitForLifecycleEvent(targetEvent, timeout: timeout);
  }

  /// Waits for a new navigation to complete to a specific state.
  Future<void> waitForNavigation(
      {WaitUntilState? waitUntil, Duration? timeout}) async {
    final targetEvent = _eventForState(waitUntil ?? WaitUntilState.load);
    final loaderId = currentLoaderId;
    final ordinal = _navigationOrdinal;
    await _waitForLifecycleEvent(
      targetEvent,
      requiredLoaderId: loaderId.isEmpty ? null : loaderId,
      requiredNavigationOrdinal: ordinal,
      timeout: timeout,
    );
  }

  Future<void> _waitForLifecycleEvent(String targetEvent,
      {String? requiredLoaderId,
      int? requiredNavigationOrdinal,
      Duration? timeout}) async {
    final completer = Completer<void>();

    void onEvent(dynamic eventName) {
      final loaderMatches = requiredLoaderId == null ||
          currentLoaderId.isEmpty ||
          currentLoaderId != requiredLoaderId;
      final navigationMatches = requiredNavigationOrdinal == null ||
          _navigationOrdinal != requiredNavigationOrdinal;
      if (loaderMatches &&
          navigationMatches &&
          eventName == targetEvent &&
          !completer.isCompleted) {
        completer.complete();
      }
    }

    _emitter.on('lifecycle', onEvent);

    try {
      if (timeout != null) {
        await completer.future.timeout(timeout);
      } else {
        await completer.future;
      }
    } finally {
      _emitter.off('lifecycle', onEvent);
    }
  }

  String _eventForState(WaitUntilState state) {
    switch (state) {
      case WaitUntilState.load:
        return 'load';
      case WaitUntilState.domcontentloaded:
        return 'DOMContentLoaded';
      case WaitUntilState.networkidle:
        return 'networkIdle';
      case WaitUntilState.commit:
        return 'commit';
    }
  }
}

class CoreFrameManager {
  final CorePage page;
  final _frames = <String, CoreFrame>{};
  String? _mainFrameId;
  final _mainFrameCompleter = Completer<CoreFrame>();

  CoreFrameManager(this.page);

  CoreFrame? get mainFrame =>
      _mainFrameId != null ? _frames[_mainFrameId!] : null;

  List<CoreFrame> get frames => _frames.values.toList();

  CoreFrame? frame(String frameId) => _frames[frameId];

  Future<CoreFrame> waitForMainFrame(
      {Duration timeout = const Duration(seconds: 30)}) {
    final frame = mainFrame;
    if (frame != null) return Future.value(frame);
    return _mainFrameCompleter.future.timeout(timeout);
  }

  void frameAttached(String frameId, String? parentId) {
    if (_frames.containsKey(frameId)) return;
    final frame = CoreFrame(
      page: page,
      manager: this,
      id: frameId,
      parentId: parentId,
    );
    _frames[frameId] = frame;
    if (parentId == null) {
      _mainFrameId = frameId;
      if (!_mainFrameCompleter.isCompleted) {
        _mainFrameCompleter.complete(frame);
      }
    }
    page.emit('frameAttached', frame);
  }

  void frameNavigated(String frameId, String url, String name, String loaderId,
      {String? parentId}) {
    var frame = _frames[frameId];
    if (frame == null) {
      // In some engines (like Firefox), we might not get frameAttached before navigated
      frameAttached(frameId, parentId);
      frame = _frames[frameId]!;
    } else if (parentId == null) {
      _mainFrameId = frameId;
      if (!_mainFrameCompleter.isCompleted) {
        _mainFrameCompleter.complete(frame);
      }
    }
    frame.onNavigated(url, name, loaderId);
    page.emit('frameNavigated', frame);
  }

  void frameNavigatedWithinDocument(String frameId, String url) {
    _frames[frameId]?.onNavigatedWithinDocument(url);
  }

  void frameDetached(String frameId) {
    final frame = _frames[frameId];
    _frames.remove(frameId);
    if (_mainFrameId == frameId) {
      _mainFrameId = null;
    }
    if (frame != null) {
      page.emit('frameDetached', frame);
    }
  }

  void frameLifecycleEvent(String frameId, String eventName) {
    final frame = _frames[frameId];
    if (frame == null) return;
    final isNewEvent = frame.onLifecycleEvent(eventName);
    if (!isNewEvent) return;
    if (frameId == _mainFrameId) {
      if (eventName == 'load') {
        page.emit('load');
      } else if (eventName == 'DOMContentLoaded') {
        page.emit('domcontentloaded');
      } else if (eventName == 'networkIdle' || eventName == 'networkidle') {
        page.emit('networkidle');
      }
    }
  }
}

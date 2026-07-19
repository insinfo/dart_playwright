import 'dart:convert';
import 'dart:io';
import 'package:playwright_protocol/playwright_protocol.dart';
import 'cr_execution_context.dart';
import 'cr_input.dart';
import 'cr_network_manager.dart';
import 'cr_route.dart';
import '../core_route.dart';
import '../../accessibility.dart';
import '../core_page.dart';
import '../core_js_handle.dart';

/// Represents a Chromium Page (tab).
class CrPage extends EventEmitter
    with CorePageInputHelpers, CorePageDialogs, CorePageContentHelpers
    implements CorePage {
  final dynamic session;
  final CrNetworkManager networkManager;
  @override
  late final Keyboard keyboard;
  late final CrExecutionContext executionContext;
  final _routes = <String, void Function(CoreRoute)>{};
  late final CoreFrameManager frameManager;

  bool _isClosed = false;

  CrPage._(this.session) : networkManager = CrNetworkManager(session) {
    frameManager = CoreFrameManager(this);
    keyboard = Keyboard(CrRawKeyboard(session));
    executionContext = CrExecutionContext(session);
    session.on('closed', () => _onClosed());
    session.on('Page.javascriptDialogOpening', _onDialogOpening);

    // Frame events
    session.on('Page.frameAttached', (params) {
      frameManager.frameAttached(
          params['frameId'] as String, params['parentFrameId'] as String?);
    });
    session.on('Page.frameNavigated', (params) {
      final frame = params['frame'] as Map<String, dynamic>;
      frameManager.frameNavigated(
        frame['id'] as String,
        frame['url'] as String,
        frame['name'] as String? ?? '',
        frame['loaderId'] as String? ?? '',
        parentId: frame['parentId'] as String?,
      );
    });
    session.on('Page.frameDetached', (params) {
      frameManager.frameDetached(params['frameId'] as String);
    });
    session.on('Page.navigatedWithinDocument', (params) {
      frameManager.frameNavigatedWithinDocument(
          params['frameId'] as String, params['url'] as String);
    });
    session.on('Page.lifecycleEvent', (params) {
      frameManager.frameLifecycleEvent(
        params['frameId'] as String,
        params['name'] as String,
        loaderId: params['loaderId'] as String?,
      );
    });
    // Some Chromium builds do not deliver Page.lifecycleEvent reliably for
    // the main frame even after Page.setLifecycleEventsEnabled. The legacy
    // load events are always emitted, so use them as a main-frame fallback.
    session.on('Page.loadEventFired', (_) {
      final frame = frameManager.mainFrame;
      if (frame != null) {
        frameManager.frameLifecycleEvent(frame.id, 'load');
      }
    });
    session.on('Page.domContentEventFired', (_) {
      final frame = frameManager.mainFrame;
      if (frame != null) {
        frameManager.frameLifecycleEvent(frame.id, 'DOMContentLoaded');
      }
    });
  }

  void _onDialogOpening(Map<String, dynamic> params) {
    dispatchDialog(Dialog(
      params['type'] as String? ?? 'alert',
      params['message'] as String? ?? '',
      params['defaultPrompt'] as String? ?? '',
      (accept, promptText) async {
        await session.send('Page.handleJavaScriptDialog', {
          'accept': accept,
          if (promptText != null) 'promptText': promptText,
        });
      },
    ));
  }

  /// Create and initialize a new page.
  static Future<CrPage> create(dynamic session) async {
    final page = CrPage._(session);
    await page._initialize();
    return page;
  }

  Future<void> _initialize() async {
    // Enable essential domains
    await Future.wait(<Future<dynamic>>[
      session.send('Page.enable') as Future<dynamic>,
      session.send('Page.setLifecycleEventsEnabled', {'enabled': true})
          as Future<dynamic>,
      session.send('Runtime.enable') as Future<dynamic>,
      session.send('Network.enable') as Future<dynamic>,
      session.send('Log.enable') as Future<dynamic>,
      session.send('Accessibility.enable') as Future<dynamic>,
    ]);
    // Chromium only emits Page.frameAttached/frameNavigated for frames
    // created after Page.enable. The main frame predates it, so seed the
    // existing tree or waitForMainFrame() would never complete.
    final result = await session.send('Page.getFrameTree');
    _handleFrameTree(result['frameTree'] as Map<String, dynamic>);
  }

  void _handleFrameTree(Map<String, dynamic> frameTree) {
    final frame = frameTree['frame'] as Map<String, dynamic>;
    final parentId = frame['parentId'] as String?;
    frameManager.frameAttached(frame['id'] as String, parentId);
    frameManager.frameNavigated(
      frame['id'] as String,
      frame['url'] as String? ?? '',
      frame['name'] as String? ?? '',
      frame['loaderId'] as String? ?? '',
      parentId: parentId,
    );
    for (final child in frameTree['childFrames'] as List? ?? const []) {
      _handleFrameTree(child as Map<String, dynamic>);
    }
  }

  @override
  CoreFrame get mainFrame => frameManager.mainFrame!;

  @override
  List<CoreFrame> get frames => frameManager.frames;

  @override
  Future<void> waitForLoadState(
      {WaitUntilState state = WaitUntilState.load, Duration? timeout}) async {
    final frame = await frameManager.waitForMainFrame();
    await frame.waitForLoadState(state, timeout: timeout);
  }

  @override
  Future<void> waitForNavigation(
      {WaitUntilState? waitUntil, Duration? timeout}) async {
    await mainFrame.waitForNavigation(waitUntil: waitUntil, timeout: timeout);
  }

  @override
  Future<void> goto(String url, {WaitUntilState? waitUntil}) async {
    final frame = await frameManager.waitForMainFrame();
    final loaded = frame.waitForNavigation(
        waitUntil: waitUntil, timeout: const Duration(seconds: 30));
    final result = await session.send('Page.navigate', {'url': url});
    if (result['errorText'] != null) {
      throw PlaywrightException(
          'Navigation to $url failed: ${result['errorText']}');
    }
    await loaded;
  }

  @override
  Future<void> reload({WaitUntilState? waitUntil}) async {
    final frame = await frameManager.waitForMainFrame();
    final loaded = frame.waitForNavigation(
        waitUntil: waitUntil, timeout: const Duration(seconds: 30));
    await session.send('Page.reload');
    await loaded;
  }

  @override
  Future<bool> goBack({WaitUntilState? waitUntil}) =>
      _goHistory(-1, waitUntil);

  @override
  Future<bool> goForward({WaitUntilState? waitUntil}) =>
      _goHistory(1, waitUntil);

  Future<bool> _goHistory(int delta, WaitUntilState? waitUntil) async {
    final history = await session.send('Page.getNavigationHistory');
    final entries = history['entries'] as List;
    final targetIndex = (history['currentIndex'] as int) + delta;
    if (targetIndex < 0 || targetIndex >= entries.length) return false;
    final entry = entries[targetIndex] as Map<String, dynamic>;
    final frame = await frameManager.waitForMainFrame();
    final loaded = frame.waitForNavigation(
        waitUntil: waitUntil, timeout: const Duration(seconds: 30));
    await session.send('Page.navigateToHistoryEntry', {'entryId': entry['id']});
    await loaded;
    return true;
  }

  /// Get the page title.
  Future<String> title() async {
    final result = await executionContext.evaluate('document.title');
    return result.toString();
  }

  /// Evaluate JavaScript in the page.
  @override
  Future<dynamic> evaluate(String expression) async {
    return executionContext.evaluate(expression);
  }

  /// Click an element using trusted CDP input events.
  @override
  Future<void> click(String selector) async {
    final point = await clickPointFor(selector);
    await _mouseMove(point);
    await _mousePressRelease(point, clickCount: 1);
  }

  @override
  Future<void> dblclick(String selector) async {
    final point = await clickPointFor(selector);
    await _mouseMove(point);
    await _mousePressRelease(point, clickCount: 1);
    await _mousePressRelease(point, clickCount: 2);
  }

  @override
  Future<void> hover(String selector) async {
    final point = await clickPointFor(selector);
    await _mouseMove(point);
  }

  Future<void> _mouseMove(({double x, double y}) point) async {
    await session.send('Input.dispatchMouseEvent', {
      'type': 'mouseMoved',
      'x': point.x,
      'y': point.y,
      'button': 'none',
      'buttons': 0,
    });
  }

  Future<void> _mousePressRelease(({double x, double y}) point,
      {required int clickCount}) async {
    await session.send('Input.dispatchMouseEvent', {
      'type': 'mousePressed',
      'x': point.x,
      'y': point.y,
      'button': 'left',
      'buttons': 1,
      'clickCount': clickCount,
    });
    await session.send('Input.dispatchMouseEvent', {
      'type': 'mouseReleased',
      'x': point.x,
      'y': point.y,
      'button': 'left',
      'buttons': 0,
      'clickCount': clickCount,
    });
  }

  /// Fill an element using trusted CDP input events.
  @override
  Future<void> fill(String selector, String text) async {
    await focusAndSelect(selector);
    if (text.isEmpty) {
      await session.send('Input.dispatchKeyEvent', {
        'type': 'keyDown',
        'key': 'Delete',
        'code': 'Delete',
        'windowsVirtualKeyCode': 46,
      });
      await session.send('Input.dispatchKeyEvent', {
        'type': 'keyUp',
        'key': 'Delete',
        'code': 'Delete',
        'windowsVirtualKeyCode': 46,
      });
      return;
    }
    await session.send('Input.insertText', {'text': text});
  }

  @override
  Future<CoreJSHandle> evaluateHandle(String expression) async {
    return executionContext.evaluateHandle(expression);
  }

  /// Take a screenshot.
  Future<List<int>> screenshot({String? path}) async {
    final result = await session.send('Page.captureScreenshot', {
      'format': 'png',
    });
    final data = result['data'] as String;
    final bytes = base64Decode(data);

    if (path != null) {
      await File(path).writeAsBytes(bytes);
    }
    return bytes;
  }

  /// Get Accessibility Snapshot
  Future<AccessibilitySnapshot> accessibilitySnapshot() async {
    final result = await session.send('Accessibility.getFullAXTree');
    final nodes = result['nodes'] as List;

    // Simplistic parser for V0.1
    if (nodes.isEmpty) {
      return AccessibilitySnapshot(
          title: '',
          root: AccessibilityNode(role: 'WebArea', name: '', ref: 'root'));
    }

    final rootData = nodes.firstWhere((n) => n['role']?['value'] == 'WebArea',
        orElse: () => nodes.first);

    AccessibilityNode parseNode(Map<String, dynamic> data) {
      final role = data['role']?['value'] as String? ?? 'Unknown';
      final name = data['name']?['value'] as String? ?? '';
      final description = data['description']?['value'] as String?;
      final value = data['value']?['value']?.toString();
      final nodeId = data['nodeId'] as String? ?? '';

      final childIds = (data['childIds'] as List?)?.cast<String>() ?? [];
      final children = childIds
          .map((id) {
            final childData =
                nodes.firstWhere((n) => n['nodeId'] == id, orElse: () => null);
            return childData != null ? parseNode(childData) : null;
          })
          .whereType<AccessibilityNode>()
          .toList();

      return AccessibilityNode(
        role: role,
        name: name,
        description: description,
        value: value,
        children: children,
        ref: 'node_$nodeId',
      );
    }

    final root = parseNode(rootData);
    final title = await this.title();

    return AccessibilitySnapshot(title: title, root: root);
  }

  /// Add a route interception handler.
  @override
  Future<void> route(
      String urlPattern, void Function(CoreRoute) handler) async {
    if (_routes.isEmpty) {
      await session.send('Fetch.enable', {
        'patterns': [
          {'requestStage': 'Request'}
        ]
      });
      session.on('Fetch.requestPaused', _onRequestPaused);
    }
    _routes[urlPattern] = handler;
  }

  void _onRequestPaused(Map<String, dynamic> params) {
    final fetchRequestId = params['requestId'] as String;
    final request = params['request'] as Map<String, dynamic>;
    final url = request['url'] as String;

    // Find matching route handler
    void Function(CoreRoute)? matchedHandler;
    for (final pattern in _routes.keys) {
      final cleanPattern = pattern.replaceAll('**/', '');
      if (pattern == '**/*' || url.contains(cleanPattern)) {
        matchedHandler = _routes[pattern];
        break;
      }
    }

    if (matchedHandler != null) {
      matchedHandler(CrRoute(
        session,
        fetchRequestId,
        url,
        method: request['method'] as String? ?? 'GET',
        headers: _stringHeaders(request['headers']),
      ));
    } else {
      session.send('Fetch.continueRequest', {'requestId': fetchRequestId});
    }
  }

  Map<String, String> _stringHeaders(dynamic headers) {
    if (headers is! Map) return const <String, String>{};
    return headers.map((key, value) => MapEntry('$key', '$value'));
  }

  /// Close the page.
  Future<void> close() async {
    if (_isClosed) return;
    await session.send('Page.close');
  }

  void _onClosed() {
    if (_isClosed) return;
    _isClosed = true;
    emit('close');
  }
}

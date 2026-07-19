import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:playwright_protocol/playwright_protocol.dart';
import '../core_page.dart';
import '../core_js_handle.dart';
import '../core_route.dart';
import 'wk_connection.dart';
import 'wk_input.dart';
import 'wk_route.dart';
import '../../accessibility.dart';

/// A WebKit page, backed by a pageProxy session.
///
/// Page-level commands are wrapped in `Target.sendMessageToTarget` by
/// [WkPageProxySession.sendToTarget]; page-level events arrive unwrapped
/// on the same session (via `Target.dispatchMessageFromTarget`).
class WkPage extends EventEmitter
    with CorePageInputHelpers, CorePageDialogs, CorePageContentHelpers
    implements CorePage {
  final WkPageProxySession session;
  final String? browserContextId;
  @override
  late final Keyboard keyboard;
  late final CoreFrameManager frameManager;

  bool _isClosed = false;

  WkPage(this.session, {this.browserContextId}) {
    frameManager = CoreFrameManager(this);
    keyboard = Keyboard(WkRawKeyboard(session));
    // WebKit reports dialogs via the Dialog domain on the pageProxy session.
    session.on('Dialog.javascriptDialogOpening', _onDialogOpening);
    session.on('Page.frameNavigated', (params) {
      final frame = params['frame'] as Map<String, dynamic>;
      frameManager.frameNavigated(
        frame['id'] as String,
        frame['url'] as String,
        frame['name'] as String? ?? '',
        frame['loaderId'] as String? ?? frame['navigationId'] as String? ?? '',
        parentId: frame['parentId'] as String?,
      );
    });
    session.on('Page.frameDetached', (params) {
      frameManager.frameDetached(params['frameId'] as String);
    });
    session.on('Page.loadEventFired', (_) {
      if (frameManager.mainFrame != null) {
        frameManager.frameLifecycleEvent(frameManager.mainFrame!.id, 'load');
      }
    });
    session.on('Page.domContentEventFired', (_) {
      if (frameManager.mainFrame != null) {
        frameManager.frameLifecycleEvent(
            frameManager.mainFrame!.id, 'DOMContentLoaded');
      }
    });
    session.on('closed', () => _onClosed());
  }

  void _onDialogOpening(Map<String, dynamic> params) {
    dispatchDialog(Dialog(
      params['type'] as String? ?? 'alert',
      params['message'] as String? ?? '',
      params['defaultPrompt'] as String? ?? '',
      (accept, promptText) async {
        await session.send('Dialog.handleJavaScriptDialog', {
          'accept': accept,
          if (promptText != null) 'promptText': promptText,
        });
      },
    ));
  }

  Future<void> initialize() async {
    await session.send('Dialog.enable');
    await session.sendToTarget('Page.enable');
    await session.sendToTarget('Runtime.enable');
    // WebKit only reports frame changes that happen after Page.enable. The
    // main frame predates it, so seed the existing tree (mirrors upstream
    // _handleFrameTree) or waitForMainFrame() would never complete.
    final result = await session.sendToTarget('Page.getResourceTree');
    _handleFrameTree(result['frameTree'] as Map<String, dynamic>);
    if (session.targetIsPaused) {
      await session.send('Target.resume', {'targetId': session.targetId});
    }
  }

  void _handleFrameTree(Map<String, dynamic> frameTree) {
    final frame = frameTree['frame'] as Map<String, dynamic>;
    final frameId = frame['id'] as String;
    final parentId = frame['parentId'] as String?;
    frameManager.frameAttached(frameId, parentId);
    frameManager.frameNavigated(
      frameId,
      frame['url'] as String? ?? '',
      frame['name'] as String? ?? '',
      frame['loaderId'] as String? ?? '',
      parentId: parentId,
    );
    frameManager.frameLifecycleEvent(frameId, 'DOMContentLoaded');
    frameManager.frameLifecycleEvent(frameId, 'load');
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
    // Navigation is a Playwright-domain command on the browser session,
    // scoped by pageProxyId (WebKit's Page domain has no Page.navigate).
    await session.connection.send('Playwright.navigate', {
      'url': url,
      'pageProxyId': session.pageProxyId,
    });
    await loaded;
  }

  @override
  Future<void> reload({WaitUntilState? waitUntil}) async {
    final frame = await frameManager.waitForMainFrame();
    final loaded = frame.waitForNavigation(
        waitUntil: waitUntil, timeout: const Duration(seconds: 30));
    await session.sendToTarget('Page.reload');
    await loaded;
  }

  @override
  Future<bool> goBack({WaitUntilState? waitUntil}) =>
      _goHistory('Page.goBack', waitUntil);

  @override
  Future<bool> goForward({WaitUntilState? waitUntil}) =>
      _goHistory('Page.goForward', waitUntil);

  Future<bool> _goHistory(String method, WaitUntilState? waitUntil) async {
    final frame = await frameManager.waitForMainFrame();
    final loaded = frame.waitForNavigation(
        waitUntil: waitUntil, timeout: const Duration(seconds: 30));
    try {
      await session.sendToTarget(method);
    } on PlaywrightException catch (error) {
      // WebKit reports an exhausted history as "Failed to go back/forward".
      if (error.message.contains('Failed to go')) {
        loaded.catchError((_) {});
        return false;
      }
      rethrow;
    }
    await loaded;
    return true;
  }

  Future<String> title() async {
    final result = await evaluate('document.title');
    return result.toString();
  }

  /// Click an element using trusted WebKit input events.
  ///
  /// Mouse events are a pageProxy-level command (`Input.dispatchMouseEvent`),
  /// not a page-target command.
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
      'type': 'move',
      'button': 'none',
      'buttons': 0,
      'x': point.x,
      'y': point.y,
      'modifiers': 0,
    });
  }

  Future<void> _mousePressRelease(({double x, double y}) point,
      {required int clickCount}) async {
    await session.send('Input.dispatchMouseEvent', {
      'type': 'down',
      'button': 'left',
      'buttons': 1,
      'x': point.x,
      'y': point.y,
      'modifiers': 0,
      'clickCount': clickCount,
    });
    await session.send('Input.dispatchMouseEvent', {
      'type': 'up',
      'button': 'left',
      'buttons': 0,
      'x': point.x,
      'y': point.y,
      'modifiers': 0,
      'clickCount': clickCount,
    });
  }

  /// Fill an element using trusted WebKit input events.
  @override
  Future<void> fill(String selector, String text) async {
    await focusAndSelect(selector);
    if (text.isEmpty) {
      // Goes through the keyboard so macCommands (deleteForward:) are
      // attached; a bare key event does not edit on macOS.
      await keyboard.press('Delete');
      return;
    }
    await session.sendToTarget('Page.insertText', {'text': text});
  }

  @override
  Future<dynamic> evaluate(String expression) async {
    final isFunction =
        expression.trim().startsWith('function') || expression.contains('=>');
    final finalExpression = isFunction ? '($expression)()' : expression;

    final result = await session.sendToTarget('Runtime.evaluate', {
      'expression': finalExpression,
      'returnByValue': true,
    });

    if (result['wasThrown'] == true || result['exceptionDetails'] != null) {
      throw PlaywrightException('Evaluation failed: ${result["result"]}');
    }

    return result['result']?['value'];
  }

  @override
  Future<CoreJSHandle> evaluateHandle(String expression) async {
    throw UnsupportedError(
        'evaluateHandle not fully implemented for WkPage yet');
  }

  Future<List<int>> screenshot({String? path}) async {
    final width = await evaluate('window.innerWidth');
    final height = await evaluate('window.innerHeight');

    final result = await session.sendToTarget('Page.snapshotRect', {
      'x': 0,
      'y': 0,
      'width': width ?? 800,
      'height': height ?? 600,
      'coordinateSystem': 'Viewport',
    });
    final data = result['dataURL'] as String;
    final bytes = base64Decode(data.split(',').last);

    if (path != null) {
      await File(path).writeAsBytes(bytes);
    }
    return bytes;
  }

  Future<AccessibilitySnapshot> accessibilitySnapshot() async {
    return AccessibilitySnapshot(
        title: await title(),
        root: AccessibilityNode(role: 'WebArea', name: '', ref: 'root'));
  }

  final _routes = <String, void Function(CoreRoute)>{};

  @override
  Future<void> route(
      String urlPattern, void Function(CoreRoute) handler) async {
    if (_routes.isEmpty) {
      session.on('Network.requestIntercepted', _onRequestIntercepted);
      await session.sendToTarget('Network.enable');
      await session
          .sendToTarget('Network.setInterceptionEnabled', {'enabled': true});
      await session.sendToTarget('Network.addInterception', {
        'url': '.*',
        'stage': 'request',
        'isRegex': true,
      });
    }
    _routes[urlPattern] = handler;
  }

  void _onRequestIntercepted(Map<String, dynamic> params) {
    final requestId = params['requestId'] as String;
    final request = params['request'] as Map<String, dynamic>? ?? {};
    final url = request['url'] as String? ?? '';

    void Function(CoreRoute)? matchedHandler;
    for (final pattern in _routes.keys) {
      final cleanPattern = pattern.replaceAll('**/', '');
      if (pattern == '**/*' || url.contains(cleanPattern)) {
        matchedHandler = _routes[pattern];
        break;
      }
    }

    if (matchedHandler != null) {
      matchedHandler(WkRoute(
        session,
        requestId,
        url,
        method: request['method'] as String? ?? 'GET',
        headers: _stringHeaders(request['headers']),
      ));
    } else {
      // Fire-and-forget: the page may be closing and the session already
      // gone; that must not surface as an unhandled async error.
      session.sendToTarget('Network.interceptContinue', {
        'requestId': requestId,
        'stage': 'request',
      }).catchError((_) => <String, dynamic>{});
    }
  }

  Map<String, String> _stringHeaders(dynamic headers) {
    if (headers is! Map) return const <String, String>{};
    return headers.map((key, value) => MapEntry('$key', '$value'));
  }

  Future<void> close() async {
    if (_isClosed) return;
    await session.connection
        .send('Playwright.closePage', {'pageProxyId': session.pageProxyId});
  }

  void _onClosed() {
    if (_isClosed) return;
    _isClosed = true;
    emit('close');
  }
}

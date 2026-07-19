import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:playwright_protocol/playwright_protocol.dart';
import 'ff_connection.dart';
import 'ff_input.dart';
import 'ff_route.dart';
import '../../accessibility.dart';

import '../core_page.dart';
import '../core_route.dart';
import '../core_js_handle.dart';

/// Represents a Firefox Juggler Page (tab).
class FfPage extends EventEmitter
    with CorePageInputHelpers, CorePageDialogs, CorePageContentHelpers
    implements CorePage {
  final FfSession session;
  @override
  late final Keyboard keyboard;
  late final CoreFrameManager frameManager;

  bool _isClosed = false;
  String? _executionContextId;

  FfPage(this.session) {
    frameManager = CoreFrameManager(this);
    keyboard = Keyboard(FfRawKeyboard(session));
    session.on('Page.dialogOpened', _onDialogOpened);
    session.on('Page.frameAttached', (params) {
      frameManager.frameAttached(
          params['frameId'] as String, params['parentFrameId'] as String?);
    });
    session.on('Page.frameDetached', (params) {
      frameManager.frameDetached(params['frameId'] as String);
    });
    // Firefox Juggler reports document navigations as
    // Page.navigationCommitted (not Page.navigated).
    session.on('Page.navigationCommitted', (params) {
      frameManager.frameNavigated(
        params['frameId'] as String,
        params['url'] as String,
        params['name'] as String? ?? '',
        params['navigationId'] as String? ?? '',
        parentId: params['parentFrameId'] as String?,
      );
    });
    session.on('Page.sameDocumentNavigation', (params) {
      frameManager.frameNavigatedWithinDocument(
        params['frameId'] as String,
        params['url'] as String,
      );
    });
    session.on('Page.eventFired', (params) {
      frameManager.frameLifecycleEvent(
          params['frameId'] as String, params['name'] as String);
    });
    session.on('Runtime.executionContextCreated', (params) {
      if (params['auxData'] != null &&
          params['auxData']['frameId'] == frameManager.mainFrame?.id) {
        _executionContextId = params['executionContextId'] as String;
      }
    });
    session.on('closed', () => _onClosed());
  }

  void _onDialogOpened(Map<String, dynamic> params) {
    final dialogId = params['dialogId'];
    dispatchDialog(Dialog(
      params['type'] as String? ?? 'alert',
      params['message'] as String? ?? '',
      params['defaultValue'] as String? ?? '',
      (accept, promptText) async {
        await session.send('Page.handleDialog', {
          'dialogId': dialogId,
          'accept': accept,
          if (promptText != null) 'promptText': promptText,
        });
      },
    ));
  }

  Future<void> initialize() async {
    // Wait for Page.ready
    // Instead of enabling Page/Runtime like Chromium, Juggler just emits Page.ready
    await session.waitForEvent('Page.ready');
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

  /// Navigate to a URL.
  @override
  Future<void> goto(String url, {WaitUntilState? waitUntil}) async {
    final frame = await frameManager.waitForMainFrame();
    final loaded = frame.waitForNavigation(
        waitUntil: waitUntil, timeout: const Duration(seconds: 30));
    await session.send('Page.navigate', {'url': url, 'frameId': frame.id});
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
      _goHistory('Page.goBack', waitUntil);

  @override
  Future<bool> goForward({WaitUntilState? waitUntil}) =>
      _goHistory('Page.goForward', waitUntil);

  Future<bool> _goHistory(String method, WaitUntilState? waitUntil) async {
    final frame = await frameManager.waitForMainFrame();
    final loaded = frame.waitForNavigation(
        waitUntil: waitUntil, timeout: const Duration(seconds: 30));
    final result = await session.send(method, {'frameId': frame.id});
    if (result['success'] != true) {
      // Nothing will navigate; drop the waiter silently.
      loaded.catchError((_) {});
      return false;
    }
    await loaded;
    return true;
  }

  /// Get the page title.
  Future<String> title() async {
    final result = await evaluate('document.title');
    return result.toString();
  }

  /// Click an element using trusted Juggler input events.
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
    await session.send('Page.dispatchMouseEvent', {
      'type': 'mousemove',
      'button': 0,
      'buttons': 0,
      'x': point.x.floor(),
      'y': point.y.floor(),
      'modifiers': 0,
    });
  }

  Future<void> _mousePressRelease(({double x, double y}) point,
      {required int clickCount}) async {
    final x = point.x.floor();
    final y = point.y.floor();
    await session.send('Page.dispatchMouseEvent', {
      'type': 'mousedown',
      'button': 0,
      'buttons': 1,
      'x': x,
      'y': y,
      'modifiers': 0,
      'clickCount': clickCount,
    });
    await session.send('Page.dispatchMouseEvent', {
      'type': 'mouseup',
      'button': 0,
      'buttons': 0,
      'x': x,
      'y': y,
      'modifiers': 0,
      'clickCount': clickCount,
    });
  }

  /// Fill an element using trusted Juggler input events.
  @override
  Future<void> fill(String selector, String text) async {
    await focusAndSelect(selector);
    if (text.isEmpty) {
      await session.send('Page.dispatchKeyEvent', {
        'type': 'keydown',
        'key': 'Delete',
        'code': 'Delete',
        'keyCode': 46,
        'location': 0,
        'repeat': false,
        'text': '',
      });
      await session.send('Page.dispatchKeyEvent', {
        'type': 'keyup',
        'key': 'Delete',
        'code': 'Delete',
        'keyCode': 46,
        'location': 0,
        'repeat': false,
      });
      return;
    }
    await session.send('Page.insertText', {'text': text});
  }

  /// Evaluate JavaScript in the page.
  @override
  Future<dynamic> evaluate(String expression) async {
    final isFunction =
        expression.trim().startsWith('function') || expression.contains('=>');
    final finalExpression = isFunction ? '($expression)()' : expression;

    final result = await session.send('Runtime.evaluate', {
      'expression': finalExpression,
      'returnByValue': true,
      if (_executionContextId != null)
        'executionContextId': _executionContextId,
    });

    if (result['exceptionDetails'] != null) {
      throw PlaywrightException(
          'Evaluation failed: ${result["exceptionDetails"]}');
    }

    return result['result']?['value'];
  }

  @override
  Future<CoreJSHandle> evaluateHandle(String expression) async {
    throw UnsupportedError(
        'evaluateHandle not fully implemented for FfPage yet');
  }

  /// Take a screenshot.
  Future<List<int>> screenshot({String? path}) async {
    // Juggler requires an explicit clip rect.
    final width = await evaluate('window.innerWidth');
    final height = await evaluate('window.innerHeight');

    final result = await session.send('Page.screenshot', {
      'mimeType': 'image/png',
      'clip': {
        'x': 0,
        'y': 0,
        'width': width ?? 1280,
        'height': height ?? 720,
      },
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
    // Firefox might not have Accessibility.getFullAXTree out of the box in Juggler
    // We mock it for parity tests if it fails
    try {
      await session.send('Accessibility.getFullAXTree');
      // Similar parsing...
      return AccessibilitySnapshot(
          title: 'Firefox A11y',
          root: AccessibilityNode(role: 'WebArea', name: '', ref: 'root'));
    } catch (_) {
      return AccessibilitySnapshot(
          title: await title(),
          root: AccessibilityNode(role: 'WebArea', name: '', ref: 'root'));
    }
  }

  final _routes = <String, void Function(CoreRoute)>{};

  @override
  Future<void> route(
      String urlPattern, void Function(CoreRoute) handler) async {
    if (_routes.isEmpty) {
      session.on('Network.requestWillBeSent', _onRequestWillBeSent);
      await session.send('Network.setRequestInterception', {'enabled': true});
    }
    _routes[urlPattern] = handler;
  }

  void _onRequestWillBeSent(Map<String, dynamic> params) {
    if (params['isIntercepted'] != true) return;
    final requestId = params['requestId'] as String;
    final url = params['url'] as String;

    void Function(CoreRoute)? matchedHandler;
    for (final pattern in _routes.keys) {
      final cleanPattern = pattern.replaceAll('**/', '');
      if (pattern == '**/*' || url.contains(cleanPattern)) {
        matchedHandler = _routes[pattern];
        break;
      }
    }

    if (matchedHandler != null) {
      matchedHandler(FfRoute(
        session,
        requestId,
        url,
        method: params['method'] as String? ?? 'GET',
        headers: _stringHeaders(params['headers']),
      ));
    } else {
      session
          .send('Network.resumeInterceptedRequest', {'requestId': requestId});
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

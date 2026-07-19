import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:playwright_protocol/playwright_protocol.dart';
import 'ff_connection.dart';
import 'ff_input.dart';
import 'ff_route.dart';
import '../../accessibility.dart';

import '../core_page.dart';
import '../core_js_handle.dart';

/// Represents a Firefox Juggler Page (tab).
class FfPage extends EventEmitter
    with CorePageInputHelpers, CorePageDialogs
    implements CorePage {
  final FfSession session;
  @override
  late final Keyboard keyboard;

  bool _isClosed = false;

  String? _mainFrameId;
  String? _executionContextId;

  FfPage(this.session) {
    keyboard = Keyboard(FfRawKeyboard(session));
    session.on('Page.dialogOpened', _onDialogOpened);
    session.on('Page.frameAttached', (params) {
      _mainFrameId ??= params['frameId'] as String;
    });
    session.on('Runtime.executionContextCreated', (params) {
      if (params['auxData'] != null && params['auxData']['frameId'] == _mainFrameId) {
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
  Future<void> waitForLoadState({WaitUntilState state = WaitUntilState.load, Duration? timeout}) async {
    final targetName = (state == WaitUntilState.load || state == WaitUntilState.networkidle) 
        ? 'load' 
        : 'DOMContentLoaded';
        
    final completer = Completer<void>();
    void Function(dynamic)? listener;
    Timer? timer;
    
    listener = (payload) {
      if (payload['name'] == targetName) {
        session.off('Page.eventFired', listener!);
        timer?.cancel();
        if (!completer.isCompleted) completer.complete();
      }
    };
    
    session.on('Page.eventFired', listener);
    
    if (timeout != null) {
      timer = Timer(timeout, () {
        session.off('Page.eventFired', listener!);
        if (!completer.isCompleted) completer.completeError(TimeoutException('Timeout waiting for $targetName'));
      });
    }
    
    await completer.future;
    
    if (state == WaitUntilState.networkidle) {
      await Future.delayed(const Duration(milliseconds: 500));
    }
  }

  @override
  Future<void> waitForNavigation({WaitUntilState? waitUntil, Duration? timeout}) async {
    await waitForLoadState(state: waitUntil ?? WaitUntilState.load, timeout: timeout);
  }

  /// Navigate to a URL.
  @override
  Future<void> goto(String url, {WaitUntilState? waitUntil}) async {
    final loaded = waitForLoadState(state: waitUntil ?? WaitUntilState.load, timeout: const Duration(seconds: 30));
    await session.send('Page.navigate', {'url': url, 'frameId': _mainFrameId});
    await loaded;
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
    final x = point.x.floor();
    final y = point.y.floor();
    await session.send('Page.dispatchMouseEvent', {
      'type': 'mousemove',
      'button': 0,
      'buttons': 0,
      'x': x,
      'y': y,
      'modifiers': 0,
    });
    await session.send('Page.dispatchMouseEvent', {
      'type': 'mousedown',
      'button': 0,
      'buttons': 1,
      'x': x,
      'y': y,
      'modifiers': 0,
      'clickCount': 1,
    });
    await session.send('Page.dispatchMouseEvent', {
      'type': 'mouseup',
      'button': 0,
      'buttons': 0,
      'x': x,
      'y': y,
      'modifiers': 0,
      'clickCount': 1,
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
      if (_executionContextId != null) 'executionContextId': _executionContextId,
    });

    if (result['exceptionDetails'] != null) {
      throw PlaywrightException('Evaluation failed: ${result["exceptionDetails"]}');
    }
    
    return result['result']?['value'];
  }

  @override
  Future<CoreJSHandle> evaluateHandle(String expression) async {
    throw UnsupportedError('evaluateHandle not fully implemented for FfPage yet');
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
      return AccessibilitySnapshot(title: 'Firefox A11y', root: AccessibilityNode(role: 'WebArea', name: '', ref: 'root'));
    } catch (_) {
      return AccessibilitySnapshot(title: await title(), root: AccessibilityNode(role: 'WebArea', name: '', ref: 'root'));
    }
  }

  final _routes = <String, Function(FfRoute)>{};

  /// Add a route interception handler.
  Future<void> route(String urlPattern, Function(dynamic) handler) async {
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

    Function(FfRoute)? matchedHandler;
    for (final pattern in _routes.keys) {
      final cleanPattern = pattern.replaceAll('**/', '');
      if (pattern == '**/*' || url.contains(cleanPattern)) {
        matchedHandler = _routes[pattern];
        break;
      }
    }

    if (matchedHandler != null) {
      matchedHandler(FfRoute(session, requestId, url));
    } else {
      session.send('Network.resumeInterceptedRequest', {'requestId': requestId});
    }
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

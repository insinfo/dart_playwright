import 'dart:convert';
import 'dart:io';
import 'package:playwright_protocol/playwright_protocol.dart';
import '../core_page.dart';
import '../core_js_handle.dart';
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
    with CorePageInputHelpers, CorePageDialogs
    implements CorePage {
  final WkPageProxySession session;
  final String? browserContextId;
  @override
  late final Keyboard keyboard;

  bool _isClosed = false;

  WkPage(this.session, {this.browserContextId}) {
    keyboard = Keyboard(WkRawKeyboard(session));
    session.on('Dialog.javascriptDialogOpening', _onDialogOpening);
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
    if (session.targetIsPaused) {
      await session.send('Target.resume', {'targetId': session.targetId});
    }
  }

  @override
  Future<void> waitForLoadState({WaitUntilState state = WaitUntilState.load, Duration? timeout}) async {
    String eventName;
    if (state == WaitUntilState.load || state == WaitUntilState.networkidle) {
      eventName = 'Page.loadEventFired';
    } else {
      eventName = 'Page.domContentEventFired';
    }
    
    await session.waitForEvent(eventName, timeout: timeout);
    
    if (state == WaitUntilState.networkidle) {
      await Future.delayed(const Duration(milliseconds: 500));
    }
  }

  @override
  Future<void> waitForNavigation({WaitUntilState? waitUntil, Duration? timeout}) async {
    await waitForLoadState(state: waitUntil ?? WaitUntilState.load, timeout: timeout);
  }

  @override
  Future<void> goto(String url, {WaitUntilState? waitUntil}) async {
    final loaded = waitForLoadState(state: waitUntil ?? WaitUntilState.load, timeout: const Duration(seconds: 30));
    // Navigation is a Playwright-domain command on the browser session,
    // scoped by pageProxyId (WebKit's Page domain has no Page.navigate).
    await session.connection.send('Playwright.navigate', {
      'url': url,
      'pageProxyId': session.pageProxyId,
    });
    await loaded;
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
    await session.send('Input.dispatchMouseEvent', {
      'type': 'move',
      'button': 'none',
      'buttons': 0,
      'x': point.x,
      'y': point.y,
      'modifiers': 0,
    });
    await session.send('Input.dispatchMouseEvent', {
      'type': 'down',
      'button': 'left',
      'buttons': 1,
      'x': point.x,
      'y': point.y,
      'modifiers': 0,
      'clickCount': 1,
    });
    await session.send('Input.dispatchMouseEvent', {
      'type': 'up',
      'button': 'left',
      'buttons': 0,
      'x': point.x,
      'y': point.y,
      'modifiers': 0,
      'clickCount': 1,
    });
  }

  /// Fill an element using trusted WebKit input events.
  @override
  Future<void> fill(String selector, String text) async {
    await focusAndSelect(selector);
    if (text.isEmpty) {
      await session.send('Input.dispatchKeyEvent', {
        'type': 'keyDown',
        'modifiers': 0,
        'key': 'Delete',
        'code': 'Delete',
        'windowsVirtualKeyCode': 46,
        'isKeypad': false,
      });
      await session.send('Input.dispatchKeyEvent', {
        'type': 'keyUp',
        'modifiers': 0,
        'key': 'Delete',
        'code': 'Delete',
        'windowsVirtualKeyCode': 46,
        'isKeypad': false,
      });
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
    throw UnsupportedError('evaluateHandle not fully implemented for WkPage yet');
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

  final _routes = <String, Function(WkRoute)>{};

  Future<void> route(String urlPattern, Function(dynamic) handler) async {
    if (_routes.isEmpty) {
      session.on('Network.requestIntercepted', _onRequestIntercepted);
      await session.sendToTarget('Network.enable');
      await session.sendToTarget(
          'Network.setInterceptionEnabled', {'enabled': true});
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

    Function(WkRoute)? matchedHandler;
    for (final pattern in _routes.keys) {
      final cleanPattern = pattern.replaceAll('**/', '');
      if (pattern == '**/*' || url.contains(cleanPattern)) {
        matchedHandler = _routes[pattern];
        break;
      }
    }

    if (matchedHandler != null) {
      matchedHandler(WkRoute(session, requestId, url));
    } else {
      session.sendToTarget('Network.interceptContinue', {
        'requestId': requestId,
        'stage': 'request',
      });
    }
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

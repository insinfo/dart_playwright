import 'dart:convert';
import 'dart:io';
import 'package:playwright_protocol/playwright_protocol.dart';
import 'cr_execution_context.dart';
import 'cr_input.dart';
import 'cr_network_manager.dart';
import 'cr_route.dart';
import '../../accessibility.dart';
import '../core_page.dart';

/// Represents a Chromium Page (tab).
class CrPage extends EventEmitter
    with CorePageInputHelpers, CorePageDialogs
    implements CorePage {
  final dynamic session;
  final CrNetworkManager networkManager;
  @override
  late final Keyboard keyboard;
  late final CrExecutionContext executionContext;
  final _routes = <String, Function(CrRoute)>{};

  bool _isClosed = false;

  CrPage._(this.session) : networkManager = CrNetworkManager(session) {
    keyboard = Keyboard(CrRawKeyboard(session));
    executionContext = CrExecutionContext(session);
    session.on('closed', () => _onClosed());
    session.on('Page.javascriptDialogOpening', _onDialogOpening);
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
      session.send('Runtime.enable') as Future<dynamic>,
      session.send('Network.enable') as Future<dynamic>,
      session.send('Log.enable') as Future<dynamic>,
      session.send('Accessibility.enable') as Future<dynamic>,
    ]);
  }

  /// Navigate to a URL.
  Future<void> goto(String url) async {
    final loaded = session.waitForEvent('Page.loadEventFired',
        timeout: const Duration(seconds: 30));
    final result = await session.send('Page.navigate', {'url': url});
    if (result['errorText'] != null) {
      throw PlaywrightException(
          'Navigation to $url failed: ${result['errorText']}');
    }
    await loaded;
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
    await session.send('Input.dispatchMouseEvent', {
      'type': 'mouseMoved',
      'x': point.x,
      'y': point.y,
      'button': 'none',
      'buttons': 0,
    });
    await session.send('Input.dispatchMouseEvent', {
      'type': 'mousePressed',
      'x': point.x,
      'y': point.y,
      'button': 'left',
      'buttons': 1,
      'clickCount': 1,
    });
    await session.send('Input.dispatchMouseEvent', {
      'type': 'mouseReleased',
      'x': point.x,
      'y': point.y,
      'button': 'left',
      'buttons': 0,
      'clickCount': 1,
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

  Future<dynamic> evaluateHandle(String expression) async {
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
      return AccessibilitySnapshot(title: '', root: AccessibilityNode(role: 'WebArea', name: '', ref: 'root'));
    }
    
    final rootData = nodes.firstWhere((n) => n['role']?['value'] == 'WebArea', orElse: () => nodes.first);
    
    AccessibilityNode parseNode(Map<String, dynamic> data) {
      final role = data['role']?['value'] as String? ?? 'Unknown';
      final name = data['name']?['value'] as String? ?? '';
      final description = data['description']?['value'] as String?;
      final value = data['value']?['value']?.toString();
      final nodeId = data['nodeId'] as String? ?? '';

      final childIds = (data['childIds'] as List?)?.cast<String>() ?? [];
      final children = childIds.map((id) {
        final childData = nodes.firstWhere((n) => n['nodeId'] == id, orElse: () => null);
        return childData != null ? parseNode(childData) : null;
      }).whereType<AccessibilityNode>().toList();
      
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
  Future<void> route(String urlPattern, Function(CrRoute) handler) async {
    if (_routes.isEmpty) {
      await session.send('Fetch.enable', {
        'patterns': [{'requestStage': 'Request'}]
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
    Function(CrRoute)? matchedHandler;
    for (final pattern in _routes.keys) {
      final cleanPattern = pattern.replaceAll('**/', '');
      if (pattern == '**/*' || url.contains(cleanPattern)) {
        matchedHandler = _routes[pattern];
        break;
      }
    }
    
    if (matchedHandler != null) {
      final crRoute = CrRoute(session, fetchRequestId, url);
      matchedHandler(crRoute);
    } else {
      session.send('Fetch.continueRequest', {'requestId': fetchRequestId});
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

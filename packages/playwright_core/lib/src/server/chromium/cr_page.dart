import 'dart:convert';
import 'dart:io';
import 'package:playwright_protocol/playwright_protocol.dart';
import 'cr_connection.dart';
import 'cr_execution_context.dart';
import 'cr_input.dart';
import 'cr_network_manager.dart';
import 'cr_route.dart';

/// Represents a Chromium Page (tab).
class CrPage extends EventEmitter {
  final CDPSession session;
  final CrNetworkManager networkManager;
  final CrInput input;
  late final CrExecutionContext executionContext;
  final _routes = <String, Function(CrRoute)>{};
  
  bool _isClosed = false;

  CrPage._(this.session)
      : networkManager = CrNetworkManager(session),
        input = CrInput(session) {
    executionContext = CrExecutionContext(session);
    session.on('closed', () => _onClosed());
  }

  /// Create and initialize a new page.
  static Future<CrPage> create(CDPSession session) async {
    final page = CrPage._(session);
    await page._initialize();
    return page;
  }

  Future<void> _initialize() async {
    // Enable essential domains
    await Future.wait([
      session.send('Page.enable'),
      session.send('Runtime.enable'),
      session.send('Network.enable'),
      session.send('Log.enable'),
    ]);
  }

  /// Navigate to a URL.
  Future<void> goto(String url) async {
    await session.send('Page.navigate', {'url': url});
    // For a real implementation, we need to wait for the frame to load
    // This requires tracking frames and lifecycle events.
    // For now, we just wait a bit to simulate network delay.
    await Future.delayed(const Duration(milliseconds: 500));
  }

  /// Get the page title.
  Future<String> title() async {
    final result = await executionContext.evaluate('document.title');
    return result.toString();
  }

  /// Evaluate JavaScript in the page.
  Future<dynamic> evaluate(String expression) async {
    return executionContext.evaluate(expression);
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
      if (pattern == '**/*' || url.contains(pattern)) {
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

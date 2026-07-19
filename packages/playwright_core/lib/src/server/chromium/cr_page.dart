import 'dart:async';
import 'package:playwright_protocol/playwright_protocol.dart';
import 'cr_connection.dart';
import 'cr_execution_context.dart';
import 'cr_input.dart';
import 'cr_network_manager.dart';

/// Represents a Chromium Page (tab).
class CrPage extends EventEmitter {
  final CDPSession session;
  final CrNetworkManager networkManager;
  final CrInput input;
  late final CrExecutionContext executionContext;
  
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
  Future<List<int>> screenshot() async {
    final result = await session.send('Page.captureScreenshot', {
      'format': 'png',
    });
    // result['data'] is base64 encoded image
    // Need dart:convert to decode
    throw UnimplementedError('Needs base64 decode');
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

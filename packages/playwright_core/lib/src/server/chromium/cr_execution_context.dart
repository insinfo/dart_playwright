import 'dart:async';
import 'package:playwright_protocol/playwright_protocol.dart';
import 'cr_connection.dart';

/// Handles JavaScript execution in Chromium.
class CrExecutionContext {
  final CDPSession session;
  int? _executionContextId;

  CrExecutionContext(this.session) {
    session.on('Runtime.executionContextCreated', _onExecutionContextCreated);
    session.on('Runtime.executionContextDestroyed', _onExecutionContextDestroyed);
    session.on('Runtime.executionContextsCleared', _onExecutionContextsCleared);
  }

  void _onExecutionContextCreated(Map<String, dynamic> params) {
    final context = params['context'] as Map<String, dynamic>;
    // In a real implementation we track isolated worlds and frames.
    // For now, just grab the first one as default.
    _executionContextId ??= context['id'] as int;
  }

  void _onExecutionContextDestroyed(Map<String, dynamic> params) {
    final id = params['executionContextId'] as int;
    if (_executionContextId == id) {
      _executionContextId = null;
    }
  }

  void _onExecutionContextsCleared(Map<String, dynamic> params) {
    _executionContextId = null;
  }

  /// Evaluate a JS expression.
  Future<dynamic> evaluate(String expression) async {
    final params = <String, dynamic>{
      'expression': expression,
      'returnByValue': true,
      'awaitPromise': true,
    };

    if (_executionContextId != null) {
      params['contextId'] = _executionContextId;
    }

    final result = await session.send('Runtime.evaluate', params);
    
    if (result['exceptionDetails'] != null) {
      final exception = result['exceptionDetails'];
      throw PlaywrightException('JavaScript evaluation failed: $exception');
    }

    return result['result']['value'];
  }
}

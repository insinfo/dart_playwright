import 'dart:async';
import 'package:playwright_protocol/playwright_protocol.dart';
import 'cr_connection.dart';
import 'cr_js_handle.dart';
import 'cr_element_handle.dart';

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

  /// Evaluate a JS expression and return the raw primitive value.
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

  /// Evaluate a JS expression and return a CrJSHandle (or CrElementHandle).
  Future<CrJSHandle> evaluateHandle(String expression) async {
    final params = <String, dynamic>{
      'expression': expression,
      'returnByValue': false,
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

    final objectId = result['result']['objectId'] as String;
    final subtype = result['result']['subtype'] as String?;

    if (subtype == 'node') {
      return CrElementHandle(this, objectId);
    }
    return CrJSHandle(this, objectId);
  }

  /// Evaluate a function by passing arguments to it via Runtime.callFunctionOn
  Future<dynamic> evaluateWithArguments(String functionDeclaration, List<Map<String, dynamic>> arguments) async {
    final params = <String, dynamic>{
      'functionDeclaration': functionDeclaration,
      'arguments': arguments,
      'returnByValue': true,
      'awaitPromise': true,
    };

    // Use the objectId of the first argument as the target, or the execution context.
    if (arguments.isNotEmpty && arguments.first.containsKey('objectId')) {
      params['objectId'] = arguments.first['objectId'];
    } else if (_executionContextId != null) {
      params['executionContextId'] = _executionContextId;
    }

    final result = await session.send('Runtime.callFunctionOn', params);

    if (result['exceptionDetails'] != null) {
      final exception = result['exceptionDetails'];
      throw PlaywrightException('JavaScript evaluation failed: $exception');
    }

    return result['result']['value'];
  }
}

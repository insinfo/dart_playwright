import 'dart:async';
import 'package:playwright_protocol/playwright_protocol.dart';
import '../core_js_handle.dart';
import '../core_page.dart';
import 'cr_js_handle.dart';
import 'cr_element_handle.dart';

/// A Chromium execution context, i.e. one frame's main world.
///
/// [contextId] is null only for the fallback context used before
/// `Runtime.executionContextCreated` has been seen, where CDP resolves the
/// evaluation against the page's default context.
class CrExecutionContext implements CoreExecutionContext {
  final dynamic session;
  final int? executionContextId;

  CrExecutionContext(this.session, this.executionContextId);

  @override
  Object get contextId => executionContextId ?? 'default';

  /// Evaluate a JS expression and return the raw primitive value.
  @override
  Future<dynamic> rawEvaluate(String expression) async {
    final params = <String, dynamic>{
      'expression': expression,
      'returnByValue': true,
      'awaitPromise': true,
    };
    if (executionContextId != null) params['contextId'] = executionContextId;

    final result = await session.send('Runtime.evaluate', params);

    if (result['exceptionDetails'] != null) {
      throw PlaywrightException(
          'JavaScript evaluation failed: ${result['exceptionDetails']}');
    }

    return result['result']['value'];
  }

  /// Evaluate a JS expression and return a CrJSHandle (or CrElementHandle).
  @override
  Future<CoreJSHandle> rawEvaluateHandle(String expression) async {
    final params = <String, dynamic>{
      'expression': expression,
      'returnByValue': false,
      'awaitPromise': true,
    };
    if (executionContextId != null) params['contextId'] = executionContextId;

    final result = await session.send('Runtime.evaluate', params);

    if (result['exceptionDetails'] != null) {
      throw PlaywrightException(
          'JavaScript evaluation failed: ${result['exceptionDetails']}');
    }

    final objectId = result['result']['objectId'] as String?;
    if (objectId == null) {
      throw PlaywrightException(
          'Expected a handle, got ${result['result']['type']}');
    }
    final subtype = result['result']['subtype'] as String?;

    if (subtype == 'node') {
      return CrElementHandle(this, objectId);
    }
    return CrJSHandle(this, objectId);
  }

  /// Legacy alias kept for the engine-level `evaluate` entry points.
  Future<dynamic> evaluate(String expression) =>
      rawEvaluate(wrapEvaluationExpression(expression));

  Future<CoreJSHandle> evaluateHandle(String expression) =>
      rawEvaluateHandle(wrapEvaluationExpression(expression));

  /// Evaluate a function by passing arguments to it via Runtime.callFunctionOn
  Future<dynamic> evaluateWithArguments(
      String functionDeclaration, List<Map<String, dynamic>> arguments) async {
    final params = <String, dynamic>{
      'functionDeclaration': functionDeclaration,
      'arguments': arguments,
      'returnByValue': true,
      'awaitPromise': true,
    };

    // Use the objectId of the first argument as the target, or the execution context.
    if (arguments.isNotEmpty && arguments.first.containsKey('objectId')) {
      params['objectId'] = arguments.first['objectId'];
    } else if (executionContextId != null) {
      params['executionContextId'] = executionContextId;
    }

    final result = await session.send('Runtime.callFunctionOn', params);

    if (result['exceptionDetails'] != null) {
      final exception = result['exceptionDetails'];
      throw PlaywrightException('JavaScript evaluation failed: $exception');
    }

    return result['result']['value'];
  }
}

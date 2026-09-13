import 'dart:async';
import 'package:playwright_protocol/playwright_protocol.dart';
import '../core_element_handle.dart';
import '../core_js_handle.dart';
import '../core_page.dart';
import 'ff_connection.dart';

/// A Firefox (Juggler) execution context, i.e. one frame's main world.
///
/// Mirrors upstream's `ffExecutionContext.ts`: Juggler addresses contexts by
/// the string `executionContextId` and has `Runtime.callFunction` /
/// `Runtime.getObjectProperties` / `Runtime.disposeObject` where CDP has the
/// `Runtime.callFunctionOn` family.
class FfExecutionContext implements CoreExecutionContext {
  final FfSession session;
  final String? executionContextId;

  FfExecutionContext(this.session, this.executionContextId);

  @override
  Object get contextId => executionContextId ?? 'default';

  @override
  Future<dynamic> rawEvaluate(String expression) async {
    final result = await session.send('Runtime.evaluate', {
      'expression': expression,
      'returnByValue': true,
      if (executionContextId != null) 'executionContextId': executionContextId,
    });
    _checkException(result);
    return result['result']?['value'];
  }

  @override
  Future<CoreJSHandle> rawEvaluateHandle(String expression) async {
    final result = await session.send('Runtime.evaluate', {
      'expression': expression,
      'returnByValue': false,
      if (executionContextId != null) 'executionContextId': executionContextId,
    });
    _checkException(result);
    return createHandle(result['result'] as Map<String, dynamic>);
  }

  /// Builds the right handle flavour for a Juggler remote object.
  CoreJSHandle createHandle(Map<String, dynamic> remoteObject) {
    final objectId = remoteObject['objectId'] as String?;
    if (objectId == null) {
      throw PlaywrightException(
          'Expected a handle, got ${remoteObject['type']}');
    }
    if (remoteObject['subtype'] == 'node') {
      return FfElementHandle(this, objectId);
    }
    return FfJSHandle(this, objectId);
  }

  Future<dynamic> callFunction(
      String functionDeclaration, List<Map<String, dynamic>> args,
      {bool returnByValue = true}) async {
    final result = await session.send('Runtime.callFunction', {
      'functionDeclaration': functionDeclaration,
      'args': args,
      'returnByValue': returnByValue,
      if (executionContextId != null) 'executionContextId': executionContextId,
    });
    _checkException(result);
    return result['result']?['value'];
  }

  void _checkException(Map<String, dynamic> result) {
    final details = result['exceptionDetails'];
    if (details == null) return;
    throw PlaywrightException('Evaluation failed: $details');
  }
}

/// A JavaScript object living in a Firefox execution context.
class FfJSHandle implements CoreJSHandle {
  final FfExecutionContext context;
  final String objectId;

  FfJSHandle(this.context, this.objectId);

  @override
  Future<dynamic> evaluate(String expression) {
    return context.callFunction(expression, [
      {'objectId': objectId}
    ]);
  }

  @override
  Future<Map<String, dynamic>> getProperties() async {
    final result = await context.session.send('Runtime.getObjectProperties', {
      'executionContextId': context.executionContextId,
      'objectId': objectId,
    });
    final props = <String, dynamic>{};
    for (final property in result['properties'] as List? ?? const []) {
      final map = property as Map<String, dynamic>;
      props[map['name'] as String] = map['value']?['value'];
    }
    return props;
  }

  @override
  Future<void> dispose() async {
    await context.session.send('Runtime.disposeObject', {
      'executionContextId': context.executionContextId,
      'objectId': objectId,
    });
  }
}

/// A DOM element living in a Firefox execution context.
class FfElementHandle extends FfJSHandle implements CoreElementHandle {
  FfElementHandle(super.context, super.objectId);

  @override
  Future<String> textContent() async {
    final result = await evaluate('(el) => el.textContent');
    return result?.toString() ?? '';
  }

  @override
  Future<void> click() async {
    await evaluate('(el) => el.click()');
  }

  @override
  Future<void> focus() async {
    await evaluate('(el) => el.focus()');
  }

  @override
  Future<void> fill(String value) async {
    await context.callFunction('''
      (el, value) => {
        el.value = value;
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      }
    ''', [
      {'objectId': objectId},
      {'value': value},
    ]);
  }
}

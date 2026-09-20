import 'dart:async';
import 'package:playwright_protocol/playwright_protocol.dart';
import '../core_element_handle.dart';
import '../core_js_handle.dart';
import '../core_page.dart';
import 'wk_connection.dart';

/// A WebKit execution context, i.e. one frame's main world.
///
/// Mirrors upstream's `wkExecutionContext.ts`. Page-domain commands travel
/// through `Target.sendMessageToTarget`, so everything here goes through
/// [WkPageProxySession.sendToTarget].
class WkExecutionContext implements CoreExecutionContext {
  /// Either the page proxy session or a worker tunnel; both answer
  /// `Runtime.*` through [WkTargetSession.sendToTarget].
  final WkTargetSession session;
  final int? executionContextId;

  WkExecutionContext(this.session, this.executionContextId);

  @override
  Object get contextId => executionContextId ?? 'default';

  @override
  Future<dynamic> rawEvaluate(String expression) async {
    // WebKit's `Runtime.evaluate` has no awaitPromise flag, and it does not
    // tag a promise with `subtype: 'promise'` either, so asking for the value
    // straight away hands back `{}` for anything asynchronous. The way out is
    // the one upstream takes (wkExecutionContext.ts): get a handle, then ask
    // for it by value through `Runtime.callFunctionOn`, which *does* have
    // awaitPromise — `this` is the promise, and the flag settles it. A
    // rejected promise comes back as `wasThrown`, which is how an async
    // function that throws surfaces as an error here instead of as a value.
    final result = await session.sendToTarget('Runtime.evaluate', {
      'expression': expression,
      'returnByValue': false,
      if (executionContextId != null) 'contextId': executionContextId,
    });
    _checkThrown(result);
    final remote = result['result'] as Map<String, dynamic>?;
    final objectId = remote?['objectId'] as String?;
    if (objectId == null) return remote?['value'];
    final byValue = await session.sendToTarget('Runtime.callFunctionOn', {
      'functionDeclaration': '(function() { return this; })',
      'objectId': objectId,
      'returnByValue': true,
      'awaitPromise': true,
    });
    _checkThrown(byValue);
    return (byValue['result'] as Map<String, dynamic>?)?['value'];
  }

  @override
  Future<CoreJSHandle> rawEvaluateHandle(String expression) async {
    final result = await session.sendToTarget('Runtime.evaluate', {
      'expression': expression,
      'returnByValue': false,
      if (executionContextId != null) 'contextId': executionContextId,
    });
    _checkThrown(result);
    return createHandle(result['result'] as Map<String, dynamic>);
  }

  CoreJSHandle createHandle(Map<String, dynamic> remoteObject) {
    final objectId = remoteObject['objectId'] as String?;
    if (objectId == null) {
      throw PlaywrightException(
          'Expected a handle, got ${remoteObject['type']}');
    }
    if (remoteObject['subtype'] == 'node') {
      return WkElementHandle(this, objectId);
    }
    return WkJSHandle(this, objectId);
  }

  Future<dynamic> callFunctionOn(
      String functionDeclaration, List<Map<String, dynamic>> arguments,
      {required String objectId}) async {
    final result = await session.sendToTarget('Runtime.callFunctionOn', {
      'functionDeclaration': functionDeclaration,
      'objectId': objectId,
      'arguments': arguments,
      'returnByValue': true,
      'awaitPromise': true,
      'emulateUserGesture': true,
    });
    _checkThrown(result);
    return result['result']?['value'];
  }

  void _checkThrown(Map<String, dynamic> result) {
    if (result['wasThrown'] == true || result['exceptionDetails'] != null) {
      throw PlaywrightException('Evaluation failed: ${result['result']}');
    }
  }
}

/// A JavaScript object living in a WebKit execution context.
class WkJSHandle implements CoreJSHandle {
  final WkExecutionContext context;
  final String objectId;

  WkJSHandle(this.context, this.objectId);

  @override
  Future<dynamic> evaluate(String expression) {
    return context.callFunctionOn(
        expression,
        [
          {'objectId': objectId}
        ],
        objectId: objectId);
  }

  @override
  Future<Map<String, dynamic>> getProperties() async {
    final result = await context.session.sendToTarget('Runtime.getProperties', {
      'objectId': objectId,
      'ownProperties': true,
    });
    final props = <String, dynamic>{};
    for (final property in result['properties'] as List? ?? const []) {
      final map = property as Map<String, dynamic>;
      if (map['enumerable'] == false) continue;
      props[map['name'] as String] = map['value']?['value'];
    }
    return props;
  }

  @override
  Future<void> dispose() async {
    await context.session
        .sendToTarget('Runtime.releaseObject', {'objectId': objectId});
  }
}

/// A DOM element living in a WebKit execution context.
class WkElementHandle extends WkJSHandle implements CoreElementHandle {
  WkElementHandle(super.context, super.objectId);

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
    await context.callFunctionOn('''
      (el, value) => {
        el.value = value;
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      }
    ''', [
      {'objectId': objectId},
      {'value': value},
    ], objectId: objectId);
  }
}

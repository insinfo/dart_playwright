/// Represents a JavaScript object in the page.
class CrJSHandle {
  final dynamic context;
  final String objectId;

  CrJSHandle(this.context, this.objectId);

  /// Evaluate a function with this handle as an argument.
  Future<dynamic> evaluate(String expression) async {
    return context.evaluateWithArguments(expression, [
      {'objectId': objectId}
    ]);
  }

  /// Get properties of the object.
  Future<Map<String, dynamic>> getProperties() async {
    final result = await context.session.send('Runtime.getProperties', {
      'objectId': objectId,
      'ownProperties': true,
    });
    
    final props = <String, dynamic>{};
    for (final prop in result['result'] as List) {
      if (prop['enumerable'] == true) {
        props[prop['name'] as String] = prop['value']?['value'];
      }
    }
    return props;
  }

  /// Dispose the handle to release memory in the browser.
  Future<void> dispose() async {
    await context.session.send('Runtime.releaseObject', {
      'objectId': objectId,
    });
  }
}

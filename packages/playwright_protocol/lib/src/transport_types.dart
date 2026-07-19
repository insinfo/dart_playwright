import 'dart:convert';

/// A protocol request sent to a browser process.
///
/// Corresponds to a JSON-RPC style message with an id, method, and params.
/// Used by all browser engines (CDP for Chromium, Juggler for Firefox,
/// WebKit Inspector for WebKit).
class ProtocolRequest {
  /// Unique ID for request/response correlation.
  final int id;

  /// The protocol method to invoke (e.g., 'Page.navigate', 'Runtime.evaluate').
  final String method;

  /// Optional parameters for the method.
  final Map<String, dynamic>? params;

  /// Optional session ID (CDP uses this for target-specific sessions).
  final String? sessionId;

  /// WebKit-specific: page proxy identifier for pageProxy-scoped messages.
  final String? pageProxyId;

  ProtocolRequest({
    required this.id,
    required this.method,
    this.params,
    this.sessionId,
    this.pageProxyId,
  });

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'id': id,
      'method': method,
    };
    if (params != null) json['params'] = params;
    if (sessionId != null) json['sessionId'] = sessionId;
    if (pageProxyId != null) json['pageProxyId'] = pageProxyId;
    return json;
  }

  String toJsonString() => jsonEncode(toJson());

  @override
  String toString() => 'ProtocolRequest(id: $id, method: $method)';
}

/// A protocol response received from a browser process.
///
/// Can be either:
/// - A response to a command (has [id] and [result] or [error])
/// - An event notification (has [method] and [params])
class ProtocolResponse {
  /// Response ID, matching the request ID. Null for events.
  final int? id;

  /// Event method name. Null for responses.
  final String? method;

  /// Session ID for target-scoped messages (CDP).
  final String? sessionId;

  /// Error information if the command failed.
  final ProtocolError? error;

  /// Event parameters or additional data.
  final Map<String, dynamic>? params;

  /// Command result data.
  final Map<String, dynamic>? result;

  /// WebKit-specific: page proxy identifier.
  final String? pageProxyId;

  /// WebKit-specific: browser context identifier.
  final String? browserContextId;

  ProtocolResponse({
    this.id,
    this.method,
    this.sessionId,
    this.error,
    this.params,
    this.result,
    this.pageProxyId,
    this.browserContextId,
  });

  /// Whether this is a response to a command (has an id).
  bool get isResponse => id != null;

  /// Whether this is an event notification (has a method but no id).
  bool get isEvent => id == null && method != null;

  factory ProtocolResponse.fromJson(Map<String, dynamic> json) {
    return ProtocolResponse(
      id: json['id'] as int?,
      method: json['method'] as String?,
      sessionId: json['sessionId'] as String?,
      error: json['error'] != null
          ? ProtocolError.fromJson(json['error'] as Map<String, dynamic>)
          : null,
      params: json['params'] as Map<String, dynamic>?,
      result: json['result'] as Map<String, dynamic>?,
      pageProxyId: json['pageProxyId'] as String?,
      browserContextId: json['browserContextId'] as String?,
    );
  }

  @override
  String toString() {
    if (isResponse) return 'ProtocolResponse(id: $id, hasError: ${error != null})';
    if (isEvent) return 'ProtocolEvent(method: $method)';
    return 'ProtocolResponse(unknown)';
  }
}

/// An error returned by the browser protocol.
class ProtocolError {
  final String message;
  final dynamic data;
  final int? code;

  ProtocolError({
    required this.message,
    this.data,
    this.code,
  });

  factory ProtocolError.fromJson(Map<String, dynamic> json) {
    return ProtocolError(
      message: json['message'] as String? ?? 'Unknown error',
      data: json['data'],
      code: json['code'] as int?,
    );
  }

  @override
  String toString() => 'ProtocolError($message, code: $code)';
}

/// Represents a network request in the core engine.
abstract class CoreRequest {
  String get url;
  String get method;
  Map<String, String> get headers;

  /// Request body for POST-like requests, when the protocol reports it.
  String? get postData;

  dynamic
      get frame; // Frame is not fully decoupled yet, so dynamic or CoreFrame later
}

class BasicCoreRequest implements CoreRequest {
  @override
  final String url;

  @override
  final String method;

  @override
  final Map<String, String> headers;

  @override
  final String? postData;

  @override
  final dynamic frame;

  BasicCoreRequest({
    required this.url,
    this.method = 'GET',
    Map<String, String>? headers,
    this.postData,
    this.frame,
  }) : headers = headers ?? const <String, String>{};
}

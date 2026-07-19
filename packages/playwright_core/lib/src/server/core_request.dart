/// Represents a network request in the core engine.
abstract class CoreRequest {
  String get url;
  String get method;
  Map<String, String> get headers;
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
  final dynamic frame;

  BasicCoreRequest({
    required this.url,
    this.method = 'GET',
    Map<String, String>? headers,
    this.frame,
  }) : headers = headers ?? const <String, String>{};
}

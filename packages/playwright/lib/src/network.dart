import 'package:playwright_core/playwright_core.dart';
import 'frame.dart';

/// Represents a network request made by a page.
abstract class Request {
  /// URL of the request.
  String url();

  /// HTTP method of the request (GET, POST, etc).
  String method();

  /// Headers of the request.
  Map<String, String> headers();

  /// The frame that initiated this request.
  Frame frame();
}

class RequestImpl implements Request {
  final CoreRequest _coreRequest;

  RequestImpl(this._coreRequest);

  @override
  String url() => _coreRequest.url;

  @override
  String method() => _coreRequest.method;

  @override
  Map<String, String> headers() => _coreRequest.headers;

  @override
  Frame frame() {
    // TODO: Implement properly when CoreFrame is decoupled
    throw UnimplementedError('Request.frame is not fully decoupled yet');
  }
}

/// Represents a network response received by a page.
abstract class Response {
  /// The corresponding request.
  Request request();

  /// URL of the response.
  String url();

  /// HTTP status code (e.g. 200).
  int status();

  /// Status text (e.g. "OK").
  String statusText();

  /// Whether the response was successful (status 200-299).
  bool ok();
}

class ResponseImpl implements Response {
  final CoreResponse _coreResponse;
  late final Request _request;

  ResponseImpl(this._coreResponse) {
    _request = RequestImpl(_coreResponse.request);
  }

  @override
  Request request() => _request;

  @override
  String url() => _coreResponse.url;

  @override
  int status() => _coreResponse.status;

  @override
  String statusText() => _coreResponse.statusText;

  @override
  bool ok() => _coreResponse.ok;
}

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

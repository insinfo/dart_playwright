import 'core_request.dart';

/// Represents a network response in the core engine.
abstract class CoreResponse {
  CoreRequest get request;
  String get url;
  int get status;
  String get statusText;
  bool get ok;

  /// Response headers as the engine first reported them.
  Map<String, String> get headers;

  /// The headers actually received, or null when the engine does not report
  /// them separately (neither Firefox nor WebKit does), in which case
  /// [headers] is the best answer available.
  Map<String, String>? get rawHeaders;

  /// The address the response came from, when the engine reports it.
  CoreRemoteAddr? get remoteAddr;

  /// The TLS details of a secure response, when the engine reports them.
  CoreSecurityDetails? get securityDetails;

  /// Whether a service worker produced this response.
  bool get fromServiceWorker;

  /// Completes when the request behind this response finished (successfully
  /// or not), yielding the failure text on failure and null on success.
  Future<String?> finished();

  /// The raw response body bytes, fetched from the browser cache.
  Future<List<int>> body();
}

/// The parts of a response filled in after the headers arrived.
mixin CoreResponseState {
  Map<String, String>? rawHeaders;
  CoreRemoteAddr? remoteAddr;
  CoreSecurityDetails? securityDetails;
  bool fromServiceWorker = false;
}

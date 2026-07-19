import 'core_request.dart';

/// Represents a network response in the core engine.
abstract class CoreResponse {
  CoreRequest get request;
  String get url;
  int get status;
  String get statusText;
  bool get ok;

  /// The raw response body bytes, fetched from the browser cache.
  Future<List<int>> body();
}

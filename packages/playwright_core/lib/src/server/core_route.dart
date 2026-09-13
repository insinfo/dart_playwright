import 'core_request.dart';

/// Represents a route interception in the core engine.
abstract class CoreRoute {
  CoreRequest get request;

  /// Continue the request, optionally rewriting it on the way out.
  ///
  /// Header names keep the casing given here; a name that collides with one
  /// the request already carries replaces it.
  Future<void> continue_({
    String? url,
    String? method,
    Map<String, String>? headers,
    List<int>? postData,
  });

  /// Fulfill the request with the given response.
  Future<void> fulfill({
    int status = 200,
    Map<String, String>? headers,
    List<int>? bodyBytes,
  });

  /// Decline this route so the next matching handler gets it.
  ///
  /// Handlers run newest first, the way upstream orders them; when the last
  /// one falls back, the request continues untouched. Unlike every other
  /// method here, this touches no protocol at all — it only moves the request
  /// along the chain the page built.
  Future<void> fallback();

  /// Set by the page to the continuation of the handler chain.
  set onFallback(void Function()? callback);

  /// Abort the request.
  ///
  /// [errorCode] is one of the codes upstream documents (`aborted`,
  /// `accessdenied`, `addressunreachable`, `blockedbyclient`,
  /// `blockedbyresponse`, `connectionaborted`, `connectionclosed`,
  /// `connectionfailed`, `connectionrefused`, `connectionreset`,
  /// `internetdisconnected`, `namenotresolved`, `timedout`, `failed`); each
  /// driver maps it onto whatever its engine understands.
  Future<void> abort([String errorCode = 'failed']);
}

/// Maps an upstream error code onto the engine-specific spelling.
///
/// Ports the three tables in `crNetworkManager.ts:745`,
/// `wkInterceptableRequest.ts:28` and `ffNetworkManager.ts:272`. Firefox has
/// no table at all upstream — Juggler takes the API string verbatim.
class RouteErrorCodes {
  /// Chromium `Fetch.failRequest { errorReason }`.
  static const chromium = <String, String>{
    'aborted': 'Aborted',
    'accessdenied': 'AccessDenied',
    'addressunreachable': 'AddressUnreachable',
    'blockedbyclient': 'BlockedByClient',
    'blockedbyresponse': 'BlockedByResponse',
    'connectionaborted': 'ConnectionAborted',
    'connectionclosed': 'ConnectionClosed',
    'connectionfailed': 'ConnectionFailed',
    'connectionrefused': 'ConnectionRefused',
    'connectionreset': 'ConnectionReset',
    'internetdisconnected': 'InternetDisconnected',
    'namenotresolved': 'NameNotResolved',
    'timedout': 'TimedOut',
    'failed': 'Failed',
  };

  /// WebKit `Network.interceptRequestWithError { errorType }`. WebKit only
  /// distinguishes four outcomes, so most codes collapse onto `General`.
  static const webkit = <String, String>{
    'aborted': 'Cancellation',
    'accessdenied': 'AccessControl',
    'addressunreachable': 'General',
    'blockedbyclient': 'Cancellation',
    'blockedbyresponse': 'General',
    'connectionaborted': 'General',
    'connectionclosed': 'General',
    'connectionfailed': 'General',
    'connectionrefused': 'General',
    'connectionreset': 'General',
    'internetdisconnected': 'General',
    'namenotresolved': 'General',
    'timedout': 'Timeout',
    'failed': 'General',
  };

  /// Looks [errorCode] up in [table], throwing the way upstream asserts.
  static String resolve(Map<String, String> table, String errorCode) {
    final mapped = table[errorCode.toLowerCase()];
    if (mapped == null) {
      throw ArgumentError.value(errorCode, 'errorCode',
          'Unknown error code. Expected one of: ${table.keys.join(', ')}');
    }
    return mapped;
  }
}

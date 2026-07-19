import 'dart:async';
import 'package:playwright_protocol/playwright_protocol.dart';

/// Base interface for internal browser implementations.
abstract class CoreBrowser extends EventEmitter {
  /// Exposes the underlying connection for CDP/Juggler operations.
  dynamic get connection;

  /// Returns the browser version.
  Future<String> version();

  /// Closes the browser.
  Future<void> close();
}

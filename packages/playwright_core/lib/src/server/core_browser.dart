import 'dart:async';
import 'package:playwright_protocol/playwright_protocol.dart';
import 'core_page.dart';

/// Base interface for internal browser implementations.
abstract class CoreBrowser extends EventEmitter {
  /// Exposes the underlying connection for CDP/Juggler operations.
  dynamic get connection;

  /// Returns the browser version.
  Future<String> version();

  /// Creates a new page and returns its CorePage instance.
  Future<CorePage> newPage();

  /// Closes the browser.
  Future<void> close();
}

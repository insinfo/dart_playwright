import 'dart:async';
import 'package:playwright_protocol/playwright_protocol.dart';
import 'core_page.dart';

/// Base interface for internal browser implementations.
abstract class CoreBrowser extends EventEmitter {
  /// Exposes the underlying connection for CDP/Juggler/WebKit operations.
  dynamic get connection;

  /// Returns the browser version.
  Future<String> version();

  /// Creates an isolated browser context (cookies/storage separated).
  Future<CoreBrowserContext> createBrowserContext();

  /// Closes the browser.
  Future<void> close();
}

/// An isolated browser context owned by a [CoreBrowser].
abstract class CoreBrowserContext {
  /// Creates a new page inside this context.
  Future<CorePage> newPage();

  /// Disposes this context and every page that belongs to it.
  Future<void> close();
}

/// Public API for Playwright Dart.
///
/// This package exposes the user-facing API for automating Chromium,
/// Firefox, and WebKit browsers.
library playwright;

export 'src/playwright.dart';
export 'src/browser_type.dart';
export 'src/browser.dart';
export 'src/browser_context.dart';
export 'src/page.dart';
export 'src/locator.dart';
export 'src/frame.dart';
export 'src/network.dart';
export 'src/js_handle.dart';
export 'src/element_handle.dart';
export 'src/console_message.dart';
export 'src/dialog.dart';
export 'package:playwright_core/src/accessibility.dart';
export 'src/route.dart';

// Re-export common types from protocol
export 'package:playwright_protocol/playwright_protocol.dart'
    show ViewportSize, LoadState, WaitUntil, PlaywrightException, TimeoutException;

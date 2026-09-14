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
export 'src/frame_locator.dart';
export 'src/network.dart';
export 'src/js_handle.dart';
export 'src/element_handle.dart';
export 'src/console_message.dart';
export 'src/dialog.dart';
export 'src/api_request.dart';
export 'src/devices.dart';
export 'src/test_id.dart';
export 'src/download.dart';
export 'src/file_chooser.dart';
export 'src/page_error.dart';
export 'package:playwright_core/src/accessibility.dart';
export 'package:playwright_core/src/aria_template.dart';
export 'src/route.dart';

// Re-export common types from protocol
export 'package:playwright_protocol/playwright_protocol.dart'
    show ViewportSize, LoadState, WaitUntil, PlaywrightException, TimeoutException;

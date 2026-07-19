import 'package:playwright_core/src/server/chromium/cr_connection.dart';
import 'package:playwright_core/src/server/chromium/cr_page.dart';
import 'page.dart';

/// An isolated browser context.
abstract class BrowserContext {
  /// Create a new page in this context.
  Future<Page> newPage();

  /// Close the context.
  Future<void> close();
}

class BrowserContextImpl implements BrowserContext {
  final CDPSession _session;
  
  BrowserContextImpl(this._session);

  @override
  Future<Page> newPage() async {
    final crPage = await CrPage.create(_session);
    return PageImpl(crPage);
  }

  @override
  Future<void> close() async {
    // Requires Target.closeTarget
  }
}

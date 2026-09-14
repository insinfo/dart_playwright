import 'dart:async';

import 'package:playwright_core/src/server/core_browser.dart';
import 'package:playwright_core/src/server/core_events.dart' as core_events;
import 'package:playwright_core/src/server/core_page.dart'
    show CoreDownload, CorePage, initScriptSource;
import 'package:playwright_core/src/server/dialog.dart' as core;
import 'package:playwright_protocol/playwright_protocol.dart';
import 'api_request.dart';
import 'binding_source.dart';
import 'clock.dart';
import 'console_message.dart';
import 'dialog.dart';
import 'download.dart';
import 'network.dart';
import 'instrumented.dart';
import 'page.dart';
import 'page_error.dart';
import 'tracing.dart';
import 'waiter.dart';

/// An isolated browser context.
///
/// A context has its own cookie jar and storage, and its pages report their
/// events here as well as on themselves — so a listener on the context sees
/// what happens in every page it owns, including pages the pages themselves
/// opened.
abstract class BrowserContext {
  /// Create a new page in this context.
  Future<Page> newPage();

  /// Pages opened in this context.
  ///
  /// Includes pages opened by the pages themselves (`window.open`), not only
  /// the ones created through [newPage].
  List<Page> pages();

  /// Whether this context has been closed.
  bool isClosed();

  /// Return all cookies in this context (optionally filtered by [urls]).
  Future<List<Map<String, dynamic>>> cookies([List<String>? urls]);

  /// Add the given cookies to this context.
  Future<void> addCookies(List<Map<String, dynamic>> cookies);

  /// Remove all cookies from this context.
  Future<void> clearCookies();

  /// Capture cookies and per-origin localStorage as a portable snapshot.
  Future<Map<String, dynamic>> storageState();

  /// Run [script] at the start of every document of every page of this
  /// context, before any of the page's own scripts.
  ///
  /// Applies to the pages that already exist and to the ones created later,
  /// popups included. See [Page.addInitScript] for what [arg] carries and for
  /// why the document that is already open is left alone.
  Future<void> addInitScript(String script, {Object? arg});

  /// Expose [callback] as `window.<name>` on every page of this context,
  /// present and future.
  ///
  /// See [Page.exposeFunction]; the only difference is the reach.
  Future<void> exposeFunction(String name, ExposedFunction callback);

  /// Like [exposeFunction], but the callback is also told which page and
  /// frame called it. See [Page.exposeBinding].
  Future<void> exposeBinding(String name, BindingCallback callback);

  /// Deterministic time for every page of this context.
  ///
  /// See [Clock]: the same object is reachable as `page.clock`.
  Clock get clock;

  /// Close the context and every page that belongs to it.
  Future<void> close();

  /// An HTTP client that shares this context's cookie jar.
  ///
  /// Cookies stored in the context are sent with the request, and
  /// `Set-Cookie` on the response is written back, so a session established
  /// through the API is visible to the pages and the other way round.
  APIRequestContext get request;

  /// Records a trace of this context that `npx playwright show-trace` opens.
  Tracing get tracing;

  /// Event emitted when a page is opened in this context.
  Stream<Page> get onPage;

  /// Event emitted when the context closes.
  Stream<void> get onClose;

  /// Event emitted when any page in this context logs to the console.
  Stream<ConsoleMessage> get onConsole;

  /// Event emitted when any page in this context raises an uncaught error.
  Stream<PageError> get onPageError;

  /// Event emitted when any page in this context opens a JavaScript dialog.
  ///
  /// Subscribing here suppresses the automatic dismissal, exactly as
  /// subscribing on the page does; see [Page.onDialog].
  Stream<Dialog> get onDialog;

  /// Event emitted when any page in this context starts a download.
  Stream<Download> get onDownload;

  /// Event emitted when any page in this context issues a request.
  Stream<Request> get onRequest;

  /// Event emitted when any page in this context receives a response.
  Stream<Response> get onResponse;

  /// Event emitted when a request in this context finishes successfully.
  Stream<Request> get onRequestFinished;

  /// Event emitted when a request in this context fails.
  Stream<Request> get onRequestFailed;

  /// Wait for a page to be opened in this context.
  ///
  /// Start the wait before the action that opens the page, then await both.
  Future<Page> waitForPage({bool Function(Page)? predicate, Duration? timeout});

  /// Wait for a console message from any page in this context.
  Future<ConsoleMessage> waitForConsoleMessage(
      {bool Function(ConsoleMessage)? predicate, Duration? timeout});

  /// Wait for the next occurrence of a context event.
  Future<T> waitForEvent<T>(String event, {Duration? timeout});
}

/// Public wrappers keyed by the core context, so the same context always
/// yields the same [BrowserContext] object.
final Expando<BrowserContextImpl> _contextWrappers =
    Expando<BrowserContextImpl>('playwright.browserContext');

class BrowserContextImpl implements BrowserContext {
  final CoreBrowserContext _coreContext;

  BrowserContextImpl(this._coreContext);

  /// The single wrapper for [coreContext], created on first use.
  factory BrowserContextImpl.forCore(CoreBrowserContext coreContext) =>
      _contextWrappers[coreContext] ??= BrowserContextImpl(coreContext);

  @override
  Future<Page> newPage() => instrumentedOnContext(
        instrumentation: _coreContext.instrumentation,
        type: 'BrowserContext',
        method: 'newPage',
        body: () async {
          final corePage = await _coreContext.newPage();
          return PageImpl.forCore(corePage);
        },
      );

  @override
  List<Page> pages() => _coreContext.pages.map(PageImpl.forCore).toList();

  @override
  bool isClosed() => _coreContext.isClosed;

  @override
  Future<List<Map<String, dynamic>>> cookies([List<String>? urls]) =>
      instrumentedOnContext(
        instrumentation: _coreContext.instrumentation,
        type: 'BrowserContext',
        method: 'cookies',
        body: () => _coreContext.cookies(urls),
      );

  @override
  Future<void> addCookies(List<Map<String, dynamic>> cookies) =>
      instrumentedOnContext(
        instrumentation: _coreContext.instrumentation,
        type: 'BrowserContext',
        method: 'addCookies',
        body: () => _coreContext.addCookies(cookies),
      );

  @override
  Future<void> clearCookies() => instrumentedOnContext(
        instrumentation: _coreContext.instrumentation,
        type: 'BrowserContext',
        method: 'clearCookies',
        body: () => _coreContext.clearCookies(),
      );

  @override
  Future<Map<String, dynamic>> storageState() => instrumentedOnContext(
        instrumentation: _coreContext.instrumentation,
        type: 'BrowserContext',
        method: 'storageState',
        body: () => _coreContext.storageState(),
      );

  @override
  Future<void> addInitScript(String script, {Object? arg}) async {
    await _coreContext.addInitScript(initScriptSource(script, arg: arg));
  }

  @override
  Future<void> exposeFunction(String name, ExposedFunction callback) =>
      _coreContext.exposeBinding(name, (source, args) => callback(args),
          noGlobal: false);

  @override
  Future<void> exposeBinding(String name, BindingCallback callback) =>
      _coreContext.exposeBinding(name, adaptBindingCallback(callback),
          noGlobal: false);

  late final Clock _clock = ClockImpl(_coreContext.clock);

  @override
  Clock get clock => _clock;

  @override
  Future<void> close() => instrumentedOnContext(
        instrumentation: _coreContext.instrumentation,
        type: 'BrowserContext',
        method: 'close',
        body: () => _coreContext.close(),
      );

  @override
  late final Tracing tracing = TracingImpl(_coreContext);

  late final APIRequestContext _request =
      APIRequestContextImpl(cookieOwner: this);

  @override
  APIRequestContext get request => _request;

  @override
  Stream<Page> get onPage =>
      _coreContext.stream<CorePage>('page').map(PageImpl.forCore);

  @override
  Stream<void> get onClose => _coreContext.stream<void>('close');

  @override
  Stream<ConsoleMessage> get onConsole => _coreContext
      .stream<core_events.CoreConsoleMessage>('console')
      .map((message) => ConsoleMessageImpl(message));

  @override
  Stream<PageError> get onPageError => _coreContext
      .stream<core_events.CorePageError>('pageerror')
      .map((error) => PageErrorImpl(error));

  @override
  Stream<Dialog> get onDialog => _coreContext
      .stream<core.Dialog>('dialog')
      .map((coreDialog) => DialogImpl(coreDialog));

  @override
  Stream<Download> get onDownload =>
      _coreContext.stream<CoreDownload>('download').map(DownloadImpl.new);

  @override
  Stream<Request> get onRequest =>
      _coreContext.stream('request').map((r) => RequestImpl(r));

  @override
  Stream<Response> get onResponse =>
      _coreContext.stream('response').map((r) => ResponseImpl(r));

  @override
  Stream<Request> get onRequestFinished =>
      _coreContext.stream('requestFinished').map((r) => RequestImpl(r));

  @override
  Stream<Request> get onRequestFailed =>
      _coreContext.stream('requestFailed').map((r) => RequestImpl(r));

  /// A context-scoped wait gives up when the context closes; unlike a page,
  /// a context has no crash of its own.
  List<WaitAbort> get _contextAborts => [
        (
          stream: onClose,
          error: () => TargetClosedException('Browser context closed'),
        ),
      ];

  @override
  Future<Page> waitForPage(
          {bool Function(Page)? predicate, Duration? timeout}) =>
      waitForStreamEvent(
        'page',
        onPage,
        predicate: predicate,
        timeout: timeout,
        abortOn: _contextAborts,
      );

  @override
  Future<ConsoleMessage> waitForConsoleMessage(
          {bool Function(ConsoleMessage)? predicate, Duration? timeout}) =>
      waitForStreamEvent(
        'console',
        onConsole,
        predicate: predicate,
        timeout: timeout,
        abortOn: _contextAborts,
      );

  @override
  Future<T> waitForEvent<T>(String event, {Duration? timeout}) =>
      _coreContext.waitForEvent<T>(event, timeout: timeout);
}

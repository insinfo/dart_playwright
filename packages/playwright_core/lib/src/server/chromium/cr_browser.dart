import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:playwright_protocol/playwright_protocol.dart';
import '../core_browser.dart';
import '../core_page.dart';
import 'cr_connection.dart';
import 'cr_page.dart';

/// Represents a Chromium browser instance.
class CrBrowser extends EventEmitter implements CoreBrowser {
  @override
  final CRConnection connection;
  final Process? process;
  final String? _tempUserDataDir;
  final _contexts = <CrBrowserContext>[];

  bool _isClosed = false;

  /// Pages by CDP target id, so a popup can find the page that opened it.
  final _pagesByTarget = <String, CrPage>{};

  /// One completer per target id, completed once the page is fully adopted
  /// (attached, initialized, emulation applied and registered on a context).
  final _pageCompleters = <String, Completer<CrPage>>{};

  CrBrowser._(this.connection, this.process, this._tempUserDataDir) {
    connection.on('closed', () => _onClosed());
    connection.on('Target.targetCreated', _onTargetCreated);
    connection.on('Target.targetDestroyed', _onTargetDestroyed);
    connection.on('Target.attachedToTarget', _onAttachedToTarget);
    connection.on('Browser.downloadWillBegin', _onDownloadWillBegin);
    connection.on('Browser.downloadProgress', _onDownloadProgress);
    connection.on('Target.detachedFromTarget', _onDetachedFromTarget);
  }

  /// Connect to a Chromium instance.
  static Future<CrBrowser> connect(
      CRConnection connection, Process? process, String? tempUserDataDir,
      {bool persistentContext = false}) async {
    final browser = CrBrowser._(connection, process, tempUserDataDir);
    await browser._initialize();
    if (persistentContext) {
      browser._contexts.add(
        CrBrowserContext(browser, null, const CoreContextOptions()),
      );
    }
    return browser;
  }

  Future<void> _initialize() async {
    // Enable target discovery
    await connection.send('Target.setDiscoverTargets', {'discover': true});
    // Auto-attach is what makes popups observable: a page opened by
    // `window.open` is never handed to us by a command response, so the only
    // way to get a session for it is to be attached as it appears. Flattened
    // sessions ride the same websocket with a `sessionId` field.
    //
    // waitForDebuggerOnStart is left off on purpose: pausing every new target
    // means we would also have to resume the ones we do not model (OOPIFs,
    // workers), and a target we forget to resume hangs the page.
    await connection.send('Target.setAutoAttach', {
      'autoAttach': true,
      'waitForDebuggerOnStart': false,
      'flatten': true,
    });
  }

  void _onAttachedToTarget(Map<String, dynamic> params) {
    final targetInfo = params['targetInfo'] as Map<String, dynamic>?;
    if (targetInfo == null || targetInfo['type'] != 'page') return;
    final targetId = targetInfo['targetId'] as String;
    if (_pagesByTarget.containsKey(targetId)) return;
    // Fire-and-forget: adopting is async, and a target that goes away
    // mid-adoption must not surface as an unhandled error.
    _adoptTarget(params['sessionId'] as String, targetId, targetInfo)
        .catchError((Object _) {});
  }

  Future<void> _adoptTarget(String sessionId, String targetId,
      Map<String, dynamic> targetInfo) async {
    final context = _contextFor(targetInfo['browserContextId'] as String?);
    // A target from a context we do not own (the launch-time about:blank of a
    // non-persistent browser, for instance) is left alone.
    if (context == null) return;

    final session = connection.createSession(sessionId, 'page');
    final page = await CrPage.create(session, targetId: targetId);
    await context.applyContextOptions(session);

    final openerId = targetInfo['openerId'] as String?;
    _pagesByTarget[targetId] = page;
    context.registerPage(page,
        opener: openerId == null ? null : _pagesByTarget[openerId]);

    final completer = _pageCompleters.remove(targetId);
    if (completer != null && !completer.isCompleted) completer.complete(page);
  }

  void _onDetachedFromTarget(Map<String, dynamic> params) {
    final sessionId = params['sessionId'] as String?;
    if (sessionId != null) connection.closeSession(sessionId);
    final targetId = params['targetId'] as String?;
    if (targetId != null) _pagesByTarget.remove(targetId);
  }

  void _onDownloadWillBegin(Map<String, dynamic> params) {
    final guid = params['guid'] as String?;
    final frameId = params['frameId'] as String?;
    if (guid == null) return;
    // The frame id is also the target id of the page that owns it, which is
    // how the download finds its page and therefore its context.
    final page = frameId == null ? null : _pagesByTarget[frameId];
    final context = page?.browserContext as CrBrowserContext? ??
        (_contexts.length == 1 ? _contexts.first : null);
    if (context == null) return;
    context.registerDownload(
      CoreDownload(
        uuid: guid,
        url: params['url'] as String? ?? '',
        // `allowAndName` makes Chromium write the file under the download
        // directory named by the guid.
        downloadPath: p.join(context.downloadsDirectory, guid),
        suggestedFilename: params['suggestedFilename'] as String?,
        cancel: () async {
          await connection.send('Browser.cancelDownload', {
            'guid': guid,
            if (context.browserContextId != null)
              'browserContextId': context.browserContextId,
          });
        },
      ),
      page: page,
    );
  }

  void _onDownloadProgress(Map<String, dynamic> params) {
    final guid = params['guid'] as String?;
    final state = params['state'] as String?;
    if (guid == null || state == 'inProgress') return;
    for (final context in _contexts) {
      final download = context.downloads[guid];
      if (download == null) continue;
      download.markFinished(state == 'canceled' ? 'canceled' : null);
      return;
    }
  }

  CrBrowserContext? _contextFor(String? browserContextId) {
    for (final context in _contexts) {
      if (context.browserContextId == browserContextId) return context;
    }
    return null;
  }

  /// The page for [targetId], waiting for the auto-attach to land.
  ///
  /// `Target.createTarget` answers with a target id before the session for it
  /// exists, so page creation funnels through the same adoption path as a
  /// popup and both end up on `context.pages`.
  Future<CrPage> pageForTarget(String targetId,
      {Duration timeout = const Duration(seconds: 30)}) {
    final existing = _pagesByTarget[targetId];
    if (existing != null) return Future.value(existing);
    final completer =
        _pageCompleters.putIfAbsent(targetId, () => Completer<CrPage>());
    return completer.future.timeout(timeout, onTimeout: () {
      _pageCompleters.remove(targetId);
      throw PlaywrightException(
          'Timeout waiting for the Chromium page session of target $targetId');
    });
  }

  void _onTargetCreated(Map<String, dynamic> params) {
    final targetInfo = params['targetInfo'] as Map<String, dynamic>;
    emit('targetcreated', targetInfo);
  }

  void _onTargetDestroyed(Map<String, dynamic> params) {
    final targetId = params['targetId'] as String;
    emit('targetdestroyed', targetId);
  }

  Future<String> version() async {
    final result = await connection.send('Browser.getVersion');
    return result['product'] as String;
  }

  @override
  List<CoreBrowserContext> get contexts => List.unmodifiable(_contexts);

  @override
  bool get isConnected => !_isClosed;

  @override
  Future<CoreBrowserContext> createBrowserContext(
      {CoreContextOptions options = const CoreContextOptions()}) async {
    final result = await connection.send('Target.createBrowserContext', {
      'disposeOnDetach': true,
    });
    final context =
        CrBrowserContext(this, result['browserContextId'] as String, options);
    _contexts.add(context);
    await context.applyDownloadBehavior();
    return context;
  }

  /// Close the browser.
  Future<void> close() async {
    if (_isClosed) return;

    try {
      await connection.send('Browser.close');
    } catch (e) {
      // Process might already be dead
    }

    if (process != null) {
      process!.kill();
    }
    await connection.close();
  }

  String? _downloadsDirectory;

  /// A temporary directory for this browser's downloads, created on demand
  /// and removed when the browser closes.
  String _defaultDownloadsDirectory() {
    return _downloadsDirectory ??= Directory.systemTemp
        .createTempSync('playwright-dart-downloads')
        .path;
  }

  void _onClosed() {
    if (_isClosed) return;
    _isClosed = true;
    final downloads = _downloadsDirectory;
    if (downloads != null) {
      try {
        Directory(downloads).deleteSync(recursive: true);
      } catch (_) {}
    }
    for (final context in _contexts.toList()) {
      context.notifyClosed();
    }
    _contexts.clear();
    emit('disconnected', true);
    disposeStreams();

    // Cleanup temp profile if needed
    if (_tempUserDataDir != null) {
      try {
        Directory(_tempUserDataDir).deleteSync(recursive: true);
      } catch (_) {}
    }
  }
}

/// An isolated Chromium browser context (incognito-like partition).
class CrBrowserContext extends EventEmitter
    with BrowserContextStorage
    implements CoreBrowserContext {
  final CrBrowser browser;
  final String? browserContextId;
  final CoreContextOptions options;
  bool _closed = false;

  CrBrowserContext(this.browser, this.browserContextId, this.options);

  @override
  bool get isClosed => _closed;

  @override
  Future<CorePage> newPage() async {
    if (_closed) throw PlaywrightException('Context closed');
    final targetId = (await browser.connection.send('Target.createTarget', {
      'url': 'about:blank',
      if (browserContextId != null) 'browserContextId': browserContextId,
    }))['targetId'] as String;
    // The page itself is built by the auto-attach handler; see
    // CrBrowser.pageForTarget.
    return browser.pageForTarget(targetId);
  }

  /// Where this context's downloads land.
  late final String downloadsDirectory =
      options.downloadsPath ?? browser._defaultDownloadsDirectory();

  /// Tells Chromium what to do with downloads, and where to put them.
  ///
  /// `allowAndName` is what upstream uses: the file is stored under the
  /// download directory named by its guid, so two downloads called
  /// `report.pdf` cannot collide.
  Future<void> applyDownloadBehavior() async {
    await browser.connection.send('Browser.setDownloadBehavior', {
      'behavior': options.acceptDownloads ? 'allowAndName' : 'deny',
      if (browserContextId != null) 'browserContextId': browserContextId,
      if (options.acceptDownloads) 'downloadPath': downloadsDirectory,
      'eventsEnabled': true,
    });
  }

  /// Applies the context's emulation to a freshly attached page session.
  ///
  /// Chromium has no context-wide viewport or user agent, so both are set per
  /// page - including pages the context did not create, such as popups.
  Future<void> applyContextOptions(CDPSession session) async {
    final viewport = options.viewport;
    if (viewport != null) {
      await session.send('Emulation.setDeviceMetricsOverride', {
        'width': viewport.width,
        'height': viewport.height,
        'deviceScaleFactor': 1,
        'mobile': false,
      });
    }
    if (options.userAgent != null) {
      await session.send('Emulation.setUserAgentOverride', {
        'userAgent': options.userAgent,
      });
    }
  }

  @override
  Future<List<Map<String, dynamic>>> cookies([List<String>? urls]) async {
    final result = await browser.connection.send('Storage.getCookies', {
      if (browserContextId != null) 'browserContextId': browserContextId,
    });
    return (result['cookies'] as List).cast<Map<String, dynamic>>();
  }

  @override
  Future<void> addCookies(List<Map<String, dynamic>> cookies) async {
    await browser.connection.send('Storage.setCookies', {
      if (browserContextId != null) 'browserContextId': browserContextId,
      'cookies': rewriteCookies(cookies),
    });
  }

  @override
  Future<void> clearCookies() async {
    await browser.connection.send('Storage.clearCookies', {
      if (browserContextId != null) 'browserContextId': browserContextId,
    });
  }

  @override
  Future<Map<String, dynamic>> storageState() => collectStorageState();

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (browserContextId != null) {
      // Disposing the context closes every target that belongs to it.
      await browser.connection.send('Target.disposeBrowserContext', {
        'browserContextId': browserContextId,
      });
    } else {
      for (final page in trackedPages.toList()) {
        await page.close();
      }
    }
    trackedPages.clear();
    browser._contexts.remove(this);
    notifyClosed();
  }
}

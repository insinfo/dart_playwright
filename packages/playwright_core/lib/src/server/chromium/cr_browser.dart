import 'dart:async';
import 'dart:io';
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

  CrBrowser._(this.connection, this.process, this._tempUserDataDir) {
    connection.on('closed', () => _onClosed());
    connection.on('Target.targetCreated', _onTargetCreated);
    connection.on('Target.targetDestroyed', _onTargetDestroyed);
  }

  /// Connect to a Chromium instance.
  static Future<CrBrowser> connect(CRConnection connection, Process? process,
      String? tempUserDataDir) async {
    final browser = CrBrowser._(connection, process, tempUserDataDir);
    await browser._initialize();
    return browser;
  }

  Future<void> _initialize() async {
    // Enable target discovery
    await connection.send('Target.setDiscoverTargets', {'discover': true});
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
  Future<CoreBrowserContext> createBrowserContext() async {
    final result = await connection.send('Target.createBrowserContext', {
      'disposeOnDetach': true,
    });
    final context =
        CrBrowserContext(this, result['browserContextId'] as String);
    _contexts.add(context);
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

  void _onClosed() {
    if (_isClosed) return;
    _isClosed = true;
    _contexts.clear();
    emit('disconnected');

    // Cleanup temp profile if needed
    if (_tempUserDataDir != null) {
      try {
        Directory(_tempUserDataDir).deleteSync(recursive: true);
      } catch (_) {}
    }
  }
}

/// An isolated Chromium browser context (incognito-like partition).
class CrBrowserContext
    with BrowserContextStorage
    implements CoreBrowserContext {
  final CrBrowser browser;
  final String browserContextId;
  bool _closed = false;

  CrBrowserContext(this.browser, this.browserContextId);

  @override
  bool get isClosed => _closed;

  @override
  Future<CorePage> newPage() async {
    if (_closed) throw PlaywrightException('Context closed');
    final connection = browser.connection;

    final targetId = (await connection.send('Target.createTarget', {
      'url': 'about:blank',
      'browserContextId': browserContextId,
    }))['targetId'];

    final sessionId = (await connection.send('Target.attachToTarget', {
      'targetId': targetId,
      'flatten': true,
    }))['sessionId'];

    final page =
        await CrPage.create(connection.createSession(sessionId, 'page'));
    trackedPages.add(page);
    return page;
  }

  @override
  Future<List<Map<String, dynamic>>> cookies([List<String>? urls]) async {
    final result = await browser.connection.send('Storage.getCookies', {
      'browserContextId': browserContextId,
    });
    return (result['cookies'] as List).cast<Map<String, dynamic>>();
  }

  @override
  Future<void> addCookies(List<Map<String, dynamic>> cookies) async {
    await browser.connection.send('Storage.setCookies', {
      'browserContextId': browserContextId,
      'cookies': rewriteCookies(cookies),
    });
  }

  @override
  Future<void> clearCookies() async {
    await browser.connection.send('Storage.clearCookies', {
      'browserContextId': browserContextId,
    });
  }

  @override
  Future<Map<String, dynamic>> storageState() => collectStorageState();

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // Disposing the context closes every target that belongs to it.
    await browser.connection.send('Target.disposeBrowserContext', {
      'browserContextId': browserContextId,
    });
    trackedPages.clear();
    browser._contexts.remove(this);
  }
}

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
  
  bool _isClosed = false;

  CrBrowser._(this.connection, this.process, this._tempUserDataDir) {
    connection.on('closed', () => _onClosed());
    connection.on('Target.targetCreated', _onTargetCreated);
    connection.on('Target.targetDestroyed', _onTargetDestroyed);
  }

  /// Connect to a Chromium instance.
  static Future<CrBrowser> connect(CRConnection connection, Process? process, String? tempUserDataDir) async {
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
  Future<CoreBrowserContext> createBrowserContext() async {
    final result = await connection.send('Target.createBrowserContext', {
      'disposeOnDetach': true,
    });
    return CrBrowserContext(this, result['browserContextId'] as String);
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
class CrBrowserContext implements CoreBrowserContext {
  final CrBrowser browser;
  final String browserContextId;
  final _pages = <CrPage>[];
  bool _closed = false;

  CrBrowserContext(this.browser, this.browserContextId);

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
    _pages.add(page);
    return page;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // Disposing the context closes every target that belongs to it.
    await browser.connection.send('Target.disposeBrowserContext', {
      'browserContextId': browserContextId,
    });
    _pages.clear();
  }
}

import 'dart:async';
import 'dart:io';
import 'package:playwright_protocol/playwright_protocol.dart';
import 'cr_connection.dart';

/// Represents a Chromium browser instance.
class CrBrowser extends EventEmitter {
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

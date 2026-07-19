import 'dart:async';
import 'package:playwright_protocol/playwright_protocol.dart';
import '../core_browser.dart';
import 'wk_connection.dart';

class WkBrowser extends EventEmitter implements CoreBrowser {
  @override
  final WkConnection connection;
  late final WkSession session;
  
  WkBrowser(this.connection) {
    session = connection.rootSession;
  }
  
  Future<void> init() async {
    session.on('Target.targetCreated', (_) {
      // Handle target created
    });
  }

  @override
  Future<void> close() async {
    connection.transport.close();
  }

  @override
  Future<String> version() async {
    // WebKit specific get version or userAgent
    return 'WebKit RemoteDebugging';
  }
}

import 'dart:async';

import 'package:playwright_core/playwright_core.dart';
import 'package:playwright_core/src/server/chromium/cr_browser.dart';
import 'package:playwright_core/src/server/chromium/cr_connection.dart';
import 'package:playwright_core/src/server/firefox/ff_browser.dart';
import 'package:playwright_core/src/server/firefox/ff_connection.dart';
import 'package:playwright_core/src/server/webkit/wk_browser.dart';
import 'package:playwright_core/src/server/webkit/wk_connection.dart';
import 'package:playwright_protocol/playwright_protocol.dart';
import 'package:test/test.dart';

/// A transport whose browser answers every command except the one that asks
/// it to shut down — the shape of a browser wedged on a `beforeunload`
/// dialog, on a hung renderer, or simply mid-crash.
///
/// [killed] is what the real transports do to the OS process in [close]:
/// if `browser.close()` never reaches here, the process outlives us.
class _DeafOnClose implements ConnectionTransport {
  _DeafOnClose(this.deafTo);

  /// The graceful-shutdown command this engine's browser will not answer.
  final String deafTo;

  final _messages = StreamController<ProtocolResponse>.broadcast();
  final _close = StreamController<String?>.broadcast();

  bool killed = false;
  final sent = <String>[];

  @override
  Stream<ProtocolResponse> get onMessage => _messages.stream;

  @override
  Stream<String?> get onClose => _close.stream;

  @override
  void send(ProtocolRequest message) {
    sent.add(message.method);
    if (message.method == deafTo) return;
    // Everything else gets an empty success, asynchronously, like the wire.
    scheduleMicrotask(() {
      if (_messages.isClosed) return;
      _messages.add(ProtocolResponse(
        id: message.id,
        sessionId: message.sessionId,
        result: const {},
      ));
    });
  }

  @override
  Future<void> close() async {
    if (killed) return;
    killed = true;
    await _messages.close();
    _close.add('killed');
    await _close.close();
  }
}

void main() {
  // A browser that will not shut down on request must still be killed, and
  // `close()` must return so the caller's `tearDown` can move on. Otherwise
  // the await never finishes, the test run is interrupted, and the browser
  // process — with its renderer children — survives the Dart process.
  //
  // Firefox and WebKit already bounded the wait; Chromium did not, which is
  // what this group exists to keep true for all three.
  group('close() does not hang on a browser that ignores the shutdown command',
      () {
    test('[chromium]', () async {
      final transport = _DeafOnClose('Browser.close');
      final browser =
          await CrBrowser.connect(CRConnection(transport), null, null);

      await browser.close().timeout(
            const Duration(seconds: 20),
            onTimeout: () => fail('CrBrowser.close() never returned'),
          );

      expect(transport.sent, contains('Browser.close'),
          reason: 'the graceful shutdown must be attempted first');
      expect(transport.killed, isTrue,
          reason: 'the process must be killed when the engine does not comply');
    });

    test('[firefox]', () async {
      final transport = _DeafOnClose('Browser.close');
      final browser = FfBrowser(FfConnection(transport));

      await browser.close().timeout(
            const Duration(seconds: 20),
            onTimeout: () => fail('FfBrowser.close() never returned'),
          );

      expect(transport.sent, contains('Browser.close'));
      expect(transport.killed, isTrue);
    });

    test('[webkit]', () async {
      final transport = _DeafOnClose('Playwright.close');
      final browser = WkBrowser(WkConnection(transport));

      await browser.close().timeout(
            const Duration(seconds: 20),
            onTimeout: () => fail('WkBrowser.close() never returned'),
          );

      expect(transport.sent, contains('Playwright.close'));
      expect(transport.killed, isTrue);
    });
  });

  // Closing twice is what a `tearDown` plus an explicit `close()` in the test
  // body amount to, and it must not blow up or re-kill.
  group('close() is idempotent', () {
    test('[chromium]', () async {
      final transport = _DeafOnClose('never-deaf');
      final browser =
          await CrBrowser.connect(CRConnection(transport), null, null);
      await browser.close();
      await browser.close();
      expect(transport.killed, isTrue);
    });

    test('[firefox]', () async {
      final transport = _DeafOnClose('never-deaf');
      final browser = FfBrowser(FfConnection(transport));
      await browser.close();
      await browser.close();
      expect(transport.killed, isTrue);
    });

    test('[webkit]', () async {
      final transport = _DeafOnClose('never-deaf');
      final browser = WkBrowser(WkConnection(transport));
      await browser.close();
      await browser.close();
      expect(transport.killed, isTrue);
    });
  });
}

import 'package:playwright_core/src/server/core_page.dart';
import 'package:test/test.dart';

class FakeCorePage extends CorePage {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('waitForNavigation ignores lifecycle events from the current loader',
      () async {
    final manager = CoreFrameManager(FakeCorePage());
    manager.frameAttached('main', null);
    manager.frameNavigated('main', 'about:blank', '', 'loader-1');

    final frame = manager.mainFrame!;
    var completed = false;
    final navigation = frame
        .waitForNavigation(timeout: const Duration(seconds: 1))
        .then((_) => completed = true);

    manager.frameLifecycleEvent('main', 'load');
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);

    manager.frameNavigated('main', 'https://example.com', '', 'loader-2');
    manager.frameLifecycleEvent('main', 'load');

    await navigation;
    expect(completed, isTrue);
  });

  test('waitForNavigation waits for a new navigation when loader is missing',
      () async {
    final manager = CoreFrameManager(FakeCorePage());
    manager.frameAttached('main', null);

    final frame = manager.mainFrame!;
    var completed = false;
    final navigation = frame
        .waitForNavigation(timeout: const Duration(seconds: 1))
        .then((_) => completed = true);

    manager.frameLifecycleEvent('main', 'load');
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);

    manager.frameNavigated('main', 'https://example.com', '', '');
    manager.frameLifecycleEvent('main', 'load');

    await navigation;
    expect(completed, isTrue);
  });

  test('waitForLoadState resolves immediately for existing lifecycle state',
      () async {
    final manager = CoreFrameManager(FakeCorePage());
    manager.frameAttached('main', null);
    manager.frameNavigated('main', 'https://example.com', '', 'loader-1');
    manager.frameLifecycleEvent('main', 'DOMContentLoaded');

    await manager.mainFrame!.waitForLoadState(WaitUntilState.domcontentloaded,
        timeout: const Duration(milliseconds: 10));
  });

  test('manager emits frame and main-frame lifecycle events', () async {
    final page = FakeCorePage();
    final manager = CoreFrameManager(page);
    final events = <String>[];

    page.on('frameAttached', (_) => events.add('attached'));
    page.on('frameNavigated', (_) => events.add('navigated'));
    page.on('load', () => events.add('load'));
    page.on('frameDetached', (_) => events.add('detached'));

    manager.frameAttached('main', null);
    manager.frameNavigated('main', 'https://example.com', '', 'loader-1');
    manager.frameLifecycleEvent('main', 'load');
    manager.frameDetached('main');

    expect(events, ['attached', 'navigated', 'load', 'detached']);
  });
}

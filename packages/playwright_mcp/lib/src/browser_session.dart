import 'dart:async';

import 'package:playwright/playwright.dart';

/// One console line, kept so `browser_console_messages` can report it later.
typedef ConsoleEntry = ({String type, String text});

/// One network exchange, kept so `browser_network_requests` can report it.
typedef NetworkEntry = ({String method, String url, int? status});

/// The browser state the tools share: the browser, its context, the open
/// tabs, and the console, network and dialog bookkeeping.
///
/// The browser is launched lazily, on the first tool that needs a page, so
/// starting the server costs nothing and a client that only lists tools never
/// pays for a browser.
class BrowserSession {
  final String browserName;
  final bool headless;

  /// How many console lines and network entries to keep per session.
  static const historyLimit = 200;

  Playwright? _playwright;
  Browser? _browser;
  BrowserContext? _context;

  final List<Page> _tabs = [];
  int _currentTab = 0;

  final List<ConsoleEntry> consoleMessages = [];
  final List<NetworkEntry> networkRequests = [];
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  /// A dialog the page opened and nobody has answered yet.
  ///
  /// The dialog is deliberately left open: a modal blocks the page, and the
  /// agent has to be told about it and decide. `browser_handle_dialog`
  /// answers it.
  Dialog? pendingDialog;

  BrowserSession({this.browserName = 'chromium', this.headless = true});

  /// Whether a browser has been launched yet.
  bool get isStarted => _browser != null;

  /// Open tabs, in the order they were opened.
  List<Page> get tabs => List.unmodifiable(_tabs);

  /// The index of the tab tools act on.
  int get currentTabIndex => _currentTab;

  /// The browser context, launching the browser if needed.
  Future<BrowserContext> context() async {
    final existing = _context;
    if (existing != null) return existing;

    final playwright = _playwright ??= await Playwright.create();
    final type = switch (browserName.toLowerCase()) {
      'firefox' => playwright.firefox,
      'webkit' => playwright.webkit,
      _ => playwright.chromium,
    };
    final browser = _browser = await type.launch(headless: headless);
    final context = _context = await browser.newContext();

    // Pages the page itself opens (window.open, target=_blank) become tabs
    // too, or the agent would lose track of where it is.
    _subscriptions.add(context.onPage.listen((page) {
      if (!_tabs.contains(page)) {
        _tabs.add(page);
        _watch(page);
      }
    }));
    return context;
  }

  /// The tab tools act on, opening one if there is none.
  Future<Page> currentPage() async {
    if (_tabs.isEmpty) return newTab();
    if (_currentTab >= _tabs.length) _currentTab = _tabs.length - 1;
    return _tabs[_currentTab];
  }

  /// Opens a tab and makes it current.
  Future<Page> newTab() async {
    final page = await (await context()).newPage();
    if (!_tabs.contains(page)) {
      _tabs.add(page);
      _watch(page);
    }
    _currentTab = _tabs.indexOf(page);
    return page;
  }

  /// Makes the tab at [index] current.
  void selectTab(int index) {
    if (index < 0 || index >= _tabs.length) {
      throw ArgumentError.value(
          index, 'index', 'No such tab; open tabs: ${_tabs.length}');
    }
    _currentTab = index;
  }

  /// Closes the tab at [index].
  Future<void> closeTab(int index) async {
    if (index < 0 || index >= _tabs.length) {
      throw ArgumentError.value(
          index, 'index', 'No such tab; open tabs: ${_tabs.length}');
    }
    final page = _tabs.removeAt(index);
    await page.close();
    if (_currentTab >= _tabs.length) {
      _currentTab = _tabs.isEmpty ? 0 : _tabs.length - 1;
    }
  }

  void _watch(Page page) {
    _subscriptions.add(page.onConsole.listen((message) {
      _push(consoleMessages, (type: message.type(), text: message.text()));
    }));
    _subscriptions.add(page.onPageError.listen((error) {
      _push(consoleMessages,
          (type: 'pageerror', text: '${error.name}: ${error.message}'));
    }));
    _subscriptions.add(page.onResponse.listen((response) {
      _push(
          networkRequests,
          (
            method: response.request().method(),
            url: response.url(),
            status: response.status()
          ));
    }));
    _subscriptions.add(page.onRequestFailed.listen((request) {
      _push(networkRequests,
          (method: request.method(), url: request.url(), status: null));
    }));
    // Subscribing at all is what stops the dialog from being auto-dismissed,
    // which is the behaviour we want: the agent decides.
    _subscriptions.add(page.onDialog.listen((dialog) {
      pendingDialog = dialog;
    }));
  }

  static void _push<T>(List<T> target, T value) {
    target.add(value);
    if (target.length > historyLimit) target.removeAt(0);
  }

  /// Closes the browser and drops every listener.
  Future<void> close() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _tabs.clear();
    pendingDialog = null;
    consoleMessages.clear();
    networkRequests.clear();
    final browser = _browser;
    _browser = null;
    _context = null;
    if (browser != null) await browser.close();
  }
}

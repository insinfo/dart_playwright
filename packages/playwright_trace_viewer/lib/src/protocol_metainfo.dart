// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/protocolMetainfo.ts, which upstream
// generates from protocol.yml. This file was transcribed from it entry by
// entry, so it carries the same 327 rows; regenerate it when the upstream
// reference is rolled.

/// What the protocol says about each method: how to title it in the action
/// list, which of its params are worth showing, and whether it is internal.
library;

/// `MethodMetainfo`: one row of the table.
class MethodMetainfo {
  /// Internal calls are dropped by `_modernize_3_to_4`; they never reach the
  /// action list.
  final bool internal;

  /// The title template, e.g. `Fill "{value}"`. A `{name}` is filled from the
  /// call params, with `name` allowing `a|b` alternatives and `a.b` paths.
  final String? title;

  /// The subtitle template, shown after the title when every one of its
  /// placeholders resolves.
  final String? subtitle;

  /// Which params to report, as `[key=]path[:selector]` entries.
  final List<String>? renderParams;

  final bool slowMo;
  final bool snapshot;
  final bool pause;
  final bool isAutoWaiting;
  final bool input;

  /// `configuration`, `route` or `getter`: the group the action list filters
  /// by. An action with no group is always shown.
  final String? group;

  const MethodMetainfo({
    this.internal = false,
    this.title,
    this.subtitle,
    this.renderParams,
    this.slowMo = false,
    this.snapshot = false,
    this.pause = false,
    this.isAutoWaiting = false,
    this.input = false,
    this.group,
  });
}

/// The table, keyed by `<class>.<method>`.
const Map<String, MethodMetainfo> methodMetainfo = {
  'Android.devices': MethodMetainfo(internal: true),
  'AndroidSocket.write': MethodMetainfo(internal: true),
  'AndroidSocket.close': MethodMetainfo(internal: true),
  'AndroidDevice.wait': MethodMetainfo(title: 'Wait'),
  'AndroidDevice.fill': MethodMetainfo(title: 'Fill "{text}"'),
  'AndroidDevice.tap': MethodMetainfo(title: 'Tap'),
  'AndroidDevice.drag': MethodMetainfo(title: 'Drag'),
  'AndroidDevice.fling': MethodMetainfo(title: 'Fling'),
  'AndroidDevice.longTap': MethodMetainfo(title: 'Long tap'),
  'AndroidDevice.pinchClose': MethodMetainfo(title: 'Pinch close'),
  'AndroidDevice.pinchOpen': MethodMetainfo(title: 'Pinch open'),
  'AndroidDevice.scroll': MethodMetainfo(title: 'Scroll'),
  'AndroidDevice.swipe': MethodMetainfo(title: 'Swipe'),
  'AndroidDevice.info': MethodMetainfo(internal: true),
  'AndroidDevice.screenshot': MethodMetainfo(title: 'Screenshot'),
  'AndroidDevice.inputType': MethodMetainfo(title: 'Type'),
  'AndroidDevice.inputPress': MethodMetainfo(title: 'Press'),
  'AndroidDevice.inputTap': MethodMetainfo(title: 'Tap'),
  'AndroidDevice.inputSwipe': MethodMetainfo(title: 'Swipe'),
  'AndroidDevice.inputDrag': MethodMetainfo(title: 'Drag'),
  'AndroidDevice.launchBrowser': MethodMetainfo(title: 'Launch browser'),
  'AndroidDevice.open': MethodMetainfo(title: 'Open app'),
  'AndroidDevice.shell':
      MethodMetainfo(title: 'Execute shell command', group: 'configuration'),
  'AndroidDevice.installApk': MethodMetainfo(title: 'Install apk'),
  'AndroidDevice.push': MethodMetainfo(title: 'Push'),
  'AndroidDevice.connectToWebView':
      MethodMetainfo(title: 'Connect to Web View'),
  'AndroidDevice.close': MethodMetainfo(internal: true),
  'APIRequestContext.fetch': MethodMetainfo(
      title: '{method}', subtitle: '{url}', renderParams: ['url', 'method']),
  'APIRequestContext.fetchResponseBody':
      MethodMetainfo(title: 'Get response body', group: 'getter'),
  'APIRequestContext.fetchLog': MethodMetainfo(internal: true),
  'APIRequestContext.storageState':
      MethodMetainfo(title: 'Get storage state', group: 'configuration'),
  'APIRequestContext.disposeAPIResponse': MethodMetainfo(internal: true),
  'APIRequestContext.dispose': MethodMetainfo(internal: true),
  'Artifact.pathAfterFinished': MethodMetainfo(internal: true),
  'Artifact.saveAs': MethodMetainfo(internal: true),
  'Artifact.saveAsStream': MethodMetainfo(internal: true),
  'Artifact.failure': MethodMetainfo(internal: true),
  'Artifact.stream': MethodMetainfo(internal: true),
  'Artifact.cancel': MethodMetainfo(internal: true),
  'Artifact.delete': MethodMetainfo(internal: true),
  'Stream.read': MethodMetainfo(internal: true),
  'Stream.close': MethodMetainfo(internal: true),
  'WritableStream.write': MethodMetainfo(internal: true),
  'WritableStream.close': MethodMetainfo(internal: true),
  'Browser.startServer': MethodMetainfo(title: 'Start server'),
  'Browser.stopServer': MethodMetainfo(title: 'Stop server'),
  'Browser.close': MethodMetainfo(title: 'Close browser', pause: true),
  'Browser.killForTests': MethodMetainfo(internal: true),
  'Browser.defaultUserAgentForTest': MethodMetainfo(internal: true),
  'Browser.newContext': MethodMetainfo(title: 'Create context'),
  'Browser.newContextForReuse': MethodMetainfo(internal: true),
  'Browser.disconnectFromReusedContext': MethodMetainfo(internal: true),
  'Browser.newBrowserCDPSession':
      MethodMetainfo(title: 'Create CDP session', group: 'configuration'),
  'Browser.startTracing':
      MethodMetainfo(title: 'Start browser tracing', group: 'configuration'),
  'Browser.stopTracing':
      MethodMetainfo(title: 'Stop browser tracing', group: 'configuration'),
  'BrowserContext.addCookies':
      MethodMetainfo(title: 'Add cookies', group: 'configuration'),
  'BrowserContext.addInitScript':
      MethodMetainfo(title: 'Add init script', group: 'configuration'),
  'BrowserContext.clearCookies':
      MethodMetainfo(title: 'Clear cookies', group: 'configuration'),
  'BrowserContext.clearPermissions':
      MethodMetainfo(title: 'Clear permissions', group: 'configuration'),
  'BrowserContext.close': MethodMetainfo(title: 'Close context', pause: true),
  'BrowserContext.cookies':
      MethodMetainfo(title: 'Get cookies', group: 'getter'),
  'BrowserContext.exposeBinding':
      MethodMetainfo(title: 'Expose binding', group: 'configuration'),
  'BrowserContext.grantPermissions':
      MethodMetainfo(title: 'Grant permissions', group: 'configuration'),
  'BrowserContext.newPage': MethodMetainfo(title: 'Create page'),
  'BrowserContext.registerSelectorEngine': MethodMetainfo(internal: true),
  'BrowserContext.setTestIdAttributeName': MethodMetainfo(internal: true),
  'BrowserContext.setExtraHTTPHeaders':
      MethodMetainfo(title: 'Set extra HTTP headers', group: 'configuration'),
  'BrowserContext.setGeolocation':
      MethodMetainfo(title: 'Set geolocation', group: 'configuration'),
  'BrowserContext.setHTTPCredentials':
      MethodMetainfo(title: 'Set HTTP credentials', group: 'configuration'),
  'BrowserContext.setNetworkInterceptionPatterns':
      MethodMetainfo(title: 'Route requests', group: 'route'),
  'BrowserContext.setWebSocketInterceptionPatterns':
      MethodMetainfo(title: 'Route WebSockets', group: 'route'),
  'BrowserContext.setOffline':
      MethodMetainfo(title: 'Set offline mode', renderParams: ['offline']),
  'BrowserContext.storageState':
      MethodMetainfo(title: 'Get storage state', group: 'configuration'),
  'BrowserContext.setStorageState':
      MethodMetainfo(title: 'Set storage state', group: 'configuration'),
  'BrowserContext.pause': MethodMetainfo(title: 'Pause'),
  'BrowserContext.showRecorder': MethodMetainfo(internal: true),
  'BrowserContext.startRecording': MethodMetainfo(internal: true),
  'BrowserContext.stopRecording': MethodMetainfo(internal: true),
  'BrowserContext.exposeConsoleApi': MethodMetainfo(internal: true),
  'BrowserContext.newCDPSession':
      MethodMetainfo(title: 'Create CDP session', group: 'configuration'),
  'BrowserContext.createTempFiles': MethodMetainfo(internal: true),
  'BrowserContext.updateSubscription': MethodMetainfo(internal: true),
  'BrowserContext.clockFastForward':
      MethodMetainfo(title: 'Fast forward clock "{ticksNumber|ticksString}"'),
  'BrowserContext.clockInstall':
      MethodMetainfo(title: 'Install clock "{timeNumber|timeString}"'),
  'BrowserContext.clockPauseAt':
      MethodMetainfo(title: 'Pause clock "{timeNumber|timeString}"'),
  'BrowserContext.clockResume': MethodMetainfo(title: 'Resume clock'),
  'BrowserContext.clockRunFor':
      MethodMetainfo(title: 'Run clock "{ticksNumber|ticksString}"'),
  'BrowserContext.clockSetFixedTime':
      MethodMetainfo(title: 'Set fixed time "{timeNumber|timeString}"'),
  'BrowserContext.clockSetSystemTime':
      MethodMetainfo(title: 'Set system time "{timeNumber|timeString}"'),
  'BrowserContext.credentialsInstall': MethodMetainfo(
      title: 'Install virtual WebAuthn authenticator', group: 'configuration'),
  'BrowserContext.credentialsCreate': MethodMetainfo(
      title: 'Create virtual credential for "{rpId}"', group: 'configuration'),
  'BrowserContext.credentialsGet':
      MethodMetainfo(title: 'Get virtual credentials', group: 'configuration'),
  'BrowserContext.credentialsDelete': MethodMetainfo(
      title: 'Delete virtual credential', group: 'configuration'),
  'BrowserType.launch': MethodMetainfo(title: 'Launch browser'),
  'BrowserType.launchPersistentContext':
      MethodMetainfo(title: 'Launch persistent context'),
  'BrowserType.connectOverCDP': MethodMetainfo(title: 'Connect over CDP'),
  'BrowserType.connectToWorker': MethodMetainfo(title: 'Connect to worker'),
  'Disposable.dispose': MethodMetainfo(internal: true),
  'Electron.launch': MethodMetainfo(title: 'Launch electron'),
  'ElectronApplication.browserWindow': MethodMetainfo(internal: true),
  'ElectronApplication.evaluateExpression': MethodMetainfo(title: 'Evaluate'),
  'ElectronApplication.evaluateExpressionHandle':
      MethodMetainfo(title: 'Evaluate'),
  'ElectronApplication.updateSubscription': MethodMetainfo(internal: true),
  'Frame.evalOnSelector': MethodMetainfo(
      title: 'Evaluate', subtitle: '{selector}', snapshot: true, pause: true),
  'Frame.evalOnSelectorAll': MethodMetainfo(
      title: 'Evaluate', subtitle: '{selector}', snapshot: true, pause: true),
  'Frame.addScriptTag': MethodMetainfo(
      title: 'Add script tag',
      renderParams: ['url'],
      snapshot: true,
      pause: true),
  'Frame.addStyleTag': MethodMetainfo(
      title: 'Add style tag',
      renderParams: ['url'],
      snapshot: true,
      pause: true),
  'Frame.ariaSnapshot': MethodMetainfo(
      title: 'Aria snapshot', subtitle: '{selector}', group: 'getter'),
  'Frame.ariaSnapshotJSON': MethodMetainfo(
      title: 'Aria snapshot JSON', subtitle: '{selector}', group: 'getter'),
  'Frame.blur': MethodMetainfo(
      title: 'Blur',
      subtitle: '{selector}',
      slowMo: true,
      snapshot: true,
      pause: true),
  'Frame.check': MethodMetainfo(
      title: 'Check',
      subtitle: '{selector}',
      renderParams: ['position'],
      slowMo: true,
      snapshot: true,
      pause: true,
      isAutoWaiting: true,
      input: true),
  'Frame.click': MethodMetainfo(
      title: 'Click',
      subtitle: '{selector}',
      renderParams: ['button', 'clickCount', 'modifiers', 'position'],
      slowMo: true,
      snapshot: true,
      pause: true,
      isAutoWaiting: true,
      input: true),
  'Frame.content':
      MethodMetainfo(title: 'Get content', snapshot: true, pause: true),
  'Frame.dragAndDrop': MethodMetainfo(
      title: 'Drag and drop',
      renderParams: ['source:selector', 'target:selector'],
      slowMo: true,
      snapshot: true,
      pause: true,
      isAutoWaiting: true,
      input: true),
  'Frame.drop': MethodMetainfo(
      title: 'Drop files or data onto an element',
      subtitle: '{selector}',
      slowMo: true,
      snapshot: true,
      pause: true,
      isAutoWaiting: true,
      input: true),
  'Frame.dblclick': MethodMetainfo(
      title: 'Double click',
      subtitle: '{selector}',
      renderParams: ['button', 'modifiers', 'position'],
      slowMo: true,
      snapshot: true,
      pause: true,
      isAutoWaiting: true,
      input: true),
  'Frame.dispatchEvent': MethodMetainfo(
      title: 'Dispatch "{type}"',
      subtitle: '{selector}',
      renderParams: ['type'],
      slowMo: true,
      snapshot: true,
      pause: true),
  'Frame.evaluateExpression':
      MethodMetainfo(title: 'Evaluate', snapshot: true, pause: true),
  'Frame.evaluateExpressionHandle':
      MethodMetainfo(title: 'Evaluate', snapshot: true, pause: true),
  'Frame.fill': MethodMetainfo(
      title: 'Fill "{value}"',
      subtitle: '{selector}',
      renderParams: ['value'],
      slowMo: true,
      snapshot: true,
      pause: true,
      isAutoWaiting: true,
      input: true),
  'Frame.focus': MethodMetainfo(
      title: 'Focus',
      subtitle: '{selector}',
      slowMo: true,
      snapshot: true,
      pause: true),
  'Frame.frameElement':
      MethodMetainfo(title: 'Get frame element', group: 'getter'),
  'Frame.resolveSelector': MethodMetainfo(internal: true),
  'Frame.highlight': MethodMetainfo(internal: true),
  'Frame.hideHighlight': MethodMetainfo(internal: true),
  'Frame.getAttribute': MethodMetainfo(
      title: 'Get attribute "{name}"',
      subtitle: '{selector}',
      snapshot: true,
      pause: true,
      group: 'getter'),
  'Frame.goto': MethodMetainfo(
      title: 'Navigate',
      subtitle: '{url}',
      renderParams: ['url'],
      slowMo: true,
      snapshot: true,
      pause: true),
  'Frame.hover': MethodMetainfo(
      title: 'Hover',
      subtitle: '{selector}',
      renderParams: ['modifiers', 'position'],
      slowMo: true,
      snapshot: true,
      pause: true,
      isAutoWaiting: true,
      input: true),
  'Frame.innerHTML': MethodMetainfo(
      title: 'Get HTML',
      subtitle: '{selector}',
      snapshot: true,
      pause: true,
      group: 'getter'),
  'Frame.innerText': MethodMetainfo(
      title: 'Get inner text',
      subtitle: '{selector}',
      snapshot: true,
      pause: true,
      group: 'getter'),
  'Frame.inputValue': MethodMetainfo(
      title: 'Get input value',
      subtitle: '{selector}',
      snapshot: true,
      pause: true,
      group: 'getter'),
  'Frame.isChecked': MethodMetainfo(
      title: 'Is checked',
      subtitle: '{selector}',
      snapshot: true,
      pause: true,
      group: 'getter'),
  'Frame.isDisabled': MethodMetainfo(
      title: 'Is disabled',
      subtitle: '{selector}',
      snapshot: true,
      pause: true,
      group: 'getter'),
  'Frame.isEnabled': MethodMetainfo(
      title: 'Is enabled',
      subtitle: '{selector}',
      snapshot: true,
      pause: true,
      group: 'getter'),
  'Frame.isHidden': MethodMetainfo(
      title: 'Is hidden',
      subtitle: '{selector}',
      snapshot: true,
      pause: true,
      group: 'getter'),
  'Frame.isVisible': MethodMetainfo(
      title: 'Is visible',
      subtitle: '{selector}',
      snapshot: true,
      pause: true,
      group: 'getter'),
  'Frame.isEditable': MethodMetainfo(
      title: 'Is editable',
      subtitle: '{selector}',
      snapshot: true,
      pause: true,
      group: 'getter'),
  'Frame.press': MethodMetainfo(
      title: 'Press "{key}"',
      subtitle: '{selector}',
      renderParams: ['key'],
      slowMo: true,
      snapshot: true,
      pause: true,
      isAutoWaiting: true,
      input: true),
  'Frame.querySelector': MethodMetainfo(
      title: 'Query selector', subtitle: '{selector}', snapshot: true),
  'Frame.querySelectorAll': MethodMetainfo(
      title: 'Query selector all', subtitle: '{selector}', snapshot: true),
  'Frame.queryCount': MethodMetainfo(
      title: 'Query count',
      subtitle: '{selector}',
      snapshot: true,
      pause: true),
  'Frame.selectOption': MethodMetainfo(
      title: 'Select option',
      subtitle: '{selector}',
      renderParams: ['options'],
      slowMo: true,
      snapshot: true,
      pause: true,
      isAutoWaiting: true,
      input: true),
  'Frame.setContent':
      MethodMetainfo(title: 'Set content', snapshot: true, pause: true),
  'Frame.setInputFiles': MethodMetainfo(
      title: 'Set input files',
      subtitle: '{selector}',
      renderParams: ['files=localPaths'],
      slowMo: true,
      snapshot: true,
      pause: true,
      isAutoWaiting: true,
      input: true),
  'Frame.tap': MethodMetainfo(
      title: 'Tap',
      subtitle: '{selector}',
      renderParams: ['modifiers', 'position'],
      slowMo: true,
      snapshot: true,
      pause: true,
      isAutoWaiting: true,
      input: true),
  'Frame.textContent': MethodMetainfo(
      title: 'Get text content',
      subtitle: '{selector}',
      snapshot: true,
      pause: true,
      group: 'getter'),
  'Frame.title': MethodMetainfo(title: 'Get page title', group: 'getter'),
  'Frame.type': MethodMetainfo(
      title: 'Type "{text}"',
      subtitle: '{selector}',
      renderParams: ['text'],
      slowMo: true,
      snapshot: true,
      pause: true,
      isAutoWaiting: true,
      input: true),
  'Frame.uncheck': MethodMetainfo(
      title: 'Uncheck',
      subtitle: '{selector}',
      renderParams: ['position'],
      slowMo: true,
      snapshot: true,
      pause: true,
      isAutoWaiting: true,
      input: true),
  'Frame.waitForTimeout': MethodMetainfo(
      title: 'Wait for timeout',
      renderParams: ['timeout=waitTimeout'],
      snapshot: true),
  'Frame.waitForFunction': MethodMetainfo(
      title: 'Wait for function',
      subtitle: '{selector}',
      snapshot: true,
      pause: true),
  'Frame.waitForSelector': MethodMetainfo(
      title: 'Wait for selector',
      subtitle: '{selector}',
      renderParams: ['state'],
      snapshot: true),
  'Frame.expect': MethodMetainfo(
      title: 'Expect "{expression}"',
      subtitle: '{selector}',
      snapshot: true,
      pause: true),
  'JSHandle.dispose': MethodMetainfo(internal: true),
  'ElementHandle.dispose': MethodMetainfo(internal: true),
  'JSHandle.evaluateExpression':
      MethodMetainfo(title: 'Evaluate', snapshot: true, pause: true),
  'ElementHandle.evaluateExpression':
      MethodMetainfo(title: 'Evaluate', snapshot: true, pause: true),
  'JSHandle.evaluateExpressionHandle':
      MethodMetainfo(title: 'Evaluate', snapshot: true, pause: true),
  'ElementHandle.evaluateExpressionHandle':
      MethodMetainfo(title: 'Evaluate', snapshot: true, pause: true),
  'JSHandle.getPropertyList':
      MethodMetainfo(title: 'Get property list', group: 'getter'),
  'ElementHandle.getPropertyList':
      MethodMetainfo(title: 'Get property list', group: 'getter'),
  'JSHandle.getProperty':
      MethodMetainfo(title: 'Get JS property', group: 'getter'),
  'ElementHandle.getProperty':
      MethodMetainfo(title: 'Get JS property', group: 'getter'),
  'JSHandle.jsonValue':
      MethodMetainfo(title: 'Get JSON value', group: 'getter'),
  'ElementHandle.jsonValue':
      MethodMetainfo(title: 'Get JSON value', group: 'getter'),
  'ElementHandle.evalOnSelector': MethodMetainfo(
      title: 'Evaluate', subtitle: '{selector}', snapshot: true, pause: true),
  'ElementHandle.evalOnSelectorAll': MethodMetainfo(
      title: 'Evaluate', subtitle: '{selector}', snapshot: true, pause: true),
  'ElementHandle.boundingBox':
      MethodMetainfo(title: 'Get bounding box', snapshot: true, pause: true),
  'ElementHandle.check': MethodMetainfo(
      title: 'Check',
      renderParams: ['position'],
      slowMo: true,
      snapshot: true,
      pause: true,
      isAutoWaiting: true,
      input: true),
  'ElementHandle.click': MethodMetainfo(
      title: 'Click',
      renderParams: ['button', 'clickCount', 'modifiers', 'position'],
      slowMo: true,
      snapshot: true,
      pause: true,
      isAutoWaiting: true,
      input: true),
  'ElementHandle.contentFrame':
      MethodMetainfo(title: 'Get content frame', group: 'getter'),
  'ElementHandle.dblclick': MethodMetainfo(
      title: 'Double click',
      renderParams: ['button', 'modifiers', 'position'],
      slowMo: true,
      snapshot: true,
      pause: true,
      isAutoWaiting: true,
      input: true),
  'ElementHandle.dispatchEvent': MethodMetainfo(
      title: 'Dispatch event',
      renderParams: ['type'],
      slowMo: true,
      snapshot: true,
      pause: true),
  'ElementHandle.fill': MethodMetainfo(
      title: 'Fill "{value}"',
      renderParams: ['value'],
      slowMo: true,
      snapshot: true,
      pause: true,
      isAutoWaiting: true,
      input: true),
  'ElementHandle.focus':
      MethodMetainfo(title: 'Focus', slowMo: true, snapshot: true, pause: true),
  'ElementHandle.getAttribute': MethodMetainfo(
      title: 'Get attribute', snapshot: true, pause: true, group: 'getter'),
  'ElementHandle.hover': MethodMetainfo(
      title: 'Hover',
      renderParams: ['modifiers', 'position'],
      slowMo: true,
      snapshot: true,
      pause: true,
      isAutoWaiting: true,
      input: true),
  'ElementHandle.innerHTML': MethodMetainfo(
      title: 'Get HTML', snapshot: true, pause: true, group: 'getter'),
  'ElementHandle.innerText': MethodMetainfo(
      title: 'Get inner text', snapshot: true, pause: true, group: 'getter'),
  'ElementHandle.inputValue': MethodMetainfo(
      title: 'Get input value', snapshot: true, pause: true, group: 'getter'),
  'ElementHandle.isChecked': MethodMetainfo(
      title: 'Is checked', snapshot: true, pause: true, group: 'getter'),
  'ElementHandle.isDisabled': MethodMetainfo(
      title: 'Is disabled', snapshot: true, pause: true, group: 'getter'),
  'ElementHandle.isEditable': MethodMetainfo(
      title: 'Is editable', snapshot: true, pause: true, group: 'getter'),
  'ElementHandle.isEnabled': MethodMetainfo(
      title: 'Is enabled', snapshot: true, pause: true, group: 'getter'),
  'ElementHandle.isHidden': MethodMetainfo(
      title: 'Is hidden', snapshot: true, pause: true, group: 'getter'),
  'ElementHandle.isVisible': MethodMetainfo(
      title: 'Is visible', snapshot: true, pause: true, group: 'getter'),
  'ElementHandle.ownerFrame':
      MethodMetainfo(title: 'Get owner frame', group: 'getter'),
  'ElementHandle.press': MethodMetainfo(
      title: 'Press "{key}"',
      renderParams: ['key'],
      slowMo: true,
      snapshot: true,
      pause: true,
      isAutoWaiting: true,
      input: true),
  'ElementHandle.querySelector': MethodMetainfo(
      title: 'Query selector', subtitle: '{selector}', snapshot: true),
  'ElementHandle.querySelectorAll': MethodMetainfo(
      title: 'Query selector all', subtitle: '{selector}', snapshot: true),
  'ElementHandle.screenshot': MethodMetainfo(
      title: 'Screenshot', renderParams: ['type'], snapshot: true, pause: true),
  'ElementHandle.scrollIntoViewIfNeeded': MethodMetainfo(
      title: 'Scroll into view', slowMo: true, snapshot: true, pause: true),
  'ElementHandle.selectOption': MethodMetainfo(
      title: 'Select option',
      renderParams: ['options'],
      slowMo: true,
      snapshot: true,
      pause: true,
      isAutoWaiting: true,
      input: true),
  'ElementHandle.selectText': MethodMetainfo(
      title: 'Select text', slowMo: true, snapshot: true, pause: true),
  'ElementHandle.setInputFiles': MethodMetainfo(
      title: 'Set input files',
      renderParams: ['files=localPaths'],
      slowMo: true,
      snapshot: true,
      pause: true,
      isAutoWaiting: true,
      input: true),
  'ElementHandle.tap': MethodMetainfo(
      title: 'Tap',
      renderParams: ['modifiers', 'position'],
      slowMo: true,
      snapshot: true,
      pause: true,
      isAutoWaiting: true,
      input: true),
  'ElementHandle.textContent': MethodMetainfo(
      title: 'Get text content', snapshot: true, pause: true, group: 'getter'),
  'ElementHandle.type': MethodMetainfo(
      title: 'Type',
      renderParams: ['text'],
      slowMo: true,
      snapshot: true,
      pause: true,
      isAutoWaiting: true,
      input: true),
  'ElementHandle.uncheck': MethodMetainfo(
      title: 'Uncheck',
      renderParams: ['position'],
      slowMo: true,
      snapshot: true,
      pause: true,
      isAutoWaiting: true,
      input: true),
  'ElementHandle.waitForElementState': MethodMetainfo(
      title: 'Wait for state',
      renderParams: ['state'],
      snapshot: true,
      pause: true),
  'ElementHandle.waitForSelector': MethodMetainfo(
      title: 'Wait for selector',
      subtitle: '{selector}',
      renderParams: ['state'],
      snapshot: true),
  'LocalUtils.zip': MethodMetainfo(internal: true),
  'LocalUtils.harOpen': MethodMetainfo(internal: true),
  'LocalUtils.harLookup': MethodMetainfo(internal: true),
  'LocalUtils.harClose': MethodMetainfo(internal: true),
  'LocalUtils.harUnzip': MethodMetainfo(internal: true),
  'LocalUtils.connect': MethodMetainfo(internal: true),
  'LocalUtils.tracingStarted': MethodMetainfo(internal: true),
  'LocalUtils.addStackToTracingNoReply': MethodMetainfo(internal: true),
  'LocalUtils.traceDiscarded': MethodMetainfo(internal: true),
  'LocalUtils.globToRegex': MethodMetainfo(internal: true),
  'Request.response': MethodMetainfo(internal: true),
  'Request.rawRequestHeaders': MethodMetainfo(internal: true),
  'Route.redirectNavigationRequest': MethodMetainfo(internal: true),
  'Route.abort': MethodMetainfo(title: 'Abort request', group: 'route'),
  'Route.continue': MethodMetainfo(title: 'Continue request', group: 'route'),
  'Route.fulfill': MethodMetainfo(title: 'Fulfill request', group: 'route'),
  'WebSocketRoute.connect':
      MethodMetainfo(title: 'Connect WebSocket to server', group: 'route'),
  'WebSocketRoute.ensureOpened': MethodMetainfo(internal: true),
  'WebSocketRoute.sendToPage':
      MethodMetainfo(title: 'Send WebSocket message', group: 'route'),
  'WebSocketRoute.sendToServer':
      MethodMetainfo(title: 'Send WebSocket message', group: 'route'),
  'WebSocketRoute.closePage': MethodMetainfo(internal: true),
  'WebSocketRoute.closeServer': MethodMetainfo(internal: true),
  'Response.body': MethodMetainfo(title: 'Get response body', group: 'getter'),
  'Response.securityDetails': MethodMetainfo(internal: true),
  'Response.serverAddr': MethodMetainfo(internal: true),
  'Response.rawResponseHeaders': MethodMetainfo(internal: true),
  'Response.httpVersion': MethodMetainfo(internal: true),
  'Response.sizes': MethodMetainfo(internal: true),
  'Page.addInitScript':
      MethodMetainfo(title: 'Add init script', group: 'configuration'),
  'Page.close': MethodMetainfo(title: 'Close page', pause: true),
  'Page.runBeforeUnload':
      MethodMetainfo(title: 'Run beforeunload', pause: true),
  'Page.clearConsoleMessages': MethodMetainfo(title: 'Clear console messages'),
  'Page.consoleMessages':
      MethodMetainfo(title: 'Get console messages', group: 'getter'),
  'Page.emulateMedia': MethodMetainfo(
      title: 'Emulate media',
      renderParams: [
        'media',
        'colorScheme',
        'reducedMotion',
        'forcedColors',
        'contrast'
      ],
      snapshot: true,
      pause: true),
  'Page.exposeBinding':
      MethodMetainfo(title: 'Expose binding', group: 'configuration'),
  'Page.goBack': MethodMetainfo(
      title: 'Go back', slowMo: true, snapshot: true, pause: true),
  'Page.goForward': MethodMetainfo(
      title: 'Go forward', slowMo: true, snapshot: true, pause: true),
  'Page.requestGC': MethodMetainfo(
      title: 'Request garbage collection', group: 'configuration'),
  'Page.registerLocatorHandler':
      MethodMetainfo(title: 'Register locator handler', subtitle: '{selector}'),
  'Page.resolveLocatorHandlerNoReply': MethodMetainfo(internal: true),
  'Page.unregisterLocatorHandler':
      MethodMetainfo(title: 'Unregister locator handler'),
  'Page.reload': MethodMetainfo(
      title: 'Reload', slowMo: true, snapshot: true, pause: true),
  'Page.expectScreenshot': MethodMetainfo(
      title: 'Expect screenshot',
      subtitle: '{locator.selector}',
      snapshot: true,
      pause: true),
  'Page.screenshot': MethodMetainfo(
      title: 'Screenshot',
      renderParams: ['type', 'fullPage'],
      snapshot: true,
      pause: true),
  'Page.setExtraHTTPHeaders':
      MethodMetainfo(title: 'Set extra HTTP headers', group: 'configuration'),
  'Page.setNetworkInterceptionPatterns':
      MethodMetainfo(title: 'Route requests', group: 'route'),
  'Page.setWebSocketInterceptionPatterns':
      MethodMetainfo(title: 'Route WebSockets', group: 'route'),
  'Page.setViewportSize': MethodMetainfo(
      title: 'Set viewport size',
      renderParams: ['viewportSize.width', 'viewportSize.height'],
      snapshot: true,
      pause: true),
  'Page.keyboardDown': MethodMetainfo(
      title: 'Key down "{key}"',
      renderParams: ['key'],
      slowMo: true,
      snapshot: true,
      pause: true,
      input: true),
  'Page.keyboardUp': MethodMetainfo(
      title: 'Key up "{key}"',
      renderParams: ['key'],
      slowMo: true,
      snapshot: true,
      pause: true,
      input: true),
  'Page.keyboardInsertText': MethodMetainfo(
      title: 'Insert "{text}"',
      renderParams: ['text'],
      slowMo: true,
      snapshot: true,
      pause: true,
      input: true),
  'Page.keyboardType': MethodMetainfo(
      title: 'Type "{text}"',
      renderParams: ['text'],
      slowMo: true,
      snapshot: true,
      pause: true,
      input: true),
  'Page.keyboardPress': MethodMetainfo(
      title: 'Press "{key}"',
      renderParams: ['key'],
      slowMo: true,
      snapshot: true,
      pause: true,
      input: true),
  'Page.mouseMove': MethodMetainfo(
      title: 'Mouse move',
      renderParams: ['x', 'y'],
      slowMo: true,
      snapshot: true,
      pause: true,
      input: true),
  'Page.mouseDown': MethodMetainfo(
      title: 'Mouse down',
      renderParams: ['button', 'clickCount'],
      slowMo: true,
      snapshot: true,
      pause: true,
      input: true),
  'Page.mouseUp': MethodMetainfo(
      title: 'Mouse up',
      renderParams: ['button', 'clickCount'],
      slowMo: true,
      snapshot: true,
      pause: true,
      input: true),
  'Page.mouseClick': MethodMetainfo(
      title: 'Click',
      renderParams: ['x', 'y', 'button', 'clickCount'],
      slowMo: true,
      snapshot: true,
      pause: true,
      input: true),
  'Page.mouseWheel': MethodMetainfo(
      title: 'Mouse wheel',
      renderParams: ['deltaX', 'deltaY'],
      slowMo: true,
      snapshot: true,
      pause: true,
      input: true),
  'Page.touchscreenTap': MethodMetainfo(
      title: 'Tap',
      renderParams: ['x', 'y'],
      slowMo: true,
      snapshot: true,
      pause: true,
      input: true),
  'Page.clearPageErrors': MethodMetainfo(title: 'Clear page errors'),
  'Page.pageErrors': MethodMetainfo(title: 'Get page errors', group: 'getter'),
  'Page.pdf': MethodMetainfo(title: 'PDF'),
  'Page.requests':
      MethodMetainfo(title: 'Get network requests', group: 'getter'),
  'Page.startJSCoverage':
      MethodMetainfo(title: 'Start JS coverage', group: 'configuration'),
  'Page.stopJSCoverage':
      MethodMetainfo(title: 'Stop JS coverage', group: 'configuration'),
  'Page.startCSSCoverage':
      MethodMetainfo(title: 'Start CSS coverage', group: 'configuration'),
  'Page.stopCSSCoverage':
      MethodMetainfo(title: 'Stop CSS coverage', group: 'configuration'),
  'Page.bringToFront': MethodMetainfo(title: 'Bring to front'),
  'Page.pickLocator':
      MethodMetainfo(title: 'Pick locator', group: 'configuration'),
  'Page.cancelPickLocator':
      MethodMetainfo(title: 'Cancel pick locator', group: 'configuration'),
  'Page.hideHighlight': MethodMetainfo(
      title: 'Hide all element highlights', group: 'configuration'),
  'Page.screencastShowOverlay':
      MethodMetainfo(title: 'Show overlay', group: 'configuration'),
  'Page.screencastRemoveOverlay':
      MethodMetainfo(title: 'Remove overlay', group: 'configuration'),
  'Page.screencastChapter':
      MethodMetainfo(title: 'Show chapter overlay', group: 'configuration'),
  'Page.screencastSetOverlayVisible':
      MethodMetainfo(title: 'Set overlay visibility', group: 'configuration'),
  'Page.screencastShowActions':
      MethodMetainfo(title: 'Show actions', group: 'configuration'),
  'Page.screencastHideActions':
      MethodMetainfo(title: 'Remove actions', group: 'configuration'),
  'Page.screencastStart':
      MethodMetainfo(title: 'Start screencast', group: 'configuration'),
  'Page.screencastFrameAck': MethodMetainfo(internal: true),
  'Page.screencastStop':
      MethodMetainfo(title: 'Stop screencast', group: 'configuration'),
  'Page.updateSubscription': MethodMetainfo(internal: true),
  'Page.setDockTile': MethodMetainfo(internal: true),
  'Page.webStorageItems':
      MethodMetainfo(title: 'Get WebStorage items', group: 'getter'),
  'Page.webStorageGetItem':
      MethodMetainfo(title: 'Get WebStorage item', group: 'getter'),
  'Page.webStorageSetItem':
      MethodMetainfo(title: 'Set WebStorage item', group: 'configuration'),
  'Page.webStorageRemoveItem':
      MethodMetainfo(title: 'Remove WebStorage item', group: 'configuration'),
  'Page.webStorageClear':
      MethodMetainfo(title: 'Clear WebStorage', group: 'configuration'),
  'Root.initialize': MethodMetainfo(internal: true),
  'Playwright.newRequest': MethodMetainfo(title: 'Create request context'),
  'DebugController.initialize': MethodMetainfo(internal: true),
  'DebugController.setReportStateChanged': MethodMetainfo(internal: true),
  'DebugController.setRecorderMode': MethodMetainfo(internal: true),
  'DebugController.highlight': MethodMetainfo(internal: true),
  'DebugController.hideHighlight': MethodMetainfo(internal: true),
  'DebugController.resume': MethodMetainfo(internal: true),
  'DebugController.kill': MethodMetainfo(internal: true),
  'SocksSupport.socksConnected': MethodMetainfo(internal: true),
  'SocksSupport.socksFailed': MethodMetainfo(internal: true),
  'SocksSupport.socksData': MethodMetainfo(internal: true),
  'SocksSupport.socksError': MethodMetainfo(internal: true),
  'SocksSupport.socksEnd': MethodMetainfo(internal: true),
  'JsonPipe.send': MethodMetainfo(internal: true),
  'JsonPipe.close': MethodMetainfo(internal: true),
  'CDPSession.send':
      MethodMetainfo(title: 'Send CDP command', group: 'configuration'),
  'CDPSession.detach':
      MethodMetainfo(title: 'Detach CDP session', group: 'configuration'),
  'BindingCall.reject': MethodMetainfo(internal: true),
  'BindingCall.resolve': MethodMetainfo(internal: true),
  'Debugger.requestPause':
      MethodMetainfo(title: 'Pause on next call', group: 'configuration'),
  'Debugger.resume': MethodMetainfo(title: 'Resume', group: 'configuration'),
  'Debugger.next':
      MethodMetainfo(title: 'Step to next call', group: 'configuration'),
  'Debugger.runTo':
      MethodMetainfo(title: 'Run to location', group: 'configuration'),
  'Debugger.enable': MethodMetainfo(internal: true),
  'Dialog.accept':
      MethodMetainfo(title: 'Accept dialog', renderParams: ['promptText']),
  'Dialog.dismiss': MethodMetainfo(title: 'Dismiss dialog'),
  'Tracing.tracingStart':
      MethodMetainfo(title: 'Start tracing', group: 'configuration'),
  'Tracing.tracingStartChunk':
      MethodMetainfo(title: 'Start tracing', group: 'configuration'),
  'Tracing.tracingGroup':
      MethodMetainfo(title: 'Trace "{name}"', renderParams: ['name']),
  'Tracing.tracingGroupEnd': MethodMetainfo(title: 'Group end'),
  'Tracing.tracingStopChunk':
      MethodMetainfo(title: 'Stop tracing', group: 'configuration'),
  'Tracing.tracingStop':
      MethodMetainfo(title: 'Stop tracing', group: 'configuration'),
  'Tracing.harStart': MethodMetainfo(internal: true),
  'Tracing.harExport': MethodMetainfo(internal: true),
  'Worker.disconnect': MethodMetainfo(title: 'Disconnect from worker'),
  'Worker.evaluateExpression': MethodMetainfo(title: 'Evaluate'),
  'Worker.evaluateExpressionHandle': MethodMetainfo(title: 'Evaluate'),
  'Worker.updateSubscription': MethodMetainfo(internal: true),
};

/// Looks a call up by its protocol class and method.
MethodMetainfo? getMetainfo(String className, String method) =>
    methodMetainfo['$className.$method'];

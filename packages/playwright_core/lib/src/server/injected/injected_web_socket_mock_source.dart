// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/injected/src/webSocketMock.ts.

/// The page half of `routeWebSocket`.
///
/// It replaces `globalThis.WebSocket` with a mock that behaves like the real
/// one to the page and reports every event to the driver through the binding
/// [kWebSocketBindingName]. The driver steers it back through
/// `globalThis.__pwWebSocketDispatch`, which takes the request objects
/// documented in `web_socket_mock.ts` upstream.
///
/// Differences from upstream, both forced by this port having no dispatcher
/// layer and both invisible to the page:
///
/// * The binding is the one this port already installs (a function that
///   returns a promise), so the mock ignores the returned promise instead of
///   calling a void function. The payload shape is unchanged.
/// * Types are gone, because this is JavaScript and not TypeScript. Nothing
///   else was rewritten: the state machine, the buffering, the readyState
///   transitions and the error wording are upstream's.
library;

/// The binding the mock calls. Upstream's name, so the shape on the page is
/// the one upstream's own tests would recognise.
const String kWebSocketBindingName = '__pwWebSocketBinding';

/// The function the driver calls to steer one mocked socket.
const String kWebSocketDispatchName = '__pwWebSocketDispatch';

/// Installs the mock. Evaluating it twice in one document is a no-op.
const String kInjectedWebSocketMockSource = '''
if (!globalThis['$kWebSocketDispatchName']) {
  const binding = (payload) => {
    const fn = globalThis['$kWebSocketBindingName'];
    if (fn) {
      // The binding of this port returns a promise; the mock does not wait
      // for it, and an unobserved rejection must not reach the page.
      const result = fn(payload);
      if (result && typeof result.catch === 'function')
        result.catch(() => {});
    }
  };

  function generateId() {
    const bytes = new Uint8Array(32);
    globalThis.crypto.getRandomValues(bytes);
    const hex = '0123456789abcdef';
    return [...bytes].map(value => {
      const high = Math.floor(value / 16);
      const low = value % 16;
      return hex[high] + hex[low];
    }).join('');
  }

  function bufferToData(b) {
    let s = '';
    for (let i = 0; i < b.length; i++)
      s += String.fromCharCode(b[i]);
    return { data: globalThis.btoa(s), isBase64: true };
  }

  function stringToBuffer(s) {
    s = globalThis.atob(s);
    const b = new Uint8Array(s.length);
    for (let i = 0; i < s.length; i++)
      b[i] = s.charCodeAt(i);
    return b.buffer;
  }

  // Note: this function tries to be synchronous when it can to preserve the
  // ability to send multiple messages synchronously in the same order and
  // then synchronously close.
  function messageToData(message, cb) {
    if (message instanceof globalThis.Blob)
      return message.arrayBuffer().then(buffer => cb(bufferToData(new Uint8Array(buffer))));
    if (typeof message === 'string')
      return cb({ data: message, isBase64: false });
    if (ArrayBuffer.isView(message))
      return cb(bufferToData(new Uint8Array(message.buffer, message.byteOffset, message.byteLength)));
    return cb(bufferToData(new Uint8Array(message)));
  }

  function dataToMessage(data, binaryType) {
    if (!data.isBase64)
      return data.data;
    const buffer = stringToBuffer(data.data);
    return binaryType === 'arraybuffer' ? buffer : new Blob([buffer]);
  }

  const NativeWebSocket = globalThis.WebSocket;
  const idToWebSocket = new Map();
  globalThis['$kWebSocketDispatchName'] = (request) => {
    const ws = idToWebSocket.get(request.id);
    if (!ws)
      return;
    if (request.type === 'connect')
      ws._apiConnect();
    if (request.type === 'passthrough')
      ws._apiPassThrough();
    if (request.type === 'ensureOpened')
      ws._apiEnsureOpened();
    if (request.type === 'sendToPage')
      ws._apiSendToPage(dataToMessage(request.data, ws.binaryType));
    if (request.type === 'closePage')
      ws._apiClosePage(request.code, request.reason, request.wasClean);
    if (request.type === 'sendToServer')
      ws._apiSendToServer(dataToMessage(request.data, ws.binaryType));
    if (request.type === 'closeServer')
      ws._apiCloseServer(request.code, request.reason, request.wasClean);
  };

  class WebSocketMock extends EventTarget {
    static CONNECTING = 0;
    static OPEN = 1;
    static CLOSING = 2;
    static CLOSED = 3;

    constructor(url, protocols) {
      super();

      this.CONNECTING = 0;
      this.OPEN = 1;
      this.CLOSING = 2;
      this.CLOSED = 3;

      this._oncloseListener = null;
      this._onerrorListener = null;
      this._onmessageListener = null;
      this._onopenListener = null;

      this.bufferedAmount = 0;
      this.extensions = '';
      this.protocol = '';
      this.readyState = 0;

      // https://github.com/whatwg/websockets/issues/20
      this.url = new URL(url, globalThis.window.document.baseURI).href.replace(/^http/, 'ws');
      this._origin = (() => {
        try {
          return new URL(this.url).origin;
        } catch (e) {
          return '';
        }
      })();
      this._protocols = protocols;
      this._ws = undefined;
      this._passthrough = false;
      this._wsBufferedMessages = [];
      this._binaryType = 'blob';

      this._id = generateId();
      idToWebSocket.set(this._id, this);
      const protocolsList = Array.isArray(protocols) ? [...protocols] : (protocols ? [protocols] : []);
      binding({ type: 'onCreate', id: this._id, url: this.url, protocols: protocolsList });
    }

    // --- native WebSocket implementation ---

    get binaryType() {
      return this._binaryType;
    }

    set binaryType(type) {
      this._binaryType = type;
      if (this._ws)
        this._ws.binaryType = type;
    }

    get onclose() {
      return this._oncloseListener;
    }

    set onclose(listener) {
      if (this._oncloseListener)
        this.removeEventListener('close', this._oncloseListener);
      this._oncloseListener = listener;
      if (this._oncloseListener)
        this.addEventListener('close', this._oncloseListener);
    }

    get onerror() {
      return this._onerrorListener;
    }

    set onerror(listener) {
      if (this._onerrorListener)
        this.removeEventListener('error', this._onerrorListener);
      this._onerrorListener = listener;
      if (this._onerrorListener)
        this.addEventListener('error', this._onerrorListener);
    }

    get onopen() {
      return this._onopenListener;
    }

    set onopen(listener) {
      if (this._onopenListener)
        this.removeEventListener('open', this._onopenListener);
      this._onopenListener = listener;
      if (this._onopenListener)
        this.addEventListener('open', this._onopenListener);
    }

    get onmessage() {
      return this._onmessageListener;
    }

    set onmessage(listener) {
      if (this._onmessageListener)
        this.removeEventListener('message', this._onmessageListener);
      this._onmessageListener = listener;
      if (this._onmessageListener)
        this.addEventListener('message', this._onmessageListener);
    }

    send(message) {
      if (this.readyState === WebSocketMock.CONNECTING)
        throw new DOMException(`Failed to execute 'send' on 'WebSocket': Still in CONNECTING state.`);
      if (this.readyState !== WebSocketMock.OPEN)
        throw new DOMException(`WebSocket is already in CLOSING or CLOSED state.`);
      if (this._passthrough) {
        if (this._ws)
          this._apiSendToServer(message);
      } else {
        messageToData(message, data => binding({ type: 'onMessageFromPage', id: this._id, data }));
      }
    }

    close(code, reason) {
      if (code !== undefined && code !== 1000 && (code < 3000 || code > 4999))
        throw new DOMException(`Failed to execute 'close' on 'WebSocket': The close code must be either 1000, or between 3000 and 4999. \${code} is neither.`);
      if (this.readyState === WebSocketMock.OPEN || this.readyState === WebSocketMock.CONNECTING)
        this.readyState = WebSocketMock.CLOSING;
      if (this._passthrough)
        this._apiCloseServer(code, reason, true);
      else
        binding({ type: 'onClosePage', id: this._id, code, reason, wasClean: true });
    }

    // --- methods called from the routing API ---

    _apiEnsureOpened() {
      // This is called at the end of the route handler. If we did not connect
      // to the server, assume that websocket will be fully mocked. In this
      // case, pretend that server connection is established right away.
      if (!this._ws)
        this._ensureOpened();
    }

    _apiSendToPage(message) {
      // Calling "sendToPage()" from the route handler. Allow this for easier testing.
      this._ensureOpened();
      if (this.readyState !== WebSocketMock.OPEN)
        throw new DOMException(`WebSocket is already in CLOSING or CLOSED state.`);
      this.dispatchEvent(new MessageEvent('message', { data: message, origin: this._origin, cancelable: true }));
    }

    _apiSendToServer(message) {
      if (!this._ws)
        throw new Error('Cannot send a message before connecting to the server');
      if (this._ws.readyState === WebSocketMock.CONNECTING)
        this._wsBufferedMessages.push(message);
      else
        this._ws.send(message);
    }

    _apiConnect() {
      if (this._ws)
        throw new Error('Can only connect to the server once');

      this._ws = new NativeWebSocket(this.url, this._protocols);
      this._ws.binaryType = this._binaryType;

      this._ws.onopen = () => {
        for (const message of this._wsBufferedMessages)
          this._ws.send(message);
        this._wsBufferedMessages = [];
        this._ensureOpened();
      };

      this._ws.onclose = event => {
        this._onWSClose(event.code, event.reason, event.wasClean);
      };

      this._ws.onmessage = event => {
        if (this._passthrough)
          this._apiSendToPage(event.data);
        else
          messageToData(event.data, data => binding({ type: 'onMessageFromServer', id: this._id, data }));
      };

      this._ws.onerror = () => {
        // We do not expose errors in the API, so short-curcuit the error event.
        const event = new Event('error', { cancelable: true });
        this.dispatchEvent(event);
      };
    }

    // This method connects to the server, and passes all messages through,
    // as if WebSocketMock was not engaged.
    _apiPassThrough() {
      this._passthrough = true;
      this._apiConnect();
    }

    _apiCloseServer(code, reason, wasClean) {
      if (!this._ws) {
        // Short-curcuit when there is no server.
        this._onWSClose(code, reason, wasClean);
        return;
      }
      if (this._ws.readyState === WebSocketMock.CONNECTING || this._ws.readyState === WebSocketMock.OPEN)
        this._ws.close(code, reason);
    }

    _apiClosePage(code, reason, wasClean) {
      if (this.readyState === WebSocketMock.CLOSED)
        return;
      this.readyState = WebSocketMock.CLOSED;
      this.dispatchEvent(new CloseEvent('close', { code, reason, wasClean, cancelable: true }));
      this._maybeCleanup();
      if (this._passthrough)
        this._apiCloseServer(code, reason, wasClean);
      else
        binding({ type: 'onClosePage', id: this._id, code, reason, wasClean });
    }

    // --- internals ---

    _ensureOpened() {
      if (this.readyState !== WebSocketMock.CONNECTING)
        return;
      this.extensions = (this._ws && this._ws.extensions) || '';
      if (this._ws)
        this.protocol = this._ws.protocol;
      else if (Array.isArray(this._protocols))
        this.protocol = this._protocols[0] || '';
      else
        this.protocol = this._protocols || '';
      this.readyState = WebSocketMock.OPEN;
      this.dispatchEvent(new Event('open', { cancelable: true }));
    }

    _onWSClose(code, reason, wasClean) {
      if (this._passthrough)
        this._apiClosePage(code, reason, wasClean);
      else
        binding({ type: 'onCloseServer', id: this._id, code, reason, wasClean });
      if (this._ws) {
        this._ws.onopen = null;
        this._ws.onclose = null;
        this._ws.onmessage = null;
        this._ws.onerror = null;
        this._ws = undefined;
        this._wsBufferedMessages = [];
      }
      this._maybeCleanup();
    }

    _maybeCleanup() {
      if (this.readyState === WebSocketMock.CLOSED && !this._ws)
        idToWebSocket.delete(this._id);
    }
  }
  globalThis.WebSocket = class WebSocket extends WebSocketMock {};
}
''';

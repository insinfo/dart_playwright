// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/injected/src/recorder/{recorder,pollingRecorder,
// clipPaths}.ts and packages/injected/src/{highlight.ts,highlight.css}.

/// The page half of the recorder: the toolbar, the highlight under the cursor
/// and the listeners that turn a click or a keystroke into a recorded action.
///
/// It talks to the driver through the bindings named below, which is upstream's
/// protocol verbatim. The driver polls nothing: the page polls
/// [kRecorderStateBinding] once a second, exactly as upstream's
/// `PollingRecorder` does, and the driver can force a refresh by calling
/// `window.__pw_refreshOverlay()`.
///
/// Differences from upstream, and why:
///
/// * **The locator in the tooltip is resolved by the driver.** Upstream calls
///   `asLocator` in the page, which would mean shipping the whole of
///   `locatorGenerators.ts` to JavaScript a second time. Here the tooltip shows
///   the generated selector and is upgraded in place as soon as
///   [kDescribeSelectorBinding] answers; answers are cached per selector, so a
///   hover costs one round trip the first time and nothing afterwards.
/// * **No `api` recorder mode.** Upstream's `JsonRecordActionTool` feeds
///   `browserContext.startRecording`, an API this port does not have.
/// * **No auto-expect precondition.** Upstream diffs two `autoexpect` aria
///   trees to find the element an action revealed. This port's aria snapshot
///   has upstream's `default` mode only and no `findNewElement`, so
///   `recordAction` never carries a precondition selector and the generators'
///   `generateExpectSignal` stays off.
/// * **No `onGlobalListenersRemoved` hook and no `builtins` snapshot.** This
///   port's injected script has neither, so listeners are installed once and
///   plain `setTimeout`/`clearTimeout` are used. The highlight is still
///   re-attached on a timer, which is what covers frameworks that wipe the DOM
///   on hydration.
/// * **The highlight is the recorder's half of `highlight.ts` only**: no user
///   overlays, no action cursor, no action title, no masked elements and no
///   live element-highlight loop. Those serve `page.highlight`, masking and the
///   screencast title, none of which exist here.
library;

/// The driver-side functions the page calls. Upstream's names, so the shape on
/// the page is the one upstream's own tests would recognise.
const String kRecorderStateBinding = '__pw_recorderState';
const String kRecorderPerformActionBinding = '__pw_recorderPerformAction';
const String kRecorderRecordActionBinding = '__pw_recorderRecordAction';
const String kRecorderElementPickedBinding = '__pw_recorderElementPicked';
const String kRecorderSetModeBinding = '__pw_recorderSetMode';
const String kRecorderSetOverlayStateBinding = '__pw_recorderSetOverlayState';

/// Not upstream's: turns a selector into the locator the tooltip shows. See
/// the library doc for why the page cannot do it itself.
const String kDescribeSelectorBinding = '__pw_recorderDescribeSelector';

/// The function the driver calls to make the page re-read the UI state at once
/// instead of waiting for the next poll.
const String kRefreshOverlayFunction = '__pw_refreshOverlay';

/// Builds the recorder init script.
///
/// [hideToolbar] drops the floating toolbar, for a caller that drives the mode
/// itself. [isUnderTest] turns on upstream's `console.error(... for test)`
/// traces, which are how a test observes the page half without a screenshot.
String recorderInstallSource({
  bool hideToolbar = false,
  bool isUnderTest = false,
}) {
  return '''
if (!window.__pwRecorder) {
const __pwRecorderOptions = {
  hideToolbar: $hideToolbar,
  isUnderTest: $isUnderTest,
};
const kStateBinding = '$kRecorderStateBinding';
const kPerformActionBinding = '$kRecorderPerformActionBinding';
const kRecordActionBinding = '$kRecorderRecordActionBinding';
const kElementPickedBinding = '$kRecorderElementPickedBinding';
const kSetModeBinding = '$kRecorderSetModeBinding';
const kSetOverlayStateBinding = '$kRecorderSetOverlayStateBinding';
const kDescribeSelectorBinding = '$kDescribeSelectorBinding';
const kRefreshOverlayFunction = '$kRefreshOverlayFunction';
$_kRecorderBody
}
''';
}

const String _kRecorderBody = r'''
const kHighlightCSS = `
:host {
  font-size: 13px;
  font-family: system-ui, "Ubuntu", "Droid Sans", sans-serif;
  color: #333;
  color-scheme: light;
}

svg {
  position: absolute;
  height: 0;
}

x-pw-tooltip {
  backdrop-filter: blur(5px);
  background-color: white;
  border-radius: 6px;
  box-shadow: 0 0.5rem 1.2rem rgba(0,0,0,.3);
  display: none;
  font-size: 12.8px;
  font-weight: normal;
  left: 0;
  line-height: 1.5;
  max-width: 600px;
  position: absolute;
  top: 0;
  padding: 0;
  flex-direction: column;
  overflow: hidden;
}

x-pw-tooltip-line {
  display: flex;
  max-width: 600px;
  padding: 6px;
  user-select: none;
  cursor: pointer;
}

x-pw-dialog {
  background-color: white;
  pointer-events: auto;
  border-radius: 6px;
  box-shadow: 0 0.5rem 1.2rem rgba(0,0,0,.3);
  display: flex;
  flex-direction: column;
  position: absolute;
  z-index: 10;
  font-size: 13px;
}

x-pw-dialog:not(.autosize) {
  width: 400px;
  height: 150px;
}

x-pw-dialog-body {
  display: flex;
  flex-direction: column;
  flex: auto;
}

x-pw-dialog-body label {
  margin: 5px 8px;
  display: flex;
  flex-direction: row;
  align-items: center;
}

x-pw-highlight {
  position: absolute;
  top: 0;
  left: 0;
  width: 0;
  height: 0;
}

x-pw-action-point {
  position: absolute;
  width: 20px;
  height: 20px;
  background: red;
  border-radius: 10px;
  margin: -10px 0 0 -10px;
  z-index: 2;
}

@keyframes pw-fade-out {
  from { opacity: 1; }
  to { opacity: 0; }
}

x-pw-tool-gripper {
  height: 28px;
  width: 24px;
  margin: 2px 0;
  cursor: grab;
}

x-pw-tool-gripper:active {
  cursor: grabbing;
}

x-pw-tool-gripper > x-div {
  width: 16px;
  height: 16px;
  margin: 6px 4px;
  clip-path: url(#icon-gripper);
  background-color: #555555;
}

x-pw-tools-list > label {
  display: flex;
  align-items: center;
  margin: 0 10px;
  user-select: none;
}

x-pw-tools-list {
  display: flex;
  width: 100%;
  border-bottom: 1px solid #dddddd;
}

x-pw-tool-item {
  pointer-events: auto;
  height: 28px;
  width: 28px;
  border-radius: 3px;
}

x-pw-tool-item:not(.disabled) {
  cursor: pointer;
}

x-pw-tool-item:not(.disabled):hover {
  background-color: hsl(0, 0%, 86%);
}

x-pw-tool-item.toggled {
  background-color: rgba(138, 202, 228, 0.5);
}

x-pw-tool-item.toggled:not(.disabled):hover {
  background-color: #8acae4c4;
}

x-pw-tool-item > x-div {
  width: 16px;
  height: 16px;
  margin: 6px;
  background-color: #3a3a3a;
}

x-pw-tool-item.disabled > x-div {
  background-color: rgba(97, 97, 97, 0.5);
  cursor: default;
}

x-pw-tool-item.record.toggled {
  background-color: transparent;
}

x-pw-tool-item.record.toggled:not(.disabled):hover {
  background-color: hsl(0, 0%, 86%);
}

x-pw-tool-item.record.toggled > x-div {
  background-color: #a1260d;
}

x-pw-tool-item.record.disabled.toggled > x-div {
  opacity: 0.8;
}

x-pw-tool-item.accept > x-div {
  background-color: #388a34;
}

x-pw-tool-item.record > x-div {
  clip-path: url(#icon-circle-large-filled);
}

x-pw-tool-item.record.toggled > x-div {
  clip-path: url(#icon-stop-circle);
}

x-pw-tool-item.pick-locator > x-div {
  clip-path: url(#icon-inspect);
}

x-pw-tool-item.text > x-div {
  clip-path: url(#icon-whole-word);
}

x-pw-tool-item.visibility > x-div {
  clip-path: url(#icon-eye);
}

x-pw-tool-item.value > x-div {
  clip-path: url(#icon-symbol-constant);
}

x-pw-tool-item.snapshot > x-div {
  clip-path: url(#icon-gist);
}

x-pw-tool-item.accept > x-div {
  clip-path: url(#icon-check);
}

x-pw-tool-item.cancel > x-div {
  clip-path: url(#icon-close);
}

x-pw-tool-item.succeeded > x-div {
  clip-path: url(#icon-pass);
  background-color: #388a34 !important;
}

x-pw-overlay {
  position: absolute;
  top: 0;
  max-width: min-content;
  z-index: 2147483647;
  background: transparent;
  pointer-events: auto;
}

x-pw-overlay x-pw-tools-list {
  background-color: #ffffffdd;
  box-shadow: rgba(0, 0, 0, 0.1) 0px 5px 5px;
  border-radius: 3px;
  border-bottom: none;
}

x-pw-overlay x-pw-tool-item {
  margin: 2px;
}

textarea.text-editor {
  font-family: system-ui,Ubuntu,Droid Sans,sans-serif;
  flex: auto;
  border: none;
  margin: 6px 10px;
  color: #333;
  outline: 1px solid transparent!important;
  resize: none;
  padding: 0;
  font-size: 13px;
}

textarea.text-editor.does-not-match {
  outline: 1px solid red !important;
}

x-div {
  display: block;
}

x-spacer {
  flex: auto;
}

* {
  box-sizing: border-box;
}

*[hidden] {
  display: none !important;
}

x-pw-action-list {
  flex: auto;
  display: flex;
  flex-direction: column;
  user-select: none;
}

x-pw-action-item {
  padding: 6px 10px;
  cursor: pointer;
  overflow: hidden;
}

x-pw-action-item:hover {
  background-color: hsl(0, 0%, 95%);
}

x-pw-action-item:last-child {
  border-bottom-left-radius: 6px;
  border-bottom-right-radius: 6px;
}
`;

// Upstream's generated clipPaths.ts: the codicon outlines the toolbar buttons
// are clipped to.
const kClipPaths = {"tagName":"svg","children":[{"tagName":"defs","children":[{"tagName":"clipPath","attrs":{"width":"16","height":"16","viewBox":"0 0 16 16","fill":"currentColor","id":"icon-gripper"},"children":[{"tagName":"path","attrs":{"d":"M5 3h2v2H5zm0 4h2v2H5zm0 4h2v2H5zm4-8h2v2H9zm0 4h2v2H9zm0 4h2v2H9z"}}]},{"tagName":"clipPath","attrs":{"width":"16","height":"16","viewBox":"0 0 16 16","fill":"currentColor","id":"icon-circle-large-filled"},"children":[{"tagName":"path","attrs":{"d":"M8 1a6.8 6.8 0 0 1 1.86.253 6.899 6.899 0 0 1 3.083 1.805 6.903 6.903 0 0 1 1.804 3.083C14.916 6.738 15 7.357 15 8s-.084 1.262-.253 1.86a6.9 6.9 0 0 1-.704 1.674 7.157 7.157 0 0 1-2.516 2.509 6.966 6.966 0 0 1-1.668.71A6.984 6.984 0 0 1 8 15a6.984 6.984 0 0 1-1.86-.246 7.098 7.098 0 0 1-1.674-.711 7.3 7.3 0 0 1-1.415-1.094 7.295 7.295 0 0 1-1.094-1.415 7.098 7.098 0 0 1-.71-1.675A6.985 6.985 0 0 1 1 8c0-.643.082-1.262.246-1.86a6.968 6.968 0 0 1 .711-1.667 7.156 7.156 0 0 1 2.509-2.516 6.895 6.895 0 0 1 1.675-.704A6.808 6.808 0 0 1 8 1z"}}]},{"tagName":"clipPath","attrs":{"width":"16","height":"16","viewBox":"0 0 16 16","fill":"currentColor","id":"icon-stop-circle"},"children":[{"tagName":"path","attrs":{"d":"M6 6h4v4H6z"}},{"tagName":"path","attrs":{"fill-rule":"evenodd","clip-rule":"evenodd","d":"M8.6 1c1.6.1 3.1.9 4.2 2 1.3 1.4 2 3.1 2 5.1 0 1.6-.6 3.1-1.6 4.4-1 1.2-2.4 2.1-4 2.4-1.6.3-3.2.1-4.6-.7-1.4-.8-2.5-2-3.1-3.5C.9 9.2.8 7.5 1.3 6c.5-1.6 1.4-2.9 2.8-3.8C5.4 1.3 7 .9 8.6 1zm.5 12.9c1.3-.3 2.5-1 3.4-2.1.8-1.1 1.3-2.4 1.2-3.8 0-1.6-.6-3.2-1.7-4.3-1-1-2.2-1.6-3.6-1.7-1.3-.1-2.7.2-3.8 1-1.1.8-1.9 1.9-2.3 3.3-.4 1.3-.4 2.7.2 4 .6 1.3 1.5 2.3 2.7 3 1.2.7 2.6.9 3.9.6z"}}]},{"tagName":"clipPath","attrs":{"width":"16","height":"16","viewBox":"0 0 16 16","fill":"currentColor","id":"icon-inspect"},"children":[{"tagName":"path","attrs":{"fill-rule":"evenodd","clip-rule":"evenodd","d":"M1 3l1-1h12l1 1v6h-1V3H2v8h5v1H2l-1-1V3zm14.707 9.707L9 6v9.414l2.707-2.707h4zM10 13V8.414l3.293 3.293h-2L10 13z"}}]},{"tagName":"clipPath","attrs":{"width":"16","height":"16","viewBox":"0 0 16 16","fill":"currentColor","id":"icon-whole-word"},"children":[{"tagName":"path","attrs":{"fill-rule":"evenodd","clip-rule":"evenodd","d":"M0 11H1V13H15V11H16V14H15H1H0V11Z"}},{"tagName":"path","attrs":{"d":"M6.84048 11H5.95963V10.1406H5.93814C5.555 10.7995 4.99104 11.1289 4.24625 11.1289C3.69839 11.1289 3.26871 10.9839 2.95718 10.6938C2.64924 10.4038 2.49527 10.0189 2.49527 9.53906C2.49527 8.51139 3.10041 7.91341 4.3107 7.74512L5.95963 7.51416C5.95963 6.57959 5.58186 6.1123 4.82632 6.1123C4.16389 6.1123 3.56591 6.33789 3.03238 6.78906V5.88672C3.57307 5.54297 4.19612 5.37109 4.90152 5.37109C6.19416 5.37109 6.84048 6.05501 6.84048 7.42285V11ZM5.95963 8.21777L4.63297 8.40039C4.22476 8.45768 3.91682 8.55973 3.70914 8.70654C3.50145 8.84977 3.39761 9.10579 3.39761 9.47461C3.39761 9.74316 3.4925 9.96338 3.68228 10.1353C3.87564 10.3035 4.13166 10.3877 4.45035 10.3877C4.8872 10.3877 5.24706 10.2355 5.52994 9.93115C5.8164 9.62321 5.95963 9.2347 5.95963 8.76562V8.21777Z"}},{"tagName":"path","attrs":{"d":"M9.3475 10.2051H9.32601V11H8.44515V2.85742H9.32601V6.4668H9.3475C9.78076 5.73633 10.4146 5.37109 11.2489 5.37109C11.9543 5.37109 12.5057 5.61816 12.9032 6.1123C13.3042 6.60286 13.5047 7.26172 13.5047 8.08887C13.5047 9.00911 13.2809 9.74674 12.8333 10.3018C12.3857 10.8532 11.7734 11.1289 10.9964 11.1289C10.2695 11.1289 9.71989 10.821 9.3475 10.2051ZM9.32601 7.98682V8.75488C9.32601 9.20964 9.47282 9.59635 9.76644 9.91504C10.0636 10.2301 10.4396 10.3877 10.8944 10.3877C11.4279 10.3877 11.8451 10.1836 12.1458 9.77539C12.4502 9.36719 12.6024 8.79964 12.6024 8.07275C12.6024 7.46045 12.4609 6.98063 12.1781 6.6333C11.8952 6.28597 11.512 6.1123 11.0286 6.1123C10.5166 6.1123 10.1048 6.29134 9.7933 6.64941C9.48177 7.00391 9.32601 7.44971 9.32601 7.98682Z"}}]},{"tagName":"clipPath","attrs":{"width":"16","height":"16","viewBox":"0 0 16 16","fill":"currentColor","id":"icon-eye"},"children":[{"tagName":"path","attrs":{"d":"M7.99993 6.00316C9.47266 6.00316 10.6666 7.19708 10.6666 8.66981C10.6666 10.1426 9.47266 11.3365 7.99993 11.3365C6.52715 11.3365 5.33324 10.1426 5.33324 8.66981C5.33324 7.19708 6.52715 6.00316 7.99993 6.00316ZM7.99993 7.00315C7.07946 7.00315 6.33324 7.74935 6.33324 8.66981C6.33324 9.59028 7.07946 10.3365 7.99993 10.3365C8.9204 10.3365 9.6666 9.59028 9.6666 8.66981C9.6666 7.74935 8.9204 7.00315 7.99993 7.00315ZM7.99993 3.66675C11.0756 3.66675 13.7307 5.76675 14.4673 8.70968C14.5344 8.97755 14.3716 9.24908 14.1037 9.31615C13.8358 9.38315 13.5643 9.22041 13.4973 8.95248C12.8713 6.45205 10.6141 4.66675 7.99993 4.66675C5.38454 4.66675 3.12664 6.45359 2.50182 8.95555C2.43491 9.22341 2.16348 9.38635 1.89557 9.31948C1.62766 9.25255 1.46471 8.98115 1.53162 8.71321C2.26701 5.76856 4.9229 3.66675 7.99993 3.66675Z"}}]},{"tagName":"clipPath","attrs":{"width":"16","height":"16","viewBox":"0 0 16 16","fill":"currentColor","id":"icon-symbol-constant"},"children":[{"tagName":"path","attrs":{"fill-rule":"evenodd","clip-rule":"evenodd","d":"M4 6h8v1H4V6zm8 3H4v1h8V9z"}},{"tagName":"path","attrs":{"fill-rule":"evenodd","clip-rule":"evenodd","d":"M1 4l1-1h12l1 1v8l-1 1H2l-1-1V4zm1 0v8h12V4H2z"}}]},{"tagName":"clipPath","attrs":{"width":"16","height":"16","viewBox":"0 0 16 16","fill":"currentColor","id":"icon-check"},"children":[{"tagName":"path","attrs":{"fill-rule":"evenodd","clip-rule":"evenodd","d":"M14.431 3.323l-8.47 10-.79-.036-3.35-4.77.818-.574 2.978 4.24 8.051-9.506.764.646z"}}]},{"tagName":"clipPath","attrs":{"width":"16","height":"16","viewBox":"0 0 16 16","fill":"currentColor","id":"icon-close"},"children":[{"tagName":"path","attrs":{"fill-rule":"evenodd","clip-rule":"evenodd","d":"M8 8.707l3.646 3.647.708-.707L8.707 8l3.647-3.646-.707-.708L8 7.293 4.354 3.646l-.707.708L7.293 8l-3.646 3.646.707.708L8 8.707z"}}]},{"tagName":"clipPath","attrs":{"width":"16","height":"16","viewBox":"0 0 16 16","fill":"currentColor","id":"icon-pass"},"children":[{"tagName":"path","attrs":{"d":"M6.27 10.87h.71l4.56-4.56-.71-.71-4.2 4.21-1.92-1.92L4 8.6l2.27 2.27z"}},{"tagName":"path","attrs":{"fill-rule":"evenodd","clip-rule":"evenodd","d":"M8.6 1c1.6.1 3.1.9 4.2 2 1.3 1.4 2 3.1 2 5.1 0 1.6-.6 3.1-1.6 4.4-1 1.2-2.4 2.1-4 2.4-1.6.3-3.2.1-4.6-.7-1.4-.8-2.5-2-3.1-3.5C.9 9.2.8 7.5 1.3 6c.5-1.6 1.4-2.9 2.8-3.8C5.4 1.3 7 .9 8.6 1zm.5 12.9c1.3-.3 2.5-1 3.4-2.1.8-1.1 1.3-2.4 1.2-3.8 0-1.6-.6-3.2-1.7-4.3-1-1-2.2-1.6-3.6-1.7-1.3-.1-2.7.2-3.8 1-1.1.8-1.9 1.9-2.3 3.3-.4 1.3-.4 2.7.2 4 .6 1.3 1.5 2.3 2.7 3 1.2.7 2.6.9 3.9.6z"}}]},{"tagName":"clipPath","attrs":{"width":"16","height":"16","viewBox":"0 0 16 16","fill":"currentColor","id":"icon-gist"},"children":[{"tagName":"path","attrs":{"fill-rule":"evenodd","clip-rule":"evenodd","d":"M10.57 1.14l3.28 3.3.15.36v9.7l-.5.5h-11l-.5-.5v-13l.5-.5h7.72l.35.14zM10 5h3l-3-3v3zM3 2v12h10V6H9.5L9 5.5V2H3zm2.062 7.533l1.817-1.828L6.17 7 4 9.179v.707l2.171 2.174.707-.707-1.816-1.82zM8.8 7.714l.7-.709 2.189 2.175v.709L9.5 12.062l-.705-.709 1.831-1.82L8.8 7.714z"}}]}]}]};

const HighlightColors = {
  multiple: '#f6b26b7f',
  single: '#6fa8dc7f',
  assert: '#8acae480',
  action: '#dc6f6f7f',
};

function addEventListener(target, eventName, listener, useCapture) {
  target.addEventListener(eventName, listener, useCapture);
  return () => target.removeEventListener(eventName, listener, useCapture);
}

function removeEventListeners(listeners) {
  for (const listener of listeners)
    listener();
  listeners.splice(0, listeners.length);
}

function createSvgElement(doc, { tagName, attrs, children }) {
  const elem = doc.createElementNS('http://www.w3.org/2000/svg', tagName);
  if (attrs) {
    for (const [k, v] of Object.entries(attrs))
      elem.setAttribute(k, v);
  }
  if (children) {
    for (const c of children)
      elem.appendChild(createSvgElement(doc, c));
  }
  return elem;
}

// ----------------------------------------------------------------- highlight

class Highlight {
  constructor(isUnderTest) {
    this._isUnderTest = isUnderTest;
    this._renderedEntries = [];
    this._actionPointElement = undefined;
    this._glassPaneElement = document.createElement('x-pw-glass');
    this._glassPaneElement.setAttribute('popover', 'manual');
    this._glassPaneElement.style.inset = '0';
    this._glassPaneElement.style.width = '100%';
    this._glassPaneElement.style.height = '100%';
    this._glassPaneElement.style.maxWidth = 'none';
    this._glassPaneElement.style.maxHeight = 'none';
    this._glassPaneElement.style.padding = '0';
    this._glassPaneElement.style.margin = '0';
    this._glassPaneElement.style.border = 'none';
    this._glassPaneElement.style.overflow = 'visible';
    this._glassPaneElement.style.pointerEvents = 'none';
    this._glassPaneElement.style.display = 'flex';
    this._glassPaneElement.style.backgroundColor = 'transparent';
    this._glassPaneShadow = this._glassPaneElement.attachShadow({ mode: isUnderTest ? 'open' : 'closed' });
    // Firefox complains that adoptedStyleSheets.push is not a function while
    // taking a screenshot, so fall back to a <style> element there.
    if (typeof this._glassPaneShadow.adoptedStyleSheets.push === 'function') {
      const sheet = new window.CSSStyleSheet();
      sheet.replaceSync(kHighlightCSS);
      this._glassPaneShadow.adoptedStyleSheets.push(sheet);
    } else {
      const styleElement = document.createElement('style');
      styleElement.textContent = kHighlightCSS;
      this._glassPaneShadow.appendChild(styleElement);
    }
  }

  install() {
    if (!document.documentElement)
      return;
    if (!document.documentElement.contains(this._glassPaneElement) || this._glassPaneElement.nextElementSibling)
      document.documentElement.appendChild(this._glassPaneElement);
    this._bringToFront();
  }

  _bringToFront() {
    // Two separate guards on purpose: `hidePopover()` throws when the popover
    // is not showing, and that must not stop `showPopover()`. Where popover is
    // unsupported the glass pane still paints, just not in the top layer.
    try { this._glassPaneElement.hidePopover(); } catch (e) {}
    try { this._glassPaneElement.showPopover(); } catch (e) {}
  }

  uninstall() {
    this._glassPaneElement.remove();
  }

  showActionPoint(x, y) {
    if (!this._actionPointElement) {
      this._actionPointElement = document.createElement('x-pw-action-point');
      this._glassPaneShadow.appendChild(this._actionPointElement);
    }
    this._actionPointElement.style.top = y + 'px';
    this._actionPointElement.style.left = x + 'px';
    this._actionPointElement.hidden = false;
  }

  hideActionPoint() {
    if (this._actionPointElement)
      this._actionPointElement.hidden = true;
  }

  clearHighlight() {
    for (const entry of this._renderedEntries) {
      if (entry.highlightElement)
        entry.highlightElement.remove();
      if (entry.tooltipElement)
        entry.tooltipElement.remove();
    }
    this._renderedEntries = [];
  }

  updateHighlight(entries) {
    // Code below should trigger one layout and leave with the destroyed layout.
    if (this._highlightIsUpToDate(entries))
      return;

    // 1. Destroy the layout.
    this.clearHighlight();

    for (const entry of entries) {
      const highlightElement = document.createElement('x-pw-highlight');
      this._glassPaneShadow.appendChild(highlightElement);

      let tooltipElement;
      if (entry.tooltipText) {
        tooltipElement = document.createElement('x-pw-tooltip');
        this._glassPaneShadow.appendChild(tooltipElement);
        tooltipElement.style.top = '0';
        tooltipElement.style.left = '0';
        tooltipElement.style.display = 'flex';
        const lineElement = document.createElement('x-pw-tooltip-line');
        lineElement.textContent = entry.tooltipText;
        tooltipElement.appendChild(lineElement);
      }
      this._renderedEntries.push({
        targetElement: entry.element,
        color: entry.color,
        tooltipText: entry.tooltipText,
        tooltipElement,
        highlightElement,
      });
    }

    // 2. Trigger layout while positioning tooltips and computing boxes.
    for (const entry of this._renderedEntries) {
      if (!entry.targetElement)
        continue;
      entry.box = entry.targetElement.getBoundingClientRect();
      if (!entry.tooltipElement)
        continue;
      const { anchorLeft, anchorTop } = this.tooltipPosition(entry.box, entry.tooltipElement);
      entry.tooltipTop = anchorTop;
      entry.tooltipLeft = anchorLeft;
    }

    // 3. Destroy the layout again.
    for (const entry of this._renderedEntries) {
      if (entry.tooltipElement) {
        entry.tooltipElement.style.top = entry.tooltipTop + 'px';
        entry.tooltipElement.style.left = entry.tooltipLeft + 'px';
      }
      const box = entry.box;
      if (!box)
        continue;
      entry.highlightElement.style.backgroundColor = entry.color;
      entry.highlightElement.style.left = box.x + 'px';
      entry.highlightElement.style.top = box.y + 'px';
      entry.highlightElement.style.width = box.width + 'px';
      entry.highlightElement.style.height = box.height + 'px';
      entry.highlightElement.style.display = 'block';

      if (this._isUnderTest)
        console.error('Highlight box for test: ' + JSON.stringify({ x: box.x, y: box.y, width: box.width, height: box.height }));
    }
  }

  firstBox() {
    return this._renderedEntries.length ? this._renderedEntries[0].box : undefined;
  }

  firstTooltipBox() {
    const entry = this._renderedEntries[0];
    if (!entry || !entry.tooltipElement || entry.tooltipLeft === undefined || entry.tooltipTop === undefined)
      return undefined;
    return {
      x: entry.tooltipLeft,
      y: entry.tooltipTop,
      left: entry.tooltipLeft,
      top: entry.tooltipTop,
      width: entry.tooltipElement.offsetWidth,
      height: entry.tooltipElement.offsetHeight,
      bottom: entry.tooltipTop + entry.tooltipElement.offsetHeight,
      right: entry.tooltipLeft + entry.tooltipElement.offsetWidth,
    };
  }

  tooltipPosition(box, tooltipElement) {
    const tooltipWidth = tooltipElement.offsetWidth;
    const tooltipHeight = tooltipElement.offsetHeight;
    const totalWidth = this._glassPaneElement.offsetWidth;
    const totalHeight = this._glassPaneElement.offsetHeight;

    let anchorLeft = Math.max(5, box.left);
    if (anchorLeft + tooltipWidth > totalWidth - 5)
      anchorLeft = totalWidth - tooltipWidth - 5;
    let anchorTop = Math.max(0, box.bottom) + 5;
    if (anchorTop + tooltipHeight > totalHeight - 5) {
      // If it cannot fit below, either position above...
      if (Math.max(0, box.top) > tooltipHeight + 5) {
        anchorTop = Math.max(0, box.top) - tooltipHeight - 5;
      } else {
        // ...or on top, in case of a large element.
        anchorTop = totalHeight - 5 - tooltipHeight;
      }
    }
    return { anchorLeft, anchorTop };
  }

  _highlightIsUpToDate(entries) {
    if (entries.length !== this._renderedEntries.length)
      return false;
    for (let i = 0; i < this._renderedEntries.length; ++i) {
      if (entries[i].element !== this._renderedEntries[i].targetElement)
        return false;
      if (entries[i].color !== this._renderedEntries[i].color)
        return false;
      if (entries[i].tooltipText !== this._renderedEntries[i].tooltipText)
        return false;
      const oldBox = this._renderedEntries[i].box;
      if (!oldBox)
        return false;
      const box = entries[i].element.getBoundingClientRect();
      if (box.top !== oldBox.top || box.right !== oldBox.right || box.bottom !== oldBox.bottom || box.left !== oldBox.left)
        return false;
    }
    return true;
  }

  appendChild(element) {
    this._glassPaneShadow.appendChild(element);
  }

  onGlassPaneClick(handler) {
    this._glassPaneElement.style.pointerEvents = 'auto';
    this._glassPaneElement.style.backgroundColor = 'rgba(0, 0, 0, 0.3)';
    this._glassPaneElement.addEventListener('click', handler);
  }

  offGlassPaneClick(handler) {
    this._glassPaneElement.style.pointerEvents = 'none';
    this._glassPaneElement.style.backgroundColor = 'transparent';
    this._glassPaneElement.removeEventListener('click', handler);
  }
}

// --------------------------------------------------------------------- tools

class NoneTool {
}

class InspectTool {
  constructor(recorder, assertVisibility) {
    this._recorder = recorder;
    this._hoveredModel = null;
    this._hoveredElement = null;
    this._assertVisibility = assertVisibility;
  }

  cursor() {
    return 'pointer';
  }

  uninstall() {
    this._hoveredModel = null;
    this._hoveredElement = null;
  }

  onClick(event) {
    consumeEvent(event);
    if (event.button !== 0)
      return;
    if (this._hoveredModel && this._hoveredModel.selector)
      this._commit(this._hoveredModel.selector, this._hoveredModel);
  }

  onPointerDown(event) { consumeEvent(event); }
  onPointerUp(event) { consumeEvent(event); }
  onMouseDown(event) { consumeEvent(event); }
  onMouseUp(event) { consumeEvent(event); }

  onMouseMove(event) {
    consumeEvent(event);
    let target = this._recorder.deepEventTarget(event);
    if (!target.isConnected)
      target = null;
    if (this._hoveredElement === target)
      return;
    this._hoveredElement = target;

    let model = null;
    if (this._hoveredElement) {
      const generated = generateSelectorFor(this._recorder, this._hoveredElement);
      model = {
        selector: generated.selector,
        elements: generated.elements,
        color: this._assertVisibility ? HighlightColors.assert : HighlightColors.single,
      };
    }

    if ((this._hoveredModel && this._hoveredModel.selector) === (model && model.selector))
      return;
    this._hoveredModel = model;
    this._recorder.updateHighlight(model, true);
  }

  onMouseEnter(event) { consumeEvent(event); }

  onMouseLeave(event) {
    consumeEvent(event);
    // Leaving iframe.
    if (window.top !== window && this._recorder.deepEventTarget(event).nodeType === Node.DOCUMENT_NODE)
      this._reset(true);
  }

  onKeyDown(event) {
    consumeEvent(event);
    if (event.key === 'Escape') {
      if (this._assertVisibility)
        this._recorder.setMode('recording');
    }
  }

  onKeyUp(event) { consumeEvent(event); }

  onScroll(event) {
    this._reset(false);
  }

  _commit(selector, model) {
    if (this._assertVisibility) {
      void this._recorder.recordAction({ name: 'assertVisible', selector });
      this._recorder.setMode('recording');
      if (this._recorder.overlay)
        this._recorder.overlay.flashToolSucceeded('assertingVisibility');
    } else {
      this._recorder.elementPicked(selector, model);
    }
  }

  _reset(userGesture) {
    this._hoveredElement = null;
    this._hoveredModel = null;
    this._recorder.updateHighlight(null, userGesture);
  }
}

class RecordActionTool {
  constructor(recorder) {
    this._recorder = recorder;
    this._performingActions = new Set();
    this._hoveredModel = null;
    this._hoveredElement = null;
    this._activeModel = null;
    this._observer = null;
    this._dialog = new Dialog(recorder);
  }

  cursor() {
    return 'pointer';
  }

  _installObserverIfNeeded() {
    if (this._observer)
      return;
    if (!document.body)
      return;
    this._observer = new MutationObserver(mutations => {
      if (!this._hoveredElement)
        return;
      for (const mutation of mutations) {
        for (const node of mutation.removedNodes) {
          if (node === this._hoveredElement || node.contains(this._hoveredElement))
            this._resetHoveredModel();
        }
      }
    });
    this._observer.observe(document.body, { childList: true, subtree: true });
  }

  uninstall() {
    if (this._observer)
      this._observer.disconnect();
    this._observer = null;
    this._hoveredModel = null;
    this._hoveredElement = null;
    this._activeModel = null;
    this._dialog.close();
  }

  onClick(event) {
    if (this._dialog.isShowing()) {
      if (event.button === 2 && event.type === 'auxclick') {
        // In some browsers, e.g. firefox mac, auxclick arrives after
        // contextmenu and should be consumed.
        consumeEvent(event);
      }
      return;
    }

    // In webkit, sliding a range element may trigger a click event with a
    // different target if the mouse is released outside the bounding box, so
    // check the hovered element instead.
    if (isRangeInput(this._hoveredElement))
      return;
    if (this._shouldIgnoreMouseEvent(event))
      return;

    if (event.button === 2 && event.type === 'auxclick') {
      // A right-click performed on behalf of the dialog is recorded via
      // onContextMenu.
      if (!this._performingActions.size)
        this._showActionListDialog(event);
      return;
    }

    // Keyboard-activated clicks, e.g. Enter on a button or Space on a
    // checkbox, come with zero detail and are recorded in onKeyDown instead.
    if (event.detail === 0)
      return;

    const target = this._recorder.deepEventTarget(event);
    const checkbox = asCheckbox(target);
    if (checkbox && event.detail === 1) {
      // inputElement.checked already reflects the new state in this handler.
      this._recordAction({
        name: checkbox.checked ? 'check' : 'uncheck',
        selector: (this._hoveredModel && this._hoveredModel.selector) || this._selectorForElement(target),
      });
      return;
    }

    this._recordAction({
      name: 'click',
      selector: (this._hoveredModel && this._hoveredModel.selector) || this._selectorForElement(target),
      position: positionForEvent(event),
      button: buttonForEvent(event),
      modifiers: modifiersForEvent(event),
      clickCount: event.detail,
    });
  }

  onContextMenu(event) {
    if (this._dialog.isShowing()) {
      // In some browsers, e.g. chromium windows, contextmenu arrives after
      // auxclick and should be consumed.
      consumeEvent(event);
      return;
    }
    if (this._shouldIgnoreMouseEvent(event))
      return;
    if (this._performingActions.size) {
      // The dialog is performing a right-click for us; record it naturally
      // instead of reopening the dialog.
      const target = this._recorder.deepEventTarget(event);
      this._recordAction({
        name: 'click',
        selector: (this._hoveredModel && this._hoveredModel.selector) || this._selectorForElement(target),
        position: positionForEvent(event),
        button: 'right',
        modifiers: modifiersForEvent(event),
        clickCount: 1,
      });
      return;
    }
    this._showActionListDialog(event);
  }

  onPointerDown(event) {
    if (this._dialog.isShowing())
      return;
    if (this._shouldIgnoreMouseEvent(event))
      return;
    this._consumeRightButtonEvent(event);
  }

  onPointerUp(event) {
    if (this._dialog.isShowing())
      return;
    if (this._shouldIgnoreMouseEvent(event))
      return;
    this._consumeRightButtonEvent(event);
  }

  onMouseDown(event) {
    if (this._dialog.isShowing())
      return;
    if (this._shouldIgnoreMouseEvent(event))
      return;
    this._consumeRightButtonEvent(event);
    this._activeModel = this._hoveredModel;
  }

  onMouseUp(event) {
    if (this._dialog.isShowing())
      return;
    if (this._shouldIgnoreMouseEvent(event))
      return;
    this._consumeRightButtonEvent(event);
  }

  onMouseMove(event) {
    if (this._dialog.isShowing())
      return;
    const target = this._recorder.deepEventTarget(event);
    if (this._hoveredElement === target)
      return;
    this._hoveredElement = target;
    this._updateModelForHoveredElement();
  }

  onMouseLeave(event) {
    if (this._dialog.isShowing())
      return;
    // Leaving iframe.
    if (window.top !== window && this._recorder.deepEventTarget(event).nodeType === Node.DOCUMENT_NODE) {
      this._hoveredElement = null;
      this._updateModelForHoveredElement();
    }
  }

  onFocus(event) {
    if (this._dialog.isShowing())
      return;
    this._onFocus(true);
  }

  onInput(event) {
    if (this._dialog.isShowing())
      return;
    const target = this._recorder.deepEventTarget(event);

    if (target.nodeName === 'INPUT' && target.type.toLowerCase() === 'file') {
      // When the file input is hidden and triggered by another element, the
      // hover model points to the trigger, not the input.
      const selector = target === this._hoveredElement && this._hoveredModel
        ? this._hoveredModel.selector
        : this._selectorForElement(target);
      this._recordAction({
        name: 'setInputFiles',
        selector,
        files: [...(target.files || [])].map(file => file.name),
      });
      return;
    }

    if (isRangeInput(target)) {
      this._recordAction({
        name: 'fill',
        // Must use hoveredModel instead of activeModel for it to work in webkit.
        selector: (this._hoveredModel && this._hoveredModel.selector) || this._selectorForElement(target),
        text: target.value,
      });
      return;
    }

    if (['INPUT', 'TEXTAREA'].includes(target.nodeName) || target.isContentEditable) {
      if (target.nodeName === 'INPUT' && ['checkbox', 'radio'].includes(target.type.toLowerCase())) {
        // Checkbox is handled in click; no duplicate action for the input event.
        return;
      }

      // By the time the input event arrives, the contenteditable already
      // contains the new text. Generate a selector that does not depend on
      // that text, so that it works before the fill.
      const selector = target.isContentEditable
        ? this._selectorForElement(target, { noText: true })
        : this._activeSelectorForEvent(event);
      this._recordAction({
        name: 'fill',
        selector,
        text: target.isContentEditable ? target.innerText : target.value,
      });
    }

    if (target.nodeName === 'SELECT') {
      this._recordAction({
        name: 'select',
        selector: this._activeSelectorForEvent(event),
        options: [...target.selectedOptions].map(option => option.value),
      });
    }
  }

  onKeyDown(event) {
    if (this._dialog.isShowing())
      return;
    if (!this._shouldGenerateKeyPressFor(event))
      return;
    // Similarly to click, trigger checkbox on key event, not input.
    if (event.key === ' ') {
      const checkbox = asCheckbox(this._recorder.deepEventTarget(event));
      if (checkbox && event.detail === 0) {
        this._recordAction({
          name: checkbox.checked ? 'uncheck' : 'check',
          selector: this._activeSelectorForEvent(event),
        });
        return;
      }
    }

    this._recordAction({
      name: 'press',
      selector: this._activeSelectorForEvent(event),
      key: event.key,
      modifiers: modifiersForEvent(event),
    });
  }

  onScroll(event) {
    if (this._dialog.isShowing())
      return;
    this._resetHoveredModel();
  }

  _showActionListDialog(event) {
    // Right click is always intercepted and opens the actions dialog instead
    // of being passed to the page.
    consumeEvent(event);
    const model = this._hoveredModel || this._modelForElement(this._recorder.deepEventTarget(event));
    if (!model)
      return;
    const actionPosition = positionForEvent(event);
    const actions = [
      {
        title: 'Click',
        cb: () => this._performAction({ name: 'click', selector: model.selector, position: actionPosition, button: 'left', modifiers: 0, clickCount: 1 }),
      },
      {
        title: 'Right click',
        cb: () => this._performAction({ name: 'click', selector: model.selector, position: actionPosition, button: 'right', modifiers: 0, clickCount: 1 }),
      },
      {
        title: 'Double click',
        cb: () => this._performAction({ name: 'click', selector: model.selector, position: actionPosition, button: 'left', modifiers: 0, clickCount: 2 }),
      },
      {
        title: 'Hover',
        cb: () => this._recordAction({ name: 'hover', selector: model.selector, position: actionPosition }),
      },
      {
        title: 'Pick locator',
        cb: () => this._recorder.elementPicked(model.selector, model),
      },
    ];

    const listElement = document.createElement('x-pw-action-list');
    listElement.setAttribute('role', 'list');
    listElement.setAttribute('aria-label', 'Choose action');
    for (const action of actions) {
      const actionElement = document.createElement('x-pw-action-item');
      actionElement.setAttribute('role', 'listitem');
      actionElement.textContent = action.title;
      actionElement.setAttribute('aria-label', action.title);
      actionElement.addEventListener('click', () => {
        this._dialog.close();
        action.cb();
      });
      listElement.appendChild(actionElement);
    }

    const dialogElement = this._dialog.show({ label: 'Choose action', body: listElement, autosize: true });
    const anchorBox = this._recorder.highlight.firstTooltipBox() || model.elements[0].getBoundingClientRect();
    const dialogPosition = this._recorder.highlight.tooltipPosition(anchorBox, dialogElement);
    this._dialog.moveTo(dialogPosition.anchorTop, dialogPosition.anchorLeft);
  }

  _resetHoveredModel() {
    this._hoveredModel = null;
    this._hoveredElement = null;
    this._updateHighlight(false);
  }

  _onFocus(userGesture) {
    const activeElement = deepActiveElement(document);
    // Firefox dispatches "focus" to body when clicking on a backgrounded
    // headed browser window; ignore that stray event.
    if (userGesture && activeElement === document.body)
      return;
    const result = activeElement ? generateSelectorFor(this._recorder, activeElement) : null;
    this._activeModel = result && result.selector ? { selector: result.selector, elements: result.elements, color: HighlightColors.action } : null;
    if (userGesture) {
      this._hoveredElement = activeElement;
      this._updateModelForHoveredElement();
    }
  }

  _shouldIgnoreMouseEvent(event) {
    return shouldIgnoreMouseEvent(this._recorder.deepEventTarget(event));
  }

  _consumeRightButtonEvent(event) {
    // Right click is intercepted to open the actions dialog, so the page
    // should not see it.
    if (event.button === 2 && !this._performingActions.size)
      consumeEvent(event);
  }

  _selectorForElement(element, options) {
    return generateSelectorFor(this._recorder, element, options).selector;
  }

  _modelForElement(element) {
    const { selector, elements } = generateSelectorFor(this._recorder, element);
    return selector ? { selector, elements, color: HighlightColors.action } : null;
  }

  _activeSelectorForEvent(event) {
    const target = this._recorder.deepEventTarget(event);
    if (this._activeModel && this._activeModel.elements[0] === target)
      return this._activeModel.selector;
    return this._selectorForElement(target);
  }

  _reportPerformedActionForTests() {
    if (!__pwRecorderOptions.isUnderTest)
      return;
    // Serialize all to string as we cannot attribute console messages to an
    // isolated world in Firefox.
    console.error('Action performed for test: ' + JSON.stringify({
      hovered: this._hoveredModel ? this._hoveredModel.selector : null,
      active: this._activeModel ? this._activeModel.selector : null,
    }));
  }

  _recordAction(action) {
    void this._recorder.recordAction(action).then(() => this._reportPerformedActionForTests());
  }

  _performAction(action) {
    this._recorder.updateHighlight(null, false);
    this._performingActions.add(action);
    void this._recorder.performAction(action).finally(() => {
      this._performingActions.delete(action);
      // If that was a keyboard action, it similarly requires new selectors for
      // the active model.
      this._onFocus(false);
    }).then(() => this._reportPerformedActionForTests());
  }

  _shouldGenerateKeyPressFor(event) {
    // IME can generate keyboard events without a value for the key property.
    if (typeof event.key !== 'string')
      return false;
    // Enter aka. new line is handled in the input event.
    if (event.key === 'Enter' && (this._recorder.deepEventTarget(event).nodeName === 'TEXTAREA' || this._recorder.deepEventTarget(event).isContentEditable))
      return false;
    // Backspace, Delete, AltGraph are changing input; handled there.
    if (['Backspace', 'Delete', 'AltGraph'].includes(event.key))
      return false;
    // Ignore the QWERTZ shortcut for creating an at sign on MacOS.
    if (event.key === '@' && event.code === 'KeyL')
      return false;
    // Allow and ignore the common shortcut for pasting.
    if (navigator.platform.includes('Mac')) {
      if (event.key === 'v' && event.metaKey)
        return false;
    } else {
      if (event.key === 'v' && event.ctrlKey)
        return false;
      if (event.key === 'Insert' && event.shiftKey)
        return false;
    }
    if (['Shift', 'Control', 'Meta', 'Alt', 'Process'].includes(event.key))
      return false;
    const hasModifier = event.ctrlKey || event.altKey || event.metaKey;
    if (event.key.length === 1 && !hasModifier)
      return !!asCheckbox(this._recorder.deepEventTarget(event));
    return true;
  }

  _updateModelForHoveredElement() {
    this._installObserverIfNeeded();
    if (this._performingActions.size)
      return;
    if (!this._hoveredElement || !this._hoveredElement.isConnected) {
      this._hoveredModel = null;
      this._hoveredElement = null;
      this._updateHighlight(true);
      return;
    }
    const { selector, elements } = generateSelectorFor(this._recorder, this._hoveredElement);
    if (this._hoveredModel && this._hoveredModel.selector === selector)
      return;
    this._hoveredModel = selector ? { selector, elements, color: HighlightColors.action } : null;
    this._updateHighlight(true);
  }

  _updateHighlight(userGesture) {
    this._recorder.updateHighlight(this._hoveredModel, userGesture);
  }
}

class TextAssertionTool {
  constructor(recorder, kind) {
    this._recorder = recorder;
    this._hoverHighlight = null;
    this._action = null;
    this._kind = kind;
    this._dialog = new Dialog(recorder);
  }

  cursor() {
    return 'pointer';
  }

  uninstall() {
    this._dialog.close();
    this._hoverHighlight = null;
  }

  onClick(event) {
    consumeEvent(event);
    if (this._kind === 'value') {
      this._commitAssertValue();
    } else {
      if (!this._dialog.isShowing())
        this._showDialog();
    }
  }

  onMouseDown(event) {
    const target = this._recorder.deepEventTarget(event);
    if (this._elementHasValue(target))
      event.preventDefault();
  }

  onPointerUp(event) {
    const target = this._hoverHighlight ? this._hoverHighlight.elements[0] : undefined;
    if (this._kind === 'value' && target && (target.nodeName === 'INPUT' || target.nodeName === 'SELECT') && target.disabled) {
      // A click on a disabled input does not produce a "click" event, but we
      // still want to assert the value.
      this._commitAssertValue();
    }
  }

  onMouseMove(event) {
    if (this._dialog.isShowing())
      return;
    const target = this._recorder.deepEventTarget(event);
    if (this._hoverHighlight && this._hoverHighlight.elements[0] === target)
      return;
    if (this._kind === 'text' || this._kind === 'snapshot') {
      this._hoverHighlight = window.__pwDart.elementText(target).full ? { elements: [target], selector: '', color: HighlightColors.assert } : null;
    } else if (this._elementHasValue(target)) {
      const generated = generateSelectorFor(this._recorder, target);
      this._hoverHighlight = { selector: generated.selector, elements: generated.elements, color: HighlightColors.assert };
    } else {
      this._hoverHighlight = null;
    }
    this._recorder.updateHighlight(this._hoverHighlight, true);
  }

  onKeyDown(event) {
    if (event.key === 'Escape')
      this._recorder.setMode('recording');
    consumeEvent(event);
  }

  onScroll(event) {
    this._recorder.updateHighlight(this._hoverHighlight, false);
  }

  _elementHasValue(element) {
    return element.nodeName === 'TEXTAREA' || element.nodeName === 'SELECT' || (element.nodeName === 'INPUT' && !['button', 'image', 'reset', 'submit'].includes(element.type));
  }

  _generateAction() {
    const target = this._hoverHighlight ? this._hoverHighlight.elements[0] : undefined;
    if (!target)
      return null;
    if (this._kind === 'value') {
      if (!this._elementHasValue(target))
        return null;
      const { selector } = generateSelectorFor(this._recorder, target);
      if (target.nodeName === 'INPUT' && ['checkbox', 'radio'].includes(target.type.toLowerCase())) {
        return {
          name: 'assertChecked',
          selector,
          // Interestingly, inputElement.checked is reversed inside this handler.
          checked: !target.checked,
        };
      }
      return { name: 'assertValue', selector, value: target.value };
    }
    if (this._kind === 'snapshot') {
      const generated = generateSelectorFor(this._recorder, target, { forTextExpect: true });
      this._hoverHighlight = { selector: generated.selector, elements: generated.elements, color: HighlightColors.assert };
      // forTextExpect can update the target, re-highlight it.
      this._recorder.updateHighlight(this._hoverHighlight, true);
      return {
        name: 'assertSnapshot',
        selector: this._hoverHighlight.selector,
        ariaSnapshot: window.__pwDart.ariaSnapshot(target, {}),
      };
    }
    const generated = generateSelectorFor(this._recorder, target, { forTextExpect: true });
    this._hoverHighlight = { selector: generated.selector, elements: generated.elements, color: HighlightColors.assert };
    this._recorder.updateHighlight(this._hoverHighlight, true);
    return {
      name: 'assertText',
      selector: this._hoverHighlight.selector,
      text: window.__pwDart.elementText(target).normalized,
      substring: true,
    };
  }

  _renderValue(action) {
    if (action && action.name === 'assertText')
      return window.__pwDart.normalizeWhiteSpace(action.text);
    if (action && action.name === 'assertChecked')
      return String(action.checked);
    if (action && action.name === 'assertValue')
      return action.value;
    if (action && action.name === 'assertSnapshot')
      return action.ariaSnapshot;
    return '';
  }

  _commit() {
    if (!this._action || !this._dialog.isShowing())
      return;
    this._dialog.close();
    void this._recorder.recordAction(this._action);
    this._recorder.setMode('recording');
  }

  _showDialog() {
    if (!this._hoverHighlight || !this._hoverHighlight.elements[0])
      return;
    this._action = this._generateAction();
    if (this._action && this._action.name === 'assertText') {
      this._showTextDialog(this._action);
    } else if (this._action && this._action.name === 'assertSnapshot') {
      void this._recorder.recordAction(this._action);
      this._recorder.setMode('recording');
      if (this._recorder.overlay)
        this._recorder.overlay.flashToolSucceeded('assertingSnapshot');
    }
  }

  _showTextDialog(action) {
    const textElement = document.createElement('textarea');
    textElement.setAttribute('spellcheck', 'false');
    textElement.value = this._renderValue(action);
    textElement.classList.add('text-editor');

    const updateAndValidate = () => {
      const newValue = window.__pwDart.normalizeWhiteSpace(textElement.value);
      const target = this._hoverHighlight ? this._hoverHighlight.elements[0] : undefined;
      if (!target)
        return;
      action.text = newValue;
      const targetText = window.__pwDart.elementText(target).normalized;
      const matches = newValue && targetText.includes(newValue);
      textElement.classList.toggle('does-not-match', !matches);
    };
    textElement.addEventListener('input', updateAndValidate);

    const dialogElement = this._dialog.show({
      label: 'Assert that element contains text',
      body: textElement,
      onCommit: () => this._commit(),
    });
    const position = this._recorder.highlight.tooltipPosition(this._recorder.highlight.firstBox(), dialogElement);
    this._dialog.moveTo(position.anchorTop, position.anchorLeft);
    textElement.focus();
  }

  _commitAssertValue() {
    if (this._kind !== 'value')
      return;
    const action = this._generateAction();
    if (!action)
      return;
    void this._recorder.recordAction(action);
    this._recorder.setMode('recording');
    if (this._recorder.overlay)
      this._recorder.overlay.flashToolSucceeded('assertingValue');
  }
}

// ------------------------------------------------------------------- overlay

class Overlay {
  constructor(recorder) {
    this._recorder = recorder;
    this._listeners = [];
    this._offsetX = 0;
    this._dragState = undefined;
    this._measure = { width: 0, height: 0 };

    this._overlayElement = document.createElement('x-pw-overlay');
    const toolsListElement = document.createElement('x-pw-tools-list');
    this._overlayElement.appendChild(toolsListElement);

    this._dragHandle = document.createElement('x-pw-tool-gripper');
    this._dragHandle.appendChild(document.createElement('x-div'));
    toolsListElement.appendChild(this._dragHandle);

    const makeToggle = (title, className) => {
      const element = document.createElement('x-pw-tool-item');
      element.title = title;
      element.classList.add(className);
      element.appendChild(document.createElement('x-div'));
      toolsListElement.appendChild(element);
      return element;
    };

    this._recordToggle = makeToggle('Record', 'record');
    this._pickLocatorToggle = makeToggle('Pick locator', 'pick-locator');
    this._assertVisibilityToggle = makeToggle('Assert visibility', 'visibility');
    this._assertTextToggle = makeToggle('Assert text', 'text');
    this._assertValuesToggle = makeToggle('Assert value', 'value');
    this._assertSnapshotToggle = makeToggle('Assert snapshot', 'snapshot');

    this._updateVisualPosition();
    this._refreshListeners();
  }

  _refreshListeners() {
    removeEventListeners(this._listeners);
    this._listeners = [
      addEventListener(this._dragHandle, 'mousedown', event => {
        this._dragState = { offsetX: this._offsetX, dragStart: { x: event.clientX, y: 0 } };
      }),
      addEventListener(this._recordToggle, 'click', () => {
        if (this._recordToggle.classList.contains('disabled'))
          return;
        const mode = this._recorder.state.mode;
        this._recorder.setMode(mode === 'none' || mode === 'standby' || mode === 'inspecting' ? 'recording' : 'standby');
      }),
      addEventListener(this._pickLocatorToggle, 'click', () => {
        if (this._pickLocatorToggle.classList.contains('disabled'))
          return;
        const newMode = {
          'inspecting': 'standby',
          'none': 'inspecting',
          'standby': 'inspecting',
          'recording': 'recording-inspecting',
          'recording-inspecting': 'recording',
          'assertingText': 'recording-inspecting',
          'assertingVisibility': 'recording-inspecting',
          'assertingValue': 'recording-inspecting',
          'assertingSnapshot': 'recording-inspecting',
        };
        this._recorder.setMode(newMode[this._recorder.state.mode]);
      }),
      addEventListener(this._assertVisibilityToggle, 'click', () => {
        if (!this._assertVisibilityToggle.classList.contains('disabled'))
          this._recorder.setMode(this._recorder.state.mode === 'assertingVisibility' ? 'recording' : 'assertingVisibility');
      }),
      addEventListener(this._assertTextToggle, 'click', () => {
        if (!this._assertTextToggle.classList.contains('disabled'))
          this._recorder.setMode(this._recorder.state.mode === 'assertingText' ? 'recording' : 'assertingText');
      }),
      addEventListener(this._assertValuesToggle, 'click', () => {
        if (!this._assertValuesToggle.classList.contains('disabled'))
          this._recorder.setMode(this._recorder.state.mode === 'assertingValue' ? 'recording' : 'assertingValue');
      }),
      addEventListener(this._assertSnapshotToggle, 'click', () => {
        if (!this._assertSnapshotToggle.classList.contains('disabled'))
          this._recorder.setMode(this._recorder.state.mode === 'assertingSnapshot' ? 'recording' : 'assertingSnapshot');
      }),
    ];
  }

  install() {
    this._recorder.highlight.appendChild(this._overlayElement);
    this._refreshListeners();
    this._updateVisualPosition();
  }

  contains(element) {
    return window.__pwDart.isInsideScope(this._overlayElement, element);
  }

  setUIState(state) {
    const isRecording = state.mode === 'recording' || state.mode === 'assertingText' || state.mode === 'assertingVisibility' || state.mode === 'assertingValue' || state.mode === 'assertingSnapshot' || state.mode === 'recording-inspecting';
    const assertDisabled = state.mode === 'none' || state.mode === 'standby' || state.mode === 'inspecting';
    this._recordToggle.classList.toggle('toggled', isRecording);
    this._recordToggle.title = isRecording ? 'Stop Recording' : 'Start Recording';
    this._pickLocatorToggle.classList.toggle('toggled', state.mode === 'inspecting' || state.mode === 'recording-inspecting');
    this._assertVisibilityToggle.classList.toggle('toggled', state.mode === 'assertingVisibility');
    this._assertVisibilityToggle.classList.toggle('disabled', assertDisabled);
    this._assertTextToggle.classList.toggle('toggled', state.mode === 'assertingText');
    this._assertTextToggle.classList.toggle('disabled', assertDisabled);
    this._assertValuesToggle.classList.toggle('toggled', state.mode === 'assertingValue');
    this._assertValuesToggle.classList.toggle('disabled', assertDisabled);
    this._assertSnapshotToggle.classList.toggle('toggled', state.mode === 'assertingSnapshot');
    this._assertSnapshotToggle.classList.toggle('disabled', assertDisabled);
    if (this._offsetX !== state.overlay.offsetX) {
      this._offsetX = state.overlay.offsetX;
      this._updateVisualPosition();
    }
    if (state.mode === 'none')
      this._hideOverlay();
    else
      this._showOverlay();
  }

  flashToolSucceeded(tool) {
    let element;
    if (tool === 'assertingVisibility')
      element = this._assertVisibilityToggle;
    else if (tool === 'assertingSnapshot')
      element = this._assertSnapshotToggle;
    else
      element = this._assertValuesToggle;
    element.classList.add('succeeded');
    setTimeout(() => element.classList.remove('succeeded'), 2000);
  }

  _hideOverlay() {
    this._overlayElement.setAttribute('hidden', 'true');
  }

  _showOverlay() {
    if (!this._overlayElement.hasAttribute('hidden'))
      return;
    this._overlayElement.removeAttribute('hidden');
    this._updateVisualPosition();
  }

  _updateVisualPosition() {
    this._measure = this._overlayElement.getBoundingClientRect();
    this._overlayElement.style.left = ((window.innerWidth - this._measure.width) / 2 + this._offsetX) + 'px';
  }

  onMouseMove(event) {
    if (!event.buttons) {
      this._dragState = undefined;
      return false;
    }
    if (this._dragState) {
      this._offsetX = this._dragState.offsetX + event.clientX - this._dragState.dragStart.x;
      const halfGapSize = (window.innerWidth - this._measure.width) / 2 - 10;
      this._offsetX = Math.max(-halfGapSize, Math.min(halfGapSize, this._offsetX));
      this._updateVisualPosition();
      this._recorder.setOverlayState({ offsetX: this._offsetX });
      consumeEvent(event);
      return true;
    }
    return false;
  }

  onMouseUp(event) {
    if (this._dragState) {
      consumeEvent(event);
      return true;
    }
    return false;
  }

  onClick(event) {
    if (this._dragState) {
      this._dragState = undefined;
      consumeEvent(event);
      return true;
    }
    return false;
  }

  onDblClick(event) {
    return false;
  }
}

// ------------------------------------------------------------------ recorder

// Wraps `__pwDart.generateSelector` with the recorder's current test id
// attribute, and asks the driver for the locator spelling of a new selector.
function generateSelectorFor(recorder, element, options) {
  const generated = window.__pwDart.generateSelector(element, {
    ...(options || {}),
    testIdAttributeName: recorder.state.testIdAttributeName,
  });
  recorder.requestLocatorDescription(generated.selector);
  return generated;
}

class Recorder {
  constructor() {
    this._listeners = [];
    this._delegate = {};
    this._locatorDescriptions = new Map();
    this._lastHighlightModel = null;
    this.state = {
      mode: 'none',
      testIdAttributeName: 'data-testid',
      language: 'dart',
      overlay: { offsetX: 0 },
    };
    this.highlight = new Highlight(__pwRecorderOptions.isUnderTest);
    this._tools = {
      'none': new NoneTool(),
      'standby': new NoneTool(),
      'inspecting': new InspectTool(this, false),
      'recording': new RecordActionTool(this),
      'recording-inspecting': new InspectTool(this, false),
      'assertingText': new TextAssertionTool(this, 'text'),
      'assertingVisibility': new InspectTool(this, true),
      'assertingValue': new TextAssertionTool(this, 'value'),
      'assertingSnapshot': new TextAssertionTool(this, 'snapshot'),
    };
    this._currentTool = this._tools.none;
    if (this._currentTool.install)
      this._currentTool.install();
    this.overlay = undefined;
    if (window.top === window && !__pwRecorderOptions.hideToolbar) {
      this.overlay = new Overlay(this);
      this.overlay.setUIState(this.state);
    }
    this._stylesheet = new window.CSSStyleSheet();
    this._stylesheet.replaceSync(`
      body[data-pw-cursor=pointer] *, body[data-pw-cursor=pointer] *::after { cursor: pointer !important; }
      body[data-pw-cursor=text] *, body[data-pw-cursor=text] *::after { cursor: text !important; }
    `);
    this.installListeners();
    if (__pwRecorderOptions.isUnderTest)
      console.error('Recorder script ready for test');
  }

  installListeners() {
    removeEventListeners(this._listeners);
    this._listeners = [
      addEventListener(document, 'click', event => this._onClick(event), true),
      addEventListener(document, 'auxclick', event => this._onClick(event), true),
      addEventListener(document, 'dblclick', event => this._onDblClick(event), true),
      addEventListener(document, 'contextmenu', event => this._onContextMenu(event), true),
      addEventListener(document, 'dragstart', event => this._onDragStart(event), true),
      addEventListener(document, 'input', event => this._onInput(event), true),
      addEventListener(document, 'keydown', event => this._onKeyDown(event), true),
      addEventListener(document, 'keyup', event => this._onKeyUp(event), true),
      addEventListener(document, 'pointerdown', event => this._onPointerDown(event), true),
      addEventListener(document, 'pointerup', event => this._onPointerUp(event), true),
      addEventListener(document, 'mousedown', event => this._onMouseDown(event), true),
      addEventListener(document, 'mouseup', event => this._onMouseUp(event), true),
      addEventListener(document, 'mousemove', event => this._onMouseMove(event), true),
      addEventListener(document, 'mouseleave', event => this._onMouseLeave(event), true),
      addEventListener(document, 'mouseenter', event => this._onMouseEnter(event), true),
      addEventListener(document, 'focus', event => this._onFocus(event), true),
      addEventListener(document, 'scroll', event => this._onScroll(event), true),
    ];

    this.highlight.install();
    // Some frameworks erase the DOM on hydration; this reattaches the glass pane.
    let recreationInterval;
    const recreate = () => {
      this.highlight.install();
      recreationInterval = setTimeout(recreate, 500);
    };
    recreationInterval = setTimeout(recreate, 500);
    this._listeners.push(() => clearTimeout(recreationInterval));

    this.highlight.appendChild(createSvgElement(document, kClipPaths));
    if (this.overlay)
      this.overlay.install();
    if (this._currentTool && this._currentTool.install)
      this._currentTool.install();
    try {
      document.adoptedStyleSheets.push(this._stylesheet);
    } catch (e) {
      // Firefox in some modes refuses the push; the cursor hint is cosmetic.
    }
  }

  _switchCurrentTool() {
    const newTool = this._tools[this.state.mode];
    if (newTool === this._currentTool)
      return;
    if (this._currentTool.uninstall)
      this._currentTool.uninstall();
    this.clearHighlight();
    this._currentTool = newTool;
    if (this._currentTool.install)
      this._currentTool.install();
    const cursor = newTool.cursor ? newTool.cursor() : undefined;
    if (cursor && document.body)
      document.body.setAttribute('data-pw-cursor', cursor);
  }

  setUIState(state, delegate) {
    this._delegate = delegate;

    if (state.actionPoint && this.state.actionPoint && state.actionPoint.x === this.state.actionPoint.x && state.actionPoint.y === this.state.actionPoint.y) {
      // All good.
    } else if (!state.actionPoint && !this.state.actionPoint) {
      // All good.
    } else {
      if (state.actionPoint)
        this.highlight.showActionPoint(state.actionPoint.x, state.actionPoint.y);
      else
        this.highlight.hideActionPoint();
    }

    this.state = state;
    this._switchCurrentTool();
    if (this.overlay)
      this.overlay.setUIState(state);
  }

  clearHighlight() {
    this.updateHighlight(null, false);
  }

  // The tooltip shows the locator, which only the driver can spell. Ask it
  // once per selector and re-render when the answer lands.
  requestLocatorDescription(selector) {
    if (!selector || this._locatorDescriptions.has(selector))
      return;
    this._locatorDescriptions.set(selector, selector);
    const describe = window[kDescribeSelectorBinding];
    if (!describe)
      return;
    Promise.resolve(describe(selector)).then(locator => {
      if (!locator)
        return;
      this._locatorDescriptions.set(selector, locator);
      if (this._lastHighlightModel && this._lastHighlightModel.selector === selector)
        this._renderHighlight(this._lastHighlightModel);
    }).catch(() => {});
  }

  _onClick(event) {
    if (!event.isTrusted)
      return;
    if (this.overlay && this.overlay.onClick(event))
      return;
    if (this._ignoreOverlayEvent(event))
      return;
    if (this._currentTool.onClick)
      this._currentTool.onClick(event);
  }

  _onDblClick(event) {
    if (!event.isTrusted)
      return;
    if (this.overlay && this.overlay.onDblClick(event))
      return;
    if (this._ignoreOverlayEvent(event))
      return;
    if (this._currentTool.onDblClick)
      this._currentTool.onDblClick(event);
  }

  _onContextMenu(event) {
    if (!event.isTrusted)
      return;
    // In chromium windows the context menu event always includes the overlay,
    // even for a right click on the page, so the overlay is not checked here.
    if (this._currentTool.onContextMenu)
      this._currentTool.onContextMenu(event);
  }

  _onDragStart(event) {
    if (!event.isTrusted)
      return;
    if (this._ignoreOverlayEvent(event))
      return;
    if (this._currentTool.onDragStart)
      this._currentTool.onDragStart(event);
  }

  _onPointerDown(event) {
    if (!event.isTrusted)
      return;
    if (this._ignoreOverlayEvent(event))
      return;
    if (this._currentTool.onPointerDown)
      this._currentTool.onPointerDown(event);
  }

  _onPointerUp(event) {
    if (!event.isTrusted)
      return;
    if (this._ignoreOverlayEvent(event))
      return;
    if (this._currentTool.onPointerUp)
      this._currentTool.onPointerUp(event);
  }

  _onMouseDown(event) {
    if (!event.isTrusted)
      return;
    if (this._ignoreOverlayEvent(event))
      return;
    if (this._currentTool.onMouseDown)
      this._currentTool.onMouseDown(event);
  }

  _onMouseUp(event) {
    if (!event.isTrusted)
      return;
    if (this.overlay && this.overlay.onMouseUp(event))
      return;
    if (this._ignoreOverlayEvent(event))
      return;
    if (this._currentTool.onMouseUp)
      this._currentTool.onMouseUp(event);
  }

  _onMouseMove(event) {
    if (!event.isTrusted)
      return;
    if (this.overlay && this.overlay.onMouseMove(event))
      return;
    if (this._ignoreOverlayEvent(event))
      return;
    if (this._currentTool.onMouseMove)
      this._currentTool.onMouseMove(event);
  }

  _onMouseEnter(event) {
    if (!event.isTrusted)
      return;
    if (this._ignoreOverlayEvent(event))
      return;
    if (this._currentTool.onMouseEnter)
      this._currentTool.onMouseEnter(event);
  }

  _onMouseLeave(event) {
    if (!event.isTrusted)
      return;
    if (this._ignoreOverlayEvent(event))
      return;
    if (this._currentTool.onMouseLeave)
      this._currentTool.onMouseLeave(event);
  }

  _onFocus(event) {
    if (!event.isTrusted)
      return;
    if (this._ignoreOverlayEvent(event))
      return;
    if (this._currentTool.onFocus)
      this._currentTool.onFocus(event);
  }

  _onScroll(event) {
    if (!event.isTrusted)
      return;
    this.highlight.hideActionPoint();
    if (this._currentTool.onScroll)
      this._currentTool.onScroll(event);
  }

  _onInput(event) {
    if (this._ignoreOverlayEvent(event))
      return;
    if (this._currentTool.onInput)
      this._currentTool.onInput(event);
  }

  _onKeyDown(event) {
    if (!event.isTrusted)
      return;
    if (this._ignoreOverlayEvent(event))
      return;
    if (this._currentTool.onKeyDown)
      this._currentTool.onKeyDown(event);
  }

  _onKeyUp(event) {
    if (!event.isTrusted)
      return;
    if (this._ignoreOverlayEvent(event))
      return;
    if (this._currentTool.onKeyUp)
      this._currentTool.onKeyUp(event);
  }

  updateHighlight(model, userGesture) {
    this._lastHighlightModel = model;
    this._renderHighlight(model);
    if (userGesture && this._delegate.highlightUpdated)
      this._delegate.highlightUpdated();
  }

  _renderHighlight(model) {
    if (model) {
      let tooltipText = model.tooltipText;
      if (tooltipText === undefined && model.selector)
        tooltipText = this._locatorDescriptions.get(model.selector) || model.selector;
      this.highlight.updateHighlight(model.elements.map(element => ({ element, color: model.color, tooltipText })));
    } else {
      this.highlight.clearHighlight();
    }
  }

  _ignoreOverlayEvent(event) {
    return event.composedPath().some(e => (e.nodeName || '').toLowerCase() === 'x-pw-glass');
  }

  deepEventTarget(event) {
    for (const element of event.composedPath()) {
      if (!this.overlay || !this.overlay.contains(element))
        return element;
    }
    return event.composedPath()[0];
  }

  setMode(mode) {
    if (this._delegate.setMode)
      void this._delegate.setMode(mode);
  }

  async performAction(action) {
    if (this._delegate.performAction)
      await this._delegate.performAction(action).catch(() => {});
  }

  async recordAction(action) {
    if (this._delegate.recordAction)
      await this._delegate.recordAction(action);
  }

  setOverlayState(state) {
    if (this._delegate.setOverlayState)
      void this._delegate.setOverlayState(state);
  }

  elementPicked(selector, model) {
    const ariaSnapshot = window.__pwDart.ariaSnapshot(model.elements[0], {});
    if (this._delegate.elementPicked)
      void this._delegate.elementPicked({ selector, ariaSnapshot });
  }
}

class Dialog {
  constructor(recorder) {
    this._recorder = recorder;
    this._dialogElement = null;
    this._keyboardListener = undefined;
    this._onGlassPaneClickHandler = undefined;
  }

  isShowing() {
    return !!this._dialogElement;
  }

  show(options) {
    const acceptButton = document.createElement('x-pw-tool-item');
    acceptButton.title = 'Accept';
    acceptButton.classList.add('accept');
    acceptButton.appendChild(document.createElement('x-div'));
    acceptButton.addEventListener('click', () => {
      if (options.onCommit)
        options.onCommit();
    });

    const cancelButton = document.createElement('x-pw-tool-item');
    cancelButton.title = 'Close';
    cancelButton.classList.add('cancel');
    cancelButton.appendChild(document.createElement('x-div'));
    cancelButton.addEventListener('click', () => {
      this.close();
      if (options.onCancel)
        options.onCancel();
    });

    this._dialogElement = document.createElement('x-pw-dialog');
    if (options.autosize)
      this._dialogElement.classList.add('autosize');

    this._keyboardListener = event => {
      if (event.key === 'Escape') {
        this.close();
        if (options.onCancel)
          options.onCancel();
        return;
      }
      if (options.onCommit && event.key === 'Enter' && (event.ctrlKey || event.metaKey)) {
        if (this._dialogElement)
          options.onCommit();
      }
    };

    this._onGlassPaneClickHandler = () => {
      this.close();
      if (options.onCancel)
        options.onCancel();
    };

    // Ensure any clicks in the dialog are caught rather than passing through
    // to the page and thus closing the dialog.
    this._dialogElement.addEventListener('click', event => event.stopPropagation());

    const toolbarElement = document.createElement('x-pw-tools-list');
    const labelElement = document.createElement('label');
    labelElement.textContent = options.label;
    toolbarElement.appendChild(labelElement);
    toolbarElement.appendChild(document.createElement('x-spacer'));
    if (options.onCommit)
      toolbarElement.appendChild(acceptButton);
    toolbarElement.appendChild(cancelButton);

    this._dialogElement.appendChild(toolbarElement);
    const bodyElement = document.createElement('x-pw-dialog-body');
    bodyElement.appendChild(options.body);
    this._dialogElement.appendChild(bodyElement);
    this._recorder.highlight.appendChild(this._dialogElement);
    this._recorder.highlight.onGlassPaneClick(this._onGlassPaneClickHandler);
    document.addEventListener('keydown', this._keyboardListener, true);
    return this._dialogElement;
  }

  moveTo(top, left) {
    if (!this._dialogElement)
      return;
    this._dialogElement.style.top = top + 'px';
    this._dialogElement.style.left = left + 'px';
  }

  close() {
    if (!this._dialogElement)
      return;
    this._dialogElement.remove();
    this._recorder.highlight.offGlassPaneClick(this._onGlassPaneClickHandler);
    document.removeEventListener('keydown', this._keyboardListener, true);
    this._dialogElement = null;
  }
}

function deepActiveElement(doc) {
  let activeElement = doc.activeElement;
  while (activeElement && activeElement.shadowRoot && activeElement.shadowRoot.activeElement)
    activeElement = activeElement.shadowRoot.activeElement;
  return activeElement;
}

function modifiersForEvent(event) {
  return (event.altKey ? 1 : 0) | (event.ctrlKey ? 2 : 0) | (event.metaKey ? 4 : 0) | (event.shiftKey ? 8 : 0);
}

function buttonForEvent(event) {
  switch (event.which) {
    case 1: return 'left';
    case 2: return 'middle';
    case 3: return 'right';
  }
  return 'left';
}

function positionForEvent(event) {
  const targetElement = event.target;
  if (targetElement.nodeName !== 'CANVAS')
    return undefined;
  return { x: event.offsetX, y: event.offsetY };
}

function consumeEvent(e) {
  e.preventDefault();
  e.stopPropagation();
  e.stopImmediatePropagation();
}

function asCheckbox(node) {
  if (!node || node.nodeName !== 'INPUT')
    return null;
  return ['checkbox', 'radio'].includes(node.type) ? node : null;
}

function isRangeInput(node) {
  if (!node || node.nodeName !== 'INPUT')
    return false;
  return node.type.toLowerCase() === 'range';
}

// Non-text input types that open native pickers.
const kNativePickerInputTypes = new Set(['color', 'date', 'datetime-local', 'file', 'month', 'range', 'time', 'week']);

function shouldIgnoreMouseEvent(target) {
  const nodeName = target.nodeName;
  if (nodeName === 'SELECT' || nodeName === 'OPTION')
    return true;
  if (nodeName === 'INPUT' && kNativePickerInputTypes.has(target.type))
    return true;
  return false;
}

// ----------------------------------------------------------- polling recorder

class PollingRecorder {
  constructor() {
    this._recorder = new Recorder();
    this._pollRecorderModeTimer = undefined;
    this._lastStateJSON = undefined;

    const refreshOverlay = () => {
      this._lastStateJSON = undefined;
      this._pollRecorderMode().catch(e => console.log(e));
    };
    window[kRefreshOverlayFunction] = refreshOverlay;
    refreshOverlay();
  }

  async _pollRecorderMode() {
    const pollPeriod = 1000;
    if (this._pollRecorderModeTimer)
      clearTimeout(this._pollRecorderModeTimer);
    const stateBinding = window[kStateBinding];
    const state = stateBinding ? await stateBinding().catch(() => null) : null;
    if (!state) {
      this._pollRecorderModeTimer = setTimeout(() => this._pollRecorderMode(), pollPeriod);
      return;
    }

    const stringifiedState = JSON.stringify(state);
    if (this._lastStateJSON !== stringifiedState) {
      this._lastStateJSON = stringifiedState;
      if (window.top !== window) {
        // Only show the action point in the main frame, since it is relative
        // to the page's viewport.
        state.actionPoint = undefined;
      }
      this._recorder.setUIState(state, this);
    }

    this._pollRecorderModeTimer = setTimeout(() => this._pollRecorderMode(), pollPeriod);
  }

  async performAction(action) {
    await window[kPerformActionBinding](action);
  }

  async recordAction(action) {
    await window[kRecordActionBinding](action);
  }

  async elementPicked(elementInfo) {
    await window[kElementPickedBinding](elementInfo);
  }

  async setMode(mode) {
    await window[kSetModeBinding](mode);
  }

  async setOverlayState(state) {
    await window[kSetOverlayStateBinding](state);
  }
}

window.__pwRecorder = new PollingRecorder();
''';

# 08 — Mapeamento Arquivo-a-Arquivo TypeScript → Dart

## 1. Legenda

- 🟢 **v0.1** — Primeiro marco (fundação + Chromium básico)
- 🔵 **v0.2** — Chromium completo
- 🟡 **v0.3** — Tracing, vídeo, emulação
- 🟠 **v0.4** — Firefox
- 🔴 **v0.5** — WebKit
- ⚫ **v0.6+** — MCP e extras
- ⬜ **Skip** — Não portar (irrelevante para Dart)

---

## 2. packages/protocol/spec/ → playwright_protocol/

| Arquivo TS | Arquivo Dart | Marco | Notas |
|---|---|---|---|
| `core.yml` | `lib/src/generated/core.dart` | 🟢 v0.1 | Metadata, SDKLanguage |
| `playwright.yml` | `lib/src/generated/playwright.dart` | 🟢 v0.1 | Root interface |
| `browserType.yml` | `lib/src/generated/browser_type.dart` | 🟢 v0.1 | Launch, connect |
| `browser.yml` | `lib/src/generated/browser.dart` | 🟢 v0.1 | newContext, close |
| `browserContext.yml` | `lib/src/generated/browser_context.dart` | 🟢 v0.1 | Cookies, permissions |
| `page.yml` | `lib/src/generated/page.dart` | 🟢 v0.1 | 15.1 KB — grande |
| `frame.yml` | `lib/src/generated/frame.dart` | 🟢 v0.1 | 16.7 KB — grande |
| `handles.yml` | `lib/src/generated/handles.dart` | 🟢 v0.1 | JSHandle, ElementHandle |
| `network.yml` | `lib/src/generated/network.dart` | 🟢 v0.1 | Request, Response, Route |
| `mixins.yml` | `lib/src/generated/mixins.dart` | 🟢 v0.1 | LaunchOptions, ContextOptions |
| `serialized.yml` | `lib/src/generated/serialized.dart` | 🟢 v0.1 | Tipos serializados |
| `structs.yml` | `lib/src/generated/structs.dart` | 🟢 v0.1 | StackFrame, etc. |
| `api.yml` | `lib/src/generated/api.dart` | 🟢 v0.1 | Tipos de API |
| `artifact.yml` | `lib/src/generated/artifact.dart` | 🔵 v0.2 | Downloads, traces |
| `tracing.yml` | `lib/src/generated/tracing.dart` | 🟡 v0.3 | Start, stop |
| `worker.yml` | `lib/src/generated/worker.dart` | 🔵 v0.2 | Worker interface |
| `localUtils.yml` | `lib/src/generated/local_utils.dart` | 🔵 v0.2 | HAR, zip |
| `android.yml` | ⬜ Skip | — | Não portar inicialmente |
| `electron.yml` | ⬜ Skip | — | Não portar inicialmente |

---

## 3. packages/protocol/src/ → playwright_protocol/

| Arquivo TS | Arquivo Dart | Marco | Tamanho | Notas |
|---|---|---|---|---|
| `validator.ts` | `lib/src/validator.dart` | 🟢 v0.1 | 101 KB | Validação de mensagens |
| `validatorPrimitives.ts` | `lib/src/validator_primitives.dart` | 🟢 v0.1 | 6.3 KB | Primitivos de validação |
| `serializers.ts` | `lib/src/serializers.dart` | 🟢 v0.1 | 7.4 KB | Serialização |
| `structs.d.ts` | `lib/src/structs.dart` | 🟢 v0.1 | 6.7 KB | Tipos de estruturas |

---

## 4. packages/playwright-core/src/client/ → playwright/lib/src/

| Arquivo TS | Arquivo Dart | Marco | Tamanho | Notas |
|---|---|---|---|---|
| `channelOwner.ts` | `connection/channel_owner.dart` | 🟢 v0.1 | 9.6 KB | Base de todos os objetos |
| `connection.ts` | `connection/connection.dart` | 🟢 v0.1 | 14.6 KB | Gerencia RPC |
| `eventEmitter.ts` | `connection/event_emitter.dart` | 🟢 v0.1 | 12.5 KB | Sistema de eventos |
| `playwright.ts` | `api/playwright.dart` | 🟢 v0.1 | 3.0 KB | Root object |
| `browserType.ts` | `api/browser_type.dart` | 🟢 v0.1 | 9.4 KB | Launch/connect |
| `browser.ts` | `api/browser.dart` | 🟢 v0.1 | 7.6 KB | Browser API |
| `browserContext.ts` | `api/browser_context.dart` | 🟢 v0.1 | 25.9 KB | Context API |
| `page.ts` | `api/page.dart` | 🟢 v0.1 | 40.7 KB | **GRANDE** — Page API |
| `frame.ts` | `api/frame.dart` | 🟢 v0.1 | 26.1 KB | Frame API |
| `locator.ts` | `api/locator.dart` | 🟢 v0.1 | 20.8 KB | Locator API |
| `elementHandle.ts` | `api/element_handle.dart` | 🟢 v0.1 | 15.1 KB | ElementHandle |
| `jsHandle.ts` | `api/js_handle.dart` | 🟢 v0.1 | 5.9 KB | JSHandle |
| `network.ts` | `api/network.dart` | 🟢 v0.1 | 31.9 KB | Request, Response, Route, WebSocket |
| `input.ts` | `api/input.dart` | 🟢 v0.1 | 2.9 KB | Keyboard, Mouse, Touchscreen |
| `selectors.ts` | `api/selectors.dart` | 🟢 v0.1 | 2.4 KB | Custom selectors |
| `errors.ts` | `api/errors.dart` | 🟢 v0.1 | 2.6 KB | Error types |
| `types.ts` | `api/types.dart` | 🟢 v0.1 | 5.4 KB | Shared types |
| `events.ts` | `api/events.dart` | 🟢 v0.1 | 2.8 KB | Event constants |
| `waiter.ts` | `helpers/waiter.dart` | 🟢 v0.1 | 7.0 KB | Wait helpers |
| `timeoutSettings.ts` | `helpers/timeout_settings.dart` | 🟢 v0.1 | 3.3 KB | Timeout config |
| `clientHelper.ts` | `helpers/client_helper.dart` | 🟢 v0.1 | 2.0 KB | Utilities |
| `consoleMessage.ts` | `api/console_message.dart` | 🟢 v0.1 | 2.1 KB | Console messages |
| `dialog.ts` | `api/dialog.dart` | 🔵 v0.2 | 2.0 KB | Dialog API |
| `download.ts` | `api/download.dart` | 🔵 v0.2 | 1.9 KB | Download API |
| `fileChooser.ts` | `api/file_chooser.dart` | 🔵 v0.2 | 1.6 KB | File chooser |
| `artifact.ts` | `api/artifact.dart` | 🔵 v0.2 | 2.7 KB | Artifact API |
| `fetch.ts` | `api/fetch.dart` | 🔵 v0.2 | 16.7 KB | API request context |
| `coverage.ts` | `api/coverage.dart` | 🔵 v0.2 | 1.5 KB | Coverage |
| `harRouter.ts` | `api/har_router.dart` | 🔵 v0.2 | 5.4 KB | HAR replay |
| `worker.ts` | `api/worker.dart` | 🔵 v0.2 | 5.1 KB | Web Workers |
| `webError.ts` | `api/web_error.dart` | 🔵 v0.2 | 1.2 KB | Web errors |
| `webStorage.ts` | `api/web_storage.dart` | 🔵 v0.2 | 1.8 KB | Web storage |
| `tracing.ts` | `api/tracing.dart` | 🟡 v0.3 | 9.1 KB | Tracing API |
| `video.ts` | `api/video.dart` | 🟡 v0.3 | 1.7 KB | Video API |
| `screencast.ts` | `api/screencast.dart` | 🟡 v0.3 | 4.0 KB | Screencast |
| `clock.ts` | `api/clock.dart` | 🟡 v0.3 | 2.6 KB | Clock API |
| `credentials.ts` | `api/credentials.dart` | 🔵 v0.2 | 1.8 KB | WebAuthn |
| `connect.ts` | `api/connect.dart` | 🔵 v0.2 | 6.0 KB | Remote connect |
| `clientInstrumentation.ts` | `helpers/instrumentation.dart` | 🟢 v0.1 | 3.8 KB | Instrumentation |
| `clientStackTrace.ts` | `helpers/stack_trace.dart` | 🟢 v0.1 | 2.4 KB | Stack traces |
| `cdpSession.ts` | `api/cdp_session.dart` | 🔵 v0.2 | 2.0 KB | Raw CDP |
| `debugger.ts` | `api/debugger.dart` | ⬜ Skip | 2.0 KB | Debug UI |
| `disposable.ts` | `api/disposable.dart` | 🟢 v0.1 | 2.0 KB | Disposable |
| `stream.ts` | `api/stream_utils.dart` | 🟢 v0.1 | 1.8 KB | Stream utils |
| `writableStream.ts` | `api/writable_stream.dart` | 🔵 v0.2 | 2.0 KB | Writable stream |
| `jsonPipe.ts` | `api/json_pipe.dart` | 🔵 v0.2 | 1.1 KB | JSON pipe |
| `localUtils.ts` | `api/local_utils.dart` | 🔵 v0.2 | 2.7 KB | Local utilities |
| `fileUtils.ts` | `helpers/file_utils.dart` | 🟢 v0.1 | 1.0 KB | File helpers |
| `android.ts` | ⬜ Skip | — | 16.0 KB | Android |
| `electron.ts` | ⬜ Skip | — | 7.2 KB | Electron |

---

## 5. packages/playwright-core/src/server/ → playwright_core/lib/src/server/

| Arquivo TS | Arquivo Dart | Marco | Tamanho | Notas |
|---|---|---|---|---|
| `browser.ts` | `browser.dart` | 🟢 v0.1 | 10.1 KB | Browser base |
| `browserContext.ts` | `browser_context.dart` | 🟢 v0.1 | 34.9 KB | **GRANDE** |
| `browserType.ts` | `browser_type.dart` | 🟢 v0.1 | 17.2 KB | Launch logic |
| `page.ts` | `page.dart` | 🟢 v0.1 | 47.6 KB | **GRANDE** |
| `frames.ts` | `frames.dart` | 🟢 v0.1 | 82.7 KB | **MUITO GRANDE** |
| `dom.ts` | `dom.dart` | 🟢 v0.1 | 48.5 KB | **GRANDE** — DOM manipulation |
| `input.ts` | `input.dart` | 🟢 v0.1 | 14.9 KB | Input dispatch |
| `network.ts` | `network.dart` | 🟢 v0.1 | 29.5 KB | Network layer |
| `javascript.ts` | `javascript.dart` | 🟢 v0.1 | 15.3 KB | JS evaluation |
| `selectors.ts` | `selectors.dart` | 🟢 v0.1 | 3.7 KB | Selector engine |
| `progress.ts` | `progress.dart` | 🟢 v0.1 | 7.5 KB | Progress/timeout |
| `instrumentation.ts` | `instrumentation.dart` | 🟢 v0.1 | 6.3 KB | Instrumentation |
| `transport.ts` | `transport/transport.dart` | 🟢 v0.1 | 8.0 KB | WebSocket transport |
| `pipeTransport.ts` | `transport/pipe_transport.dart` | 🟢 v0.1 | 3.0 KB | Pipe transport |
| `playwright.ts` | `playwright.dart` | 🟢 v0.1 | 2.8 KB | Server playwright |
| `helper.ts` | `helper.dart` | 🟢 v0.1 | 4.0 KB | Helpers |
| `errors.ts` | `errors.dart` | 🟢 v0.1 | 2.3 KB | Error types |
| `types.ts` | `types.dart` | 🟢 v0.1 | 4.3 KB | Shared types |
| `protocolError.ts` | `protocol_error.dart` | 🟢 v0.1 | 1.4 KB | Protocol errors |
| `screenshotter.ts` | `screenshotter.dart` | 🟢 v0.1 | 15.8 KB | Screenshot logic |
| `fetch.ts` | `fetch.dart` | 🔵 v0.2 | 38.7 KB | **GRANDE** — HTTP |
| `dialog.ts` | `dialog.dart` | 🔵 v0.2 | 4.2 KB | Dialog handler |
| `download.ts` | `download.dart` | 🔵 v0.2 | 2.4 KB | Download handler |
| `fileChooser.ts` | `file_chooser.dart` | 🔵 v0.2 | 1.0 KB | File chooser |
| `fileUploadUtils.ts` | `file_upload_utils.dart` | 🔵 v0.2 | 3.4 KB | Upload utils |
| `artifact.ts` | `artifact.dart` | 🔵 v0.2 | 4.5 KB | Artifact handler |
| `harBackend.ts` | `har_backend.dart` | 🔵 v0.2 | 8.0 KB | HAR backend |
| `cookieStore.ts` | `cookie_store.dart` | 🔵 v0.2 | 6.6 KB | Cookie manager |
| `credentials.ts` | `credentials.dart` | 🔵 v0.2 | 10.5 KB | WebAuthn |
| `clock.ts` | `clock.dart` | 🟡 v0.3 | 6.1 KB | Clock |
| `screencast.ts` | `screencast.dart` | 🟡 v0.3 | 6.2 KB | Screencast |
| `videoRecorder.ts` | `video_recorder.dart` | 🟡 v0.3 | 11.1 KB | Video |
| `ebml.ts` | `ebml.dart` | 🟡 v0.3 | 6.5 KB | EBML format |
| `overlay.ts` | `overlay.dart` | ⬜ Skip | 5.1 KB | Debug overlay |
| `recorder.ts` | ⬜ Skip | — | 22.6 KB | Codegen recorder |
| `debugController.ts` | ⬜ Skip | — | 8.8 KB | Debug controller |
| `debugger.ts` | ⬜ Skip | — | 5.5 KB | Debugger |
| `userAgent.ts` | `user_agent.dart` | 🟢 v0.1 | 3.1 KB | UA string |
| `usKeyboardLayout.ts` | `us_keyboard_layout.dart` | 🟢 v0.1 | 8.2 KB | Key definitions |
| `macEditingCommands.ts` | `mac_editing_commands.dart` | 🔵 v0.2 | 6.0 KB | Mac commands |
| `formData.ts` | `form_data.dart` | 🔵 v0.2 | 3.0 KB | Form data |
| `frameSelectors.ts` | `frame_selectors.dart` | 🟢 v0.1 | 10.9 KB | Frame selectors |
| `launchApp.ts` | ⬜ Skip | — | 5.1 KB | Desktop apps |
| `localUtils.ts` | `local_utils.dart` | 🔵 v0.2 | 9.7 KB | Local utils |
| `socksInterceptor.ts` | ⬜ Skip | — | 4.4 KB | SOCKS proxy |
| `socksClientCerts...ts` | ⬜ Skip | — | 22.5 KB | Client certs |
| `disposable.ts` | `disposable.dart` | 🟢 v0.1 | 1.3 KB | Disposable base |
| `callLog.ts` | `call_log.dart` | 🟢 v0.1 | 2.9 KB | Call logging |
| `console.ts` | `console.dart` | 🟢 v0.1 | 1.9 KB | Console |
| `index.ts` | ⬜ Skip | — | 1.8 KB | Barrel export |
| `utils.ts` | `utils.dart` | 🟢 v0.1 | 1.8 KB | Utilities |

---

## 6. server/chromium/ → playwright_core/lib/src/server/chromium/

| Arquivo TS | Arquivo Dart | Marco | Tamanho |
|---|---|---|---|
| `chromium.ts` | `chromium.dart` | 🟢 v0.1 | 24.2 KB |
| `chromiumSwitches.ts` | `chromium_switches.dart` | 🟢 v0.1 | 4.6 KB |
| `crBrowser.ts` | `cr_browser.dart` | 🟢 v0.1 | 24.4 KB |
| `crConnection.ts` | `cr_connection.dart` | 🟢 v0.1 | 9.3 KB |
| `crPage.ts` | `cr_page.dart` | 🟢 v0.1 | 53.6 KB |
| `crNetworkManager.ts` | `cr_network_manager.dart` | 🟢 v0.1 | 43.4 KB |
| `crInput.ts` | `cr_input.dart` | 🟢 v0.1 | 6.7 KB |
| `crExecutionContext.ts` | `cr_execution_context.dart` | 🟢 v0.1 | 6.1 KB |
| `crProtocolHelper.ts` | `cr_protocol_helper.dart` | 🟢 v0.1 | 4.4 KB |
| `crCoverage.ts` | `cr_coverage.dart` | 🔵 v0.2 | 10.3 KB |
| `crPdf.ts` | `cr_pdf.dart` | 🟡 v0.3 | 4.0 KB |
| `crDragDrop.ts` | `cr_drag_drop.dart` | 🔵 v0.2 | 5.2 KB |
| `crDevTools.ts` | ⬜ Skip | — | 3.7 KB |
| `crServiceWorker.ts` | `cr_service_worker.dart` | 🔵 v0.2 | 5.7 KB |
| `defaultFontFamilies.ts` | `default_font_families.dart` | 🟢 v0.1 | 4.1 KB |
| `protocol.d.ts` | `protocol.dart` (gerado) | 🟢 v0.1 | 823 KB |

---

## 7. server/firefox/ → playwright_core/lib/src/server/firefox/

| Arquivo TS | Arquivo Dart | Marco | Tamanho |
|---|---|---|---|
| `firefox.ts` | `firefox.dart` | 🟠 v0.4 | 5.5 KB |
| `ffBrowser.ts` | `ff_browser.dart` | 🟠 v0.4 | 18.6 KB |
| `ffConnection.ts` | `ff_connection.dart` | 🟠 v0.4 | 6.4 KB |
| `ffPage.ts` | `ff_page.dart` | 🟠 v0.4 | 27.6 KB |
| `ffNetworkManager.ts` | `ff_network_manager.dart` | 🟠 v0.4 | 11.5 KB |
| `ffInput.ts` | `ff_input.dart` | 🟠 v0.4 | 6.5 KB |
| `ffExecutionContext.ts` | `ff_execution_context.dart` | 🟠 v0.4 | 6.0 KB |
| `protocol.d.ts` | `protocol.dart` (gerado) | 🟠 v0.4 | 40.9 KB |

---

## 8. server/webkit/ → playwright_core/lib/src/server/webkit/

| Arquivo TS | Arquivo Dart | Marco | Tamanho |
|---|---|---|---|
| `webkit.ts` | `webkit.dart` | 🔴 v0.5 | 7.1 KB |
| `wkBrowser.ts` | `wk_browser.dart` | 🔴 v0.5 | 16.2 KB |
| `wkConnection.ts` | `wk_connection.dart` | 🔴 v0.5 | 6.4 KB |
| `wkPage.ts` | `wk_page.dart` | 🔴 v0.5 | 62.1 KB |
| `wkInput.ts` | `wk_input.dart` | 🔴 v0.5 | 6.3 KB |
| `wkExecutionContext.ts` | `wk_execution_context.dart` | 🔴 v0.5 | 5.9 KB |
| `wkInterceptableRequest.ts` | `wk_interceptable_request.dart` | 🔴 v0.5 | 8.1 KB |
| `wkProvisionalPage.ts` | `wk_provisional_page.dart` | 🔴 v0.5 | 5.0 KB |
| `wkWorkers.ts` | `wk_workers.dart` | 🔴 v0.5 | 4.4 KB |
| `protocol.d.ts` | `protocol.dart` (gerado) | 🔴 v0.5 | 312.2 KB |

---

## 9. server/registry/ → playwright_core/lib/src/registry/

| Arquivo TS | Arquivo Dart | Marco | Tamanho |
|---|---|---|---|
| `index.ts` | `registry.dart` | 🟢 v0.1 | 71.3 KB |
| `browserFetcher.ts` | `browser_fetcher.dart` | 🟢 v0.1 | 7.0 KB |
| `dependencies.ts` | `dependencies.dart` | 🔵 v0.2 | 16.9 KB |
| `nativeDeps.ts` | `native_deps.dart` | 🔵 v0.2 | 36.9 KB |
| `oopDownloadBrowserMain.ts` | ⬜ Skip | — | 5.2 KB |

---

## 10. server/dispatchers/ → playwright_core/lib/src/dispatchers/

| Arquivo TS | Arquivo Dart | Marco | Tamanho |
|---|---|---|---|
| `dispatcher.ts` | `dispatcher.dart` | 🟢 v0.1 | 18.1 KB |
| `playwrightDispatcher.ts` | `playwright_dispatcher.dart` | 🟢 v0.1 | 6.4 KB |
| `browserTypeDispatcher.ts` | `browser_type_dispatcher.dart` | 🟢 v0.1 | 3.4 KB |
| `browserDispatcher.ts` | `browser_dispatcher.dart` | 🟢 v0.1 | 7.2 KB |
| `browserContextDispatcher.ts` | `browser_context_dispatcher.dart` | 🟢 v0.1 | 26.7 KB |
| `pageDispatcher.ts` | `page_dispatcher.dart` | 🟢 v0.1 | 28.5 KB |
| `frameDispatcher.ts` | `frame_dispatcher.dart` | 🟢 v0.1 | 15.1 KB |
| `elementHandlerDispatcher.ts` | `element_handle_dispatcher.dart` | 🟢 v0.1 | 11.0 KB |
| `jsHandleDispatcher.ts` | `js_handle_dispatcher.dart` | 🟢 v0.1 | 4.8 KB |
| `networkDispatchers.ts` | `network_dispatchers.dart` | 🟢 v0.1 | 11.1 KB |
| `dialogDispatcher.ts` | `dialog_dispatcher.dart` | 🔵 v0.2 | 1.8 KB |
| `artifactDispatcher.ts` | `artifact_dispatcher.dart` | 🔵 v0.2 | 4.4 KB |
| `tracingDispatcher.ts` | `tracing_dispatcher.dart` | 🟡 v0.3 | 3.9 KB |
| `streamDispatcher.ts` | `stream_dispatcher.dart` | 🔵 v0.2 | 2.6 KB |
| `writableStreamDispatcher.ts` | `writable_stream_dispatcher.dart` | 🔵 v0.2 | 3.1 KB |
| `localUtilsDispatcher.ts` | `local_utils_dispatcher.dart` | 🔵 v0.2 | 7.9 KB |
| `disposableDispatcher.ts` | `disposable_dispatcher.dart` | 🟢 v0.1 | 1.3 KB |
| `cdpSessionDispatcher.ts` | `cdp_session_dispatcher.dart` | 🔵 v0.2 | 1.9 KB |
| `debugControllerDispatcher.ts` | ⬜ Skip | — | 3.6 KB |
| `debuggerDispatcher.ts` | ⬜ Skip | — | 2.7 KB |
| `jsonPipeDispatcher.ts` | `json_pipe_dispatcher.dart` | 🔵 v0.2 | 1.8 KB |
| `androidDispatcher.ts` | ⬜ Skip | — | 11.7 KB |
| `electronDispatcher.ts` | ⬜ Skip | — | 4.6 KB |
| `webSocketRouteDispatcher.ts` | `web_socket_route_dispatcher.dart` | 🔵 v0.2 | 8.6 KB |

---

## 11. Totais por Marco

| Marco | Arquivos | KB Estimado |
|---|---|---|
| 🟢 v0.1 | ~65 | ~1,200 KB |
| 🔵 v0.2 | ~30 | ~300 KB |
| 🟡 v0.3 | ~10 | ~80 KB |
| 🟠 v0.4 | ~8 | ~125 KB |
| 🔴 v0.5 | ~10 | ~435 KB |
| ⬜ Skip | ~15 | ~120 KB |
| **Total** | **~138** | **~2,260 KB** |

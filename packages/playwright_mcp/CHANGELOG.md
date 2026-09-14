# Changelog

## 0.1.0

First release.

### Protocol

- Dual-era Model Context Protocol server over stdio, speaking newline-delimited
  JSON-RPC 2.0.
- Modern revision `2026-07-28`: per-request protocol version in
  `params._meta`, the mandatory `server/discover` RPC, and
  `UnsupportedProtocolVersionError` (`-32022`) carrying the supported list.
- Legacy revisions `2025-11-25`, `2025-06-18`, `2025-03-26` and `2024-11-05`
  through the `initialize` handshake, echoing the client's version when it is
  supported and naming the server's newest otherwise.
- Consistent JSON-RPC error codes, and notifications that are never answered.
- A failing tool is reported as a tool result with `isError: true`, not as a
  transport error, so the model can read it and try again.

### Tools

Twenty-two tools: `browser_navigate`, `browser_navigate_back`,
`browser_navigate_forward`, `browser_snapshot`, `browser_click`,
`browser_type`, `browser_hover`, `browser_select_option`,
`browser_press_key`, `browser_file_upload`, `browser_handle_dialog`,
`browser_tab_list`, `browser_tab_new`, `browser_tab_select`,
`browser_tab_close`, `browser_take_screenshot`, `browser_pdf_save`,
`browser_console_messages`, `browser_network_requests`, `browser_evaluate`,
`browser_wait_for`, `browser_resize` and `browser_close`.

- `browser_snapshot` returns the page as roles, names and element references,
  computed by walking the DOM so it behaves the same on all three engines —
  `page.accessibilitySnapshot()` is only real on Chromium.
- Every element-targeting tool accepts `ref`, `selector`, or `role` plus
  `name`.
- Dialogs stay open until `browser_handle_dialog` answers them.

### Package

- A public library (`package:playwright_mcp/playwright_mcp.dart`) exposing the
  server, the session and the tool interface, so the server can be embedded
  and extended with your own tools.
- Protocol tests that run the server as a real process and speak JSON-RPC over
  the pipe, covering the handshake, modern negotiation, the error paths, and a
  full agent flow that drives a browser and asserts the click was trusted.

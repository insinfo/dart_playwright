# playwright_mcp

[![CI](https://github.com/insinfo/dart_playwright/actions/workflows/ci.yml/badge.svg)](https://github.com/insinfo/dart_playwright/actions/workflows/ci.yml)
[![AI Assisted](https://img.shields.io/badge/AI-Assisted-purple.svg)](https://github.com/insinfo/dart_playwright#how-this-package-was-built)

A [Model Context Protocol](https://modelcontextprotocol.io) server that gives
an agent a real browser — Chromium, Firefox or WebKit — through the Dart port
of [Playwright](https://pub.dev/packages/playwright).

No Node.js anywhere in the loop: the server, the browser drivers and the
protocol transports are all Dart.

## Run it

```bash
dart pub global activate playwright_mcp
dart pub global run playwright:playwright install chromium
playwright_mcp --browser chromium
```

It speaks newline-delimited JSON-RPC 2.0 over stdio. Point an MCP client at
it:

```json
{
  "mcpServers": {
    "playwright-dart": {
      "command": "playwright_mcp",
      "args": ["--browser", "chromium"]
    }
  }
}
```

`--browser` takes `chromium`, `firefox` or `webkit`; `--headed` shows the
window. The browser is launched lazily, on the first tool that needs a page,
so a client that only lists tools never starts one.

## Protocol

The server is **dual-era**, in the specification's terms:

- **Modern** clients (revision `2026-07-28`) declare the protocol version on
  every request, in `params._meta["io.modelcontextprotocol/protocolVersion"]`.
  `server/discover` — which servers MUST implement — reports the supported
  versions, the capabilities and the server identity. A version the server
  does not speak is refused with `UnsupportedProtocolVersionError` (code
  `-32022`), carrying `data.supported` and `data.requested` so the client can
  retry with a version both sides know.
- **Legacy** clients (`2025-11-25` and earlier) open with the `initialize`
  handshake. The reply echoes the client's version when it is supported, and
  otherwise names the server's newest handshake revision — a legacy client
  has no way to fall forward, so that message is the only diagnostic it gets.

Supported revisions: `2026-07-28`, `2025-11-25`, `2025-06-18`, `2025-03-26`,
`2024-11-05`.

Notifications are never answered, known or not. Requests carry consistent
JSON-RPC codes: `-32700` for unparseable input, `-32600` for a malformed
envelope, `-32601` for an unknown method or tool, `-32602` for malformed
params. A tool that *fails* is reported as a tool result with `isError: true`,
not as a transport error, so the model can read what went wrong and try
something else.

## Tools

Start with `browser_snapshot`. It returns the page as a tree of roles, names
and element references, and stamps each listed element so the other tools can
address it by `ref`:

```
url: https://example.com/
title: Example Domain

- heading "Example Domain" [ref=e1]
- paragraph "This domain is for use in illustrative examples..." [ref=e2]
- link "More information..." [ref=e3]
```

Every element-targeting tool accepts `ref`, or a CSS `selector`, or a `role`
plus an optional `name`.

| Tool | What it does |
| --- | --- |
| `browser_navigate` | Go to a URL, then snapshot |
| `browser_navigate_back` / `browser_navigate_forward` | Move through history |
| `browser_snapshot` | The page as roles, names and refs |
| `browser_click` | Click, with `button` and `doubleClick` |
| `browser_type` | Fill a field, optionally pressing Enter |
| `browser_hover` | Hover the pointer |
| `browser_select_option` | Choose options in a `<select>` |
| `browser_press_key` | A key or chord, e.g. `Control+A` |
| `browser_file_upload` | Point a file input at files on disk |
| `browser_handle_dialog` | Accept or dismiss an open dialog |
| `browser_tab_list` / `_new` / `_select` / `_close` | Work with tabs |
| `browser_take_screenshot` | The page, or one element |
| `browser_pdf_save` | Render to PDF (Chromium only) |
| `browser_console_messages` | Console output and uncaught errors |
| `browser_network_requests` | Network exchanges seen so far |
| `browser_evaluate` | Run JavaScript, when no other tool fits |
| `browser_wait_for` | Wait for text, an element state, or a delay |
| `browser_resize` | Resize the viewport |
| `browser_close` | Close the browser |

Actions go through the port's real actionability: an element is waited for
until it is visible, stable, enabled and actually reachable by a pointer, and
clicks and keystrokes are dispatched by the browser protocol, so the page sees
`event.isTrusted === true`.

Dialogs are **not** auto-dismissed here. When a page opens one, the tool that
triggered it says so and the dialog stays open until `browser_handle_dialog`
answers it — a modal blocks the page, and the agent should be the one to
decide. The flip side is that ignoring the message leaves the page blocked.

### What is not here

The upstream `@playwright/mcp` has roughly twenty-five tools. These are
missing, and why:

- **Tracing and video** — the port does not have them yet (milestone 3).
- **`browser_drag`** — needs native HTML5 drag interception, which the port
  does not do yet.
- **`browser_install`** — browser installation is `dart run playwright
  install`, deliberately kept outside the agent's reach.
- **Coverage, `browser_generate_playwright_test`, the vision/coordinate
  tools** — they depend on parts of the port that are not built yet
  (`Coverage`, a test runner).

### A caveat about the snapshot

`browser_snapshot` walks the DOM in the page rather than calling
`page.accessibilitySnapshot()`, because that one is backed by
`Accessibility.getFullAXTree` and only Chromium answers it properly — Firefox
and WebKit return a stub. Walking the DOM behaves the same on all three.

The role and name computation is pragmatic, not a full ARIA implementation: an
explicit `role` wins, then a small tag-to-role table covering the interactive
set, and the name comes from `aria-label`, a referenced or wrapping `<label>`,
`placeholder`, `alt`, `title`, or the element's own text. That is enough for an
agent to find and act on things. It is not an accessibility audit, and it
should not be used as one.

## Embed it

```dart
import 'package:playwright_mcp/playwright_mcp.dart';

Future<void> main() async {
  final server = PlaywrightMcpServer(
    session: BrowserSession(browserName: 'firefox'),
  );
  server.registerTool(MyTool());
  try {
    await server.serve();
  } finally {
    await server.dispose();
  }
}
```

`handleLine` and `handleMessage` are public too, so the server can be driven
over any transport, not only stdio.

## Maturity

This sits on `package:playwright`, which is at **milestone 3 of 5** of the
port and not at parity with Playwright for Node. Read [that package's
README](https://pub.dev/packages/playwright) for what is missing before you
build on this.

The protocol surface is covered by tests that run the server as a real
process and speak JSON-RPC over the pipe, including the version negotiation,
the error paths and a full agent flow that drives a browser.

## How this package was built

Parts of the code, the tests and the documentation were written with the help
of LLM tooling. Everything in the package goes through the test suite
(`dart test`), the analyzer (`dart analyze`) and `dart pub publish --dry-run`
before it lands, and the person who commits it is responsible for it. Treat the
disclosure as information about how the work was produced, not as a disclaimer
about its quality: the checks are the same either way, and so is the
accountability.

## License

Apache License 2.0. See `LICENSE`.

Part of a derivative work of [Playwright](https://github.com/microsoft/playwright),
Copyright (c) Microsoft Corporation, under Apache 2.0. This project is not
produced, endorsed or supported by Microsoft, and "Playwright" is their
trademark, used here only to say what this is compatible with. The Model
Context Protocol is a specification by Anthropic; this is an independent
implementation of it.

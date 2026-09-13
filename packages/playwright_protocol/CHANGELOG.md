# Changelog

## 0.1.0

First release, extracted as the shared bottom layer under `playwright`.

- Protocol request/response envelopes covering the flattened CDP `sessionId`
  and WebKit's `pageProxyId`.
- Error taxonomy under `PlaywrightException`.
- Ordered event emitter with `once` and `waitForEvent`, bridged to Dart
  broadcast streams that only register their underlying listener while
  somebody is subscribed.
- Viewport, load-state and wait-until types.

The API of this package is internal and will change without a major version
bump while the port matures.

// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/playwright-core/browsers.json

const browsersJsonString = '''
{
  "comment": "Browser versions compatible with Playwright Dart. Synced from microsoft/playwright.",
  "browsers": [
    {
      "name": "chromium",
      "revision": "1234",
      "installByDefault": true,
      "browserVersion": "151.0.7922.34",
      "title": "Chrome for Testing"
    },
    {
      "name": "chromium-headless-shell",
      "revision": "1234",
      "installByDefault": true,
      "browserVersion": "151.0.7922.34",
      "title": "Chrome Headless Shell"
    },
    {
      "name": "firefox",
      "revision": "1535",
      "installByDefault": true,
      "browserVersion": "152.0.4",
      "title": "Firefox"
    },
    {
      "name": "webkit",
      "revision": "2333",
      "installByDefault": true,
      "browserVersion": "26.5",
      "title": "WebKit"
    },
    {
      "name": "ffmpeg",
      "revision": "1011",
      "installByDefault": true
    }
  ]
}
''';

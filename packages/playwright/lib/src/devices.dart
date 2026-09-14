/// One entry of the device catalogue.
typedef DeviceDescriptor = ({
  String userAgent,
  ({int width, int height}) viewport,
  double deviceScaleFactor,
  bool isMobile,
  bool hasTouch,
  String defaultBrowserType,
});

/// Ready-made device emulation presets, used with `Browser.newContext`:
///
/// ```dart
/// final iPhone = devices['iPhone 15']!;
/// final context = await browser.newContext(
///   viewport: iPhone.viewport,
///   userAgent: iPhone.userAgent,
///   deviceScaleFactor: iPhone.deviceScaleFactor,
///   isMobile: iPhone.isMobile,
///   hasTouch: iPhone.hasTouch,
/// );
/// ```
///
/// **This is a subset.** Upstream ships 207 descriptors, generated from its
/// own device list; the ones here are the common desktop and mobile targets,
/// transcribed from `packages/isomorphic/deviceDescriptorsSource.json` of the
/// upstream project (Apache 2.0). `defaultBrowserType` says which engine the
/// preset was measured against — a WebKit descriptor driven by Chromium still
/// works, it just is not what upstream calibrated.
///
/// Emulation here is viewport, user agent, scale factor, mobile and touch. It
/// is not a device: it does not change the JavaScript engine, the font stack
/// or the network, and a site that sniffs beyond the user agent can still
/// tell.
const Map<String, DeviceDescriptor> devices = {
  'Desktop Chrome': (
    userAgent:
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36',
    viewport: (width: 1280, height: 720),
    deviceScaleFactor: 1,
    isMobile: false,
    hasTouch: false,
    defaultBrowserType: 'chromium',
  ),
  'Desktop Chrome HiDPI': (
    userAgent:
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36',
    viewport: (width: 1280, height: 720),
    deviceScaleFactor: 2,
    isMobile: false,
    hasTouch: false,
    defaultBrowserType: 'chromium',
  ),
  'Desktop Edge': (
    userAgent:
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36 Edg/140.0.0.0',
    viewport: (width: 1280, height: 720),
    deviceScaleFactor: 1,
    isMobile: false,
    hasTouch: false,
    defaultBrowserType: 'chromium',
  ),
  'Desktop Firefox': (
    userAgent:
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 14.0; rv:143.0) Gecko/20100101 '
        'Firefox/143.0',
    viewport: (width: 1280, height: 720),
    deviceScaleFactor: 1,
    isMobile: false,
    hasTouch: false,
    defaultBrowserType: 'firefox',
  ),
  'Desktop Safari': (
    userAgent:
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 '
        '(KHTML, like Gecko) Version/26.0 Safari/605.1.15',
    viewport: (width: 1280, height: 720),
    deviceScaleFactor: 2,
    isMobile: false,
    hasTouch: false,
    defaultBrowserType: 'webkit',
  ),
  'iPhone SE': (
    userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 '
        'Safari/604.1',
    viewport: (width: 320, height: 568),
    deviceScaleFactor: 2,
    isMobile: true,
    hasTouch: true,
    defaultBrowserType: 'webkit',
  ),
  'iPhone 12': (
    userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 '
        'Safari/604.1',
    viewport: (width: 390, height: 664),
    deviceScaleFactor: 3,
    isMobile: true,
    hasTouch: true,
    defaultBrowserType: 'webkit',
  ),
  'iPhone 13': (
    userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 '
        'Safari/604.1',
    viewport: (width: 390, height: 664),
    deviceScaleFactor: 3,
    isMobile: true,
    hasTouch: true,
    defaultBrowserType: 'webkit',
  ),
  'iPhone 14 Pro': (
    userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 '
        'Safari/604.1',
    viewport: (width: 393, height: 660),
    deviceScaleFactor: 3,
    isMobile: true,
    hasTouch: true,
    defaultBrowserType: 'webkit',
  ),
  'iPhone 15': (
    userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 '
        'Safari/604.1',
    viewport: (width: 393, height: 659),
    deviceScaleFactor: 3,
    isMobile: true,
    hasTouch: true,
    defaultBrowserType: 'webkit',
  ),
  'iPad (gen 7)': (
    userAgent:
        'Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) AppleWebKit/605.1.15 '
        '(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1',
    viewport: (width: 810, height: 1080),
    deviceScaleFactor: 2,
    isMobile: true,
    hasTouch: true,
    defaultBrowserType: 'webkit',
  ),
  'iPad Pro 11': (
    userAgent:
        'Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) AppleWebKit/605.1.15 '
        '(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1',
    viewport: (width: 834, height: 1194),
    deviceScaleFactor: 2,
    isMobile: true,
    hasTouch: true,
    defaultBrowserType: 'webkit',
  ),
  'Pixel 5': (
    userAgent: 'Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36',
    viewport: (width: 393, height: 727),
    deviceScaleFactor: 3,
    isMobile: true,
    hasTouch: true,
    defaultBrowserType: 'chromium',
  ),
  'Pixel 7': (
    userAgent: 'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36',
    viewport: (width: 412, height: 839),
    deviceScaleFactor: 2.625,
    isMobile: true,
    hasTouch: true,
    defaultBrowserType: 'chromium',
  ),
  'Galaxy S9+': (
    userAgent: 'Mozilla/5.0 (Linux; Android 9; SM-G965U) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36',
    viewport: (width: 320, height: 658),
    deviceScaleFactor: 4.5,
    isMobile: true,
    hasTouch: true,
    defaultBrowserType: 'chromium',
  ),
  'Galaxy Tab S4': (
    userAgent:
        'Mozilla/5.0 (Linux; Android 8.1.0; SM-T837A) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36',
    viewport: (width: 712, height: 1138),
    deviceScaleFactor: 2.25,
    isMobile: true,
    hasTouch: true,
    defaultBrowserType: 'chromium',
  ),
};

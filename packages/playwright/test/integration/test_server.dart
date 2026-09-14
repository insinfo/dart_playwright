import 'dart:async';
import 'dart:convert';
import 'dart:io';

class TestServer {
  final HttpServer _server;
  final int port;

  TestServer._(this._server) : port = _server.port;

  static Future<TestServer> start({int? port}) async {
    final server = await HttpServer.bind('127.0.0.1', port ?? 0);
    final testServer = TestServer._(server);

    server.listen((request) {
      testServer._handleRequest(request);
    });

    return testServer;
  }

  String url(String path) => 'http://127.0.0.1:$port$path';

  void _handleRequest(HttpRequest request) {
    final path = request.uri.path;

    // Responds only after a long delay; used to exercise goto timeouts.
    // Handled outside the try/finally so the response is not closed early.
    if (path == '/slow') {
      Future.delayed(const Duration(seconds: 5), () {
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          ..write('<html><body>slow</body></html>');
        request.response.close().catchError((_) {});
      });
      return;
    }

    // Echoes the request headers as JSON; used to prove setExtraHTTPHeaders
    // reaches the wire. Handled before the switch so the header map is read
    // from the live request.
    if (path == '/echo-headers') {
      final headers = <String, String>{};
      request.headers.forEach((name, values) {
        headers[name.toLowerCase()] = values.join(', ');
      });
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(headers));
      request.response.close().catchError((_) {});
      return;
    }

    // Echoes method, headers and body as JSON, so a test can prove what
    // actually reached the server after a route rewrote the request.
    if (path == '/echo-request') {
      final headers = <String, String>{};
      request.headers.forEach((name, values) {
        headers[name.toLowerCase()] = values.join(', ');
      });
      utf8.decoder.bind(request).join().then((body) {
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..headers.set('X-Echo', 'yes')
          ..write(jsonEncode({
            'method': request.method,
            'headers': headers,
            'body': body,
          }));
        request.response.close().catchError((_) {});
      });
      return;
    }

    // 302 to /redirect-end, for the redirect chain.
    if (path == '/redirect-start') {
      request.response
        ..statusCode = 302
        ..headers.set(HttpHeaders.locationHeader, '/redirect-end');
      request.response.close().catchError((_) {});
      return;
    }

    // A file the browser must download rather than render.
    if (path == '/download-file') {
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType('application', 'octet-stream')
        ..headers
            .set('Content-Disposition', 'attachment; filename="report.txt"')
        ..write('downloaded payload');
      request.response.close().catchError((_) {});
      return;
    }

    // Sets a session cookie, so an API request and a page can be shown to
    // share one jar.
    if (path == '/set-cookie') {
      request.response
        ..statusCode = 200
        ..headers.set('Set-Cookie', 'apitoken=abc123; Path=/')
        ..headers.contentType = ContentType.json
        ..write('{"ok":true}');
      request.response.close().catchError((_) {});
      return;
    }

    try {
      switch (path) {
        case '/hello':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write('<html><body><h1 id="hello">Hello</h1></body></html>');
          break;

        case '/init-probe':
          // Records what the init script left behind, read at three moments:
          // while <head> parses, while <body> parses, and after load. A page
          // script can only see a value an init script set if the init script
          // really ran first.
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write('''
              <html><head><script>
                window.__seenInHead = window.__seed;
              </script></head><body>
                <div id="out">nothing</div>
                <script>
                  window.__seenInBody = window.__seed;
                  document.getElementById('out').textContent =
                      String(window.__seed);
                </script>
              </body></html>
            ''');
          break;

        case '/init-frames':
          // A host page with one child frame, both loading /init-probe, so a
          // test can prove an init script reaches child frames too.
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write('''
              <html><head><script>
                window.__seenInHead = window.__seed;
              </script></head><body>
                <div id="out">host</div>
                <iframe id="child" name="init-child" src="/init-probe"
                        style="width:200px;height:80px"></iframe>
              </body></html>
            ''');
          break;

        case '/title':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write(
                '<html><head><title>Test Page Title</title></head><body></body></html>');
          break;

        case '/button':
          // __clicked records event.isTrusted so tests can prove the click
          // came from real protocol input, not a synthetic JS el.click().
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write('''
              <html><body>
                <button id="clickMe">Click</button>
                <script>
                  document.getElementById('clickMe').addEventListener('click', (e) => {
                    window.__clicked = e.isTrusted;
                  });
                </script>
              </body></html>
            ''');
          break;

        case '/input':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write('''
              <html><body>
                <input name="search" type="text" />
              </body></html>
            ''');
          break;

        case '/text':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write(
                '<html><body><div id="content">Hello, World!</div></body></html>');
          break;

        case '/delayed-element':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write('''
              <html><body>
                <script>
                  setTimeout(() => {
                    const el = document.createElement('div');
                    el.id = 'delayed';
                    el.textContent = 'Appeared!';
                    document.body.appendChild(el);
                  }, 500);
                </script>
              </body></html>
            ''');
          break;

        case '/form':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write('''
              <html><body>
                <input id="name" type="text" value="initial" data-role="field" />
                <input id="agree" type="checkbox" />
                <select id="color">
                  <option value="red">Red</option>
                  <option value="green">Green</option>
                </select>
                <div class="item">A</div>
                <div class="item">B</div>
                <div class="item">C</div>
                <div id="hidden" style="display:none">secret</div>
                <button id="btn" disabled>Disabled</button>
                <script>
                  document.getElementById('name').addEventListener('input', (e) => {
                    window.__inputTrusted = e.isTrusted;
                  });
                </script>
              </body></html>
            ''');
          break;

        case '/mouse':
          // Records dblclick and hover with isTrusted so tests can prove the
          // events came from real protocol input.
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write('''
              <html><body>
                <button id="target">Target</button>
                <div id="pad" style="position:fixed;left:0;top:150px;width:100px;height:100px;background:#eee"></div>
                <script>
                  const t = document.getElementById('target');
                  t.addEventListener('dblclick', (e) => {
                    window.__dblclicked = e.isTrusted;
                  });
                  t.addEventListener('mouseover', (e) => {
                    window.__hovered = e.isTrusted;
                  });
                  t.addEventListener('contextmenu', (e) => {
                    e.preventDefault();
                    window.__ctx = e.isTrusted && e.button === 2;
                  });
                  document.getElementById('pad').addEventListener('mousedown', (e) => {
                    window.__off = {x: e.offsetX, y: e.offsetY};
                  });
                </script>
              </body></html>
            ''');
          break;

        case '/keyboard':
          // Records keydown events and mirrors the input value so tests can
          // assert both real key events and inserted text.
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write('''
              <html><body>
                <input id="field" type="text" />
                <div id="log"></div>
                <script>
                  window.__keys = [];
                  const f = document.getElementById('field');
                  f.addEventListener('keydown', (e) => {
                    window.__keys.push(e.key);
                    document.getElementById('log').textContent = window.__keys.join(',');
                  });
                </script>
              </body></html>
            ''');
          break;

        case '/dialog':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write('''
              <html><body>
                <div id="result">pending</div>
                <script>
                  window.runPrompt = () => {
                    const answer = prompt('Your name?', 'default');
                    document.getElementById('result').textContent = 'got:' + answer;
                  };
                  window.runConfirm = () => {
                    const ok = confirm('Proceed?');
                    document.getElementById('result').textContent = 'confirm:' + ok;
                  };
                </script>
              </body></html>
            ''');
          break;

        case '/drag':
          // Pointer-based drag (mousedown/mousemove/mouseup), which is what
          // modern drag libraries listen to. Native HTML5 drag-and-drop needs
          // protocol-level drag interception and is not covered here.
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write("""
              <html><body style="margin:0">
                <div id="source" style="position:fixed;left:10px;top:10px;width:50px;height:50px;background:#c00"></div>
                <div id="target" style="position:fixed;left:200px;top:200px;width:80px;height:80px;background:#0c0"></div>
                <div id="tall" style="height:3000px"></div>
                <script>
                  window.__moves = 0;
                  window.__downTrusted = false;
                  window.__overTarget = false;
                  window.__dropped = false;
                  document.getElementById('source').addEventListener('mousedown', (e) => {
                    window.__downTrusted = e.isTrusted;
                  });
                  document.addEventListener('mousemove', () => { window.__moves++; });
                  const t = document.getElementById('target');
                  t.addEventListener('mousemove', () => { window.__overTarget = true; });
                  t.addEventListener('mouseup', (e) => { window.__dropped = e.isTrusted; });
                </script>
              </body></html>
            """);
          break;

        case '/semantics':
          // Exercises the getBy* engines: roles, accessible names from
          // labels, whitespace that needs normalising, and the attribute
          // engines behind placeholder/alt/title/testid.
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write("""
              <html><head><title>Semantics</title></head><body>
                <h1>Pagina de semantica</h1>
                <h2>Secao dois</h2>
                <nav aria-label="Principal"><a href="/hello">Ir para hello</a></nav>
                <button id="save">Save</button>
                <button id="saveDraft">Save draft</button>
                <button id="close" aria-label="Fechar">x</button>
                <label for="user">Username</label>
                <input id="user" type="text" />
                <label>Password <input id="pass" type="password" /></label>
                <input id="search" type="search" placeholder="Search here" />
                <img id="cat" alt="A cat" width="20" height="20"
                     src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7" />
                <span id="tip" title="Tooltip text">hover me</span>
                <button data-testid="submit">Enviar</button>
                <input id="agree" type="checkbox" checked />
                <input id="news" type="checkbox" />
                <div id="spaced">Hello
                       world</div>
                <ul>
                  <li class="row">Alpha</li>
                  <li class="row">Beta</li>
                  <li class="row">Gamma</li>
                </ul>
                <button id="disabledBtn" disabled>Disabled action</button>
                <script>
                  document.getElementById('save').addEventListener('click', (e) => {
                    window.__savedTrusted = e.isTrusted;
                  });
                </script>
              </body></html>
            """);
          break;

        case '/late':
          // The button only appears after a delay, and only becomes stable
          // after a short animation: exercises auto-waiting.
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write("""
              <html><body>
                <div id="slot"></div>
                <script>
                  setTimeout(() => {
                    const button = document.createElement('button');
                    button.id = 'later';
                    button.textContent = 'Later';
                    button.style.position = 'relative';
                    button.style.left = '0px';
                    button.addEventListener('click', (e) => {
                      window.__lateClicked = e.isTrusted;
                      const r = button.getBoundingClientRect();
                      window.__lateLeft = r.left;
                      // Did the click land on the button where it is *now*?
                      // That is what waiting for stability buys: a click aimed
                      // at a stale position would miss.
                      window.__lateHit = e.clientX >= r.left && e.clientX <= r.right &&
                          e.clientY >= r.top && e.clientY <= r.bottom;
                    });
                    document.getElementById('slot').appendChild(button);
                    let left = 0;
                    const move = setInterval(() => {
                      left += 20;
                      button.style.left = left + 'px';
                      if (left >= 60) clearInterval(move);
                    }, 40);
                  }, 400);
                </script>
              </body></html>
            """);
          break;

        case '/frames':
          // Two sibling frames plus a nested one, so tests can exercise frame
          // trees, per-frame execution contexts and FrameLocator chains.
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write("""
              <html><head><title>Frames Host</title></head><body>
                <h1 id="host">Host page</h1>
                <iframe id="one" name="frame-one" src="/frame-one" style="width:300px;height:120px;border:2px solid black"></iframe>
                <iframe id="two" name="frame-two" src="/frame-two" style="width:300px;height:120px"></iframe>
              </body></html>
            """);
          break;

        case '/frame-one':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write("""
              <html><head><title>Frame One</title></head><body style="margin:0">
                <div id="label">inside frame one</div>
                <input id="field" type="text" />
                <button id="go">Go one</button>
                <iframe id="deep" name="frame-deep" src="/frame-nested" style="width:200px;height:60px;border:0"></iframe>
                <script>
                  document.getElementById('go').addEventListener('click', (e) => {
                    window.__clickedInFrame = e.isTrusted;
                  });
                  document.getElementById('field').addEventListener('input', (e) => {
                    window.__inputInFrame = e.isTrusted;
                  });
                </script>
              </body></html>
            """);
          break;

        case '/frame-two':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write("""
              <html><head><title>Frame Two</title></head><body style="margin:0">
                <div id="label">inside frame two</div>
              </body></html>
            """);
          break;

        case '/frame-nested':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write("""
              <html><head><title>Frame Nested</title></head><body style="margin:0">
                <div id="label">deeply nested</div>
                <button id="deepButton">Deep</button>
                <script>
                  document.getElementById('deepButton').addEventListener('click', (e) => {
                    window.__deepClicked = e.isTrusted;
                  });
                </script>
              </body></html>
            """);
          break;

        case '/empty-frame':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write("""
              <html><head><title>Empty Frame Host</title></head><body>
                <iframe id="target" src="/frame-two"></iframe>
              </body></html>
            """);
          break;

        // Opens a popup via window.open and via a target=_blank link.
        case '/popup':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write("""
              <html><head><title>Popup Host</title></head><body>
                <a id="link" href="/popup-target" target="_blank">open</a>
                <button id="open" onclick="window.open('/popup-target')">open</button>
              </body></html>
            """);
          break;

        case '/popup-target':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write(
                '<html><head><title>Popup Target</title></head><body><h1 id="popup">I am a popup</h1></body></html>');
          break;

        // console.* on demand, so a test can start listening first.
        case '/console':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write("""
              <html><body>
                <script>
                  window.emitLog = () => console.log('hello', 42);
                  window.emitWarning = () => console.warn('watch out');
                  window.emitError = () => console.error('it broke');
                </script>
              </body></html>
            """);
          break;

        // Throws an uncaught error on demand.
        case '/pageerror':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write("""
              <html><body>
                <script>
                  window.boom = () => { setTimeout(() => { throw new TypeError('kaboom'); }, 0); };
                </script>
              </body></html>
            """);
          break;

        // A button fully covered by an overlay: clicking it must be refused,
        // not silently delivered to the overlay.
        case '/occluded':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write("""
              <html><body style="margin:0">
                <button id="target" style="position:absolute; left:20px; top:20px; width:200px; height:60px;"
                        onclick="window.__hit = true">Click me</button>
                <div id="overlay" style="position:absolute; left:0; top:0; width:400px; height:200px; background:rgba(0,0,0,0.4)"></div>
                <script>
                  window.__hit = false;
                  window.uncover = () => document.getElementById('overlay').remove();
                </script>
              </body></html>
            """);
          break;

        case '/redirect-end':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write('<html><body><h1 id="arrived">arrived</h1></body></html>');
          break;

        // A page with a stylesheet and an image, so resourceType has
        // something other than "document" to report.
        case '/resources':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write("""
              <html><head><link rel="stylesheet" href="/style.css"></head>
              <body><p id="styled">styled</p></body></html>
            """);
          break;

        // A page with one external script and one external stylesheet, both
        // half used, so a coverage run has something to report that is not
        // trivially all-or-nothing.
        case '/coverage':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write('''
              <html><head><link rel="stylesheet" href="/coverage.css"></head>
              <body>
                <p id="used">used</p>
                <script src="/coverage.js"></script>
              </body></html>
            ''');
          break;

        case '/coverage.js':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType('application', 'javascript')
            ..write('''
function usedFunction() {
  window.__coverageMark = 'ran';
  return 1;
}
function neverCalledFunction() {
  window.__neverHappens = 'this line is never reached at all';
  return 2;
}
usedFunction();
''');
          break;

        case '/coverage.css':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType('text', 'css')
            ..write('#used { color: rgb(1, 2, 3); }\n'
                '#missing { color: rgb(4, 5, 6); background: rgb(7, 8, 9); }\n');
          break;

        case '/style.css':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType('text', 'css')
            ..write('#styled { color: rgb(1, 2, 3); }');
          break;

        // A file input plus a button that opens the chooser for it.
        case '/upload':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write("""
              <html><body>
                <input id="upload" type="file">
                <input id="uploadMany" type="file" multiple>
                <button id="pick" onclick="document.getElementById('upload').click()">Pick</button>
                <script>
                  window.names = (id) => Array.from(
                      document.getElementById(id).files).map(f => f.name).join(',');
                </script>
              </body></html>
            """);
          break;

        // Tall enough that a full-page shot is clearly bigger than the
        // viewport, with a known box to clip and to shoot by element.
        case '/tall':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write("""
              <html><body style="margin:0; height:3000px; background:linear-gradient(white, black)">
                <div id="box" style="position:absolute; left:10px; top:20px;
                     width:120px; height:60px; background:rgb(0,128,0)"></div>
              </body></html>
            """);
          break;

        case '/download':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write(
                '<html><body><a id="grab" href="/download-file" download="report.txt">Grab</a></body></html>');
          break;

        // A touch target that records event.isTrusted, so a tap can be
        // proven to have come from the protocol.
        case '/touch':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write("""
              <html><body style="margin:0">
                <div id="pad" style="width:200px; height:200px; background:#eee"></div>
                <script>
                  window.__tapped = false;
                  document.getElementById('pad').addEventListener('touchend',
                      (e) => { window.__tapped = e.isTrusted; });
                </script>
              </body></html>
            """);
          break;

        case '/visual':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write(
                '<html><body style="background: red;"><h1>Red Page</h1></body></html>');
          break;

        // Repinta sozinha, para os testes de screencast. Chromium e WebKit so
        // mandam quadro quando a pagina pinta: numa pagina parada a gravacao
        // fica em silencio e nao da para distinguir isso de um ack faltando.
        case '/animated':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write("""
              <html><body style="margin:0;background:#fff">
                <div id="box" style="width:200px;height:200px;background:#f00"></div>
                <script>
                  let tick = 0;
                  const box = document.getElementById('box');
                  function paint() {
                    tick = (tick + 11) % 256;
                    box.style.background = 'rgb(' + tick + ',' + (255 - tick) + ',128)';
                    box.style.width = (100 + (tick % 100)) + 'px';
                    requestAnimationFrame(paint);
                  }
                  requestAnimationFrame(paint);
                </script>
              </body></html>
            """);
          break;

        default:
          request.response
            ..statusCode = 404
            ..write('Not found');
      }
    } catch (e) {
      print('TestServer error handling path $path: $e');
    } finally {
      request.response.close().catchError((_) {});
    }
  }

  Future<void> stop() async {
    await _server.close(force: true);
  }
}

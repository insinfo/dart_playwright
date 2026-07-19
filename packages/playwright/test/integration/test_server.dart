import 'dart:io';
import 'dart:async';

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

    try {
      switch (path) {
        case '/hello':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write('<html><body><h1 id="hello">Hello</h1></body></html>');
          break;
        
        case '/title':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write('<html><head><title>Test Page Title</title></head><body></body></html>');
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
            ..write('<html><body><div id="content">Hello, World!</div></body></html>');
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

        case '/visual':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write('<html><body style="background: red;"><h1>Red Page</h1></body></html>');
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

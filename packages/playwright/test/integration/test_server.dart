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

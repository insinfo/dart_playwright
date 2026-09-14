import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Um app com login, para exercitar fixtures e `storageState` como um app web
/// de verdade: sessao por cookie, um token no localStorage, e um contador de
/// logins que prova quantas vezes o login realmente aconteceu.
class AppServer {
  final HttpServer _server;
  final int port;

  /// Quantas vezes `/session` foi chamado. E o que prova que o segundo teste
  /// pulou o login em vez de so ter passado.
  int logins = 0;

  AppServer._(this._server) : port = _server.port;

  static Future<AppServer> start() async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    final app = AppServer._(server);
    server.listen(app._handle);
    return app;
  }

  String url(String path) => 'http://127.0.0.1:$port$path';

  Future<void> stop() => _server.close(force: true);

  bool _isLoggedIn(HttpRequest request) => request.cookies
      .any((cookie) => cookie.name == 'session' && cookie.value == 'ok');

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;

    void html(String body, {int status = 200}) {
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.html
        ..write('<!doctype html><html><body>$body</body></html>');
    }

    switch (path) {
      case '/login':
        html('''
          <h1>Entrar</h1>
          <form id="form" method="POST" action="/session">
            <input id="user" name="user">
            <input id="pass" name="pass" type="password">
            <button id="entrar" type="submit">Entrar</button>
          </form>
        ''');
        break;

      case '/session':
        logins++;
        await utf8.decoder.bind(request).join();
        request.response
          ..statusCode = 302
          ..cookies.add(Cookie('session', 'ok')
            ..path = '/'
            ..maxAge = 3600)
          ..headers.set(HttpHeaders.locationHeader, '/painel');
        break;

      case '/painel':
        if (!_isLoggedIn(request)) {
          html('<p id="nao-logado">Faca login</p>', status: 401);
          break;
        }
        html('''
          <h1 id="bemvindo">Painel</h1>
          <button id="sair">Sair</button>
          <script>localStorage.setItem('token', 'abc-123');</script>
        ''');
        break;

      case '/token':
        // Mostra o que ha no localStorage desta origem, para provar que o
        // storageState trouxe o localStorage junto com os cookies.
        html('''
          <p id="token"></p>
          <script>
            document.getElementById('token').textContent =
                localStorage.getItem('token') || '(vazio)';
          </script>
        ''');
        break;

      case '/logins':
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'logins': logins}));
        break;

      case '/widgets':
        html('''
          <style>
            #pintado { color: rgb(0, 128, 0); padding-left: 7px; }
            #rolagem { height: 60px; overflow-y: scroll; }
            #dentro { height: 20px; }
            #fora { height: 400px; }
          </style>
          <p id="pintado">pintado</p>
          <input id="campo" value="inicial">
          <select id="cores" multiple>
            <option value="vermelho" selected>Vermelho</option>
            <option value="verde">Verde</option>
            <option value="azul" selected>Azul</option>
          </select>
          <select id="unico"><option value="a" selected>A</option></select>
          <button id="salvar" aria-describedby="ajuda">Salvar</button>
          <span id="ajuda">Grava e fecha</span>
          <button id="com-title" title="Dica curta">Com title</button>
          <div id="papel" role="alert">Aviso</div>
          <div id="rolagem">
            <div id="dentro">dentro</div>
            <div id="fora">fora</div>
          </div>
          <div id="marcado" data-estado="pronto">marcado</div>
          <div id="abaixo" style="margin-top: 3000px">abaixo</div>
        ''');
        break;

      default:
        html('<p id="nada">nada</p>', status: 404);
    }

    await request.response.close().catchError((_) {});
  }
}

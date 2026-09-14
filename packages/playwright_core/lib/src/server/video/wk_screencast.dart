import 'dart:convert';

import '../webkit/wk_page.dart';
import 'page_screencast.dart';

/// Screencast do WebKit.
///
/// O dominio `Screencast` vive na sessao do pageProxy, nao na do target, e
/// `Screencast.startScreencast` devolve uma `generation` que todo ack tem de
/// repetir. A generation e o que faz o WebKit descartar o ack de um
/// screencast anterior: sem ela, um start/stop/start rapido reconheceria
/// quadros da gravacao errada e a nova travaria no primeiro quadro.
///
/// Nao ha `Screencast.startVideo` neste protocolo: no WebKit 26.5 que este
/// porte baixa o comando responde `'Screencast.startVideo' was not found`.
/// Por isso [kind] aqui e [ScreencastKind.frames], como nos outros dois.
class WkScreencast extends FramesScreencast {
  final WkPage _page;

  /// Zero ate o `startScreencast` responder; nenhum quadro chega antes disso.
  int _generation = 0;

  WkScreencast(this._page) : super(_page);

  @override
  void attachFrameListener() {
    _page.session.on('Screencast.screencastFrame', _onFrame);
    _page.session.on('closed', _onSessionGone);
  }

  @override
  void detachFrameListener() {
    _page.session.off('Screencast.screencastFrame', _onFrame);
    _page.session.off('closed', _onSessionGone);
  }

  @override
  Future<void> startEngine(int width, int height, int quality) async {
    try {
      final result = await _page.session.send('Screencast.startScreencast', {
        'width': width,
        'height': height,
        // Upstream so manda altura de barra de ferramentas no WebKit headful
        // do macOS (59, ou 69 no macOS 26), para descontar a moldura da
        // janela. Headless e qualquer outra plataforma nao tem barra.
        'toolbarHeight': 0,
        'quality': quality,
      }).timeout(const Duration(seconds: 5));
      _generation = (result['generation'] as num?)?.toInt() ?? 0;
    } catch (_) {
      // A pagina pode ter fechado no meio do start.
    }
  }

  @override
  Future<void> stopEngine() => _sendMayFail('Screencast.stopScreencast');

  void _onSessionGone([dynamic _]) => onSessionClosed();

  void _onFrame(dynamic params) {
    final frame = params as Map<String, dynamic>;
    final data = frame['data'] as String?;
    final generation = _generation;
    void ack() =>
        _sendMayFail('Screencast.screencastFrameAck', {'generation': generation});
    if (data == null) {
      ack();
      return;
    }
    deliverFrame(base64Decode(data),
        engineSeconds: (frame['timestamp'] as num?)?.toDouble(), ack: ack);
  }

  Future<void> _sendMayFail(String method, [Map<String, dynamic>? params]) =>
      sendMayFail(() async {
        await _page.session.send(method, params);
      });
}

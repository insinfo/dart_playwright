import 'dart:convert';

import '../firefox/ff_page.dart';
import 'page_screencast.dart';

/// Screencast do Firefox, via Juggler.
///
/// `Page.startScreencast` toma `width`, `height` e `quality` — nao ha campo
/// de formato: o Juggler sempre entrega JPEG (medido: `FF D8`, 640x480 para
/// 640x480 pedidos num viewport 800x600). O ack e `Page.screencastFrameAck`
/// sem parametro nenhum: o Juggler so tem um screencast por sessao, entao
/// nao ha o que identificar.
class FfScreencast extends FramesScreencast {
  final FfPage _page;

  FfScreencast(this._page) : super(_page);

  @override
  void attachFrameListener() {
    _page.session.on('Page.screencastFrame', _onFrame);
    _page.session.on('closed', _onSessionGone);
  }

  @override
  void detachFrameListener() {
    _page.session.off('Page.screencastFrame', _onFrame);
    _page.session.off('closed', _onSessionGone);
  }

  @override
  Future<void> startEngine(int width, int height, int quality) {
    return _sendMayFail('Page.startScreencast',
        {'width': width, 'height': height, 'quality': quality});
  }

  @override
  Future<void> stopEngine() => _sendMayFail('Page.stopScreencast');

  void _onSessionGone([dynamic _]) => onSessionClosed();

  void _onFrame(dynamic params) {
    final frame = params as Map<String, dynamic>;
    final data = frame['data'] as String?;
    void ack() => _sendMayFail('Page.screencastFrameAck');
    if (data == null) {
      ack();
      return;
    }
    // `timestamp` aqui e monotonico em segundos desde o inicio do processo do
    // navegador, nao a epoch; so a diferenca entre quadros e usada.
    deliverFrame(base64Decode(data),
        engineSeconds: (frame['timestamp'] as num?)?.toDouble(), ack: ack);
  }

  Future<void> _sendMayFail(String method, [Map<String, dynamic>? params]) =>
      sendMayFail(() async {
        await _page.session.send(method, params);
      });
}

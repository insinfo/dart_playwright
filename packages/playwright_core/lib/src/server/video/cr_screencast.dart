import 'dart:convert';

import '../chromium/cr_page.dart';
import 'page_screencast.dart';

/// Screencast do Chromium, via CDP.
///
/// `Page.startScreencast` pede `format`, `quality`, `maxWidth` e `maxHeight`;
/// o quadro que volta cabe dentro desse retangulo mantendo a proporcao do
/// viewport. Com viewport 800x600 e 640x480 pedidos, medido: JPEG 640x480.
class CrScreencast extends FramesScreencast {
  final CrPage _page;

  CrScreencast(this._page) : super(_page);

  dynamic get _session => _page.session;

  @override
  void attachFrameListener() {
    _session.on('Page.screencastFrame', _onFrame);
    _session.on('closed', _onSessionGone);
  }

  @override
  void detachFrameListener() {
    _session.off('Page.screencastFrame', _onFrame);
    _session.off('closed', _onSessionGone);
  }

  @override
  Future<void> startEngine(int width, int height, int quality) async {
    // JPEG e nao PNG: o ffmpeg que a Playwright publica so traz os decoders
    // mjpeg e libvpx, entao um quadro PNG nao entra no encoder do video.
    await _sendMayFail('Page.startScreencast', {
      'format': 'jpeg',
      'quality': quality,
      'maxWidth': width,
      'maxHeight': height,
    });
  }

  @override
  Future<void> stopEngine() => _sendMayFail('Page.stopScreencast');

  void _onSessionGone([dynamic _]) => onSessionClosed();

  void _onFrame(dynamic params) {
    final frame = params as Map<String, dynamic>;
    final data = frame['data'] as String?;
    final sessionId = frame['sessionId'];
    final metadata = frame['metadata'] as Map<String, dynamic>?;
    // O ack tem de sair mesmo para um quadro que nao da para usar: o CDP para
    // de mandar quadro nenhum enquanto o ultimo nao for reconhecido.
    void ack() {
      _sendMayFail('Page.screencastFrameAck',
          {if (sessionId != null) 'sessionId': sessionId});
    }

    if (data == null) {
      ack();
      return;
    }
    deliverFrame(base64Decode(data),
        engineSeconds: (metadata?['timestamp'] as num?)?.toDouble(), ack: ack);
  }

  Future<void> _sendMayFail(String method, [Map<String, dynamic>? params]) =>
      sendMayFail(() async {
        await _session.send(method, params);
      });
}

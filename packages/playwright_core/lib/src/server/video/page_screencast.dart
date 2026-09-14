import 'dart:async';
import 'dart:typed_data';

import '../core_page.dart';
import 'image_size.dart';
import 'video_frame.dart';

/// O WebKit não entrega quadros: o domínio `Screencast` dele grava direto
/// num arquivo. Quem consome precisa saber disso, então está no contrato em
/// vez de escondido atrás de um Stream que nunca emite.
///
/// Correcao medida contra o WebKit 26.5 que este porte baixa: aquele
/// `Screencast.startVideo` nao existe mais — o comando responde
/// `'Screencast.startVideo' was not found`. O dominio hoje e
/// `Screencast.startScreencast`/`stopScreencast`, com evento
/// `Screencast.screencastFrame` e ack por `generation`, igual em espirito ao
/// Chromium e ao Firefox. Ou seja: os tres motores sao
/// [ScreencastKind.frames] e nenhuma implementacao devolve
/// [ScreencastKind.directFile] hoje. O valor fica no contrato porque o
/// contrato e fixo e porque gravar direto em arquivo pode voltar, mas
/// ninguem deve escrever codigo novo assumindo que algum motor o devolve.
enum ScreencastKind { frames, directFile }

abstract class PageScreencast {
  ScreencastKind get kind;
  Future<void> start(
      {required int width, required int height, int quality = 90});

  /// Só quando [kind] é [ScreencastKind.frames].
  ///
  /// **Assinatura unica, de proposito.** Nao e broadcast e nao pode virar:
  /// o ack do protocolo e a contrapressao da gravacao, e so da para segurar o
  /// ack enquanto *o* consumidor esta pausado se houver um consumidor so.
  /// Num broadcast, um assinante lento nao pausa nada — os quadros se
  /// acumulariam na memoria sem limite e ninguem perceberia. Uma segunda
  /// chamada a `listen` lanca `Bad state: Stream has already been listened
  /// to`, entao quem precisa de dois consumidores (video e filmstrip, por
  /// exemplo) assina uma vez e reparte por conta propria.
  ///
  /// O stream fecha quando [stop] e chamado, quando a pagina fecha ou crasha,
  /// e quando a sessao do motor cai — nunca fica aberto esperando quadro que
  /// nao vem mais.
  Stream<VideoFrame> get frames;

  /// Caminho do arquivo produzido; só quando [kind] é
  /// [ScreencastKind.directFile].
  ///
  /// Em [ScreencastKind.frames] `stop` continua sendo o jeito de desligar a
  /// gravacao e fechar [frames], e devolve string vazia — vazio aqui quer
  /// dizer "nao ha arquivo", nao "o arquivo tem nome vazio". Um
  /// `Future<String?>` diria isso melhor, mas o tipo e parte do contrato
  /// fixo; trocar depois e mecanico.
  Future<String> stop();
}

/// O que os tres motores tem em comum.
///
/// A diferenca entre eles cabe em tres pontos — o comando que liga, o nome do
/// evento de quadro e a forma do ack — e fica nas subclasses. Contrapressao,
/// ciclo de vida da pagina e relogio sao iguais e ficam aqui, porque errar
/// qualquer um deles trava o consumidor de um jeito que so aparece depois de
/// dezenas de quadros.
abstract class FramesScreencast implements PageScreencast {
  final CorePage page;

  late final StreamController<VideoFrame> _controller;

  /// Acks retidos enquanto ninguem esta consumindo.
  ///
  /// O ack e a valvula de contrapressao do protocolo: os tres motores so
  /// mandam o proximo quadro depois de receber o ack do anterior (medido:
  /// sem ack, 3 quadros no Chromium, 2 no WebKit e 1 no Firefox em 3s, contra
  /// 92/53/62 com ack). Segurar o ack enquanto a assinatura esta pausada e o
  /// que impede um `await for` lento de acumular quadros na memoria sem
  /// limite — o Stream do Dart bufferiza calado, o protocolo nao.
  final _heldAcks = <void Function()>[];

  bool _started = false;
  bool _stopped = false;

  /// Instante do [start], para dar a [VideoFrame.timestamp] uma origem que e
  /// o inicio da gravacao e nao o primeiro quadro.
  DateTime? _startedAt;
  DateTime? _firstFrameAt;
  double? _firstEngineSeconds;
  Duration _firstFrameOffset = Duration.zero;

  /// O ultimo carimbo entregue, para que o proximo nunca seja menor.
  Duration _lastTimestamp = Duration.zero;

  FramesScreencast(this.page) {
    _controller = StreamController<VideoFrame>(
      // Um assinante novo (ou que voltou de uma pausa) libera os acks presos,
      // que e o que faz o motor voltar a mandar quadro.
      onListen: _releaseHeldAcks,
      onResume: _releaseHeldAcks,
      onCancel: () {
        // Quem cancelou a assinatura nao quer mais quadros; deixar o motor
        // gravando gastaria CPU do navegador ate a pagina fechar.
        _stopQuietly();
      },
    );
    page.on('close', _onPageGone);
    // Um renderer morto nao volta a pintar. Upstream trata crash e close pelo
    // mesmo caminho (`_didDisconnect` -> `screencast.dispose()`), e a razao e
    // a mesma: um Stream que nunca fecha trava quem espera por ele.
    page.on('crash', _onPageGone);
  }

  @override
  ScreencastKind get kind => ScreencastKind.frames;

  @override
  Stream<VideoFrame> get frames => _controller.stream;

  @override
  Future<void> start(
      {required int width, required int height, int quality = 90}) async {
    if (_stopped) {
      throw StateError('Screencast ja parado; crie outro para gravar de novo');
    }
    if (_started) throw StateError('Screencast ja iniciado');
    _started = true;
    // A pagina pode ter fechado entre a criacao e o start. Fechar o stream
    // aqui e o que diferencia "nao vai vir quadro" de "espere para sempre".
    if (page.isClosed) {
      await stop();
      return;
    }
    _startedAt = DateTime.now();
    // Upstream arredonda para baixo em ambos os eixos antes de falar com o
    // motor (screencast.ts): o vp8 so aceita dimensoes pares, e descobrir
    // isso no encoder, quadros depois, custa caro.
    final evenWidth = width & ~1;
    final evenHeight = height & ~1;
    attachFrameListener();
    await startEngine(evenWidth, evenHeight, quality);
  }

  @override
  Future<String> stop() async {
    if (_stopped) return '';
    _stopped = true;
    page.off('close', _onPageGone);
    page.off('crash', _onPageGone);
    detachFrameListener();
    // Solta o que estiver preso: o motor pode estar esperando um ack que
    // ninguem mais vai mandar.
    _releaseHeldAcks();
    // O stream fecha antes de falar com o motor, e sem await. Duas razoes,
    // as duas medidas: depois de um crash do renderer o `stopScreencast` fica
    // sem resposta para sempre, e com a assinatura pausada — que e o estado
    // de quem chama stop() de dentro do corpo de um `await for` — o future de
    // close() so completa quando o corpo retorna. Nos dois casos, esperar
    // aqui prenderia justamente quem so queria saber que acabou.
    unawaited(_controller.close());
    if (_started) await stopEngine();
    return '';
  }

  // ------------------------------------------------------------- subclasses

  /// Liga o screencast no motor. Ja recebe dimensoes pares.
  Future<void> startEngine(int width, int height, int quality);

  /// Desliga o screencast no motor. Nunca deve lancar: a pagina pode ja ter
  /// ido embora, e parar e justamente o caminho de limpeza.
  Future<void> stopEngine();

  /// Registra o ouvinte do evento de quadro do motor, e o que mais a subclasse
  /// precisar para saber que a sessao caiu.
  void attachFrameListener();

  void detachFrameListener();

  // ------------------------------------------------------------- protegidos

  /// Entrega um quadro recebido do motor.
  ///
  /// [engineSeconds] e o carimbo do motor em segundos; so a diferenca entre
  /// quadros e usada, entao nao importa se a origem e a epoch (Chromium,
  /// WebKit) ou o inicio do processo (Firefox). [ack] e o que destrava o
  /// proximo quadro e tem de ser chamado exatamente uma vez, inclusive
  /// quando o quadro e descartado.
  void deliverFrame(Uint8List data,
      {double? engineSeconds, required void Function() ack}) {
    if (_stopped || _controller.isClosed) {
      ack();
      return;
    }
    final size = ImageSize.parse(data);
    if (size == null) {
      // Um quadro que nao e nem PNG nem JPEG nao serve para ninguem, mas
      // engolir o ack junto pararia a gravacao inteira por causa de um quadro.
      ack();
      return;
    }
    _controller.add(VideoFrame(
      data: data,
      format: size.format,
      width: size.width,
      height: size.height,
      timestamp: _timestampFor(engineSeconds),
    ));
    if (_controller.isPaused) {
      _heldAcks.add(ack);
    } else {
      ack();
    }
  }

  /// A sessao do motor caiu: nao vem mais quadro nenhum.
  void onSessionClosed() => _stopQuietly();

  /// Manda um comando ao motor sem deixar a gravacao presa nele.
  ///
  /// E o `_sendMayFail` do upstream com um prazo por cima. O erro e esperado:
  /// ligar, desligar e reconhecer um quadro sao coisas que a pagina pode ter
  /// deixado de aceitar entre o evento e o comando. O prazo e porque uma
  /// sessao CDP viva com o renderer morto aceita o comando e nunca responde —
  /// e sem ele o `stop()` de uma pagina que crashou nunca retorna.
  Future<void> sendMayFail(Future<void> Function() send) async {
    try {
      await send().timeout(const Duration(seconds: 5));
    } catch (_) {
      // A sessao ja foi, ou nao responde: nao ha o que reconhecer nem parar.
    }
  }

  // ---------------------------------------------------------------- privado

  void _onPageGone(dynamic _) => _stopQuietly();

  void _stopQuietly() {
    // Os caminhos de fim de vida chegam de callbacks sincronos (eventos do
    // emissor, onCancel do controller), onde ninguem espera pelo future.
    unawaited(stop().then((_) {}, onError: (Object _) {}));
  }

  void _releaseHeldAcks() {
    if (_heldAcks.isEmpty) return;
    final pending = List.of(_heldAcks);
    _heldAcks.clear();
    for (final ack in pending) {
      ack();
    }
  }

  Duration _timestampFor(double? engineSeconds) {
    final now = DateTime.now();
    final startedAt = _startedAt ?? now;
    if (_firstFrameAt == null) {
      _firstFrameAt = now;
      _firstEngineSeconds = engineSeconds;
      _firstFrameOffset = now.difference(startedAt);
      _lastTimestamp = _firstFrameOffset;
      return _firstFrameOffset;
    }
    // O relogio do motor e o unico que mede o intervalo entre dois quadros
    // como o navegador os pintou; o relogio local so posiciona o primeiro.
    final Duration sinceFirst;
    if (engineSeconds != null && _firstEngineSeconds != null) {
      sinceFirst = Duration(
          microseconds:
              ((engineSeconds - _firstEngineSeconds!) * 1000000).round());
    } else {
      sinceFirst = now.difference(_firstFrameAt!);
    }
    final total = _firstFrameOffset + sinceFirst;
    // Nunca anda para tras. Os carimbos dos motores sao monotonicos quase
    // sempre — medido em 360 quadros no Chromium, 129 no Firefox e 107 no
    // WebKit sem uma inversao — mas o Chromium entregou uma vez dois quadros
    // trocados, 29ms para tras, num teste que rodou logo depois quinze vezes
    // limpo. Raro, e destrutivo do outro lado: o WebM exige carimbo de
    // cluster nao decrescente, entao um quadro fora de ordem estraga o
    // arquivo inteiro num run em cem. Repetir o carimbo anterior custa um
    // quadro com duracao zero; a alternativa e um bug que ninguem reproduz.
    _lastTimestamp = total < _lastTimestamp ? _lastTimestamp : total;
    return _lastTimestamp.isNegative ? Duration.zero : _lastTimestamp;
  }
}

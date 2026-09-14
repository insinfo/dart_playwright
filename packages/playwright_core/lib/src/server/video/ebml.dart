// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/playwright-core/src/server/ebml.ts

import 'dart:typed_data';

// Escritor EBML/Matroska minimo: embrulha cada quadro MJPEG com um timestamp
// explicito antes de empurra-lo para o ffmpeg (`-f matroska -i pipe:0`). Assim
// o ffmpeg deriva o tempo do proprio fluxo em vez de a gente repetir quadros
// para fingir uma taxa constante. So o subconjunto necessario para uma unica
// trilha MJPEG ao vivo e emitido.
//
// Referencias:
//   https://www.matroska.org/technical/elements.html
//   https://datatracker.ietf.org/doc/html/rfc8794 (EBML)

// Os IDs sao escritos literalmente — o primeiro byte ja codifica o descritor de
// tamanho.
final _kEBML = _hex('1A45DFA3');
final _kEBMLVersion = _hex('4286');
final _kEBMLReadVersion = _hex('42F7');
final _kEBMLMaxIDLength = _hex('42F2');
final _kEBMLMaxSizeLength = _hex('42F3');
final _kDocType = _hex('4282');
final _kDocTypeVersion = _hex('4287');
final _kDocTypeReadVersion = _hex('4285');
final _kSegment = _hex('18538067');
final _kInfo = _hex('1549A966');
final _kTimestampScale = _hex('2AD7B1');
final _kMuxingApp = _hex('4D80');
final _kWritingApp = _hex('5741');
final _kTracks = _hex('1654AE6B');
final _kTrackEntry = _hex('AE');
final _kTrackNumber = _hex('D7');
final _kTrackUID = _hex('73C5');
final _kTrackType = _hex('83');
final _kFlagLacing = _hex('9C');
final _kCodecID = _hex('86');
final _kVideo = _hex('E0');
final _kPixelWidth = _hex('B0');
final _kPixelHeight = _hex('BA');
final _kCluster = _hex('1F43B675');
final _kTimestamp = _hex('E7');
final _kSimpleBlock = _hex('A3');

/// "Tamanho desconhecido" de um Segment em streaming: um vint de 8 bytes com
/// todos os bits de dado ligados.
final _kUnknownSize =
    Uint8List.fromList([0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]);

Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// Codifica um valor como inteiro de tamanho variavel (vint) do EBML: os bits
/// iniciais escolhem o comprimento em bytes e sao seguidos pelo valor big-endian.
Uint8List vint(int value) {
  var length = 1;
  // O valor com todos os bits ligados e reservado ("tamanho desconhecido"), por
  // isso a comparacao usa `>=` e nao `>`.
  while (value >= (1 << (7 * length)) - 1) {
    ++length;
  }
  final buffer = Uint8List(length);
  var v = value;
  for (var i = length - 1; i >= 0; --i) {
    buffer[i] = v & 0xff;
    v = v >> 8;
  }
  buffer[0] |= 1 << (8 - length);
  return buffer;
}

/// Codifica um inteiro nao negativo como a menor sequencia big-endian possivel.
Uint8List uint(int value) {
  if (value == 0) return Uint8List.fromList([0]);
  final bytes = <int>[];
  var v = value;
  while (v > 0) {
    bytes.insert(0, v & 0xff);
    v = v >> 8;
  }
  return Uint8List.fromList(bytes);
}

/// Um elemento EBML completo: id + tamanho como vint + carga.
Uint8List element(Uint8List id, Uint8List payload) =>
    _concat([id, vint(payload.length), payload]);

Uint8List _concat(List<Uint8List> parts) {
  var total = 0;
  for (final p in parts) {
    total += p.length;
  }
  final out = Uint8List(total);
  var offset = 0;
  for (final p in parts) {
    out.setRange(offset, offset + p.length, p);
    offset += p.length;
  }
  return out;
}

/// Emite o cabecalho Matroska: cabeca EBML, um Segment de tamanho desconhecido
/// (streaming), Info com escala de timestamp de 1ms e uma unica trilha MJPEG.
/// Os quadros vem depois, como Clusters, via [writeClusterHeader].
Uint8List writeHeader() {
  final ebml = element(
      _kEBML,
      _concat([
        element(_kEBMLVersion, uint(1)),
        element(_kEBMLReadVersion, uint(1)),
        element(_kEBMLMaxIDLength, uint(4)),
        element(_kEBMLMaxSizeLength, uint(8)),
        element(_kDocType, _ascii('matroska')),
        element(_kDocTypeVersion, uint(4)),
        element(_kDocTypeReadVersion, uint(2)),
      ]));
  final info = element(
      _kInfo,
      _concat([
        // TimestampScale em nanossegundos por tick: 1_000_000 => os timestamps
        // ficam em milissegundos.
        element(_kTimestampScale, uint(1000000)),
        element(_kMuxingApp, _ascii('playwright')),
        element(_kWritingApp, _ascii('playwright')),
      ]));
  final track = element(
      _kTrackEntry,
      _concat([
        element(_kTrackNumber, uint(1)),
        element(_kTrackUID, uint(1)),
        element(_kTrackType, uint(1)), // 1 = video.
        element(_kFlagLacing, uint(0)),
        element(_kCodecID, _ascii('V_MJPEG')),
        // PixelWidth/PixelHeight sao obrigatorios, mas as dimensoes reais do
        // JPEG ainda nao sao conhecidas. Um marcador grande faz o ffmpeg
        // confundir um JPEG progressivo curto com um campo entrelacado, entao
        // usamos 1x1 e deixamos o decodificador MJPEG ler o tamanho de cada
        // quadro.
        element(
            _kVideo,
            _concat([
              element(_kPixelWidth, uint(1)),
              element(_kPixelHeight, uint(1)),
            ])),
      ]));
  final tracks = element(_kTracks, track);
  return _concat([ebml, _kSegment, _kUnknownSize, info, tracks]);
}

/// Emite os bytes que precedem um quadro MJPEG no seu proprio Cluster, com o
/// deslocamento absoluto em milissegundos. O quadro em si NAO e copiado aqui: o
/// chamador escreve este cabecalho e em seguida os bytes crus, de modo que o
/// JPEG (potencialmente grande) nunca e duplicado. Cada quadro MJPEG e
/// intra-codificado, logo e o proprio keyframe no proprio Cluster (timecode
/// relativo 0), o que mantem os timecodes dentro do int16 do SimpleBlock por
/// mais distantes que os quadros estejam.
Uint8List writeClusterHeader(int timestampMs, int frameLength) {
  // Carga do SimpleBlock = vint do numero da trilha (1 byte) + timecode
  // relativo (2 bytes) + flags (1 byte) + o quadro, que o chamador anexa.
  final simpleBlockHeader = _concat([
    _kSimpleBlock,
    vint(4 + frameLength),
    vint(1), // Numero da trilha (1).
    Uint8List.fromList([0x00, 0x00]), // Timecode relativo (int16), sempre 0.
    Uint8List.fromList([0x80]), // Flags: keyframe.
  ]);
  final timestamp = element(_kTimestamp, uint(timestampMs));
  final clusterPayloadLength =
      timestamp.length + simpleBlockHeader.length + frameLength;
  return _concat([
    _kCluster,
    vint(clusterPayloadLength),
    timestamp,
    simpleBlockHeader,
  ]);
}

Uint8List _ascii(String s) => Uint8List.fromList(s.codeUnits);

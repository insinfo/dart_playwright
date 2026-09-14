// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/playwright-core/src/server/videoRecorder.ts
// (`createWhiteImage`, que la usa o pacote npm `jpeg-js`).

import 'dart:typed_data';

// Codificador JPEG baseline minusculo, restrito a imagens em tons de cinza cujo
// bloco 8x8 e sempre de cor uniforme.
//
// Existe porque o ffmpeg so cria o arquivo de saida depois de receber alguma
// entrada: um gravador que parou sem nenhum quadro precisa empurrar um quadro
// sintetico para que `video.path()` aponte para um .webm de verdade. O upstream
// faz o mesmo com `jpeg-js`; aqui nao ha dependencia equivalente, e um
// codificador completo (DCT, zigzag, AC) seria muito mais codigo do que esse
// unico caso de uso justifica.
//
// A restricao a blocos de cor uniforme e o que torna isso pequeno: um bloco
// constante tem todos os coeficientes AC iguais a zero, entao cada bloco vira
// "diferenca de DC + EOB" e nem DCT nem zigzag sao necessarios.

/// Tabela de quantizacao: tudo 1, ou seja, sem perda sobre o coeficiente DC.
/// Numa imagem chapada a qualidade nao depende dela, e 1 mantem a conta do DC
/// exata.
final _quantTable = Uint8List(64)..fillRange(0, 64, 1);

// Tabelas de Huffman padrao de luminancia (ITU-T T.81, anexo K).
const _dcBits = [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0];
const _dcValues = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
const _acBits = [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d];
const _acValues = [
  0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, //
  0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
  0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08,
  0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
  0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16,
  0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
  0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39,
  0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
  0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
  0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
  0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79,
  0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
  0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98,
  0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
  0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6,
  0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
  0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4,
  0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
  0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea,
  0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
  0xf9, 0xfa,
];

/// Codigo de Huffman: valor e comprimento em bits.
class _Code {
  final int code;
  final int length;
  const _Code(this.code, this.length);
}

/// Constroi os codigos canonicos a partir de BITS/HUFFVAL, como no anexo C.
Map<int, _Code> _buildCodes(List<int> bits, List<int> values) {
  final result = <int, _Code>{};
  var code = 0;
  var k = 0;
  for (var length = 1; length <= 16; length++) {
    for (var i = 0; i < bits[length - 1]; i++) {
      result[values[k++]] = _Code(code++, length);
    }
    code <<= 1;
  }
  return result;
}

final _dcCodes = _buildCodes(_dcBits, _dcValues);
final _acCodes = _buildCodes(_acBits, _acValues);

class _BitWriter {
  final BytesBuilder _out;
  int _buffer = 0;
  int _bits = 0;

  _BitWriter(this._out);

  void write(int value, int length) {
    for (var i = length - 1; i >= 0; i--) {
      _buffer = (_buffer << 1) | ((value >> i) & 1);
      _bits++;
      if (_bits == 8) _flushByte();
    }
  }

  void _flushByte() {
    final byte = _buffer & 0xff;
    _out.addByte(byte);
    // Byte stuffing: dentro dos dados comprimidos um 0xFF tem de ser seguido de
    // 0x00, senao o decodificador o le como o inicio de um marcador.
    if (byte == 0xff) _out.addByte(0x00);
    _buffer = 0;
    _bits = 0;
  }

  /// Completa o ultimo byte com 1s, como manda a especificacao.
  void pad() {
    while (_bits != 0) {
      _buffer = (_buffer << 1) | 1;
      _bits++;
      if (_bits == 8) _flushByte();
    }
  }
}

/// Numero de bits necessarios para representar |value| — a "categoria" do JPEG.
int _category(int value) {
  var v = value.abs();
  var bits = 0;
  while (v > 0) {
    v >>= 1;
    bits++;
  }
  return bits;
}

/// Codifica um JPEG baseline em tons de cinza de [width]x[height] no qual cada
/// bloco 8x8 tem a luminancia devolvida por [luma] (0..255), indexada pela
/// coluna e pela linha do bloco.
///
/// As dimensoes nao precisam ser multiplas de 8: os blocos da borda sao
/// codificados inteiros e o decodificador recorta.
Uint8List encodeBlockJpeg({
  required int width,
  required int height,
  required int Function(int blockX, int blockY) luma,
}) {
  if (width <= 0 || height <= 0) {
    throw ArgumentError(
        'JPEG dimensions must be positive, got ${width}x$height');
  }
  final out = BytesBuilder(copy: false);

  void marker(int code) => out
    ..addByte(0xff)
    ..addByte(code);
  void uint16(int value) => out
    ..addByte((value >> 8) & 0xff)
    ..addByte(value & 0xff);

  marker(0xd8); // SOI

  marker(0xdb); // DQT
  uint16(2 + 1 + 64);
  out.addByte(0x00); // Pq=0 (8 bits), Tq=0.
  out.add(_quantTable);

  marker(0xc0); // SOF0, baseline sequencial.
  uint16(8 + 3);
  out.addByte(8); // Precisao.
  uint16(height);
  uint16(width);
  out.addByte(1); // Um componente: tons de cinza.
  out
    ..addByte(1) // Id do componente.
    ..addByte(0x11) // Amostragem 1x1.
    ..addByte(0); // Tabela de quantizacao 0.

  void huffmanTable(int classAndId, List<int> bits, List<int> values) {
    marker(0xc4);
    uint16(2 + 1 + 16 + values.length);
    out.addByte(classAndId);
    out.add(Uint8List.fromList(bits));
    out.add(Uint8List.fromList(values));
  }

  huffmanTable(0x00, _dcBits, _dcValues);
  huffmanTable(0x10, _acBits, _acValues);

  marker(0xda); // SOS
  uint16(6 + 2);
  out.addByte(1); // Um componente no scan.
  out
    ..addByte(1) // Id do componente.
    ..addByte(0x00); // Tabela DC 0, tabela AC 0.
  out
    ..addByte(0) // Ss
    ..addByte(63) // Se
    ..addByte(0); // Ah/Al

  final blocksX = (width + 7) ~/ 8;
  final blocksY = (height + 7) ~/ 8;
  final writer = _BitWriter(out);
  final eob = _acCodes[0x00]!;
  var previousDc = 0;

  for (var by = 0; by < blocksY; by++) {
    for (var bx = 0; bx < blocksX; bx++) {
      // Num bloco constante todo coeficiente AC e zero e o DC vale
      // (amostra - 128) * 8; com quantizacao 1 esse e o valor codificado.
      final dc = (luma(bx, by).clamp(0, 255) - 128) * 8;
      final diff = dc - previousDc;
      previousDc = dc;
      final category = _category(diff);
      final code = _dcCodes[category];
      if (code == null) {
        throw StateError('DC category $category outside the standard table');
      }
      writer.write(code.code, code.length);
      if (category > 0) {
        // Negativos vao como complemento de um no campo de `category` bits.
        final magnitude = diff > 0 ? diff : diff - 1;
        writer.write(magnitude & ((1 << category) - 1), category);
      }
      writer.write(eob.code, eob.length);
    }
  }
  writer.pad();

  marker(0xd9); // EOI
  return out.takeBytes();
}

/// Quadro chapado usado quando a gravacao termina sem nenhum quadro real.
Uint8List encodeSolidJpeg(int width, int height, {int luma = 255}) =>
    encodeBlockJpeg(width: width, height: height, luma: (_, __) => luma);

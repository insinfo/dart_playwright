import 'dart:typed_data';

import 'video_frame.dart';

/// O tamanho e o formato de um quadro, lidos do cabecalho da imagem.
///
/// Nao da para confiar no tamanho que a pagina reporta: os tres protocolos
/// mandam o tamanho do *viewport* junto do quadro (`deviceWidth`/
/// `deviceHeight`), nao o tamanho da imagem codificada. Com viewport 800x600
/// e um screencast pedido em 640x480 os tres entregam JPEG 640x480 e dizem
/// 800x600. Quem for montar o video precisa do tamanho real, e ler o
/// cabecalho custa algumas dezenas de bytes contra decodificar o quadro
/// inteiro.
class ImageSize {
  final VideoFrameFormat format;
  final int width;
  final int height;

  const ImageSize(this.format, this.width, this.height);

  /// Le [bytes] como PNG ou JPEG. Devolve null para qualquer outra coisa.
  static ImageSize? parse(Uint8List bytes) => _png(bytes) ?? _jpeg(bytes);

  static ImageSize? _png(Uint8List b) {
    // Assinatura PNG seguida do chunk IHDR, cujas duas primeiras palavras de
    // 32 bits sao largura e altura.
    if (b.length < 24) return null;
    const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    for (var i = 0; i < signature.length; i++) {
      if (b[i] != signature[i]) return null;
    }
    final view = ByteData.sublistView(b);
    return ImageSize(
        VideoFrameFormat.png, view.getUint32(16), view.getUint32(20));
  }

  static ImageSize? _jpeg(Uint8List b) {
    if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return null;
    var i = 2;
    while (i + 1 < b.length) {
      // Segmentos podem vir precedidos de bytes 0xFF de preenchimento.
      if (b[i] != 0xFF) {
        i++;
        continue;
      }
      final marker = b[i + 1];
      // SOI, TEM e os RSTn nao carregam tamanho.
      if (marker == 0xD8 ||
          marker == 0x01 ||
          (marker >= 0xD0 && marker <= 0xD7)) {
        i += 2;
        continue;
      }
      if (marker == 0xD9) return null; // EOI sem SOF.
      if (i + 3 >= b.length) return null;
      final length = (b[i + 2] << 8) | b[i + 3];
      // SOF0..SOF15 exceto DHT (C4), JPG (C8) e DAC (CC): o quadro comeca com
      // precisao, altura e largura, nessa ordem.
      final isStartOfFrame = marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC;
      if (isStartOfFrame) {
        if (i + 8 >= b.length) return null;
        final height = (b[i + 5] << 8) | b[i + 6];
        final width = (b[i + 7] << 8) | b[i + 8];
        return ImageSize(VideoFrameFormat.jpeg, width, height);
      }
      if (length < 2) return null;
      i += 2 + length;
    }
    return null;
  }
}

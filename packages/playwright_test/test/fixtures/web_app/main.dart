// Aplicacao Dart web minima usada pelos testes de source map.
//
// Existe para provar a traducao de stack trace contra um alvo real: e
// compilada com `dart compile js` (que emite `main.dart.js.map` por padrao) e
// o trace que o navegador produz tem de voltar apontando para ESTE arquivo, na
// linha exata do `throw`.
import 'dart:html';

/// O nome importa: os testes procuram por ele no trace traduzido.
void explodeDeliberadamente() {
  throw StateError('boom vindo do Dart');
}

/// Um quadro intermediario, para provar que a traducao nao devolve so o topo.
void chamadorIntermediario() {
  explodeDeliberadamente();
}

void main() {
  document.body!.append(DivElement()
    ..id = 'pronto'
    ..text = 'pronto');
  querySelector('#estoura')!.onClick.listen((_) => chamadorIntermediario());
}

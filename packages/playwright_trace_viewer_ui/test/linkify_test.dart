// Part of the Dart port of the Playwright trace viewer UI.

/// The link detector that annotations and errors run their text through.
///
/// The interesting cases are all about where a link *ends*. Upstream's regex
/// deliberately stops before sentence punctuation, and getting that wrong is
/// invisible until somebody clicks a URL with a stray full stop glued to it.
library;

import 'package:playwright_trace_viewer_ui/src/ui/format.dart';
import 'package:test/test.dart';

/// The pieces as `(text, href)`, so a failure prints something readable.
List<(String, String?)> pieces(String input) =>
    linkifyText(input).map((s) => (s.text, s.href)).toList();

void main() {
  test('Deve devolver o texto inteiro quando nao ha link', () {
    expect(pieces('sem link nenhum'), [('sem link nenhum', null)]);
  });

  test('Deve reconhecer um link e o texto em volta', () {
    expect(pieces('veja https://example.com/a agora'), [
      ('veja ', null),
      ('https://example.com/a', 'https://example.com/a'),
      (' agora', null),
    ]);
  });

  test('Deve deixar de fora o ponto que fecha a frase', () {
    // O ponto pertence a frase, nao a URL. E a razao de a classe final do
    // regex do upstream existir.
    expect(pieces('veja https://example.com.'), [
      ('veja ', null),
      ('https://example.com', 'https://example.com'),
      ('.', null),
    ]);
  });

  test('Deve deixar de fora virgula, parentese e ponto e virgula', () {
    for (final fim in [',', ')', ';', ':', '!', '?', ']', '}']) {
      expect(pieces('ir a https://example.com$fim').map((p) => p.$1).toList(),
          ['ir a ', 'https://example.com', fim],
          reason: 'o caractere "$fim" nao pertence a URL');
    }
  });

  test('Deve dar esquema a um endereco que comeca em www', () {
    // Sem isso o navegador leria o href como caminho relativo.
    expect(pieces('em www.example.com aqui'), [
      ('em ', null),
      ('www.example.com', 'https://www.example.com'),
      (' aqui', null),
    ]);
  });

  test('Deve reconhecer mais de um link na mesma linha', () {
    final resultado = pieces('a https://um.example b https://dois.example c');
    expect(resultado.where((p) => p.$2 != null).map((p) => p.$1).toList(),
        ['https://um.example', 'https://dois.example']);
  });

  test('Deve aceitar esquema que nao seja http', () {
    expect(pieces('abra vscode://file/x.dart aqui').map((p) => p.$2).toList(),
        [null, 'vscode://file/x.dart', null]);
  });

  test('Deve recusar um esquema curto demais para o regex do upstream', () {
    // O upstream exige tres ou mais caracteres depois da primeira letra, o
    // que faz `a://b` nao virar link. Portado como esta, nao como eu acharia
    // melhor.
    expect(pieces('veja a://b').single.$2, isNull);
  });
}

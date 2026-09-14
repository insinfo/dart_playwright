// Lanca `serve_app.dart` num processo filho e fica vivo sem fazer mais nada.
//
// Reproduz a forma de `webdev`: quem escuta a porta nao e o processo que o
// comando criou, e sim um neto dele. Matar so o pai deixa o neto segurando a
// porta -- que e o defeito que o teste de derrubada cobre.
import 'dart:io';

void main(List<String> args) async {
  final child = await Process.start(
    Platform.resolvedExecutable,
    ['run', 'test/fixtures/serve_app.dart', ...args],
    workingDirectory: Directory.current.path,
  );
  child.stdout.pipe(stdout);
  child.stderr.pipe(stderr);
  // Nunca sai por conta propria: quem termina esta arvore e o teste.
  await child.exitCode;
}

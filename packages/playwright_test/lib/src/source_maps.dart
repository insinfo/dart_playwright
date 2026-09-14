import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:source_map_stack_trace/source_map_stack_trace.dart' as smst;
import 'package:source_maps/source_maps.dart' as sm;
import 'package:stack_trace/stack_trace.dart';

/// Raiz que o dart2js usa para as fontes da SDK dentro do source map.
///
/// Passar isto para `mapStackTrace` faz os quadros da SDK sairem como
/// `dart:async/...` em vez de `org-dartlang-sdk:///lib/async/...`, e e isso que
/// deixa [Trace.terse] reconhece-los como quadros de runtime e dobra-los.
final Uri _dartSdkRoot = Uri.parse('org-dartlang-sdk:///');

/// Onde um quadro do navegador aponta: `http://host/main.dart.js:4821:3`.
///
/// Nao tenta cobrir todo formato: `package:stack_trace` ja entende V8, Firefox
/// e Safari, e o port normaliza o stack das tres engines para a forma V8 antes
/// de entregar em `PageError.stack`.
final RegExp _compiledJsFrame = RegExp(r'\.js:\d+:\d+');

/// O resultado de traduzir um stack trace vindo do navegador.
class TranslatedStackTrace {
  /// O texto original, exatamente como o navegador reportou.
  final String original;

  /// O texto traduzido, ou o original quando nada pode ser traduzido.
  final String translated;

  /// Verdadeiro quando pelo menos um quadro foi reescrito para `.dart`.
  final bool didTranslate;

  /// Por que a traducao nao aconteceu, quando [didTranslate] e falso.
  ///
  /// Uma nota, nao um erro: um build de producao sem source map e uma escolha
  /// legitima, e falhar o teste por causa dela seria trocar a falha real por
  /// uma pior.
  final String? note;

  TranslatedStackTrace({
    required this.original,
    required this.translated,
    required this.didTranslate,
    this.note,
  });

  @override
  String toString() => translated;
}

/// Traduz stack traces de JavaScript compilado pelo dart2js de volta para
/// `arquivo.dart:linha:coluna`, usando o source map que o compilador emite.
///
/// Um so resolver serve varias traducoes: os source maps sao baixados uma vez
/// por URL e ficam em cache. Sem o cache, cada erro custaria o download e o
/// parse de um arquivo que num app real tem megabytes, o que transformaria
/// "anexar o trace traduzido a falha" numa operacao mais cara que o teste.
class DartSourceMapResolver {
  /// Dobra os quadros de runtime (`dart:*`) com [Trace.terse].
  ///
  /// Um trace de dart2js chega com dezenas de quadros de `dart:async` e do
  /// `js_helper` em volta de dois ou tres quadros do usuario; mostrar todos
  /// esconde exatamente a linha que interessa.
  final bool terse;

  /// Mapeia nome de pacote para a URI base que o source map usa, para
  /// reconstruir URIs `package:`. Normalmente desnecessario: o dart2js ja
  /// escreve fontes de pacotes como `package:...` no map.
  final Map<String, Uri>? packageMap;

  /// Quanto esperar por cada download de source map.
  final Duration fetchTimeout;

  final HttpClient _client;
  final bool _ownsClient;

  /// Cache por URL do JS compilado. O valor nulo e memorizado de proposito:
  /// um app sem source map nao deve ser sondado a cada erro.
  final Map<String, Future<sm.Mapping?>> _cache = {};

  DartSourceMapResolver({
    this.terse = true,
    this.packageMap,
    this.fetchTimeout = const Duration(seconds: 10),
    HttpClient? httpClient,
  })  : _client = httpClient ?? HttpClient(),
        _ownsClient = httpClient == null;

  /// Traduz [stack], um stack trace como o navegador o reportou.
  ///
  /// Nunca lanca: qualquer falha vira [TranslatedStackTrace.note] e o texto
  /// original sai intacto.
  Future<TranslatedStackTrace> translate(String stack) async {
    if (stack.trim().isEmpty) {
      return TranslatedStackTrace(
        original: stack,
        translated: stack,
        didTranslate: false,
        note: 'stack vazio',
      );
    }

    // O cabecalho ("Error: boom") nao e um quadro; `Trace.parse` o descarta, e
    // uma falha de teste sem a mensagem do erro nao ajuda ninguem.
    final header = _headerOf(stack);

    Trace trace;
    try {
      trace = Trace.parse(stack);
    } catch (e) {
      return TranslatedStackTrace(
        original: stack,
        translated: stack,
        didTranslate: false,
        note: 'stack em formato nao reconhecido ($e)',
      );
    }

    if (trace.frames.isEmpty) {
      return TranslatedStackTrace(
        original: stack,
        translated: stack,
        didTranslate: false,
        note: 'nenhum quadro reconhecido no stack',
      );
    }

    final notes = <String>{};
    final mapped = <Frame>[];
    var translatedAny = false;

    for (final frame in trace.frames) {
      final url = frame.uri.toString();
      if (!_looksCompiled(url)) {
        mapped.add(frame);
        continue;
      }
      sm.Mapping? mapping;
      try {
        mapping = await _mappingFor(url, notes);
      } catch (e) {
        notes.add('falha ao ler o source map de $url: $e');
      }
      if (mapping == null) {
        mapped.add(frame);
        continue;
      }
      // Quadro a quadro, e nao o trace inteiro de uma vez: `spanFor` de um
      // `SingleMapping` ignora a URI pedida, entao um trace que mistura
      // `main.dart.js` com outro script teria os quadros do outro script
      // traduzidos pelo map errado, silenciosamente.
      final one = smst.mapStackTrace(
        mapping,
        Trace([frame]),
        packageMap: packageMap,
        sdkRoot: _dartSdkRoot,
      );
      final frames = Trace.from(one).frames;
      if (frames.isEmpty) {
        // Sem span: quadro de codigo gerado sem origem Dart. Fica o original,
        // porque some-lo esconderia parte do caminho.
        mapped.add(frame);
        continue;
      }
      mapped.addAll(frames);
      translatedAny = true;
    }

    if (!translatedAny) {
      return TranslatedStackTrace(
        original: stack,
        translated: stack,
        didTranslate: false,
        note: notes.isEmpty
            ? 'nenhum quadro de JavaScript compilado por dart2js no stack'
            : notes.join('; '),
      );
    }

    var result = Trace(mapped);
    if (terse) result = result.terse;

    final body = result.toString().trimRight();
    final text = header.isEmpty ? body : '$header\n$body';
    return TranslatedStackTrace(
      original: stack,
      translated: notes.isEmpty ? text : '$text\n(${notes.join('; ')})',
      didTranslate: true,
      note: notes.isEmpty ? null : notes.join('; '),
    );
  }

  /// Traduz todo stack trace de JavaScript compilado que apareca dentro de
  /// [text], deixando o resto do texto como esta.
  ///
  /// Serve para o que nao chega como stack puro: a mensagem de uma excecao de
  /// `evaluate`, uma linha de `console`, o `toString` de um erro do port.
  Future<String> translateEmbedded(String text) async {
    if (!_compiledJsFrame.hasMatch(text)) return text;

    final lines = const LineSplitter().convert(text);
    final out = <String>[];
    var block = <String>[];

    Future<void> flush() async {
      if (block.isEmpty) return;
      final result = await translate(block.join('\n'));
      out.addAll(const LineSplitter().convert(result.translated));
      block = <String>[];
    }

    for (final line in lines) {
      if (_isFrameLine(line)) {
        block.add(line);
      } else {
        await flush();
        out.add(line);
      }
    }
    await flush();
    return out.join('\n');
  }

  /// Esquece os source maps ja baixados.
  void clearCache() => _cache.clear();

  /// Fecha o cliente HTTP, se este resolver o criou.
  void close() {
    if (_ownsClient) _client.close(force: true);
  }

  bool _looksCompiled(String url) =>
      url.endsWith('.js') || url.contains('.js?') || url.contains('.js#');

  bool _isFrameLine(String line) {
    final t = line.trimLeft();
    // V8: "at fn (url:1:2)"; Firefox/Safari: "fn@url:1:2".
    return (t.startsWith('at ') || t.contains('@')) &&
        RegExp(r':\d+:\d+\)?$').hasMatch(t.trimRight());
  }

  String _headerOf(String stack) {
    final lines = const LineSplitter().convert(stack);
    final header = <String>[];
    for (final line in lines) {
      if (_isFrameLine(line)) break;
      header.add(line);
    }
    return header.join('\n').trimRight();
  }

  Future<sm.Mapping?> _mappingFor(String jsUrl, Set<String> notes) {
    return _cache.putIfAbsent(jsUrl, () => _loadMapping(jsUrl, notes));
  }

  Future<sm.Mapping?> _loadMapping(String jsUrl, Set<String> notes) async {
    final base = Uri.tryParse(jsUrl);
    if (base == null) return null;

    // `<arquivo>.js.map` ao lado do JS e o que dart2js, webdev e build_runner
    // emitem. Tentar isso primeiro evita baixar o proprio bundle, que e a
    // parte cara.
    final sibling = base.replace(path: '${base.path}.map');
    var json = await _fetch(sibling);
    var mapUrl = sibling;

    if (json == null) {
      // Sem o vizinho, a unica fonte confiavel e o comentario
      // `//# sourceMappingURL=` no fim do bundle.
      final declared = await _sourceMappingUrlOf(base);
      if (declared == null) {
        notes.add('sem source map para $jsUrl '
            '(build de producao sem source maps?)');
        return null;
      }
      if (declared.scheme == 'data') {
        json = _decodeDataUri(declared);
        mapUrl = base;
      } else {
        json = await _fetch(declared);
        mapUrl = declared;
      }
      if (json == null) {
        notes.add('source map declarado em $jsUrl nao pode ser lido');
        return null;
      }
    }

    try {
      // Sem `mapUrl`: as fontes saem como o compilador as escreveu
      // (`main.dart`, `package:foo/bar.dart`), que e o que um desenvolvedor
      // Dart reconhece. Resolve-las contra a URL do map so as trocaria por
      // `http://127.0.0.1:8080/main.dart`, mais longo e menos util.
      return sm.parse(json);
    } catch (e) {
      notes.add('source map de $mapUrl invalido: $e');
      return null;
    }
  }

  /// Le o fim do bundle atras de `//# sourceMappingURL=`.
  ///
  /// Pede so a cauda por Range: o comentario esta na ultima linha e o bundle
  /// inteiro pode ter megabytes.
  Future<Uri?> _sourceMappingUrlOf(Uri jsUrl) async {
    var tail = await _fetch(jsUrl, rangeSuffixBytes: 2048);
    if (tail == null) return null;
    final match = RegExp(r"""[#@]\s*sourceMappingURL=([^\s'"]+)""")
        .allMatches(tail)
        .lastOrNull;
    if (match == null) return null;
    final value = match.group(1)!;
    if (value.startsWith('data:')) {
      // Um map embutido nao cabe na cauda; e preciso o arquivo inteiro.
      final whole = await _fetch(jsUrl);
      if (whole == null) return null;
      final full = RegExp(r"""[#@]\s*sourceMappingURL=([^\s'"]+)""")
          .allMatches(whole)
          .lastOrNull;
      if (full == null) return null;
      return Uri.tryParse(full.group(1)!);
    }
    return jsUrl.resolve(value);
  }

  String? _decodeDataUri(Uri uri) {
    try {
      return uri.data?.contentAsString();
    } catch (_) {
      return null;
    }
  }

  Future<String?> _fetch(Uri url, {int? rangeSuffixBytes}) async {
    if (url.scheme == 'file' || url.scheme.isEmpty) {
      try {
        final file = File(url.scheme == 'file' ? url.toFilePath() : url.path);
        if (!await file.exists()) return null;
        return await file.readAsString();
      } catch (_) {
        return null;
      }
    }
    if (url.scheme != 'http' && url.scheme != 'https') return null;
    try {
      final request = await _client.getUrl(url).timeout(fetchTimeout);
      if (rangeSuffixBytes != null) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=-$rangeSuffixBytes');
      }
      final response = await request.close().timeout(fetchTimeout);
      if (response.statusCode >= 400) {
        await response.drain<void>();
        return null;
      }
      return await response
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(fetchTimeout);
    } catch (_) {
      return null;
    }
  }
}

/// Resolver compartilhado por [translateDartStackTrace] e pelas fixtures.
///
/// Um so cache por processo: dois testes que estouram no mesmo bundle nao
/// devem baixar o mesmo source map duas vezes.
DartSourceMapResolver? _shared;

/// O resolver usado quando nenhum e passado explicitamente.
DartSourceMapResolver get sharedDartSourceMapResolver =>
    _shared ??= DartSourceMapResolver();

/// Traduz [stack] usando [sharedDartSourceMapResolver].
Future<TranslatedStackTrace> translateDartStackTrace(String stack) =>
    sharedDartSourceMapResolver.translate(stack);

/// Traduz os stack traces embutidos em [text] usando
/// [sharedDartSourceMapResolver].
Future<String> translateDartStackTracesIn(String text) =>
    sharedDartSourceMapResolver.translateEmbedded(text);

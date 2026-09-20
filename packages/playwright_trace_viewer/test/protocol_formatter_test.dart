import 'package:playwright_trace_viewer/playwright_trace_viewer.dart';
import 'package:test/test.dart';

/// Um descritor de locator de mentira, no lugar do gerador de codigo que
/// ainda nao foi portado, para provar que o formatador o consulta.
String _fakeLocator(String sdkLanguage, String selector) =>
    "$sdkLanguage:locator('$selector')";

void main() {
  group('renderTitleForCall', () {
    test('Deve usar o modelo da tabela do protocolo', () {
      expect(
        renderTitleForCall(const CallMetainfo(
          className: 'Frame',
          method: 'fill',
          params: {'selector': '#nome', 'value': 'Isaque'},
        )),
        'Fill "Isaque"',
      );
    });

    test('Deve preferir o titulo que o proprio trace ja trouxe', () {
      expect(
        renderTitleForCall(const CallMetainfo(
          className: 'Frame',
          method: 'fill',
          params: {'value': 'x'},
          title: 'Preencher o nome',
        )),
        'Preencher o nome',
      );
    });

    test('Deve cair no nome do metodo quando nao ha modelo', () {
      expect(
        renderTitleForCall(const CallMetainfo(
            className: 'Inventado', method: 'faz', params: {})),
        'faz',
      );
    });

    test('Deve deixar o placeholder cru quando o parametro falta', () {
      expect(
        renderTitleForCall(
            const CallMetainfo(className: 'Frame', method: 'fill', params: {})),
        'Fill "{value}"',
      );
    });

    test('Deve achatar a quebra de linha do parametro', () {
      expect(
        renderTitleForCall(const CallMetainfo(
          className: 'Frame',
          method: 'fill',
          params: {'value': 'a\nb'},
        )),
        r'Fill "a\nb"',
      );
    });

    test('Deve aceitar alternativas separadas por barra', () {
      expect(
        renderTitleForCall(const CallMetainfo(
          className: 'BrowserContext',
          method: 'clockInstall',
          params: {'timeString': '2026-01-01'},
        )),
        'Install clock "2026-01-01"',
      );
    });

    test('Deve formatar timeNumber como data', () {
      final title = renderTitleForCall(const CallMetainfo(
        className: 'BrowserContext',
        method: 'clockInstall',
        params: {'timeNumber': 0},
      ));
      expect(title, startsWith('Install clock "19'));
    });
  });

  group('renderSubtitleForCall e renderFullTitleForCall', () {
    test('Deve encurtar a URL para host, caminho e busca', () {
      expect(
        renderFullTitleForCall(const CallMetainfo(
          className: 'Frame',
          method: 'goto',
          params: {'url': 'https://example.com:8443/a/b?c=1#frag'},
        )),
        'Navigate example.com:8443/a/b?c=1',
      );
    });

    test('Deve mostrar so o esquema de uma URL data:', () {
      expect(
        renderSubtitleForCall(const CallMetainfo(
          className: 'Frame',
          method: 'goto',
          params: {'url': 'data:text/html,<p>x</p>'},
        )),
        'data:',
      );
    });

    test('Deve mostrar about: e chrome: por inteiro', () {
      expect(
        renderSubtitleForCall(const CallMetainfo(
          className: 'Frame',
          method: 'goto',
          params: {'url': 'about:blank'},
        )),
        'about:blank',
      );
    });

    test('Deve devolver uma URL relativa como esta', () {
      expect(
        renderSubtitleForCall(const CallMetainfo(
          className: 'Frame',
          method: 'goto',
          params: {'url': '/a/b'},
        )),
        '/a/b',
      );
    });

    test('Deve esconder o subtitulo pela metade resolvido', () {
      expect(
        renderSubtitleForCall(
            const CallMetainfo(className: 'Frame', method: 'goto', params: {})),
        isNull,
      );
      expect(
        renderFullTitleForCall(
            const CallMetainfo(className: 'Frame', method: 'goto', params: {})),
        'Navigate',
      );
    });

    test('Deve passar o seletor pelo descritor de locator', () {
      expect(
        renderFullTitleForCall(
          const CallMetainfo(
            className: 'Frame',
            method: 'click',
            params: {'selector': 'internal:role=button'},
          ),
          sdkLanguage: 'dart',
          describeLocator: _fakeLocator,
        ),
        "Click dart:locator('internal:role=button')",
      );
    });

    test('Deve mostrar o seletor cru sem descritor', () {
      expect(
        renderFullTitleForCall(const CallMetainfo(
          className: 'Frame',
          method: 'click',
          params: {'selector': '#load'},
        )),
        'Click #load',
      );
    });
  });

  group('renderParamsForCall', () {
    test('Deve reportar so os parametros curados', () {
      expect(
        renderParamsForCall(const CallMetainfo(
          className: 'Frame',
          method: 'click',
          params: {
            'selector': '#load',
            'button': 'right',
            'clickCount': 2,
            'timeout': 30000,
          },
        )),
        {'locator': '#load', 'button': 'right', 'clickCount': 2},
      );
    });

    test('Deve renomear o parametro quando a entrada traz chave', () {
      expect(
        renderParamsForCall(const CallMetainfo(
          className: 'Frame',
          method: 'setInputFiles',
          params: {
            'selector': '#file',
            'localPaths': ['/tmp/a.txt'],
          },
        )),
        {
          'locator': '#file',
          'files': ['/tmp/a.txt'],
        },
      );
    });

    test('Deve renderizar como locator o que a entrada marca com :selector',
        () {
      expect(
        renderParamsForCall(
          const CallMetainfo(
            className: 'Frame',
            method: 'dragAndDrop',
            params: {'source': '#a', 'target': '#b'},
          ),
          sdkLanguage: 'dart',
          describeLocator: _fakeLocator,
        ),
        {
          'source': "dart:locator('#a')",
          'target': "dart:locator('#b')",
        },
      );
    });

    test('Deve devolver nulo quando nada sobrou', () {
      expect(
        renderParamsForCall(const CallMetainfo(
            className: 'Frame', method: 'click', params: {})),
        isNull,
      );
      expect(
        renderParamsForCall(
            const CallMetainfo(className: 'Frame', method: 'click')),
        isNull,
      );
    });

    test('Deve cortar um parametro longo', () {
      final long = 'x' * 500;
      final params = renderParamsForCall(CallMetainfo(
        className: 'Frame',
        method: 'fill',
        params: {'value': long},
      ))!;
      expect((params['value'] as String).length, 201);
      expect(params['value'], endsWith('…'));
      expect(truncateParam('curto'), 'curto');
    });
  });

  group('getActionGroup', () {
    test('Deve ler o grupo da tabela', () {
      expect(getActionGroup('Route', 'abort'), ActionGroup.route);
      expect(getActionGroup('Frame', 'title'), ActionGroup.getter);
      expect(getActionGroup('Browser', 'newBrowserCDPSession'),
          ActionGroup.configuration);
      expect(getActionGroup('Frame', 'click'), isNull);
      expect(getActionGroup('Inventado', 'faz'), isNull);
    });

    test('Deve conhecer a tabela inteira do protocolo', () {
      expect(methodMetainfo, hasLength(327));
      expect(methodMetainfo['Frame.click']!.input, isTrue);
      expect(methodMetainfo['Frame.click']!.isAutoWaiting, isTrue);
      expect(methodMetainfo['Android.devices']!.internal, isTrue);
    });
  });
}

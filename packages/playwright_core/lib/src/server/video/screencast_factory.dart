import '../chromium/cr_page.dart';
import '../core_page.dart';
import '../firefox/ff_page.dart';
import '../webkit/wk_page.dart';
import 'cr_screencast.dart';
import 'ff_screencast.dart';
import 'page_screencast.dart';
import 'wk_screencast.dart';

/// O screencast do motor que [page] esta usando.
///
/// Fica fora de `page_screencast.dart` de proposito: o contrato nao deve
/// depender dos tres motores, senao qualquer um que so queira o tipo
/// `PageScreencast` arrasta Chromium, Firefox e WebKit junto.
///
/// Nao ha cache: uma gravacao vai do [PageScreencast.start] ao
/// [PageScreencast.stop] e nao reabre, entao gravar de novo a mesma pagina
/// pede um objeto novo.
PageScreencast createPageScreencast(CorePage page) {
  if (page is CrPage) return CrScreencast(page);
  if (page is FfPage) return FfScreencast(page);
  if (page is WkPage) return WkScreencast(page);
  throw UnsupportedError(
      'Screencast nao implementado para ${page.runtimeType}');
}

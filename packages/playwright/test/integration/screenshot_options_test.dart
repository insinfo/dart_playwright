import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:playwright/playwright.dart';
import 'package:test/test.dart';

/// Coverage for the screenshot options ported from upstream's
/// `server/screenshotter.ts`: `mask`, `maskColor`, `style`, `caret`,
/// `animations` and `omitBackground`.
///
/// Upstream proves these with reference images (`toMatchSnapshot`), which this
/// port has no fixture pipeline for, so each one is checked by sampling the
/// pixel the reference image would have differed at.
void main() {
  group('Opcoes de screenshot', () {
    late Playwright playwright;

    setUpAll(() async {
      playwright = await Playwright.create();
    });

    /// The colour of the pixel at [x], [y] of a PNG capture, as `#RRGGBB`.
    String pixelAt(List<int> png, int x, int y) {
      final decoded = img.decodePng(Uint8List.fromList(png))!;
      final pixel = decoded.getPixel(x, y);
      String hex(num v) =>
          v.toInt().toRadixString(16).padLeft(2, '0').toUpperCase();
      return '#${hex(pixel.r)}${hex(pixel.g)}${hex(pixel.b)}';
    }

    int alphaAt(List<int> png, int x, int y) {
      final decoded = img.decodePng(Uint8List.fromList(png))!;
      return decoded.getPixel(x, y).a.toInt();
    }

    for (final browserName in ['chromium', 'firefox', 'webkit']) {
      group('[$browserName]', () {
        late Browser browser;
        var browserLaunched = false;
        late BrowserContext context;
        late Page page;

        setUpAll(() async {
          browser = await switch (browserName) {
            'chromium' => playwright.chromium.launch(headless: true),
            'firefox' => playwright.firefox.launch(headless: true),
            _ => playwright.webkit.launch(headless: true),
          };
          browserLaunched = true;
        });

        setUp(() async {
          // `scale: 'css'` everywhere below, so the pixel coordinates in the
          // assertions are the CSS ones whatever the device pixel ratio is.
          context =
              await browser.newContext(viewport: (width: 300, height: 200));
          page = await context.newPage();
        });

        tearDown(() async {
          await context.close();
        });

        tearDownAll(() async {
          if (browserLaunched) await browser.close();
        });

        Future<void> setBoard() => page.setContent('''
              <html><body style="margin:0;background:#FFFFFF">
                <div id="target" style="position:absolute;left:0;top:0;
                     width:100px;height:100px;background:#000000"></div>
              </body></html>
            ''');

        // ------------------------------------------------------------ mask

        test('mask deve pintar o elemento de #F0F', () async {
          await setBoard();
          final plain = await page.screenshot(scale: 'css');
          expect(pixelAt(plain, 50, 50), equals('#000000'));

          final masked = await page
              .screenshot(scale: 'css', mask: [page.locator('#target')]);
          expect(pixelAt(masked, 50, 50), equals('#FF00FF'));
        });

        test('maskColor deve trocar a cor da mascara', () async {
          await setBoard();
          final masked = await page.screenshot(
              scale: 'css',
              mask: [page.locator('#target')],
              maskColor: '#00FF00');
          expect(pixelAt(masked, 50, 50), equals('#00FF00'));
        });

        test('A mascara some da pagina depois da captura', () async {
          await setBoard();
          await page.screenshot(scale: 'css', mask: [page.locator('#target')]);
          expect(
              await page.evaluate(
                  "() => document.querySelectorAll('x-pw-dart-mask').length"),
              equals(0));
          final after = await page.screenshot(scale: 'css');
          expect(pixelAt(after, 50, 50), equals('#000000'));
        });

        test('Uma mascara que nao casa nada nao falha a captura', () async {
          await setBoard();
          final shot = await page
              .screenshot(scale: 'css', mask: [page.locator('#nao-existe')]);
          expect(pixelAt(shot, 50, 50), equals('#000000'));
        });

        // ----------------------------------------------------------- style

        test('style vale so durante a captura', () async {
          await setBoard();
          final hidden = await page.screenshot(
              scale: 'css', style: '#target { visibility: hidden; }');
          expect(pixelAt(hidden, 50, 50), equals('#FFFFFF'));

          // Upstream asserts the same thing: the page is left as it was.
          expect(
              await page.evaluate("() => document.getElementById('target')"
                  '.style.visibility'),
              equals(''));
          final after = await page.screenshot(scale: 'css');
          expect(pixelAt(after, 50, 50), equals('#000000'));
        });

        // ------------------------------------------------------ animations

        test('animations disabled termina a animacao finita', () async {
          await page.setContent('''
            <html><body style="margin:0;background:#FFFFFF">
              <style>
                @keyframes fade { from { background:#FF0000 } to { background:#0000FF } }
                #target {
                  position:absolute; left:0; top:0; width:100px; height:100px;
                  background:#FF0000;
                  animation: fade 20s linear forwards;
                }
              </style>
              <div id="target"></div>
            </body></html>
          ''');
          // A moment into a twenty second animation: still essentially red.
          final running = await page.screenshot(scale: 'css');
          final startPixel = pixelAt(running, 50, 50);
          expect(int.parse(startPixel.substring(1, 3), radix: 16),
              greaterThan(0xF0),
              reason: startPixel);
          expect(
              int.parse(startPixel.substring(5, 7), radix: 16), lessThan(0x10),
              reason: startPixel);

          // `finish()` jumps a finite animation to its end, so the fill-mode
          // leaves the element blue for the capture.
          final frozen =
              await page.screenshot(scale: 'css', animations: 'disabled');
          expect(pixelAt(frozen, 50, 50), equals('#0000FF'));
        });

        test('animations disabled cancela e devolve a animacao infinita',
            () async {
          await page.setContent('''
            <html><body style="margin:0;background:#FFFFFF">
              <style>
                @keyframes spin { from { transform: rotate(0) } to { transform: rotate(360deg) } }
                #target {
                  position:absolute; left:0; top:0; width:100px; height:100px;
                  background:#000000;
                  animation: spin 2s linear infinite;
                }
              </style>
              <div id="target"></div>
            </body></html>
          ''');
          await page.screenshot(scale: 'css', animations: 'disabled');
          // Upstream resumes the infinite animations it cancelled; the page is
          // running again once the capture is done.
          expect(
              await page.evaluate(
                  "() => document.getElementById('target').getAnimations()"
                  '.length'),
              equals(1));
        });

        // ----------------------------------------------------------- caret

        test('caret hide deixa a captura estavel', () async {
          await page.setContent('''
            <html><body style="margin:0;background:#FFFFFF">
              <style>input { caret-color: #FF0000 !important; }</style>
              <input id="field" style="position:absolute;left:0;top:0;
                     width:200px;height:40px;font-size:20px">
            </body></html>
          ''');
          await page.locator('#field').click();
          await page.locator('#field').fill('abc');

          final first = await page.screenshot(scale: 'css');
          // The caret blinks every 500ms upstream, so six captures over about
          // a second straddle at least one blink.
          for (var i = 0; i < 6; i++) {
            await page.waitForTimeout(const Duration(milliseconds: 170));
            final next = await page.screenshot(scale: 'css');
            expect(next, equals(first), reason: 'captura $i mudou');
          }

          // The inline caret-color the capture set is removed afterwards.
          expect(
              await page.evaluate("() => document.getElementById('field')"
                  ".style.getPropertyValue('caret-color')"),
              equals(''));
        });

        // -------------------------------------------------- omitBackground

        test('omitBackground da fundo transparente, menos no Firefox',
            () async {
          await page
              .setContent('<html><body style="margin:0;background:transparent">'
                  '</body></html>');
          if (browserName == 'firefox') {
            // Admitted divergence, and not this port's: the Juggler protocol
            // has no background colour override, and upstream's
            // `ffPage.setBackgroundColor` throws for the same reason.
            expect(
                () => page.screenshot(scale: 'css', omitBackground: true),
                throwsA(isA<PlaywrightException>().having((e) => '$e',
                    'message', contains('not supported on Firefox'))));
            return;
          }
          final shot =
              await page.screenshot(scale: 'css', omitBackground: true);
          expect(alphaAt(shot, 50, 50), equals(0));

          final opaque = await page.screenshot(scale: 'css');
          expect(alphaAt(opaque, 50, 50), equals(255));
        });

        test('omitBackground e ignorado em jpeg', () async {
          await page
              .setContent('<html><body style="margin:0;background:transparent">'
                  '</body></html>');
          // jpeg has no alpha channel, so upstream skips the override — which
          // is also what keeps this from throwing on Firefox.
          final jpeg = await page.screenshot(
              scale: 'css', type: 'jpeg', omitBackground: true);
          expect(jpeg.sublist(0, 2), equals([0xFF, 0xD8]));
        });

        // -------------------------------------------------------- validacao

        test('Deve recusar animations e caret desconhecidos', () async {
          await setBoard();
          expect(
              () => page.screenshot(animations: 'freeze'), throwsArgumentError);
          expect(() => page.screenshot(caret: 'show'), throwsArgumentError);
        });

        // --------------------------------------------------- Locator.screenshot

        test('Locator.screenshot aceita mask e style', () async {
          await setBoard();
          final masked = await page
              .locator('#target')
              .screenshot(scale: 'css', mask: [page.locator('#target')]);
          expect(pixelAt(masked, 50, 50), equals('#FF00FF'));
        });
      });
    }
  });
}

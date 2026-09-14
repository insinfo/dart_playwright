import 'package:playwright/playwright.dart';
import 'package:test/test.dart';

/// Conformance coverage for `page.ariaSnapshot()` and
/// `Locator.ariaSnapshot()` on Chromium, Firefox and WebKit.
///
/// The fixtures and the expected YAML are upstream Playwright's own, from
/// `tests/page/page-aria-snapshot.spec.ts` at 1.62.0-next. They are here
/// verbatim on purpose: the point of this file is to prove the port renders
/// the same format upstream does, not merely a self-consistent one. And since
/// the tree is computed in the page by the injected script, the same
/// expectation has to hold on all three engines — where it does not, the
/// divergence gets its own test that says so out loud.

/// Upstream's `unshift`: strips the indentation the expectation is written
/// with, plus the leading and trailing blank lines.
String unshift(String text) {
  var lines = text.split('\n');
  while (lines.isNotEmpty && lines.first.trim().isEmpty) {
    lines = lines.sublist(1);
  }
  while (lines.isNotEmpty && lines.last.trim().isEmpty) {
    lines = lines.sublist(0, lines.length - 1);
  }
  if (lines.isEmpty) return '';
  var indent = 1 << 30;
  for (final line in lines) {
    if (line.trim().isEmpty) continue;
    indent = indent < line.length - line.trimLeft().length
        ? indent
        : line.length - line.trimLeft().length;
  }
  return lines
      .map((line) => line.length >= indent ? line.substring(indent) : line)
      .join('\n');
}

void main() {
  group('ariaSnapshot', () {
    late Playwright playwright;

    setUpAll(() async {
      playwright = await Playwright.create();
    });

    for (final browserName in ['chromium', 'firefox', 'webkit']) {
      group('[$browserName]', () {
        late Browser browser;
        late BrowserContext context;
        late Page page;
        var browserLaunched = false;

        setUpAll(() async {
          browser = await switch (browserName) {
            'chromium' => playwright.chromium.launch(headless: true),
            'firefox' => playwright.firefox.launch(headless: true),
            _ => playwright.webkit.launch(headless: true),
          };
          browserLaunched = true;
        });

        tearDownAll(() async {
          if (browserLaunched) await browser.close();
        });

        setUp(() async {
          context = await browser.newContext();
          page = await context.newPage();
        });

        tearDown(() async {
          await context.close();
        });

        /// Sets [html] and asserts the page snapshot equals [expected].
        Future<void> check(String html, String expected) async {
          await page.setContent(html);
          expect(await page.ariaSnapshot(), equals(unshift(expected)));
        }

        test('should snapshot', () async {
          await check('<h1>title</h1>', '''
            - heading "title" [level=1]
          ''');
        });

        test('should snapshot list with accessible name', () async {
          await check('''
            <ul aria-label="my list">
              <li>one</li>
              <li>two</li>
            </ul>
          ''', '''
            - list "my list":
              - listitem: one
              - listitem: two
          ''');
        });

        test('should snapshot complex', () async {
          await check('''
            <ul>
              <li>
                <a href='about:blank'>link</a>
              </li>
            </ul>
          ''', '''
            - list:
              - listitem:
                - link "link":
                  - /url: about:blank
          ''');
        });

        test('should allow text nodes', () async {
          await check('''
            <h1>Microsoft</h1>
            <div>Open source projects and samples from Microsoft</div>
          ''', '''
            - heading "Microsoft" [level=1]
            - text: Open source projects and samples from Microsoft
          ''');
        });

        test('should snapshot details visibility', () async {
          await check('''
            <details>
              <summary>Summary</summary>
              <div>Details</div>
            </details>
          ''', '''
            - group: Summary
          ''');
        });

        test('should snapshot integration', () async {
          await check('''
            <h1>Microsoft</h1>
            <div>Open source projects and samples from Microsoft</div>
            <ul>
              <li>
                <details>
                  <summary>
                    Verified
                  </summary>
                  <div>
                    <div>
                      <p>
                        We've verified that the organization <strong>microsoft</strong> controls the domain:
                      </p>
                      <ul>
                        <li class="mb-1">
                          <strong>opensource.microsoft.com</strong>
                        </li>
                      </ul>
                      <div>
                        <a href="about: blank">Learn more about verified organizations</a>
                      </div>
                    </div>
                  </div>
                </details>
              </li>
              <li>
                <a href="about:blank">
                  <summary title="Label: GitHub Sponsor">Sponsor</summary>
                </a>
              </li>
            </ul>
          ''', '''
            - heading "Microsoft" [level=1]
            - text: Open source projects and samples from Microsoft
            - list:
              - listitem:
                - group: Verified
              - listitem:
                - link "Sponsor":
                  - /url: about:blank
          ''');
        });

        test('should support multiline text', () async {
          await check('''
            <p>
              Line 1
              Line 2
              Line 3
            </p>
          ''', '''
            - paragraph: Line 1 Line 2 Line 3
          ''');
        });

        test('should concatenate span text', () async {
          await check('''
            <span>One</span> <span>Two</span> <span>Three</span>
          ''', '''
            - text: One Two Three
          ''');
        });

        test('should concatenate span text 2', () async {
          await check('''
            <span>One </span><span>Two </span><span>Three</span>
          ''', '''
            - text: One Two Three
          ''');
        });

        test('should concatenate div text with spaces', () async {
          await check('''
            <div>One</div><div>Two</div><div>Three</div>
          ''', '''
            - text: One Two Three
          ''');
        });

        test('should include pseudo in text', () async {
          await check('''
            <style>
              span:before {
                content: 'world';
              }
              div:after {
                content: 'bye';
              }
            </style>
            <a href="about:blank">
              <span>hello</span>
              <div>hello</div>
            </a>
          ''', '''
            - link "worldhello hellobye":
              - /url: about:blank
          ''');
        });

        test('should not include hidden pseudo in text', () async {
          await check('''
            <style>
              span:before {
                content: 'world';
                display: none;
              }
              div:after {
                content: 'bye';
                visibility: hidden;
              }
            </style>
            <a href="about:blank">
              <span>hello</span>
              <div>hello</div>
            </a>
          ''', '''
            - link "hello hello":
              - /url: about:blank
          ''');
        });

        test('should include new line for block pseudo', () async {
          await check('''
            <style>
              span:before {
                content: 'world';
                display: block;
              }
              div:after {
                content: 'bye';
                display: block;
              }
            </style>
            <a href="about:blank">
              <span>hello</span>
              <div>hello</div>
            </a>
          ''', '''
            - link "world hello hello bye":
              - /url: about:blank
          ''');
        });

        test('should work with slots', () async {
          // Text "foo" is assigned to the slot, should not be used twice.
          await check('''
            <button><div>foo</div></button>
            <script>
              (() => {
                const container = document.querySelector('div');
                const shadow = container.attachShadow({ mode: 'open' });
                const slot = document.createElement('slot');
                shadow.appendChild(slot);
              })();
            </script>
          ''', '''
            - button "foo"
          ''');

          // Text "foo" is assigned to the slot, should be used instead of
          // slot content.
          await check('''
            <div>foo</div>
            <script>
              (() => {
                const container = document.querySelector('div');
                const shadow = container.attachShadow({ mode: 'open' });
                const button = document.createElement('button');
                shadow.appendChild(button);
                const slot = document.createElement('slot');
                button.appendChild(slot);
                const span = document.createElement('span');
                span.textContent = 'pre';
                slot.appendChild(span);
              })();
            </script>
          ''', '''
            - button "foo"
          ''');

          // Nothing is assigned to the slot, should use slot content.
          await check('''
            <div></div>
            <script>
              (() => {
                const container = document.querySelector('div');
                const shadow = container.attachShadow({ mode: 'open' });
                const button = document.createElement('button');
                shadow.appendChild(button);
                const slot = document.createElement('slot');
                button.appendChild(slot);
                const span = document.createElement('span');
                span.textContent = 'pre';
                slot.appendChild(span);
              })();
            </script>
          ''', '''
            - button "pre"
          ''');
        });

        test('should snapshot inner text', () async {
          await check('''
            <div role="listitem">
              <div>
                <div>
                  <span title="a.test.ts">a.test.ts</span>
                </div>
                <div>
                  <button title="Run"></button>
                  <button title="Show source"></button>
                  <button title="Watch"></button>
                </div>
              </div>
            </div>
            <div role="listitem">
              <div>
                <div>
                  <span title="snapshot">snapshot</span>
                </div>
                <div class="ui-mode-list-item-time">30ms</div>
                <div>
                  <button title="Run"></button>
                  <button title="Show source"></button>
                  <button title="Watch"></button>
                </div>
              </div>
            </div>
          ''', '''
            - listitem:
              - text: a.test.ts
              - button "Run"
              - button "Show source"
              - button "Watch"
            - listitem:
              - text: snapshot 30ms
              - button "Run"
              - button "Show source"
              - button "Watch"
          ''');
        });

        test('check aria-hidden text', () async {
          await check('''
            <p>
              <span>hello</span>
              <span aria-hidden="true">world</span>
            </p>
          ''', '''
            - paragraph: hello
          ''');
        });

        test('should ignore presentation and none roles', () async {
          await check('''
            <ul>
              <li role='presentation'>hello</li>
              <li role='none'>world</li>
            </ul>
          ''', '''
            - list: hello world
          ''');
        });

        test('should not use on as checkbox value', () async {
          await check('''
            <input type='checkbox'>
            <input type='radio'>
          ''', '''
            - checkbox
            - radio
          ''');
        });

        test('should respect aria-owns', () async {
          await check('''
            <a href='about:blank' aria-owns='input p'>
              <div role='region'>Link 1</div>
            </a>
            <a href='about:blank' aria-owns='input p'>
              <div role='region'>Link 2</div>
            </a>
            <input id='input' value='Value'>
            <p id='p'>Paragraph</p>
          ''', '''
            - link "Link 1 Value Paragraph":
              - /url: about:blank
              - region: Link 1
              - textbox: Value
              - paragraph: Paragraph
            - link "Link 2 Value Paragraph":
              - /url: about:blank
              - region: Link 2
          ''');
        });

        test('should be ok with circular ownership', () async {
          await check('''
            <a href='about:blank' id='parent'>
              <div role='region' aria-owns='parent'>Hello</div>
            </a>
          ''', '''
            - link "Hello":
              - /url: about:blank
              - region: Hello
          ''');
        });

        test('should escape yaml text in text nodes', () async {
          await check('''
            <details>
              <summary>one: <a href="#">link1</a> "two <a href="#">link2</a> 'three <a href="#">link3</a> `four</summary>
            </details>
            <ul>
              <a href="#">one</a>,<a href="#">two</a>
              (<a href="#">three</a>)
              {<a href="#">four</a>}
              [<a href="#">five</a>]
            </ul>
            <div>[Select all]</div>
          ''', r'''
            - group:
              - text: "one:"
              - link "link1":
                - /url: "#"
              - text: "\"two"
              - link "link2":
                - /url: "#"
              - text: "'three"
              - link "link3":
                - /url: "#"
              - text: "`four"
            - list:
              - link "one":
                - /url: "#"
              - text: ","
              - link "two":
                - /url: "#"
              - text: (
              - link "three":
                - /url: "#"
              - text: ") {"
              - link "four":
                - /url: "#"
              - text: "} ["
              - link "five":
                - /url: "#"
              - text: "]"
            - text: "[Select all]"
          ''');
        });

        test('should normalize whitespace', () async {
          await check('''
            <details>
              <summary> one  \n two <a href="#"> link &nbsp;\n  1 </a> </summary>
            </details>
            <input value='  hello   &nbsp; world '>
            <button>hello­​world</button>
          ''', '''
            - group:
              - text: one two
              - link "link 1":
                - /url: "#"
            - textbox: hello world
            - button "helloworld"
          ''');
        });

        test('should handle long strings', () async {
          final s = 'a' * 10000;
          await check('''
            <a href='about:blank'>
              <div role='region'>$s</div>
            </a>
          ''', '''
            - link:
              - /url: about:blank
              - region: $s
          ''');
        });

        test('should escape special yaml characters', () async {
          await check('''
            <a href="#">@hello</a>@hello
            <a href="#">]hello</a>]hello
            <a href="#">hello\n</a>
            hello\n<a href="#">\n hello</a>\n hello
            <a href="#">#hello</a>#hello
          ''', '''
            - link "@hello":
              - /url: "#"
            - text: "@hello"
            - link "]hello":
              - /url: "#"
            - text: "]hello"
            - link "hello":
              - /url: "#"
            - text: hello
            - link "hello":
              - /url: "#"
            - text: hello
            - link "#hello":
              - /url: "#"
            - text: "#hello"
          ''');
        });

        test('should escape special yaml values', () async {
          await check('''
            <a href="#">true</a>False
            <a href="#">NO</a>yes
            <a href="#">y</a>N
            <a href="#">on</a>Off
            <a href="#">null</a>NULL
            <a href="#">123</a>123
            <a href="#">-1.2</a>-1.2
            <a href="#">-</a>-
            <input type=text value="555">
          ''', '''
            - link "true":
              - /url: "#"
            - text: "False"
            - link "NO":
              - /url: "#"
            - text: "yes"
            - link "y":
              - /url: "#"
            - text: "N"
            - link "on":
              - /url: "#"
            - text: "Off"
            - link "null":
              - /url: "#"
            - text: "NULL"
            - link "123":
              - /url: "#"
            - text: "123"
            - link "-1.2":
              - /url: "#"
            - text: "-1.2"
            - link "-":
              - /url: "#"
            - text: "-"
            - textbox: "555"
          ''');
        });

        test('should not report textarea textContent', () async {
          await check('<textarea>Before</textarea>', '''
            - textbox: Before
          ''');
          await page.evaluate(
              "() => { document.querySelector('textarea').value = 'After'; }");
          expect(await page.ariaSnapshot(), equals('- textbox: After'));
        });

        test('should not show visible children of hidden elements', () async {
          await check('''
            <div style="visibility: hidden;">
              <div style="visibility: visible;">
                <button>Button</button>
              </div>
            </div>
          ''', '');
        });

        test('should not show unhidden children of aria-hidden elements',
            () async {
          await check('''
            <div aria-hidden="true">
              <div aria-hidden="false">
                <button>Button</button>
              </div>
            </div>
          ''', '');
        });

        test('should snapshot placeholder when different from the name',
            () async {
          await check('<input placeholder="Placeholder">', '''
            - textbox "Placeholder"
          ''');
          await check(
              '<input placeholder="Placeholder" aria-label="Label">', '''
            - textbox "Label":
              - /placeholder: Placeholder
          ''');
        });

        test('should not descend into iframes', () async {
          await check('''
            <div id=target>
              Hello
              <iframe srcdoc="<ul><li>Item 1</li><li>Item 2</li></ul>"></iframe>
            </div>
          ''', '''
            - text: Hello
            - iframe
          ''');
        });

        test('Locator.ariaSnapshot roots the snapshot at the element',
            () async {
          await page.setContent('''
            <h1>Fora</h1>
            <ul id=target>
              <li>Um</li>
              <li>Dois</li>
            </ul>
          ''');
          expect(
              await page.locator('#target').ariaSnapshot(), equals(unshift('''
            - list:
              - listitem: Um
              - listitem: Dois
          ''')));
        });
      });
    }
  });
}

// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: the `applyPlaywrightAttributes` function inside
// `snapshotScript()` of packages/isomorphic/trace/snapshotRenderer.ts.

/// The script the rendered snapshot runs to become a page again.
///
/// A snapshot is captured as attributes, because the capture cannot write a
/// checked checkbox or an open shadow root into HTML: it writes
/// `__playwright_checked_`, `__playwright_shadow_root_`, `__playwright_value_`
/// and their kin, and this script turns them back into state once the
/// document parses. It also highlights the action's target, places the click
/// pointer, rewires every `<iframe>` at the snapshot of its own frame, and
/// paints canvases from the closest screenshot.
///
/// Upstream ships the function by calling `.toString()` on it, so what the
/// browser runs is whatever TypeScript compiled. Dart cannot do that, so the
/// source is kept here as text — stripped of the TypeScript annotations that
/// a browser would reject, and otherwise statement for statement the same.
library;

import 'dart:convert';

/// The blank page an `<iframe>` with no recorded source is pointed at.
final String blankSnapshotUrl = 'data:text/html;base64,${base64Encode(
  latin1.encode('<body></body><style>body { color-scheme: light dark; '
      'background: light-dark(white, #333) }</style>'),
)}';

/// `JSON.stringify(value)`, with every `<` replaced by its JSON escape.
///
/// Trace data is untrusted; turning every `<` into its JSON escape is what
/// stops an attacker-controlled target id or viewport from closing the
/// surrounding `<script>` tag with a `</script>`.
String _safe(Object? value) => jsonEncode(value).replaceAll('<', r'\u003c');

/// Builds the inline bootstrap for one snapshot.
///
/// [targetIds] are the call id and, for traces old enough to have one, the
/// snapshot name: elements the capture marked with either are highlighted.
/// A null id is passed through as the string `undefined`, which is what
/// `String(undefined)` produces upstream and which matches nothing.
String snapshotScript(
  ({int width, int height}) viewport,
  List<String?> targetIds,
) {
  final args = StringBuffer()
    ..write(_safe(blankSnapshotUrl))
    ..write(',')
    ..write(_safe({'width': viewport.width, 'height': viewport.height}));
  for (final id in targetIds) {
    args.write(', ${_safe(id ?? 'undefined')}');
  }
  return '\n($_applyPlaywrightAttributes)($args)';
}

const String _applyPlaywrightAttributes = r'''
function applyPlaywrightAttributes(blankSnapshotUrl, viewport, ...targetIds) {
    const win = window;
    const searchParams = new URLSearchParams(win.location.search);
    const shouldPopulateCanvasFromScreenshot = searchParams.has('shouldPopulateCanvasFromScreenshot');
    const isUnderTest = searchParams.has('isUnderTest');

    // info to recursively compute canvas position relative to the top snapshot frame.
    // Before rendering each iframe, its parent extracts the '__playwright_canvas_render_info__' attribute
    // value and keeps in this variable. It can then remove the attribute and render the element,
    // which will eventually trigger the same process inside the iframe recursively.
    // When there's a canvas to render, we iterate over its ancestor frames to compute
    // its position relative to the top snapshot frame.
    const frameBoundingRectsInfo = {
      viewport,
      frames: new WeakMap(),
    };
    win['__playwright_frame_bounding_rects__'] = frameBoundingRectsInfo;

    const kPointerWarningTitle = 'Recorded click position in absolute coordinates did not' +
        ' match the center of the clicked element. This is either due to the use of provided offset,' +
        ' or due to a difference between the test runner and the trace viewer operating systems.';

    const scrollTops = [];
    const scrollLefts = [];
    const targetElements = [];
    const canvasElements = [];

    let topSnapshotWindow = win;
    while (topSnapshotWindow !== topSnapshotWindow.parent && new URLSearchParams(topSnapshotWindow.location.search).has('frameId'))
      topSnapshotWindow = topSnapshotWindow.parent;

    const visit = (root) => {
      // Collect all scrolled elements for later use.
      for (const e of root.querySelectorAll(`[__playwright_scroll_top_]`))
        scrollTops.push(e);
      for (const e of root.querySelectorAll(`[__playwright_scroll_left_]`))
        scrollLefts.push(e);

      for (const element of root.querySelectorAll(`style[__playwright_style_content__]`)) {
        element.textContent = element.getAttribute('__playwright_style_content__');
        element.removeAttribute('__playwright_style_content__');
      }

      for (const element of root.querySelectorAll(`[__playwright_value_]`)) {
        const inputElement = element;
        if (inputElement.type !== 'file')
          inputElement.value = inputElement.getAttribute('__playwright_value_');
        element.removeAttribute('__playwright_value_');
      }
      for (const element of root.querySelectorAll(`[__playwright_checked_]`)) {
        element.checked = element.getAttribute('__playwright_checked_') === 'true';
        element.removeAttribute('__playwright_checked_');
      }
      for (const element of root.querySelectorAll(`[__playwright_selected_]`)) {
        element.selected = element.getAttribute('__playwright_selected_') === 'true';
        element.removeAttribute('__playwright_selected_');
      }
      for (const element of root.querySelectorAll(`[__playwright_popover_open_]`)) {
        try {
          element.showPopover();
        } catch {
        }
        element.removeAttribute('__playwright_popover_open_');
      }
      for (const element of root.querySelectorAll(`[__playwright_dialog_open_]`)) {
        try {
          if (element.getAttribute('__playwright_dialog_open_') === 'modal')
            element.showModal();
          else
            element.show();
        } catch {
        }
        element.removeAttribute('__playwright_dialog_open_');
      }

      // Highlight targets marked by the current snapshotter, which sets `__playwright_target__`
      // to an empty string on the active target elements. For traces produced by older versions,
      // also match by callId/snapshotName, which used to be stored as the attribute value.
      const highlightTarget = (target) => {
        const style = target.style;
        style.outline = '2px solid #006ab1';
        style.backgroundColor = '#6fa8dc7f';
        targetElements.push(target);
      };
      for (const target of root.querySelectorAll(`[__playwright_target__=""]`))
        highlightTarget(target);
      for (const targetId of targetIds) {
        if (!targetId)
          continue;
        for (const target of root.querySelectorAll(`[__playwright_target__="${targetId}"]`))
          highlightTarget(target);
      }

      for (const iframe of root.querySelectorAll('iframe, frame')) {
        const boundingRectJson = iframe.getAttribute('__playwright_bounding_rect__');
        iframe.removeAttribute('__playwright_bounding_rect__');
        const boundingRect = boundingRectJson ? JSON.parse(boundingRectJson) : undefined;
        if (boundingRect)
          frameBoundingRectsInfo.frames.set(iframe, { boundingRect, scrollLeft: 0, scrollTop: 0 });
        const src = iframe.getAttribute('__playwright_src__');
        if (!src) {
          iframe.setAttribute('src', blankSnapshotUrl);
        } else {
          // The attribute value is recorded as `/snapshot/<frameId>` by the snapshotter.
          const frameId = src.substring(src.lastIndexOf('/') + 1);
          // All frames of a page share the snapshot name in the path, so we only swap the frame id.
          // Retain query parameters to inherit time=, pointX=, pointY= and other values from parent.
          const url = new URL(win.location.href);
          url.searchParams.set('frameId', frameId);
          iframe.setAttribute('src', url.toString());
        }
      }

      {
        const body = root.querySelector(`body[__playwright_custom_elements__]`);
        if (body && win.customElements) {
          const customElements = (body.getAttribute('__playwright_custom_elements__') || '').split(',');
          for (const elementName of customElements)
            win.customElements.define(elementName, class extends HTMLElement {});
        }
      }

      for (const element of root.querySelectorAll(`template[__playwright_shadow_root_]`)) {
        const template = element;
        const shadowRoot = template.parentElement.attachShadow({ mode: 'open' });
        shadowRoot.appendChild(template.content);
        template.remove();
        visit(shadowRoot);
      }

      for (const element of root.querySelectorAll('a'))
        element.addEventListener('click', event => { event.preventDefault(); });

      if ('adoptedStyleSheets' in root) {
        const adoptedSheets = [...root.adoptedStyleSheets];
        for (const element of root.querySelectorAll(`template[__playwright_style_sheet_]`)) {
          const template = element;
          const sheet = new CSSStyleSheet();
          sheet.replaceSync(template.getAttribute('__playwright_style_sheet_'));
          adoptedSheets.push(sheet);
        }
        root.adoptedStyleSheets = adoptedSheets;
      }

      canvasElements.push(...root.querySelectorAll('canvas'));
    };

    const onLoad = () => {
      win.removeEventListener('load', onLoad);
      for (const element of scrollTops) {
        element.scrollTop = +element.getAttribute('__playwright_scroll_top_');
        element.removeAttribute('__playwright_scroll_top_');
        if (frameBoundingRectsInfo.frames.has(element))
          frameBoundingRectsInfo.frames.get(element).scrollTop = element.scrollTop;
      }
      for (const element of scrollLefts) {
        element.scrollLeft = +element.getAttribute('__playwright_scroll_left_');
        element.removeAttribute('__playwright_scroll_left_');
        if (frameBoundingRectsInfo.frames.has(element))
          frameBoundingRectsInfo.frames.get(element).scrollLeft = element.scrollLeft;
      }

      win.document.styleSheets[0].disabled = true;

      const search = new URL(win.location.href).searchParams;
      const isTopFrame = win === topSnapshotWindow;

      if (isTopFrame && search.get('pointX') && search.get('pointY')) {
        const pointX = +search.get('pointX');
        const pointY = +search.get('pointY');

        const pointElement = win.document.createElement('x-pw-pointer');
        pointElement.style.position = 'fixed';
        pointElement.style.backgroundColor = '#f44336';
        pointElement.style.width = '20px';
        pointElement.style.height = '20px';
        pointElement.style.borderRadius = '10px';
        pointElement.style.margin = '-10px 0 0 -10px';
        pointElement.style.zIndex = '2147483646';
        pointElement.style.display = 'flex';
        pointElement.style.alignItems = 'center';
        pointElement.style.justifyContent = 'center';

        // Sometimes there are layout discrepancies between recording and rendering, e.g. fonts,
        // that may place the point at the wrong place. To avoid confusion, we just show the
        // point in the middle of the target element.
        const target = targetElements[0];
        const targetBox = target?.getBoundingClientRect();
        const targetCenter = target ? { x: targetBox.left + targetBox.width / 2, y: targetBox.top + targetBox.height / 2 } : null;
        pointElement.style.left = (targetCenter?.x ?? pointX) + 'px';
        pointElement.style.top = (targetCenter?.y ?? pointY) + 'px';

        const isAligned = !targetCenter || (Math.abs(targetCenter.x - pointX) <= 10 && Math.abs(targetCenter.y - pointY) <= 10);
        if (!isAligned) {
          const warningElement = win.document.createElement('x-pw-pointer-warning');
          warningElement.textContent = '⚠';
          warningElement.style.fontSize = '19px';
          warningElement.style.color = 'white';
          warningElement.style.marginTop = '-3.5px';
          warningElement.style.userSelect = 'none';
          pointElement.appendChild(warningElement);
          pointElement.setAttribute('title', kPointerWarningTitle);
        }

        win.document.documentElement.appendChild(pointElement);
      }

      if (canvasElements.length > 0) {
        function drawCheckerboard(context, canvas) {
          function createCheckerboardPattern() {
            const pattern = win.document.createElement('canvas');
            pattern.width = pattern.width / Math.floor(pattern.width / 24);
            pattern.height = pattern.height / Math.floor(pattern.height / 24);
            const context = pattern.getContext('2d');
            context.fillStyle = 'lightgray';
            context.fillRect(0, 0, pattern.width, pattern.height);
            context.fillStyle = 'white';
            context.fillRect(0, 0, pattern.width / 2, pattern.height / 2);
            context.fillRect(pattern.width / 2, pattern.height / 2, pattern.width, pattern.height);
            return context.createPattern(pattern, 'repeat');
          }

          context.fillStyle = createCheckerboardPattern();
          context.fillRect(0, 0, canvas.width, canvas.height);
        }

        const img = new Image();
        img.onload = () => {
          for (const canvas of canvasElements) {
            const context = canvas.getContext('2d');

            const boundingRectAttribute = canvas.getAttribute('__playwright_bounding_rect__');
            canvas.removeAttribute('__playwright_bounding_rect__');
            if (!boundingRectAttribute)
              continue;

            let boundingRect;
            try {
              boundingRect = JSON.parse(boundingRectAttribute);
            } catch (e) {
              continue;
            }

            let currWindow = win;
            while (currWindow !== topSnapshotWindow) {
              const iframe = currWindow.frameElement;
              currWindow = currWindow.parent;

              const iframeInfo = currWindow['__playwright_frame_bounding_rects__']?.frames.get(iframe);
              if (!iframeInfo?.boundingRect)
                break;

              const leftOffset = iframeInfo.boundingRect.left - iframeInfo.scrollLeft;
              const topOffset = iframeInfo.boundingRect.top - iframeInfo.scrollTop;

              boundingRect.left += leftOffset;
              boundingRect.top += topOffset;
              boundingRect.right += leftOffset;
              boundingRect.bottom += topOffset;
            }

            const { width, height } = topSnapshotWindow['__playwright_frame_bounding_rects__'].viewport;

            boundingRect.left = boundingRect.left / width;
            boundingRect.top = boundingRect.top / height;
            boundingRect.right = boundingRect.right / width;
            boundingRect.bottom = boundingRect.bottom / height;

            const partiallyUncaptured = boundingRect.right > 1 || boundingRect.bottom > 1;
            const fullyUncaptured = boundingRect.left > 1 || boundingRect.top > 1;
            if (fullyUncaptured) {
              canvas.title = `Playwright couldn't capture canvas contents because it's located outside the viewport.`;
              continue;
            }

            drawCheckerboard(context, canvas);

            if (shouldPopulateCanvasFromScreenshot) {
              context.drawImage(img, boundingRect.left * img.width, boundingRect.top * img.height, (boundingRect.right - boundingRect.left) * img.width, (boundingRect.bottom - boundingRect.top) * img.height, 0, 0, canvas.width, canvas.height);

              if (partiallyUncaptured)
                canvas.title = `Playwright couldn't capture full canvas contents because it's located partially outside the viewport.`;
              else
                canvas.title = `Canvas contents are displayed on a best-effort basis based on viewport screenshots taken during test execution.`;
            } else {
              canvas.title = 'Canvas content display is disabled.';
            }

            if (isUnderTest)
              console.log(`canvas drawn:`, JSON.stringify([boundingRect.left, boundingRect.top, (boundingRect.right - boundingRect.left), (boundingRect.bottom - boundingRect.top)].map(v => Math.floor(v * 100))));
          }
        };
        img.onerror = () => {
          for (const canvas of canvasElements) {
            const context = canvas.getContext('2d');
            drawCheckerboard(context, canvas);
            canvas.title = `Playwright couldn't show canvas contents because the screenshot failed to load.`;
          }
        };
        img.src = location.href.replace('/snapshot', '/closest-screenshot');
      }
    };

    const onDOMContentLoaded = () => visit(win.document);

    win.addEventListener('load', onLoad);
    win.addEventListener('DOMContentLoaded', onDOMContentLoaded);
  }''';

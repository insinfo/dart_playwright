/// The page itself: markup, style and the script that renders the report.
///
/// It is one string on purpose. The report has to survive being emailed,
/// copied off a CI worker and opened from a `file://` URL with no server
/// behind it, and a single self-contained `index.html` is the only shape that
/// does all three. The only thing next to it is `data/`, which holds the
/// attachments the page links to.
library;

/// Renders `index.html` with [payloadBase64] inlined.
///
/// [payloadBase64] is base64 of the UTF-8 JSON built by `HtmlReporter`. It is
/// base64 and not raw JSON for one boring reason: a failure message containing
/// `</script>` would otherwise close the tag and blank the page, and a report
/// that breaks precisely on the interesting failures is worthless.
String renderIndexHtml(String title, String payloadBase64) => '''
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta name="color-scheme" content="dark light">
<title>${_escapeHtml(title)}</title>
<style>
$_css
</style>
</head>
<body>
<div id="root"></div>
<template id="playwrightReportJson">data:application/json;base64,$payloadBase64</template>
<script>
$_js
</script>
</body>
</html>
''';

String _escapeHtml(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

const _css = r'''
:root {
  --bg: #ffffff;
  --bg-subtle: #f6f8fa;
  --fg: #1f2328;
  --fg-muted: #59636e;
  --border: #d1d9e0;
  --accent: #0969da;
  --danger: #cf222e;
  --success: #1a7f37;
  --warning: #9a6700;
  --neutral: #59636e;
  --mono: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0d1117;
    --bg-subtle: #151b23;
    --fg: #f0f6fc;
    --fg-muted: #9198a1;
    --border: #3d444d;
    --accent: #4493f8;
    --danger: #f85149;
    --success: #3fb950;
    --warning: #d29922;
    --neutral: #9198a1;
  }
}
* { box-sizing: border-box; }
body {
  margin: 0;
  background: var(--bg);
  color: var(--fg);
  font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
}
a { color: var(--accent); text-decoration: none; }
a:hover { text-decoration: underline; }
.wrap { max-width: 1100px; margin: 0 auto; padding: 16px; }
header.top { border-bottom: 1px solid var(--border); background: var(--bg-subtle); }
h1 { font-size: 20px; margin: 0 0 4px; }
h1.detail { margin: 12px 0 4px; }
.subtitle { color: var(--fg-muted); font-size: 13px; }
.tabs { display: flex; flex-wrap: wrap; gap: 4px; margin-top: 12px; }
.tab {
  padding: 6px 12px; border-radius: 6px; border: 1px solid transparent;
  color: var(--fg); cursor: pointer; background: none; font: inherit;
}
.tab:hover { background: var(--bg); }
.tab.on { border-color: var(--border); background: var(--bg); font-weight: 600; }
.tab .n { color: var(--fg-muted); margin-left: 4px; }
.search {
  width: 100%; margin-top: 12px; padding: 7px 10px; border-radius: 6px;
  border: 1px solid var(--border); background: var(--bg); color: var(--fg);
  font: inherit;
}
.hint { color: var(--fg-muted); font-size: 12px; margin-top: 6px; }
.file { border: 1px solid var(--border); border-radius: 8px; margin-bottom: 12px; overflow: hidden; }
.file > .head {
  padding: 8px 12px; background: var(--bg-subtle); font-family: var(--mono);
  font-size: 13px; display: flex; justify-content: space-between; gap: 8px;
}
.row {
  display: flex; align-items: flex-start; gap: 8px; padding: 8px 12px;
  border-top: 1px solid var(--border); cursor: pointer;
}
.row:hover { background: var(--bg-subtle); }
.row .title { flex: 1; min-width: 0; }
.row .path { color: var(--fg-muted); }
.row .ms { color: var(--fg-muted); font-variant-numeric: tabular-nums; white-space: nowrap; }
.icon { width: 16px; text-align: center; flex: none; font-weight: 700; }
.expected .icon, .passed { color: var(--success); }
.unexpected .icon, .failed { color: var(--danger); }
.flaky .icon { color: var(--warning); }
.skipped .icon { color: var(--neutral); }
.timedout .icon { color: var(--warning); }
.chip {
  display: inline-block; margin-left: 6px; padding: 1px 7px;
  border-radius: 999px; border: 1px solid var(--border);
  font-size: 12px; color: var(--fg-muted);
}
.back { display: inline-block; margin-bottom: 12px; cursor: pointer; }
.runs { display: flex; gap: 4px; margin: 12px 0; flex-wrap: wrap; }
.err {
  background: var(--bg-subtle); border: 1px solid var(--danger);
  border-left-width: 4px; border-radius: 6px; padding: 10px 12px;
  font-family: var(--mono); font-size: 12.5px; white-space: pre-wrap;
  overflow-x: auto; margin: 10px 0;
}
h2 { font-size: 15px; margin: 20px 0 8px; }
.steps { list-style: none; margin: 0; padding: 0; }
.steps ul { list-style: none; margin: 0; padding-left: 18px; }
.steps li { padding: 3px 0; border-top: 1px solid var(--border); }
.steps .line { display: flex; gap: 8px; align-items: baseline; }
.steps .line .t { flex: 1; min-width: 0; }
.att { border: 1px solid var(--border); border-radius: 8px; padding: 10px 12px; margin-bottom: 10px; }
.att .name { font-family: var(--mono); font-size: 13px; margin-bottom: 8px; }
.att img, .att video { max-width: 100%; border: 1px solid var(--border); border-radius: 6px; display: block; }
.att pre { margin: 0; white-space: pre-wrap; font-size: 12.5px; }
.empty { color: var(--fg-muted); padding: 24px 0; text-align: center; }
.stdio { background: var(--bg-subtle); border: 1px solid var(--border); border-radius: 6px;
  padding: 10px 12px; font-family: var(--mono); font-size: 12.5px; white-space: pre-wrap; overflow-x: auto; }
''';

const _js = r'''
'use strict';

// ---------------------------------------------------------------------------
// Data
// ---------------------------------------------------------------------------

function loadPayload() {
  const template = document.getElementById('playwrightReportJson');
  const text = template.content.textContent.trim();
  const base64 = text.slice(text.indexOf(',') + 1);
  const bytes = Uint8Array.from(atob(base64), c => c.charCodeAt(0));
  return JSON.parse(new TextDecoder('utf-8').decode(bytes));
}

const payload = loadPayload();
const report = payload.report;
const filesById = payload.files;

// ---------------------------------------------------------------------------
// Filter -- ported from packages/html-reporter/src/filter.ts
//
// The grammar is the part of the upstream report that is real behaviour rather
// than chrome, so it is reproduced rather than simplified: `p:` project, `s:`
// status, `@tag`, `annot:`, a leading `!` to negate any of them, quoting to
// keep a phrase together, and bare text matched against a haystack or against
// `file:line:column`.
// ---------------------------------------------------------------------------

function tokenize(expression) {
  const result = [];
  let quote;
  let token = [];
  for (let i = 0; i < expression.length; ++i) {
    const c = expression[i];
    if (quote && c === '\\' && expression[i + 1] === quote) { token.push(quote); ++i; continue; }
    if (c === '"' || c === "'") {
      if (quote === c) { result.push(token.join('').toLowerCase()); token = []; quote = undefined; }
      else if (quote) token.push(c);
      else quote = c;
      continue;
    }
    if (quote) { token.push(c); continue; }
    if (c === ' ') { if (token.length) { result.push(token.join('').toLowerCase()); token = []; } continue; }
    token.push(c);
  }
  if (token.length) result.push(token.join('').toLowerCase());
  return result;
}

function parseFilter(expression) {
  const filter = { project: [], status: [], text: [], labels: [], annotations: [] };
  for (let token of tokenize(expression || '')) {
    const not = token.startsWith('!');
    if (not) token = token.slice(1);
    if (token.startsWith('p:')) filter.project.push({ name: token.slice(2), not });
    else if (token.startsWith('s:')) filter.status.push({ name: token.slice(2), not });
    else if (token.startsWith('@')) filter.labels.push({ name: token, not });
    else if (token.startsWith('annot:')) filter.annotations.push({ name: token.slice(6), not });
    else filter.text.push({ name: token.toLowerCase(), not });
  }
  return filter;
}

function searchValues(test) {
  if (test.__search) return test.__search;
  let status = 'passed';
  if (test.outcome === 'unexpected') status = 'failed';
  if (test.outcome === 'flaky') status = 'flaky';
  if (test.outcome === 'skipped') status = 'skipped';
  test.__search = {
    text: (status + ' ' + test.projectName + ' ' + test.tags.join(' ') + ' ' +
      test.location.file + ' ' + test.path.join(' ') + ' ' + test.title).toLowerCase(),
    project: test.projectName.toLowerCase(),
    status,
    file: test.location.file,
    line: String(test.location.line),
    column: String(test.location.column),
    labels: test.tags.map(t => t.toLowerCase()),
    annotations: test.annotations.map(a => a.type.toLowerCase() + '=' + (a.description || '').toLowerCase()),
  };
  return test.__search;
}

function matches(filter, test) {
  const v = searchValues(test);
  if (filter.project.length) {
    const ok = filter.project.some(p => p.not ? !v.project.includes(p.name) : v.project.includes(p.name));
    if (!ok) return false;
  }
  if (filter.status.length) {
    const ok = filter.status.some(s => s.not ? !v.status.includes(s.name) : v.status.includes(s.name));
    if (!ok) return false;
  } else if (v.status === 'skipped') {
    // Upstream's default: with no `s:` token at all, skipped tests are hidden.
    return false;
  }
  if (filter.text.length) {
    const ok = filter.text.every(text => {
      if (v.text.includes(text.name)) return !text.not;
      const [fileName, line, column] = text.name.split(':');
      if (v.file.includes(fileName) && v.line === line && (column === undefined || v.column === column))
        return !text.not;
      return !!text.not;
    });
    if (!ok) return false;
  }
  if (filter.labels.length) {
    const ok = filter.labels.every(l => l.not ? !v.labels.includes(l.name) : v.labels.includes(l.name));
    if (!ok) return false;
  }
  if (filter.annotations.length) {
    const ok = filter.annotations.every(a => {
      const hit = v.annotations.some(x => x.includes(a.name));
      return a.not ? !hit : hit;
    });
    if (!ok) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// Routing: everything lives in the hash so the page works from file://
// ---------------------------------------------------------------------------

function route() {
  const hash = location.hash.replace(/^#\??/, '');
  return new URLSearchParams(hash);
}

function navigate(changes) {
  const params = route();
  for (const [key, value] of Object.entries(changes)) {
    if (value === undefined || value === null || value === '') params.delete(key);
    else params.set(key, value);
  }
  location.hash = '?' + params.toString();
}

// ---------------------------------------------------------------------------
// Rendering helpers
// ---------------------------------------------------------------------------

function el(tag, props, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(props || {})) {
    if (key === 'class') node.className = value;
    else if (key === 'text') node.textContent = value;
    else if (key.startsWith('on')) node.addEventListener(key.slice(2), value);
    else if (value !== undefined && value !== null) node.setAttribute(key, value);
  }
  for (const child of children.flat()) {
    if (child === undefined || child === null || child === false) continue;
    node.append(child);
  }
  return node;
}

function ms(value) {
  if (value < 1000) return value + 'ms';
  if (value < 60000) return (value / 1000).toFixed(1) + 's';
  const minutes = Math.floor(value / 60000);
  return minutes + 'm ' + Math.round((value % 60000) / 1000) + 's';
}

const ICONS = {
  expected: '✓', passed: '✓',
  unexpected: '✗', failed: '✗',
  flaky: '⚠', timedout: '◴',
  skipped: '–', interrupted: '–',
};

function icon(outcome) {
  return el('span', { class: 'icon', text: ICONS[outcome] || '•' });
}

function allTests() {
  return report.files.flatMap(file => file.tests.map(test => ({ test, file })));
}

// ---------------------------------------------------------------------------
// Views
// ---------------------------------------------------------------------------

function renderHeader(query, filtered) {
  const s = report.stats;
  const tabs = [
    ['All', '', s.total - s.skipped],
    ['Passed', 's:passed', s.expected],
    ['Failed', 's:failed', s.unexpected],
    ['Flaky', 's:flaky', s.flaky],
    ['Skipped', 's:skipped', s.skipped],
  ];
  const nav = el('div', { class: 'tabs' }, tabs.map(([label, token, count]) =>
    el('button', {
      class: 'tab' + (query.trim() === token ? ' on' : ''),
      onclick: () => navigate({ q: token, testId: undefined, run: undefined }),
    }, label, el('span', { class: 'n', text: String(count) }))));

  const search = el('input', {
    class: 'search', type: 'search', value: query,
    placeholder: 'Filter: s:failed  p:vm  @smoke  !@slow  "some phrase"  file.dart:12',
  });
  search.addEventListener('input', () => navigate({ q: search.value }));

  // The count only means something next to a list. On a detail page there is
  // no list, and "0 shown" next to one open test reads like a bug.
  const duration = el('div', { class: 'subtitle' },
    new Date(report.startTime).toLocaleString() + ' · ' + ms(report.duration) +
    (filtered === null ? '' : ' · ' + filtered.length + ' shown'));

  const errors = report.errors.length
    ? report.errors.map(message => el('div', { class: 'err', text: message }))
    : [];

  return el('header', { class: 'top' },
    el('div', { class: 'wrap' },
      el('h1', { text: report.options.title || 'Playwright Test Report' }),
      duration, nav, search,
      el('div', { class: 'hint', text: 'Tokens: s:<status> p:<project> @tag annot:<text>, ! to negate, quotes to group.' }),
      errors));
}

function renderList(query) {
  const filter = parseFilter(query);
  const visible = allTests().filter(entry => matches(filter, entry.test));
  const body = el('div', { class: 'wrap' });

  if (!visible.length) {
    body.append(el('div', { class: 'empty', text: 'No test matches this filter.' }));
  }

  for (const file of report.files) {
    const tests = file.tests.filter(test => matches(filter, test));
    if (!tests.length) continue;
    const total = tests.reduce((sum, test) => sum + test.duration, 0);
    const card = el('div', { class: 'file' },
      el('div', { class: 'head' },
        el('span', { text: file.fileName }),
        el('span', { class: 'ms', text: ms(total) })));
    for (const test of tests) {
      card.append(el('div', {
        class: 'row ' + test.outcome,
        onclick: () => navigate({ testId: test.testId, run: '0' }),
      },
        icon(test.outcome),
        el('div', { class: 'title' },
          test.path.length ? el('span', { class: 'path', text: test.path.join(' › ') + ' › ' }) : null,
          el('span', { text: test.title }),
          test.projectName ? el('span', { class: 'chip', text: test.projectName }) : null,
          ...test.tags.map(tag => el('span', { class: 'chip', text: tag }))),
        el('span', { class: 'ms', text: ms(test.duration) })));
    }
    body.append(card);
  }
  return { body, visible };
}

function findTest(testId) {
  for (const fileId of Object.keys(filesById)) {
    const file = filesById[fileId];
    const test = file.tests.find(t => t.testId === testId);
    if (test) return { test, file };
  }
  return null;
}

function renderAttachment(attachment) {
  const card = el('div', { class: 'att' },
    el('div', { class: 'name', text: attachment.name + ' (' + attachment.contentType + ')' }));
  if (attachment.path && attachment.contentType.startsWith('image/')) {
    card.append(el('a', { href: attachment.path, target: '_blank' },
      el('img', { src: attachment.path, alt: attachment.name })));
  } else if (attachment.path && attachment.contentType.startsWith('video/')) {
    const video = el('video', { controls: '' });
    video.append(el('source', { src: attachment.path, type: attachment.contentType }));
    card.append(video);
  } else if (attachment.body !== undefined) {
    card.append(el('pre', { text: attachment.body }));
  } else if (attachment.path) {
    const note = attachment.name === 'trace'
      ? ' — open it with: dart run playwright:show_trace <file>'
      : '';
    card.append(el('div', {},
      el('a', { href: attachment.path, download: '' , text: attachment.path }),
      el('span', { class: 'hint', text: note })));
  } else {
    card.append(el('div', { class: 'hint', text: 'No content recorded for this attachment.' }));
  }
  return card;
}

function renderSteps(steps, attachments) {
  const list = el('ul', { class: 'steps' });
  for (const step of steps) {
    const item = el('li', {},
      el('div', { class: 'line' },
        icon(step.error ? 'failed' : 'passed'),
        el('span', { class: 't', text: step.title }),
        el('span', { class: 'ms', text: ms(step.duration) })));
    if (step.error) item.append(el('div', { class: 'err', text: step.error }));
    for (const index of step.attachments || []) {
      if (attachments[index]) item.append(renderAttachment(attachments[index]));
    }
    if (step.steps && step.steps.length) item.append(renderSteps(step.steps, attachments));
    list.append(item);
  }
  return list;
}

function renderDetail(testId, run) {
  const found = findTest(testId);
  const body = el('div', { class: 'wrap' });
  body.append(el('a', { class: 'back', text: '← Back to all tests', onclick: () => navigate({ testId: undefined, run: undefined }) }));
  if (!found) {
    body.append(el('div', { class: 'empty', text: 'That test is not in this report.' }));
    return body;
  }
  const { test, file } = found;
  body.append(el('h1', { class: 'detail' },
    icon(test.outcome),
    ' ',
    test.path.length ? test.path.join(' › ') + ' › ' : '',
    test.title));
  body.append(el('div', { class: 'subtitle', text: file.fileName + ':' + test.location.line + ' · ' + test.projectName + ' · ' + ms(test.duration) }));

  const index = Math.min(Number(run) || 0, test.results.length - 1);
  if (test.results.length > 1) {
    body.append(el('div', { class: 'runs' }, test.results.map((result, i) =>
      el('button', {
        class: 'tab' + (i === index ? ' on' : ''),
        onclick: () => navigate({ run: String(i) }),
      }, i === 0 ? 'Run' : 'Retry #' + i, el('span', { class: 'n', text: result.status })))));
  }

  const result = test.results[index];
  if (!result) {
    body.append(el('div', { class: 'empty', text: 'This test produced no result.' }));
    return body;
  }

  for (const error of result.errors) {
    body.append(el('div', { class: 'err', text: error.message }));
  }

  if (result.steps.length) {
    body.append(el('h2', { text: 'Steps' }));
    body.append(renderSteps(result.steps, result.attachments));
  }

  const shown = new Set();
  for (const step of flattenSteps(result.steps)) {
    for (const i of step.attachments || []) shown.add(i);
  }
  const rest = result.attachments.filter((_, i) => !shown.has(i));
  if (rest.length) {
    body.append(el('h2', { text: 'Attachments' }));
    for (const attachment of rest) body.append(renderAttachment(attachment));
  }
  return body;
}

function flattenSteps(steps) {
  const out = [];
  for (const step of steps) {
    out.push(step);
    out.push(...flattenSteps(step.steps || []));
  }
  return out;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

function render() {
  const params = route();
  const query = params.get('q') || '';
  const testId = params.get('testId');
  const root = document.getElementById('root');
  root.textContent = '';
  if (testId) {
    root.append(renderHeader(query, null));
    root.append(renderDetail(testId, params.get('run')));
    return;
  }
  const { body, visible } = renderList(query);
  root.append(renderHeader(query, visible));
  root.append(body);
}

window.addEventListener('hashchange', render);
document.title = report.options.title || 'Playwright Test Report';
render();
''';

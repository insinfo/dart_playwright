import 'package:playwright/playwright.dart';

/// Builds the page snapshot the agent reads, and stamps every listed element
/// with a `data-pw-ref` attribute so a later tool call can address it.
///
/// This is deliberately *not* `page.accessibilitySnapshot()`. That one now
/// answers on all three engines and computes real ARIA roles and names, but it
/// hands back a tree of values: nothing in it points at an element, so an
/// agent could read it and still not be able to click anything. The `ref`
/// stamping below is the whole point of this tool. Giving the aria tree
/// element handles is upstream's `ai` mode, which this port does not have.
///
/// The role and name computation is pragmatic rather than a full ARIA
/// implementation: an explicit `role` wins, then a small tag-to-role table
/// covering the interactive set, and the name comes from `aria-label`, a
/// referenced or wrapping `<label>`, `placeholder`, `alt`, `title` or the
/// element's own text. It is enough for an agent to find and act on things;
/// it is not an accessibility audit.
const String snapshotScript = r'''
() => {
  const ROLE_BY_TAG = {
    A: 'link', BUTTON: 'button', H1: 'heading', H2: 'heading', H3: 'heading',
    H4: 'heading', H5: 'heading', H6: 'heading', IMG: 'img', NAV: 'navigation',
    MAIN: 'main', HEADER: 'banner', FOOTER: 'contentinfo', FORM: 'form',
    TABLE: 'table', UL: 'list', OL: 'list', LI: 'listitem', P: 'paragraph',
    SELECT: 'combobox', TEXTAREA: 'textbox', SUMMARY: 'button',
    DIALOG: 'dialog', OPTION: 'option', LABEL: 'label',
  };
  const ROLE_BY_INPUT_TYPE = {
    button: 'button', submit: 'button', reset: 'button', image: 'button',
    checkbox: 'checkbox', radio: 'radio', range: 'slider', number: 'spinbutton',
    search: 'searchbox', email: 'textbox', tel: 'textbox', text: 'textbox',
    url: 'textbox', password: 'textbox', file: 'button',
  };

  const roleOf = (el) => {
    const explicit = el.getAttribute('role');
    if (explicit) return explicit.trim().split(/\s+/)[0];
    if (el.tagName === 'INPUT')
      return ROLE_BY_INPUT_TYPE[(el.type || 'text').toLowerCase()] || 'textbox';
    return ROLE_BY_TAG[el.tagName] || null;
  };

  const clean = (value) => (value || '').replace(/\s+/g, ' ').trim();

  const nameOf = (el) => {
    const aria = el.getAttribute('aria-label');
    if (clean(aria)) return clean(aria);
    const labelledBy = el.getAttribute('aria-labelledby');
    if (labelledBy) {
      const parts = labelledBy.split(/\s+/)
          .map(id => document.getElementById(id))
          .filter(Boolean)
          .map(node => clean(node.textContent));
      if (parts.join(' ').trim()) return clean(parts.join(' '));
    }
    if (el.id) {
      const label = document.querySelector('label[for="' + CSS.escape(el.id) + '"]');
      if (label && clean(label.textContent)) return clean(label.textContent);
    }
    const wrapping = el.closest ? el.closest('label') : null;
    if (wrapping && clean(wrapping.textContent)) return clean(wrapping.textContent);
    for (const attr of ['placeholder', 'alt', 'title', 'value']) {
      const value = el.getAttribute(attr);
      if (clean(value)) return clean(value);
    }
    return clean(el.textContent).slice(0, 80);
  };

  const isVisible = (el) => {
    const style = window.getComputedStyle(el);
    if (style.visibility === 'hidden' || style.display === 'none') return false;
    if (el.hasAttribute('hidden') || el.getAttribute('aria-hidden') === 'true')
      return false;
    const rect = el.getBoundingClientRect();
    return rect.width > 0 || rect.height > 0;
  };

  const lines = [];
  let counter = 0;

  const walk = (el, depth) => {
    let nextDepth = depth;
    const role = roleOf(el);
    if (role && isVisible(el)) {
      const ref = 'e' + (++counter);
      el.setAttribute('data-pw-ref', ref);
      const name = nameOf(el);
      const extras = [];
      if (el.disabled) extras.push('disabled');
      if (el.checked) extras.push('checked');
      if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
        if (el.value) extras.push('value=' + JSON.stringify(el.value));
      }
      lines.push('  '.repeat(depth) + '- ' + role +
          (name ? ' ' + JSON.stringify(name) : '') +
          ' [ref=' + ref + ']' +
          (extras.length ? ' (' + extras.join(', ') + ')' : ''));
      nextDepth = depth + 1;
    }
    for (const child of el.children) walk(child, nextDepth);
  };

  // Clear refs from a previous snapshot, so a stale ref fails loudly instead
  // of pointing at whatever element inherited the number.
  for (const stale of document.querySelectorAll('[data-pw-ref]'))
    stale.removeAttribute('data-pw-ref');

  if (document.body) walk(document.body, 0);
  return {
    url: window.location.href,
    title: document.title,
    tree: lines.join('\n'),
  };
}
''';

/// Renders a snapshot of [page] as the text the model reads.
Future<String> renderSnapshot(Page page) async {
  final result = await page.evaluate(snapshotScript) as Map;
  final tree = (result['tree'] as String?) ?? '';
  return [
    'url: ${result['url']}',
    'title: ${result['title']}',
    '',
    tree.isEmpty ? '(no interactive or landmark elements found)' : tree,
  ].join('\n');
}

/// Resolves the element a tool was asked to act on.
///
/// Accepts, in order of precedence: `ref` (from the last snapshot), `selector`
/// (CSS or any selector the port understands), or `role` plus optional `name`.
Locator resolveTarget(Page page, Map<String, dynamic> args, String toolName) {
  final ref = args['ref'];
  if (ref is String && ref.isNotEmpty) {
    return page.locator('[data-pw-ref="$ref"]');
  }
  final selector = args['selector'];
  if (selector is String && selector.isNotEmpty) {
    return page.locator(selector);
  }
  final role = args['role'];
  if (role is String && role.isNotEmpty) {
    final name = args['name'];
    return page.getByRole(role,
        name: name is String && name.isNotEmpty ? name : null);
  }
  throw ArgumentError(
      '$toolName needs one of: "ref" (from browser_snapshot), "selector", '
      'or "role" with an optional "name"');
}

/// The JSON Schema fragment every element-targeting tool shares.
Map<String, dynamic> targetSchemaProperties() => {
      'ref': {
        'type': 'string',
        'description':
            'Element reference from the last browser_snapshot, e.g. "e7".',
      },
      'selector': {
        'type': 'string',
        'description': 'CSS selector, as an alternative to ref.',
      },
      'role': {
        'type': 'string',
        'description': 'ARIA role, as an alternative to ref.',
      },
      'name': {
        'type': 'string',
        'description': 'Accessible name, used together with role.',
      },
    };

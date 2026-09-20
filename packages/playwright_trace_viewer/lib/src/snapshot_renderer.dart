// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/trace/snapshotRenderer.ts

/// Rebuilds the HTML of one captured DOM tree.
///
/// This is the half of the snapshot panel that has no UI: given the
/// `frame-snapshot` events of one frame and the resources of the trace, it
/// produces the document the panel loads in its iframe, and answers which
/// recorded response a request from inside that document should be served.
///
/// Two things make it more than a tree walk:
///
/// - **The subtree cache.** A snapshot may say `[[n, i]]` — "take node number
///   `i` of the snapshot `n` captures ago" — which is how a hundred-action
///   trace avoids holding a hundred copies of the same page. Resolving it
///   means numbering the nodes of an older snapshot in post-order, counting
///   only the nodes that are not themselves references.
/// - **The sanitizing.** A trace file is data from outside; a crafted one
///   must not run script in the viewer. Scripts are dropped, event handler
///   attributes are dropped, `srcdoc`, `sandbox` and dangerous `http-equiv`
///   directives are renamed out of the way, and the bootstrap runs under a
///   nonce so nothing else can.
library;

import 'dart:math';

import 'lru_cache.dart';
import 'snapshot_script.dart';
import 'string_utils.dart';
import 'trace.dart';

export 'snapshot_script.dart' show blankSnapshotUrl;

/// The rendered HTML of one snapshot plus the nonce its bootstrap runs under.
class RenderedSnapshotHtml {
  final String html;
  final String scriptNonce;

  const RenderedSnapshotHtml({required this.html, required this.scriptNonce});
}

/// [RenderedSnapshotHtml] plus where the snapshot came from.
class RenderedFrameSnapshot {
  final String html;
  final String scriptNonce;
  final String pageId;
  final String frameId;
  final int index;

  const RenderedFrameSnapshot({
    required this.html,
    required this.scriptNonce,
    required this.pageId,
    required this.frameId,
    required this.index,
  });
}

/// Returns the item of [items] whose [metric] is closest to [target].
///
/// Upstream's `findClosest`: a linear scan that stops as soon as the next
/// item would be further away, which works because the frames are ordered.
T? findClosest<T>(List<T> items, double Function(T) metric, double target) {
  for (var index = 0; index < items.length; index++) {
    final item = items[index];
    if (index == items.length - 1) return item;
    final next = items[index + 1];
    if ((metric(item) - target).abs() < (metric(next) - target).abs()) {
      return item;
    }
  }
  return null;
}

/// Renders one snapshot of one frame.
///
/// One renderer is built per `frame-snapshot` event; it holds the whole list
/// of that frame's snapshots because a reference reaches back into them.
class SnapshotRenderer {
  final LruCache<SnapshotRenderer, RenderedSnapshotHtml> _htmlCache;
  final List<FrameSnapshot> _snapshots;
  final int _index;

  /// The legacy name of this snapshot, for traces recorded before phases.
  final String? snapshotName;
  final List<ResourceSnapshot> _resources;
  final FrameSnapshot _snapshot;
  final String _callId;
  final List<ScreencastFrameTraceEvent> _screencastFrames;

  SnapshotRenderer(
    this._htmlCache,
    this._resources,
    this._snapshots,
    this._screencastFrames,
    this._index,
  )   : _snapshot = _snapshots[_index],
        _callId = _snapshots[_index].callId,
        snapshotName = _snapshots[_index].snapshotName;

  /// The snapshot this renderer draws.
  FrameSnapshot snapshot() => _snapshots[_index];

  /// The viewport the snapshot was captured at.
  TraceSize viewport() => _snapshots[_index].viewport;

  /// The filmstrip frame taken closest to this snapshot, by wall clock when
  /// both sides recorded one and by the monotonic clock otherwise.
  ///
  /// It is what paints a canvas, whose pixels no DOM capture can carry.
  String? closestScreenshot() {
    final snap = snapshot();
    final closestFrame = (snap.wallTime != null &&
            _screencastFrames.isNotEmpty &&
            _screencastFrames[0].frameSwapWallTime != null)
        ? findClosest(
            _screencastFrames, (f) => f.frameSwapWallTime ?? 0, snap.wallTime!)
        : findClosest(_screencastFrames, (f) => f.timestamp, snap.timestamp);
    return closestFrame?.file;
  }

  /// Renders the snapshot to HTML, reusing the cached result when there is
  /// one.
  RenderedFrameSnapshot render() {
    final snapshot = _snapshot;
    final rendered = _htmlCache.getOrCompute(this, () {
      final result = StringBuffer();
      _visit(result, snapshot.html, _index, null, null);
      // Sanitize doctype to prevent injection from crafted trace files.
      // Valid doctype names (from document.doctype.name) only contain
      // alphanumeric characters.
      final safeDoctype =
          snapshot.doctype?.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
      final prefix = (safeDoctype != null && safeDoctype.isNotEmpty)
          ? '<!DOCTYPE $safeDoctype>'
          : '';
      // The nonce allows our bootstrap script to run under the strict
      // `script-src` policy that the snapshot is served with. See
      // SnapshotServer.serveSnapshot().
      final scriptNonce = generateNonce();
      final view = viewport();
      final html = prefix +
          // Hide the document in order to prevent flickering. We will unhide
          // once script has processed shadow.
          '<style>*,*::before,*::after { visibility: hidden }</style>'
              '<script nonce="$scriptNonce">'
              '${snapshotScript((
                width: view.width,
                height: view.height
              ), [
                _callId,
                snapshotName
              ])}'
              '</script>' +
          result.toString();
      return SizedValue(
        RenderedSnapshotHtml(html: html, scriptNonce: scriptNonce),
        html.length,
      );
    });

    return RenderedFrameSnapshot(
      html: rendered.html,
      scriptNonce: rendered.scriptNonce,
      pageId: snapshot.pageId,
      frameId: snapshot.frameId,
      index: _index,
    );
  }

  void _visit(
    StringBuffer result,
    NodeSnapshot? n,
    int snapshotIndex,
    String? parentTag,
    List<MapEntry<String, String>>? parentAttrs,
  ) {
    // Text node.
    if (n is String) {
      result.write(escapeHtml(n));
      return;
    }

    if (isSubtreeReferenceSnapshot(n)) {
      // Node reference.
      final reference = (n as List)[0] as List;
      final referenceIndex =
          snapshotIndex - ((reference[0] as num?)?.toInt() ?? 0);
      if (referenceIndex >= 0 && referenceIndex <= snapshotIndex) {
        final nodes = snapshotNodes(_snapshots[referenceIndex]);
        final nodeIndex = (reference[1] as num?)?.toInt() ?? -1;
        if (nodeIndex >= 0 && nodeIndex < nodes.length) {
          _visit(
              result, nodes[nodeIndex], referenceIndex, parentTag, parentAttrs);
          return;
        }
      }
      return;
    }

    if (!isNodeNameAttributesChildNodesSnapshot(n)) {
      // Why are we here? Let's not throw, just in case.
      return;
    }

    final node = n as List;
    final name = node[0] as String;
    final nodeAttrs = node.length > 1 ? node[1] : null;
    final children = node.length > 2 ? node.sublist(2) : const [];
    // Filter SCRIPT elements. The capture side already strips these, but a
    // crafted trace file could include them to achieve XSS.
    if (name.toUpperCase() == 'SCRIPT') return;
    // Element node.
    // Note that <noscript> will not be rendered by default in the trace
    // viewer, because JS is enabled. So rename it to <x-noscript>.
    final upperName = name.toUpperCase();
    final nodeName = upperName == 'NOSCRIPT' ? 'X-NOSCRIPT' : name;
    final attrs = <MapEntry<String, String>>[
      if (nodeAttrs is Map)
        for (final entry in nodeAttrs.entries)
          MapEntry('${entry.key}', '${entry.value}'),
    ];
    result.write('<');
    result.write(nodeName);
    const kCurrentSrcAttribute = '__playwright_current_src__';
    final isFrame = upperName == 'IFRAME' || upperName == 'FRAME';
    final isAnchor = upperName == 'A';
    final isImg = upperName == 'IMG';
    final isMeta = upperName == 'META';
    final isImgWithCurrentSrc =
        isImg && attrs.any((a) => a.key == kCurrentSrcAttribute);
    final isSourceInsidePictureWithCurrentSrc = upperName == 'SOURCE' &&
        parentTag == 'PICTURE' &&
        (parentAttrs?.any((a) => a.key == kCurrentSrcAttribute) ?? false);
    // For META, only allow a small whitelist of http-equiv directives so a
    // malicious snapshot cannot navigate the snapshot iframe via e.g.
    // <meta http-equiv="refresh"> or otherwise affect the trace viewer.
    final hasUnsafeHttpEquiv = isMeta &&
        attrs.any((a) =>
            a.key.toLowerCase() == 'http-equiv' &&
            !kAllowedMetaHttpEquivs.contains(a.value.trim().toLowerCase()));
    for (final entry in attrs) {
      final attr = entry.key;
      final value = entry.value;
      var attrName = attr;
      // Strip event handler attributes. The capture side already empties
      // these, but a crafted trace file could include live handlers (e.g.
      // onerror, onclick). escapeHtmlAttribute does not help because payloads
      // like "alert(1)" contain no characters that need escaping.
      if (attr.toLowerCase().startsWith('on')) continue;
      if (isFrame && attr.toLowerCase() == 'src') {
        // Never set relative URLs as <iframe src> - they start fetching
        // frames immediately.
        attrName = '__playwright_src__';
      }
      if (isFrame &&
          (attr.toLowerCase() == 'srcdoc' || attr.toLowerCase() == 'sandbox')) {
        // Neutralize srcdoc (could contain arbitrary HTML/script that executes
        // automatically) and sandbox (attacker-controlled values could alter
        // iframe security policy). The capture side already skips these, but a
        // crafted trace could include them.
        attrName = '__playwright_${attr.toLowerCase()}__';
      }
      if (upperName == 'OBJECT' && attr.toLowerCase() == 'data') {
        attrName = '__playwright_data__';
      }
      if (upperName == 'EMBED' && attr.toLowerCase() == 'src') {
        attrName = '__playwright_src__';
      }
      if (isImg && attr == kCurrentSrcAttribute) {
        // Render currentSrc for images, so that trace viewer does not
        // accidentally resolve srcset to a different source.
        attrName = 'src';
      }
      if ((attr.toLowerCase() == 'src' || attr.toLowerCase() == 'srcset') &&
          (isImgWithCurrentSrc || isSourceInsidePictureWithCurrentSrc)) {
        // Disable actual <img src>, <img srcset>, <source src> and
        // <source srcset> if we will be using the currentSrc instead.
        attrName = '_$attrName';
      }
      if (hasUnsafeHttpEquiv &&
          (attr.toLowerCase() == 'http-equiv' ||
              attr.toLowerCase() == 'content')) {
        // Neutralize the META directive by renaming the attribute so the
        // browser ignores it.
        attrName = '_$attr';
      }
      var attrValue = value;
      if (!isAnchor &&
          (attr.toLowerCase() == 'href' ||
              attr.toLowerCase() == 'src' ||
              attr == kCurrentSrcAttribute)) {
        attrValue = rewriteUrlForCustomProtocol(value);
      }
      result.write(' ');
      result.write(attrName);
      result.write('="');
      result.write(escapeHtmlAttribute(attrValue));
      result.write('"');
    }
    if (upperName == 'STYLE') {
      // Style has always exactly one child which is a text node.
      final styleContent = children.isNotEmpty && children[0] is String
          ? children[0] as String
          : '';
      result.write(' __playwright_style_content__="');
      result.write(escapeHtmlAttribute(
          rewriteUrlsInStyleSheetForCustomProtocol(styleContent)));
      result.write('"');
      result.write('></');
      result.write(nodeName);
      result.write('>');
      return;
    }
    result.write('>');
    for (final child in children) {
      _visit(result, child, snapshotIndex, nodeName, attrs);
    }
    if (!autoClosing.contains(nodeName)) {
      result.write('</');
      result.write(nodeName);
      result.write('>');
    }
  }

  /// The recorded response for [url] and [method], as of this snapshot.
  ///
  /// Only responses that arrived before the snapshot count, the last one
  /// wins, and a `304 Not Modified` never does — the viewer has no cache to
  /// serve the real body from, so it has to find the response that carried
  /// one.
  ResourceSnapshot? resourceByUrl(String url, String method) {
    final snapshot = _snapshot;
    ResourceSnapshot? sameFrameResource;
    ResourceSnapshot? otherFrameResource;

    for (final resource in _resources) {
      // Only use resources that received response before the snapshot.
      // Note that both snapshot time and request time are taken in the same
      // process.
      final monotonicTime = resource.monotonicTime;
      if (monotonicTime != null && monotonicTime >= snapshot.timestamp) break;
      if (resource.response.status == 304) {
        // "Not Modified" responses are issued when browser requests the same
        // resource multiple times, meanwhile indicating that it has the
        // response cached.
        //
        // When rendering the snapshot, browser most likely will not have the
        // resource cached, so we should respond with the real content
        // instead, picking the last response that is not 304.
        continue;
      }
      if (resource.request.url == url && resource.request.method == method) {
        // Pick the last resource with matching url - most likely it was used
        // at the time of snapshot, not the earlier aborted resource with the
        // same url.
        if (resource.frameref == snapshot.frameId) {
          sameFrameResource = resource;
        } else {
          otherFrameResource = resource;
        }
      }
    }

    // First try locating exact resource belonging to this frame, then fall
    // back to resource with this URL to account for memory cache.
    var result = sameFrameResource ?? otherFrameResource;
    if (result != null && method.toUpperCase() == 'GET') {
      // Patch override if necessary.
      var override = _findOverride(snapshot, url);
      final ref = override?.ref;
      if (ref != null) {
        // "ref" means use the same content as "ref" snapshots ago.
        final index = _index - ref;
        if (index >= 0 && index < _snapshots.length) {
          override = _findOverride(_snapshots[index], url);
        }
      }
      final file = override?.file;
      if (file != null) result = result.copyWithResponseContentFile(file);
    }

    return result;
  }

  static ResourceOverride? _findOverride(FrameSnapshot snapshot, String url) {
    for (final override in snapshot.resourceOverrides) {
      if (override.url == url) return override;
    }
    return null;
  }
}

/// Elements HTML closes for you; the renderer must not emit a closing tag.
const Set<String> autoClosing = {
  'AREA',
  'BASE',
  'BR',
  'COL',
  'COMMAND',
  'EMBED',
  'HR',
  'IMG',
  'INPUT',
  'KEYGEN',
  'LINK',
  'MENUITEM',
  'META',
  'PARAM',
  'SOURCE',
  'TRACK',
  'WBR',
};

/// Whitelist of META http-equiv directives that are safe to render in the
/// trace viewer.
///
/// Notably excludes `refresh` (auto-navigation), `set-cookie` and
/// `content-security-policy`.
const Set<String> kAllowedMetaHttpEquivs = {
  'content-type',
  'content-language',
  'default-style',
  'x-ua-compatible',
};

/// The nodes of a snapshot, in post-order, counting only the nodes that are
/// not themselves references.
///
/// This is the numbering a `[[n, i]]` reference indexes into, so it has to
/// match the one the capture side used when it wrote the reference. The list
/// is computed once and kept on the snapshot.
List<NodeSnapshot> snapshotNodes(FrameSnapshot snapshot) {
  var nodes = snapshot.cachedNodes;
  if (nodes == null) {
    nodes = <NodeSnapshot>[];
    void visit(Object? n) {
      if (n is String) {
        nodes!.add(n);
      } else if (isNodeNameAttributesChildNodesSnapshot(n)) {
        final node = n as List;
        for (final child in node.length > 2 ? node.sublist(2) : const []) {
          visit(child);
        }
        nodes!.add(node);
      }
    }

    visit(snapshot.html);
    snapshot.cachedNodes = nodes;
  }
  return nodes;
}

const List<String> _schemas = [
  'about:',
  'blob:',
  'data:',
  'file:',
  'ftp:',
  'http:',
  'https:',
  'mailto:',
  'sftp:',
  'ws:',
  'wss:',
];

const String _kLegacyBlobPrefix = 'http://playwright.bloburl/#';

/// Best-effort Electron support: rewrite a custom protocol in the DOM.
///
/// `vscode-file://vscode-app/` becomes `https://pw-vscode-file--vscode-app/`,
/// so the snapshot's own fetches land on the viewer's origin and can be
/// answered from the trace.
///
/// A URL with an opaque path — `blob:https://host/id`, say — comes back
/// unchanged, because that is what the WHATWG setters upstream uses do with
/// one: neither the protocol nor the hostname of such a URL can be assigned.
String rewriteUrlForCustomProtocol(String href) {
  // Legacy support, we used to prepend this to blobs, strip it away.
  var value = href;
  if (value.startsWith(_kLegacyBlobPrefix)) {
    value = value.substring(_kLegacyBlobPrefix.length);
  }

  final Uri url;
  try {
    url = Uri.parse(value);
  } on FormatException {
    return value;
  }
  // `new URL(href)` throws on a relative URL; `Uri.parse` does not.
  if (!url.hasScheme) return value;

  // Sanitize URL.
  if (url.scheme == 'javascript' || url.scheme == 'vbscript') {
    return 'javascript:void(0)';
  }

  // Pass through if possible.
  final isBlob = url.scheme == 'blob';
  final isFile = url.scheme == 'file';
  if (!isBlob && !isFile && _schemas.contains('${url.scheme}:')) return value;

  // Rewrite blob, file and custom schemas.
  if (!url.hasAuthority) return value;
  final prefix = 'pw-${url.scheme}';
  final host = url.host.isNotEmpty ? '$prefix--${url.host}' : prefix;
  return url.replace(scheme: 'https', host: host).toString();
}

final RegExp _urlInCssRegex =
    RegExp(r'url\([' "'" r'"]?([\w-]+:)//', caseSensitive: false);

/// Best-effort Electron support: rewrite a custom protocol in an inline
/// stylesheet.
String rewriteUrlsInStyleSheetForCustomProtocol(String text) {
  return text.replaceAllMapped(_urlInCssRegex, (match) {
    final whole = match[0]!;
    final protocol = match[1]!;
    final isBlob = protocol == 'blob:';
    final isFile = protocol == 'file:';
    if (!isBlob && !isFile && _schemas.contains(protocol)) return whole;
    return whole.replaceAll(
      '$protocol//',
      'https://pw-${protocol.substring(0, protocol.length - 1)}--',
    );
  });
}

Random? _random;

/// A cryptographic source when the platform has one, the ordinary one
/// otherwise — a nonce only has to be unguessable by the snapshot itself.
Random _secureRandom() {
  try {
    return _random ??= Random.secure();
  } on UnsupportedError {
    return _random ??= Random();
  }
}

/// A 128-bit nonce, hex, for the snapshot's own `script-src`.
String generateNonce() {
  final random = _secureRandom();
  final buffer = StringBuffer();
  for (var i = 0; i < 16; i++) {
    buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

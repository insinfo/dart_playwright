// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source:
// packages/playwright-core/src/server/recorder/recorderUtils.ts.

import 'package:playwright_isomorphic/playwright_isomorphic.dart';

import '../frame.dart';

/// The marker that separates one frame from the next inside a selector.
const String kEnterFrameSelector = 'internal:control=enter-frame';

String _buildFullSelector(List<String> framePath, String selector) =>
    [...framePath, selector].join(' >> $kEnterFrameSelector >> ');

/// Prefixes [selector], which was generated inside [frame], with the chain of
/// iframe selectors that leads to it.
///
/// Difference from upstream: upstream then tries to shorten the chain with
/// `internal:control=any-frame`, which saves two `frameLocator()` calls on a
/// deeply nested page. That spelling has no equivalent in this port's locator
/// API — the Dart generator throws on it, as the codegen round recorded — so
/// the full chain is always kept. The result is a longer but valid locator.
Future<String> buildFullSelectorForFrame(Frame frame, String selector) async {
  final framePath = await _generateFrameSelector(frame);
  return _buildFullSelector(framePath, selector);
}

Future<List<String>> _generateFrameSelector(Frame frame) async {
  final selectors = <String>[];
  var current = frame;
  while (true) {
    final parent = current.parentFrame();
    if (parent == null) break;
    selectors.add(await _generateFrameSelectorInParent(parent, current));
    current = parent;
  }
  return selectors.reversed.toList();
}

Future<String> _generateFrameSelectorInParent(Frame parent, Frame frame) async {
  try {
    final frameElement = await frame.frameElement();
    if (frameElement != null) {
      final selector = await frameElement.evaluate(
          '(element) => window.__pwDart.generateSelectorSimple(element)');
      if (selector is String && selector.isNotEmpty) return selector;
    }
  } catch (_) {
    // A cross-origin owner, or a frame that went away: fall through to the
    // attribute form, exactly as upstream does.
  }
  if (frame.name().isNotEmpty) {
    return 'iframe[name=${quoteCSSAttributeValue(frame.name())}]';
  }
  return 'iframe[src=${quoteCSSAttributeValue(frame.url())}]';
}

/// Whether [actionInContext] should replace [lastAction] instead of following
/// it: two fills of the same input are one fill of the final text.
bool shouldMergeAction(
    ActionInContext actionInContext, ActionInContext? lastAction) {
  if (lastAction == null) return false;
  final action = actionInContext.action;
  final last = lastAction.action;
  return action is FillAction &&
      last is FillAction &&
      actionInContext.pageGuid == lastAction.pageGuid &&
      action.selector == last.selector;
}

/// Applies [shouldMergeAction] across a whole recording.
List<ActionInContext> collapseActions(List<ActionInContext> actions) {
  final result = <ActionInContext>[];
  for (final action in actions) {
    final lastAction = result.isEmpty ? null : result.last;
    if (shouldMergeAction(action, lastAction)) {
      result[result.length - 1] = ActionInContext(
        pageGuid: action.pageGuid,
        action: action.action,
        signals: [...lastAction!.signals, ...action.signals],
      );
    } else {
      result.add(action);
    }
  }
  return result;
}

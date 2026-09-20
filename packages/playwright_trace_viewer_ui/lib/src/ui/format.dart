// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0.
//
// Upstream source: packages/isomorphic/formatUtils.ts

/// The two formatters every panel shares.
library;

/// `msToString`: a duration, in the unit that keeps it short.
///
/// The thresholds are upstream's, including that a negative or non-finite
/// duration is a dash rather than a number — which is what an action that
/// never finished renders as.
String msToString(num? ms) {
  if (ms == null || ms < 0 || !ms.isFinite) return '-';
  if (ms == 0) return '0ms';
  if (ms < 1000) return '${ms.toStringAsFixed(0)}ms';
  final seconds = ms / 1000;
  if (seconds < 60) return '${seconds.toStringAsFixed(1)}s';
  final minutes = seconds / 60;
  if (minutes < 60) return '${minutes.toStringAsFixed(1)}m';
  final hours = minutes / 60;
  if (hours < 24) return '${hours.toStringAsFixed(1)}h';
  return '${(hours / 24).toStringAsFixed(1)}d';
}

/// `bytesToString`: a size, in the unit that keeps it short.
///
/// The asymmetry is upstream's and deliberate: the threshold to move up a
/// unit is 1000, but the divisor is 1024.
String bytesToString(num? bytes) {
  if (bytes == null || bytes < 0 || !bytes.isFinite) return '-';
  if (bytes == 0) return '0';
  if (bytes < 1000) return bytes.toStringAsFixed(0);
  final kb = bytes / 1024;
  if (kb < 1000) return '${kb.toStringAsFixed(1)}K';
  final mb = kb / 1024;
  if (mb < 1000) return '${mb.toStringAsFixed(1)}M';
  return '${(mb / 1024).toStringAsFixed(1)}G';
}

/// `n noun` / `n nouns`, or the empty string for zero.
///
/// The action list joins these to build the badge label a screen reader
/// reads, so a count of zero has to vanish rather than say "0 errors".
String pluralize(int count, String noun) {
  if (count == 0) return '';
  return '$count $noun${count == 1 ? '' : 's'}';
}

/// The file name of a path, which may be spelled with either separator.
String fileName(String path) {
  final separator = path.contains('/') ? '/' : r'\';
  final parts = path.split(separator);
  return parts.isEmpty ? path : parts.last;
}

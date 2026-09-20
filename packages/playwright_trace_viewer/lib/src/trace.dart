// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/trace/trace.ts

/// The current trace format.
///
/// Upstream's `trace.ts` is a single re-export of the newest version, and so
/// is this: everything the reader hands the UI is already modernized, so there
/// is exactly one shape to program against.
library;

export 'versions/trace_v10.dart';

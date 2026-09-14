// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/playwright-core/src/server/screencast.ts
//
// STUB. The three engine backends are being written in parallel and land in
// this file; the declarations below are the agreed contract and must not
// change. Who builds one for a given page is decided by
// [ScreencastFactory] in `screencast_factory.dart`, so that the backends can
// arrive without the layers above them moving.

import 'video_frame.dart';

/// O WebKit não entrega quadros: o domínio `Screencast` dele grava direto
/// num arquivo.
enum ScreencastKind { frames, directFile }

abstract class PageScreencast {
  ScreencastKind get kind;

  Future<void> start(
      {required int width, required int height, int quality = 90});

  /// Só quando [kind] é [ScreencastKind.frames].
  Stream<VideoFrame> get frames;

  /// Caminho do arquivo produzido; só quando [kind] é
  /// [ScreencastKind.directFile].
  Future<String> stop();
}

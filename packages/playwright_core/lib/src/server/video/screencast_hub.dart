// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: the client bookkeeping of
// packages/playwright-core/src/server/screencast.ts.

import 'dart:async';

import '../core_page.dart';
import 'page_screencast.dart';
import 'screencast_factory.dart';
import 'video_frame.dart';

/// One screencast per page, shared by everyone who wants its frames.
///
/// A page being recorded to video *and* traced with the filmstrip on has two
/// consumers of the same frames, and the engines only run one screencast per
/// page — asking twice either fails or silently reconfigures the first. So
/// the subscribers are counted here: the first one starts the engine's
/// screencast, the last one stops it, and its size is the size the first one
/// asked for, which is the rule upstream's `Screencast.addClient` follows too.
class ScreencastHub {
  static final _hubs = Expando<ScreencastHub>('playwright.screencastHub');

  /// The hub for [page], created on first use.
  static ScreencastHub forPage(CorePage page) =>
      _hubs[page] ??= ScreencastHub._(page);

  final CorePage _page;
  PageScreencast? _screencast;
  Future<void>? _starting;
  int _clients = 0;

  ScreencastHub._(this._page);

  /// The backend's kind, once it has been created.
  ScreencastKind? get kind => _screencast?.kind;

  /// The size the running screencast was started with.
  ({int width, int height})? get size => _size;
  ({int width, int height})? _size;

  /// The size a screencast of [page] runs at when nobody asked for one.
  ///
  /// Upstream's rule, in `Screencast._startScreencast`: the context viewport
  /// scaled down to fit in 800 pixels, then both sides rounded down to even
  /// numbers, because vp8 refuses odd ones.
  static ({int width, int height}) defaultSizeFor(CorePage page,
      {({int width, int height})? requested}) {
    var size =
        requested ?? page.browserContext?.options.viewport ?? (width: 800, height: 600);
    if (requested == null) {
      final longest = size.width > size.height ? size.width : size.height;
      final scale = longest > 800 ? 800 / longest : 1.0;
      size = (
        width: (size.width * scale).floor(),
        height: (size.height * scale).floor()
      );
    }
    return (width: size.width & ~1, height: size.height & ~1);
  }

  /// Subscribes to the frames of [_page], starting the screencast when this is
  /// the first subscriber.
  Future<ScreencastSubscription> addClient({
    required ({int width, int height}) size,
    int quality = 90,
  }) async {
    _clients++;
    try {
      final starting = _starting ??= _start(size, quality);
      await starting;
    } catch (_) {
      _clients--;
      rethrow;
    }
    return ScreencastSubscription._(this);
  }

  Future<void> _start(({int width, int height}) size, int quality) async {
    final screencast = ScreencastFactory.create(_page);
    _screencast = screencast;
    _size = size;
    await screencast.start(
        width: size.width, height: size.height, quality: quality);
  }

  Future<String?> _removeClient() async {
    if (_clients == 0) return null;
    _clients--;
    if (_clients > 0) return null;
    final screencast = _screencast;
    _screencast = null;
    _starting = null;
    _size = null;
    if (screencast == null) return null;
    final file = await screencast.stop();
    return screencast.kind == ScreencastKind.directFile ? file : null;
  }
}

/// One consumer's handle on a page's screencast.
class ScreencastSubscription {
  final ScreencastHub _hub;
  bool _closed = false;

  ScreencastSubscription._(this._hub);

  ScreencastKind get kind => _hub.kind ?? ScreencastKind.frames;

  /// The size the screencast is actually running at, which is not necessarily
  /// the size this subscriber asked for: the first subscriber decides.
  ({int width, int height}) get size =>
      _hub.size ?? (width: 0, height: 0);

  /// Only meaningful for [ScreencastKind.frames].
  Stream<VideoFrame> get frames =>
      _hub._screencast?.frames ?? const Stream<VideoFrame>.empty();

  /// Drops this consumer. Returns the file the backend produced when this was
  /// the last consumer of a [ScreencastKind.directFile] screencast, and null
  /// otherwise.
  Future<String?> close() async {
    if (_closed) return null;
    _closed = true;
    return _hub._removeClient();
  }
}

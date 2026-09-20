import 'dart:async';
import 'dart:convert';

import 'package:playwright_protocol/playwright_protocol.dart';

import 'core_browser.dart';
import 'core_clock.dart';
import 'core_page.dart';
import 'injected/injected_bindings_source.dart';

export 'injected/injected_bindings_source.dart'
    show kBindingChannelName, kBindingsControllerProperty;

/// One script the engine runs before any script of a new document.
///
/// The body is wrapped in an IIFE, as upstream's `InitScript` does, so a
/// `const` or a `let` at the top level of one script cannot collide with the
/// next one — the scripts of a context and of a page share one global scope.
class CoreInitScript {
  /// What is actually handed to the engine.
  final String source;

  CoreInitScript(String body) : source = '(() => {\n$body\n})();';
}

/// Builds the source of an init script from what the caller wrote.
///
/// A function expression is called, with [arg] when one is given; anything
/// else is a statement list and runs as it stands. This is the same rule
/// `wrapEvaluationExpression` applies to `evaluate`, so the two agree about
/// what "a function" means.
String initScriptSource(String script, {Object? arg}) {
  if (!isFunctionExpression(script)) {
    if (arg != null) {
      throw ArgumentError.value(
          arg,
          'arg',
          'An argument needs a function to receive it: pass the script as '
              '`(value) => { ... }`.');
    }
    return script;
  }
  final encoded = arg == null ? '' : jsonEncode(arg);
  return '($script)($encoded);';
}

/// What a binding callback is handed alongside the arguments.
///
/// Upstream calls this the binding's `source`. [CoreBindingSource.frame] is
/// null only when the call arrived from an execution context this driver
/// never saw announced.
typedef CoreBindingSource = ({
  CoreBrowserContext? context,
  CorePage page,
  CoreFrame? frame,
});

/// A function exposed to the page.
typedef CoreBindingCallback = FutureOr<dynamic> Function(
    CoreBindingSource source, List<dynamic> args);

/// One exposed function, on a page or on a context.
class CoreBinding {
  final String name;
  final CoreBindingCallback callback;

  /// With this the page gets no `window.<name>`; upstream uses it for its own
  /// internal bindings. The API surface here always leaves it false.
  final bool noGlobal;

  CoreBinding(this.name, this.callback, {this.noGlobal = false});

  /// The init script that declares this binding in every new document.
  late final CoreInitScript initScript =
      CoreInitScript(bindingDeclarationSource(name, noGlobal));
}

/// The controller install script, shared by every page that has a binding.
final CoreInitScript kBindingsControllerInitScript =
    CoreInitScript(kInjectedBindingsSource);

/// Init scripts and bindings on a page.
///
/// The storage lives here and the two engine hooks — [applyInitScripts] and
/// [installBindingChannel] — are all an engine has to supply. Both are called
/// again whenever the list changes and once when the context adopts the page,
/// which is what makes a script added to a context reach a page created
/// later.
mixin CorePageInitScripts on CorePageFrameEvaluation {
  List<CoreFrame> get frames;
  CoreBrowserContext? get browserContext;

  /// Scripts added through this page, in the order they were added.
  final List<CoreInitScript> ownInitScripts = <CoreInitScript>[];

  /// Functions exposed on this page only.
  final Map<String, CoreBinding> pageBindings = <String, CoreBinding>{};

  /// Engine hook: makes [scripts] the complete set the engine runs at the
  /// start of every new document of this page, replacing what came before.
  ///
  /// Upstream adds and removes scripts one by one in Chromium and replaces
  /// the whole list in Firefox and WebKit. Replacing everywhere costs one
  /// extra protocol round trip per change in Chromium and buys a single
  /// ordering rule that holds on all three engines.
  Future<void> applyInitScripts(List<CoreInitScript> scripts);

  /// Engine hook: installs the binding channel function named [name] on the
  /// global object of every context of this page, now and after every
  /// navigation. Calling it twice for the same name does nothing.
  Future<void> installBindingChannel(String name);

  /// The id of the execution context currently bound to [frame], or null.
  /// Engines answer from their own registry.
  Object? contextIdOf(CoreFrame frame);

  CoreBrowserContextBindings? get _contextBindings =>
      browserContext as CoreBrowserContextBindings?;

  /// Every script this page installs, in upstream's order: the bindings
  /// controller, the context's bindings, the page's bindings, the context's
  /// scripts, then the page's own.
  List<CoreInitScript> get allInitScripts {
    final context = _contextBindings;
    final bindings = <CoreBinding>[
      ...?context?.contextBindings.values,
      ...pageBindings.values,
    ];
    return <CoreInitScript>[
      if (bindings.isNotEmpty) kBindingsControllerInitScript,
      for (final binding in bindings) binding.initScript,
      ...?context?.contextInitScripts,
      ...ownInitScripts,
    ];
  }

  /// Adds [source] to the scripts run at the start of every new document.
  ///
  /// The current document is left alone, exactly as upstream leaves it.
  Future<CoreInitScript> addInitScript(String source) async {
    final script = CoreInitScript(source);
    ownInitScripts.add(script);
    try {
      await applyInitScripts(allInitScripts);
    } catch (error) {
      ownInitScripts.remove(script);
      rethrow;
    }
    return script;
  }

  /// Exposes [name] on this page.
  ///
  /// Unlike [addInitScript] this also reaches the document that is already
  /// open: the controller and the declaration are evaluated in every live
  /// frame, which is what makes `exposeFunction` usable after `goto`.
  Future<void> exposeBinding(String name, CoreBindingCallback callback,
      {bool noGlobal = false}) async {
    if (pageBindings.containsKey(name)) {
      throw PlaywrightException(
          'Function "$name" has been already registered in this page');
    }
    if (_contextBindings?.contextBindings.containsKey(name) == true) {
      throw PlaywrightException(
          'Function "$name" has been already registered in the browser '
          'context');
    }
    final binding = CoreBinding(name, callback, noGlobal: noGlobal);
    pageBindings[name] = binding;
    try {
      await installBindingChannel(kBindingChannelName);
      await applyInitScripts(allInitScripts);
      await installBindingInLiveFrames(binding);
    } catch (error) {
      pageBindings.remove(name);
      // Best effort: put the engine back in step with the bookkeeping. The
      // original failure is what the caller needs to see.
      try {
        await applyInitScripts(allInitScripts);
      } catch (_) {}
      rethrow;
    }
  }

  /// Evaluates the controller and the declaration of [binding] in the frames
  /// that already exist. A frame whose context is gone is skipped.
  Future<void> installBindingInLiveFrames(CoreBinding binding) async {
    for (final frame in frames) {
      try {
        final context = await executionContextFor(frame,
            timeout: const Duration(seconds: 2));
        await context.rawEvaluate(kBindingsControllerInitScript.source);
        await context.rawEvaluate(binding.initScript.source);
      } catch (_) {
        // A frame that navigated away, or one whose context never arrived,
        // gets the binding from the init script when its next document loads.
      }
    }
  }

  /// The binding [name] answers to, page-level first, then context-level.
  CoreBinding? bindingFor(String name) =>
      pageBindings[name] ?? _contextBindings?.contextBindings[name];

  /// Handles one `bindingCalled` protocol event.
  ///
  /// This is called from an event handler, so nothing may escape: a failure
  /// anywhere — a missing binding, a throwing callback, a result that cannot
  /// be encoded — has to come back as a rejection of the promise the page is
  /// holding, or `await window.myFunction()` in the page never settles.
  void dispatchBindingCall(String payload, CoreExecutionContext context) {
    unawaited(_dispatchBindingCall(payload, context));
  }

  Future<void> _dispatchBindingCall(
      String payload, CoreExecutionContext context) async {
    Object? name;
    Object? seq;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) return;
      name = decoded['name'];
      seq = decoded['seq'];
      if (name is! String || seq is! int) return;

      final rawArgs = decoded['args'];
      final args = rawArgs is List ? List<dynamic>.from(rawArgs) : <dynamic>[];
      final binding = bindingFor(name);
      if (binding == null) {
        throw PlaywrightException('Function "$name" is not exposed');
      }
      final result = await binding.callback(
        (
          context: browserContext,
          page: this as CorePage,
          frame: _frameForContext(context),
        ),
        args,
      );
      // Encoding is part of the call: a value the page cannot receive must
      // reject the promise, not disappear on the way back.
      final encoded = jsonEncode(<String, dynamic>{
        'name': name,
        'seq': seq,
        'isError': false,
        'result': result,
      });
      await _deliver(context, encoded);
    } catch (error) {
      if (name is! String || seq is! int) return;
      await _deliver(
          context,
          jsonEncode(<String, dynamic>{
            'name': name,
            'seq': seq,
            'isError': true,
            'errorName': 'Error',
            'message': '$error',
          }));
    }
  }

  Future<void> _deliver(CoreExecutionContext context, String encoded) async {
    try {
      await context.rawEvaluate(bindingDeliverySource(encoded));
    } catch (_) {
      // The document went away while the callback ran; there is no promise
      // left to settle.
    }
  }

  CoreFrame? _frameForContext(CoreExecutionContext context) {
    for (final frame in frames) {
      if (contextIdOf(frame) == context.contextId) return frame;
    }
    return null;
  }
}

/// Init scripts and bindings on a browser context.
///
/// A context owns no protocol channel of its own in this port — Chromium and
/// WebKit have none at all, and using the Juggler's context-level commands
/// would make Firefox behave differently from the other two — so everything
/// is replayed onto the pages: the ones that exist now, and, through
/// [initializePage], the ones created later.
mixin CoreBrowserContextBindings on EventEmitter {
  /// Pages owned by this context, supplied by `BrowserContextStorage`.
  List<CorePage> get trackedPages;

  /// The engine this context belongs to: `chromium`, `firefox` or `webkit`.
  String get engineName;

  /// Deterministic time for every page of this context, created on first use.
  late final CoreClock clock =
      CoreClock(this as CoreBrowserContext, engineName);

  /// `routeWebSocket` for every page of this context, created on first use.
  ///
  /// It lives here because upstream's does: the binding the injected mock
  /// calls is a context binding even when a single page is routed.
  late final CoreWebSocketRouteManager webSocketRoutes =
      CoreWebSocketRouteManager(this as CoreBrowserContext);

  final List<CoreInitScript> contextInitScripts = <CoreInitScript>[];
  final Map<String, CoreBinding> contextBindings = <String, CoreBinding>{};

  /// Installs what this context carries onto a page that just joined it.
  ///
  /// Called from the engine's adoption path, before the page is handed to
  /// whoever asked for it, so a page comes back already carrying the
  /// context's scripts.
  Future<void> initializePage(CorePage page) async {
    if (contextBindings.isNotEmpty) {
      await page.installBindingChannel(kBindingChannelName);
    }
    final scripts = page.allInitScripts;
    if (scripts.isNotEmpty) await page.applyInitScripts(scripts);
  }

  /// Adds [source] to every page of this context, present and future.
  Future<CoreInitScript> addInitScript(String source) async {
    final script = CoreInitScript(source);
    contextInitScripts.add(script);
    try {
      for (final page in trackedPages) {
        await page.applyInitScripts(page.allInitScripts);
      }
    } catch (error) {
      contextInitScripts.remove(script);
      rethrow;
    }
    return script;
  }

  /// Exposes [name] on every page of this context, present and future.
  Future<void> exposeBinding(String name, CoreBindingCallback callback,
      {bool noGlobal = false}) async {
    if (contextBindings.containsKey(name)) {
      throw PlaywrightException(
          'Function "$name" has been already registered in the browser '
          'context');
    }
    for (final page in trackedPages) {
      if (page.pageBindings.containsKey(name)) {
        throw PlaywrightException(
            'Function "$name" has been already registered in one of the '
            'pages');
      }
    }
    final binding = CoreBinding(name, callback, noGlobal: noGlobal);
    contextBindings[name] = binding;
    try {
      for (final page in trackedPages) {
        await page.installBindingChannel(kBindingChannelName);
        await page.applyInitScripts(page.allInitScripts);
        await page.installBindingInLiveFrames(binding);
      }
    } catch (error) {
      contextBindings.remove(name);
      for (final page in trackedPages) {
        try {
          await page.applyInitScripts(page.allInitScripts);
        } catch (_) {}
      }
      rethrow;
    }
  }
}

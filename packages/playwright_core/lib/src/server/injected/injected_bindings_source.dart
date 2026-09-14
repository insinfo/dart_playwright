// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/injected/src/bindingsController.ts and the
// `PageBinding` half of packages/playwright-core/src/server/page.ts.

/// The in-page half of `exposeFunction` / `exposeBinding`.
///
/// One controller object per document holds every binding the page knows.
/// Calling `window.myFunction(...)` hands a JSON payload to the engine's
/// binding channel — a function the protocol installs on the global object
/// (`Runtime.addBinding` in Chromium and WebKit, `Page.addBinding` in the
/// Juggler) — and returns a promise. The Dart side runs the callback and
/// answers by evaluating what [bindingDeliverySource] builds in the same
/// context, which settles that promise.
///
/// Differences from upstream, all deliberate:
///
/// * Arguments and results travel as JSON, not through upstream's
///   `serializeAsCallArgument` / `parseEvaluationResultValue` pair. This port
///   evaluates by value everywhere else too (see `CoreExecutionContext`), so
///   the binding channel is as expressive as `page.evaluate` is and no more:
///   `undefined` inside an object, functions, `Date`, `Map`, `Set`, cyclic
///   references and `NaN`/`Infinity` do not survive. A value JSON cannot
///   encode rejects the page's promise with a clear message instead of
///   arriving silently mangled.
/// * There is no `handle: true` mode: upstream can hand the callback a
///   `JSHandle` for the first argument, which needs the argument to stay in
///   the page. Nothing here holds page-side objects for a binding call.
library;

/// The property that holds the controller on the page's global object.
const String kBindingsControllerProperty = '__pwDartBindings';

/// The function the engine installs on the global object. The controller
/// calls it to hand a payload to the driver; it is the only piece of this
/// machinery the protocol provides.
const String kBindingChannelName = '__pwDartBindingChannel';

/// Installs the controller. Evaluating it twice in one document is harmless.
const String kInjectedBindingsSource = '''
const property = '$kBindingsControllerProperty';
const channel = '$kBindingChannelName';
if (!globalThis[property]) {
  const bindings = new Map();
  const controller = {
    // Declares a binding in this document. With noGlobal the page gets no
    // `window.<name>`; the caller reaches it through the controller.
    addBinding(name, noGlobal) {
      if (bindings.has(name))
        return;
      bindings.set(name, { callbacks: new Map(), lastSeq: 0, removed: false });
      if (!noGlobal) {
        globalThis[name] = function () {
          return controller.callBinding(name, Array.prototype.slice.call(arguments));
        };
      }
    },
    removeBinding(name) {
      const data = bindings.get(name);
      if (data)
        data.removed = true;
      bindings.delete(name);
      delete globalThis[name];
    },
    callBinding(name, args) {
      const data = bindings.get(name);
      if (!data || data.removed)
        return Promise.reject(new Error('The binding "' + name + '" is no longer exposed'));
      const seq = ++data.lastSeq;
      let payload;
      try {
        payload = JSON.stringify({ name: name, seq: seq, args: args });
      } catch (error) {
        return Promise.reject(new Error(
            'Cannot serialize the arguments of "' + name + '": ' + error.message));
      }
      const promise = new Promise((resolve, reject) => data.callbacks.set(seq, { resolve, reject }));
      globalThis[channel](payload);
      return promise;
    },
    // Called from the driver once the Dart callback settled.
    deliverBindingResult(arg) {
      const data = bindings.get(arg.name);
      if (!data)
        return;
      const callback = data.callbacks.get(arg.seq);
      if (!callback)
        return;
      data.callbacks.delete(arg.seq);
      if (arg.isError) {
        const error = new Error(arg.message);
        if (arg.errorName)
          error.name = arg.errorName;
        callback.reject(error);
      } else {
        callback.resolve(arg.result);
      }
    },
  };
  globalThis[property] = controller;
}
''';

/// The expression that declares one binding in a document.
String bindingDeclarationSource(String name, bool noGlobal) =>
    "globalThis['$kBindingsControllerProperty']"
    '.addBinding(${_jsString(name)}, $noGlobal);';

/// The expression that settles one pending call. [encodedArgument] is the
/// JSON the driver produced for it.
String bindingDeliverySource(String encodedArgument) =>
    "globalThis['$kBindingsControllerProperty']"
    '.deliverBindingResult($encodedArgument);';

String _jsString(String value) =>
    "'${value.replaceAll(r'\', r'\').replaceAll("'", r"\'")}'";

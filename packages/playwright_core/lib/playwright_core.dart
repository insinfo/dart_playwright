/// Playwright Core implementation.
///
/// This package contains the actual browser drivers, protocol transport,
/// and binary registry. It is meant to be consumed by the `playwright`
/// package to expose the public API.
library playwright_core;

export 'src/transport/transport.dart';
export 'src/transport/pipe_transport.dart';
export 'src/transport/web_socket_transport.dart';

export 'src/registry/registry.dart';
export 'src/registry/browser_descriptor.dart';
export 'src/registry/host_platform.dart';

export 'src/server/core_request.dart';
export 'src/server/core_response.dart';
export 'src/server/core_route.dart';
export 'src/server/frames.dart';

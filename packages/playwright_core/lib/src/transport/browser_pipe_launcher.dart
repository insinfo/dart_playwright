import 'dart:io';

import 'browser_process_registry.dart';
import 'pipe_transport.dart';
import 'posix_pipe_transport.dart';
import 'posix_process.dart';
import 'transport.dart';
import 'win32_process.dart';

/// Launches a browser with the Playwright fd3/fd4 inspector pipes attached
/// and returns a ready transport, selecting the platform-specific process
/// launcher (Win32 named pipes via lpReserved2, or POSIX FIFOs via sh).
///
/// The process is entered in [BrowserProcessRegistry] so an interrupted run
/// takes its browsers down with it; [handleSIGINT], [handleSIGTERM] and
/// [handleSIGHUP] choose which interruptions are handled, as upstream's
/// options of the same name do.
///
/// If transport initialization fails, the browser process is killed before
/// the error propagates.
Future<ConnectionTransport> launchBrowserWithInspectorPipe(
  String executablePath,
  List<String> arguments, {
  Map<String, String>? environment,
  bool handleSIGINT = true,
  bool handleSIGTERM = true,
  bool handleSIGHUP = true,
}) async {
  if (Platform.isWindows) {
    final process =
        Win32Process.start(executablePath, arguments, environment: environment);
    BrowserProcessRegistry.register(
      process.processId,
      process.kill,
      handleSIGINT: handleSIGINT,
      handleSIGTERM: handleSIGTERM,
      handleSIGHUP: handleSIGHUP,
    );
    final transport = PipeTransport(process);
    try {
      await transport.init();
    } catch (e) {
      process.kill();
      rethrow;
    }
    return transport;
  }

  final process = await PosixProcess.start(executablePath, arguments,
      environment: environment);
  BrowserProcessRegistry.register(
    process.processId,
    process.kill,
    handleSIGINT: handleSIGINT,
    handleSIGTERM: handleSIGTERM,
    handleSIGHUP: handleSIGHUP,
  );
  final transport = PosixPipeTransport(process);
  try {
    await transport.init();
  } catch (e) {
    process.kill();
    rethrow;
  }
  return transport;
}

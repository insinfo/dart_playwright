import 'dart:io';

import 'pipe_transport.dart';
import 'posix_pipe_transport.dart';
import 'posix_process.dart';
import 'transport.dart';
import 'win32_process.dart';

/// Launches a browser with the Playwright fd3/fd4 inspector pipes attached
/// and returns a ready transport, selecting the platform-specific process
/// launcher (Win32 named pipes via lpReserved2, or POSIX FIFOs via sh).
///
/// If transport initialization fails, the browser process is killed before
/// the error propagates.
Future<ConnectionTransport> launchBrowserWithInspectorPipe(
    String executablePath, List<String> arguments, {Map<String, String>? environment}) async {
  if (Platform.isWindows) {
    final process = Win32Process.start(executablePath, arguments, environment: environment);
    final transport = PipeTransport(process);
    try {
      await transport.init();
    } catch (e) {
      process.kill();
      rethrow;
    }
    return transport;
  }

  final process = await PosixProcess.start(executablePath, arguments, environment: environment);
  final transport = PosixPipeTransport(process);
  try {
    await transport.init();
  } catch (e) {
    process.kill();
    rethrow;
  }
  return transport;
}

// package:win32 flip-flops between namespaced (FILE_FLAGS_AND_ATTRIBUTES.*)
// and top-level constants across versions, deprecating whichever is not
// current. The values are identical; silence the churn.
// ignore_for_file: deprecated_member_use
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

class Win32Process {
  final int processId;
  final int processHandle;
  final int threadHandle;
  
  final int jugglerWriteHandle; // FD3 Write in parent
  final int jugglerReadHandle;  // FD4 Read in parent

  Win32Process._(
    this.processId, 
    this.processHandle, 
    this.threadHandle,
    this.jugglerWriteHandle,
    this.jugglerReadHandle,
  );

  void kill() {
    TerminateProcess(processHandle, 0);
    CloseHandle(processHandle);
    CloseHandle(threadHandle);
    CloseHandle(jugglerWriteHandle);
    CloseHandle(jugglerReadHandle);
  }

  static int _pipeSerial = 0;
  
  static void _createOverlappedPipe(
      Arena arena, Pointer<HANDLE> hRead, Pointer<HANDLE> hWrite, Pointer<SECURITY_ATTRIBUTES> sa, bool parentReads) {
    final name = '\\\\.\\pipe\\playwright_dart_${Isolate.current.hashCode}_${_pipeSerial++}';
    final pName = name.toNativeUtf16(allocator: arena);
    
    final serverHandle = CreateNamedPipe(
      pName,
      parentReads
          ? FILE_FLAGS_AND_ATTRIBUTES.PIPE_ACCESS_INBOUND
          : FILE_FLAGS_AND_ATTRIBUTES.PIPE_ACCESS_OUTBOUND,
      NAMED_PIPE_MODE.PIPE_TYPE_BYTE | NAMED_PIPE_MODE.PIPE_WAIT,
      1,
      65536,
      65536,
      0,
      nullptr
    );
    
    if (serverHandle == INVALID_HANDLE_VALUE) {
      throw Exception('CreateNamedPipe failed: ${GetLastError()}');
    }

    final clientHandle = CreateFile(
      pName,
      parentReads
          ? GENERIC_ACCESS_RIGHTS.GENERIC_WRITE
          : GENERIC_ACCESS_RIGHTS.GENERIC_READ,
      0,
      sa,
      FILE_CREATION_DISPOSITION.OPEN_EXISTING,
      FILE_FLAGS_AND_ATTRIBUTES.FILE_ATTRIBUTE_NORMAL,
      0
    );
    
    if (clientHandle == INVALID_HANDLE_VALUE) {
      CloseHandle(serverHandle);
      throw Exception('CreateFile failed: ${GetLastError()}');
    }
    
    if (parentReads) {
      hRead.value = serverHandle;
      hWrite.value = clientHandle;
    } else {
      hRead.value = clientHandle;
      hWrite.value = serverHandle;
    }
  }

  static Win32Process start(String executablePath, List<String> arguments,
      {Map<String, String>? environment}) {
    if (!Platform.isWindows) {
      throw UnsupportedError('Win32Process is only supported on Windows');
    }
    
    final arena = Arena();
    
    // Create Pipes
    final fd3Read = arena<HANDLE>();
    final fd3Write = arena<HANDLE>();
    final fd4Read = arena<HANDLE>();
    final fd4Write = arena<HANDLE>();

    final securityAttributes = arena<SECURITY_ATTRIBUTES>();
    securityAttributes.ref.nLength = sizeOf<SECURITY_ATTRIBUTES>();
    securityAttributes.ref.bInheritHandle = TRUE;
    securityAttributes.ref.lpSecurityDescriptor = nullptr;

    _createOverlappedPipe(arena, fd3Read, fd3Write, securityAttributes, false); // parent writes, child reads
    _createOverlappedPipe(arena, fd4Read, fd4Write, securityAttributes, true); // parent reads, child writes

    final hStdInRead = arena<HANDLE>();
    final hStdInWrite = arena<HANDLE>();
    final hStdOutRead = arena<HANDLE>();
    final hStdOutWrite = arena<HANDLE>();
    final hStdErrRead = arena<HANDLE>();
    final hStdErrWrite = arena<HANDLE>();

    _createOverlappedPipe(arena, hStdInRead, hStdInWrite, securityAttributes, false);
    _createOverlappedPipe(arena, hStdOutRead, hStdOutWrite, securityAttributes, true);
    _createOverlappedPipe(arena, hStdErrRead, hStdErrWrite, securityAttributes, true);

    final handles = <int>[
      hStdInRead.value,
      hStdOutWrite.value,
      hStdErrWrite.value,
      fd3Read.value,
      fd4Write.value,
    ];

    final count = handles.length;
    final size = 4 + count * 1 + count * 8;
    final lpReserved2 = arena<Uint8>(size);
    final byteData = ByteData.view(lpReserved2.asTypedList(size).buffer);
    
    byteData.setInt32(0, count, Endian.host);
    for (int i = 0; i < count; i++) {
      byteData.setUint8(4 + i, 0x09); // 0x09 = FOPEN (0x01) | FPIPE (0x08)
    }
    
    for (int i = 0; i < count; i++) {
      byteData.setInt64(4 + count + i * 8, handles[i], Endian.host);
    }

    final startupInfo = arena<STARTUPINFO>();
    startupInfo.ref.cb = sizeOf<STARTUPINFO>();
    startupInfo.ref.cbReserved2 = size;
    startupInfo.ref.lpReserved2 = lpReserved2;
    startupInfo.ref.dwFlags = STARTUPINFOW_FLAGS.STARTF_USESTDHANDLES |
        STARTUPINFOW_FLAGS.STARTF_USESHOWWINDOW;
    startupInfo.ref.wShowWindow = SHOW_WINDOW_CMD.SW_HIDE;
    startupInfo.ref.hStdInput = handles[0];
    startupInfo.ref.hStdOutput = handles[1];
    startupInfo.ref.hStdError = handles[2];

    // Command line construction
    final StringBuffer cmdBuffer = StringBuffer();
    cmdBuffer.write('"$executablePath"');
    for (var arg in arguments) {
      cmdBuffer.write(' ');
      if (arg.contains(' ') || arg.contains('"')) {
        cmdBuffer.write('"${arg.replaceAll('"', '\\"')}"');
      } else {
        cmdBuffer.write(arg);
      }
    }
    
    final pCommandLine = cmdBuffer.toString().toNativeUtf16(allocator: arena);

    Pointer<Void> lpEnvironment = nullptr;
    if (environment != null) {
      final envBuffer = StringBuffer();
      for (final entry in environment.entries) {
        envBuffer.write('${entry.key}=${entry.value}\x00');
      }
      envBuffer.write('\x00');
      lpEnvironment = envBuffer.toString().toNativeUtf16(allocator: arena).cast();
    }

    final processInformation = arena<PROCESS_INFORMATION>();

    final result = CreateProcess(
      nullptr,
      pCommandLine,
      nullptr,
      nullptr,
      TRUE,
      PROCESS_CREATION_FLAGS.CREATE_UNICODE_ENVIRONMENT,
      lpEnvironment,
      nullptr,
      startupInfo,
      processInformation,
    );

    if (result == 0) {
      final error = GetLastError();
      arena.releaseAll();
      throw Exception('CreateProcess failed with error $error');
    }

    CloseHandle(hStdInRead.value);
    CloseHandle(hStdOutWrite.value);
    CloseHandle(hStdErrWrite.value);
    CloseHandle(fd3Read.value);
    CloseHandle(fd4Write.value);

    // We don't use the standard I/O pipes for anything in Dart
    CloseHandle(hStdInWrite.value);
    CloseHandle(hStdOutRead.value);
    CloseHandle(hStdErrRead.value);

    final win32Process = Win32Process._(
      processInformation.ref.dwProcessId,
      processInformation.ref.hProcess,
      processInformation.ref.hThread,
      fd3Write.value,
      fd4Read.value,
    );

    arena.releaseAll();
    return win32Process;
  }
}

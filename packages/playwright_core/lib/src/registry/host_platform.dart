import 'dart:io';

/// Utility to detect the host platform for downloading browser binaries.
///
/// Returns platform identifiers that match Playwright's CDN URLs.
class HostPlatform {
  /// Get the basic platform identifier for download (e.g., win-x64, mac-arm64, linux-x64).
  static String detect() {
    if (Platform.isWindows) return 'win-x64';
    if (Platform.isMacOS) {
      final arch = _detectArch();
      return arch == 'arm64' ? 'mac-arm64' : 'mac-x64';
    }
    if (Platform.isLinux) {
      final arch = _detectArch();
      return arch == 'arm64' ? 'linux-arm64' : 'linux-x64';
    }
    return '<unknown>';
  }

  /// Get the detailed platform identifier including OS version for Linux/macOS.
  static String detectDetailed() {
    if (Platform.isWindows) return 'win64';
    if (Platform.isMacOS) {
      final version = _macOSVersion();
      final arch = _detectArch();
      final suffix = arch == 'arm64' ? '-arm64' : '';
      return 'mac$version$suffix';
    }
    if (Platform.isLinux) {
      final distro = _linuxDistro();
      final arch = _detectArch();
      final suffix = arch == 'arm64' ? '-arm64' : '-x64';
      return '$distro$suffix';
    }
    return '<unknown>';
  }

  static String _detectArch() {
    if (Platform.isMacOS || Platform.isLinux) {
      try {
        final result = Process.runSync('uname', ['-m']);
        final arch = (result.stdout as String).trim();
        if (arch == 'aarch64' || arch == 'arm64') return 'arm64';
      } catch (_) {
        // Fallback to x64 if uname fails
      }
    }
    return 'x64'; // Playwright only ships x64 for Windows
  }

  static String _macOSVersion() {
    try {
      final result = Process.runSync('sw_vers', ['-productVersion']);
      final version = (result.stdout as String).trim();
      final major = int.parse(version.split('.').first);
      return '$major';
    } catch (_) {
      return '15'; // Default fallback
    }
  }

  static String _linuxDistro() {
    try {
      final osRelease = File('/etc/os-release').readAsStringSync();
      final lines = osRelease.split('\n');
      String? id;
      String? versionId;
      for (final line in lines) {
        if (line.startsWith('ID=')) id = line.substring(3).replaceAll('"', '');
        if (line.startsWith('VERSION_ID=')) {
          versionId = line.substring(11).replaceAll('"', '');
        }
      }
      if (id == 'ubuntu' && versionId != null) return 'ubuntu$versionId';
      if (id == 'debian' && versionId != null) {
        return 'debian${versionId.split('.').first}';
      }
      return 'ubuntu22.04'; // Default fallback
    } catch (_) {
      return 'ubuntu22.04';
    }
  }
}

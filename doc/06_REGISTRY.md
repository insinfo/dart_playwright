# 06 — Download e Gerenciamento de Binários

## 1. Visão Geral

O Playwright Dart precisa baixar os mesmos binários oficiais do Playwright (Chromium, Firefox, WebKit) do CDN da Microsoft, sem depender de Node.js. Esta seção detalha o sistema de registry e download.

---

## 2. Arquitetura do Registry

```dart
// lib/src/registry/registry.dart

/// Registro central de navegadores.
/// Gerencia download, cache e localização de binários.
class BrowserRegistry {
  /// Diretório de cache dos navegadores
  late final String _cacheDir;
  
  /// Versões dos navegadores (carregadas do browsers.json)
  late final List<BrowserDescriptor> _browsers;
  
  /// CDN mirrors para download
  static const _cdnMirrors = [
    'https://cdn.playwright.dev/dbazure/download/playwright',
    'https://playwright.download.prss.microsoft.com/dbazure/download/playwright',
    'https://cdn.playwright.dev',
  ];
  
  BrowserRegistry() {
    _cacheDir = _resolveCacheDir();
    _browsers = _loadBrowsersJson();
  }
  
  /// Resolver diretório de cache
  String _resolveCacheDir() {
    // 1. Variável de ambiente tem prioridade
    final envPath = Platform.environment['PLAYWRIGHT_BROWSERS_PATH'];
    if (envPath != null && envPath.isNotEmpty) return envPath;
    
    // 2. Caminho padrão por SO
    if (Platform.isWindows) {
      final appData = Platform.environment['LOCALAPPDATA'] ?? 
          path.join(Platform.environment['USERPROFILE']!, 'AppData', 'Local');
      return path.join(appData, 'ms-playwright');
    } else if (Platform.isMacOS) {
      return path.join(Platform.environment['HOME']!, 'Library', 'Caches', 'ms-playwright');
    } else {
      final xdgCache = Platform.environment['XDG_CACHE_HOME'] ??
          path.join(Platform.environment['HOME']!, '.cache');
      return path.join(xdgCache, 'ms-playwright');
    }
  }
  
  /// Carregar browsers.json embarcado no pacote
  List<BrowserDescriptor> _loadBrowsersJson() {
    // O browsers.json é embarcado no pacote como resource
    final json = jsonDecode(_browsersJsonContent) as Map<String, dynamic>;
    final browsers = json['browsers'] as List<dynamic>;
    return browsers
        .map((b) => BrowserDescriptor.fromJson(b as Map<String, dynamic>))
        .toList();
  }
  
  /// Obter descritor de um navegador
  BrowserDescriptor? getDescriptor(String name) {
    return _browsers.where((b) => b.name == name).firstOrNull;
  }
  
  /// Verificar se um navegador está instalado
  bool isInstalled(String browserName) {
    final descriptor = getDescriptor(browserName);
    if (descriptor == null) return false;
    
    final execPath = executablePath(browserName);
    return execPath != null && File(execPath).existsSync();
  }
  
  /// Obter caminho do executável de um navegador
  String? executablePath(String browserName) {
    final descriptor = getDescriptor(browserName);
    if (descriptor == null) return null;
    
    final platform = _hostPlatform();
    final pathSegments = _executablePaths[browserName]?[platform];
    if (pathSegments == null) return null;
    
    final browserDir = _browserDirectory(browserName, descriptor.revision);
    return path.joinAll([browserDir, ...pathSegments]);
  }
  
  /// Diretório onde o navegador está instalado
  String _browserDirectory(String browserName, String revision) {
    return path.join(_cacheDir, '$browserName-$revision');
  }
  
  /// Instalar um navegador
  Future<void> install(String browserName, {
    void Function(double progress)? onProgress,
  }) async {
    final descriptor = getDescriptor(browserName);
    if (descriptor == null) {
      throw PlaywrightException('Unknown browser: $browserName');
    }
    
    if (isInstalled(browserName)) {
      print('$browserName ${descriptor.browserVersion} is already installed.');
      return;
    }
    
    final downloadUrl = _resolveDownloadUrl(browserName, descriptor);
    if (downloadUrl == null) {
      throw PlaywrightException(
        '$browserName is not available for ${_hostPlatform()}',
      );
    }
    
    final browserDir = _browserDirectory(browserName, descriptor.revision);
    
    print('Downloading $browserName ${descriptor.browserVersion}...');
    
    await _downloadAndExtract(
      url: downloadUrl,
      destinationDir: browserDir,
      onProgress: onProgress,
    );
    
    // Marcar executável como executável (Linux/macOS)
    if (!Platform.isWindows) {
      final execPath = executablePath(browserName);
      if (execPath != null) {
        await Process.run('chmod', ['+x', execPath]);
      }
    }
    
    print('$browserName ${descriptor.browserVersion} installed successfully.');
  }
  
  /// Instalar todos os navegadores padrão
  Future<void> installAll({
    void Function(String browser, double progress)? onProgress,
  }) async {
    for (final browser in _browsers) {
      if (browser.installByDefault) {
        await install(browser.name, onProgress: (p) {
          onProgress?.call(browser.name, p);
        });
      }
    }
  }
  
  /// Desinstalar um navegador
  Future<void> uninstall(String browserName) async {
    final descriptor = getDescriptor(browserName);
    if (descriptor == null) return;
    
    final browserDir = _browserDirectory(browserName, descriptor.revision);
    final dir = Directory(browserDir);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
      print('$browserName uninstalled.');
    }
  }
  
  /// Limpar versões antigas de navegadores
  Future<void> cleanOldVersions() async {
    final cacheDir = Directory(_cacheDir);
    if (!await cacheDir.exists()) return;
    
    final currentRevisions = <String>{};
    for (final browser in _browsers) {
      currentRevisions.add('${browser.name}-${browser.revision}');
    }
    
    await for (final entity in cacheDir.list()) {
      if (entity is Directory) {
        final dirName = path.basename(entity.path);
        if (!currentRevisions.contains(dirName)) {
          print('Removing old browser: $dirName');
          await entity.delete(recursive: true);
        }
      }
    }
  }
}
```

---

## 3. Descritor de Navegador

```dart
// lib/src/registry/browser_descriptor.dart

class BrowserDescriptor {
  final String name;
  final String revision;
  final bool installByDefault;
  final String? browserVersion;
  final String? title;
  final Map<String, String>? revisionOverrides;
  
  BrowserDescriptor({
    required this.name,
    required this.revision,
    required this.installByDefault,
    this.browserVersion,
    this.title,
    this.revisionOverrides,
  });
  
  factory BrowserDescriptor.fromJson(Map<String, dynamic> json) {
    return BrowserDescriptor(
      name: json['name'] as String,
      revision: json['revision'] as String,
      installByDefault: json['installByDefault'] as bool? ?? false,
      browserVersion: json['browserVersion'] as String?,
      title: json['title'] as String?,
      revisionOverrides: (json['revisionOverrides'] as Map<String, dynamic>?)
          ?.map((k, v) => MapEntry(k, v as String)),
    );
  }
  
  /// Obter a revisão efetiva para uma plataforma
  String effectiveRevision(String platform) {
    return revisionOverrides?[platform] ?? revision;
  }
}
```

---

## 4. Download de Binários

```dart
// lib/src/registry/browser_fetcher.dart

class BrowserFetcher {
  /// Baixar e extrair um arquivo zip de binário de navegador
  static Future<void> downloadAndExtract({
    required String url,
    required String destinationDir,
    void Function(double progress)? onProgress,
  }) async {
    final tempFile = File(path.join(
      Directory.systemTemp.path,
      'playwright_download_${DateTime.now().millisecondsSinceEpoch}.zip',
    ));
    
    try {
      // 1. Download com progresso
      await _downloadFile(url, tempFile, onProgress: onProgress);
      
      // 2. Extrair
      await _extractZip(tempFile, destinationDir);
      
    } finally {
      // 3. Limpar temp
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }
  }
  
  /// Download com retry e fallback de CDN mirrors
  static Future<void> _downloadFile(
    String url,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {
    final client = HttpClient();
    
    try {
      // Tentar cada mirror
      final mirrors = BrowserRegistry._cdnMirrors;
      
      for (int i = 0; i < mirrors.length; i++) {
        final mirror = mirrors[i];
        final fullUrl = '$mirror/$url';
        
        try {
          final request = await client.getUrl(Uri.parse(fullUrl));
          
          // Respeitar proxy
          final proxy = Platform.environment['HTTPS_PROXY'] ?? 
              Platform.environment['HTTP_PROXY'];
          if (proxy != null) {
            // TODO: Configurar proxy
          }
          
          final response = await request.close();
          
          if (response.statusCode != 200) {
            if (i < mirrors.length - 1) continue; // Tentar próximo mirror
            throw PlaywrightException(
              'Failed to download from $fullUrl: ${response.statusCode}',
            );
          }
          
          final totalBytes = response.contentLength;
          var downloadedBytes = 0;
          
          final sink = destination.openWrite();
          
          await for (final chunk in response) {
            sink.add(chunk);
            downloadedBytes += chunk.length;
            
            if (totalBytes > 0 && onProgress != null) {
              onProgress(downloadedBytes / totalBytes);
            }
          }
          
          await sink.close();
          return; // Sucesso!
          
        } catch (e) {
          if (i == mirrors.length - 1) rethrow;
          // Tentar próximo mirror
          continue;
        }
      }
    } finally {
      client.close();
    }
  }
  
  /// Extrair arquivo ZIP
  static Future<void> _extractZip(File zipFile, String destination) async {
    final bytes = await zipFile.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    
    for (final file in archive) {
      final filename = path.join(destination, file.name);
      
      if (file.isFile) {
        final outFile = File(filename);
        await outFile.create(recursive: true);
        await outFile.writeAsBytes(file.content as List<int>);
      } else {
        await Directory(filename).create(recursive: true);
      }
    }
  }
}
```

---

## 5. URLs de Download por Plataforma

### 5.1. Host Platform Detection

```dart
// lib/src/registry/host_platform.dart

/// Detectar a plataforma do host
class HostPlatform {
  /// Obter identificador da plataforma para download
  static String detect() {
    if (Platform.isWindows) return 'win-x64';
    if (Platform.isMacOS) {
      // Detectar arquitetura
      final arch = _detectArch();
      return arch == 'arm64' ? 'mac-arm64' : 'mac-x64';
    }
    if (Platform.isLinux) {
      final arch = _detectArch();
      return arch == 'arm64' ? 'linux-arm64' : 'linux-x64';
    }
    return '<unknown>';
  }
  
  /// Obter plataforma detalhada (com versão do SO para Linux)
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
    // Usar dart:ffi para detectar arquitetura ou ler de uname
    if (Platform.isMacOS || Platform.isLinux) {
      final result = Process.runSync('uname', ['-m']);
      final arch = (result.stdout as String).trim();
      if (arch == 'aarch64' || arch == 'arm64') return 'arm64';
      return 'x64';
    }
    return 'x64'; // Windows é sempre x64 para Playwright
  }
  
  static String _macOSVersion() {
    try {
      final result = Process.runSync('sw_vers', ['-productVersion']);
      final version = (result.stdout as String).trim();
      final major = int.parse(version.split('.').first);
      return '$major';
    } catch (_) {
      return '15';
    }
  }
  
  static String _linuxDistro() {
    try {
      final osRelease = File('/etc/os-release').readAsStringSync();
      // Parse ID e VERSION_ID
      final lines = osRelease.split('\n');
      String? id;
      String? versionId;
      for (final line in lines) {
        if (line.startsWith('ID=')) id = line.substring(3).replaceAll('"', '');
        if (line.startsWith('VERSION_ID=')) versionId = line.substring(11).replaceAll('"', '');
      }
      if (id == 'ubuntu' && versionId != null) return 'ubuntu$versionId';
      if (id == 'debian' && versionId != null) return 'debian${versionId.split('.').first}';
      return 'ubuntu22.04'; // Fallback
    } catch (_) {
      return 'ubuntu22.04';
    }
  }
}
```

### 5.2. Mapa de URLs de Download

```dart
// Mapa completo de download URLs (extraído do registry do TS)
const _downloadPaths = <String, Map<String, String?>>{
  'chromium': {
    'win-x64': null, // Usa CFT URL
    'mac-x64': null, // Usa CFT URL
    'mac-arm64': null, // Usa CFT URL
    'linux-x64': null, // Usa CFT URL
    'linux-arm64': 'builds/chromium/%s/chromium-linux-arm64.zip',
  },
  'firefox': {
    'win-x64': 'builds/firefox/%s/firefox-win64.zip',
    'mac-x64': 'builds/firefox/%s/firefox-mac.zip',
    'mac-arm64': 'builds/firefox/%s/firefox-mac-arm64.zip',
    'linux-x64': 'builds/firefox/%s/firefox-ubuntu-22.04.zip',
    'linux-arm64': 'builds/firefox/%s/firefox-ubuntu-22.04-arm64.zip',
  },
  'webkit': {
    'win-x64': 'builds/webkit/%s/webkit-win64.zip',
    'mac-x64': 'builds/webkit/%s/webkit-mac-15.zip',
    'mac-arm64': 'builds/webkit/%s/webkit-mac-15-arm64.zip',
    'linux-x64': 'builds/webkit/%s/webkit-ubuntu-22.04.zip',
    'linux-arm64': 'builds/webkit/%s/webkit-ubuntu-22.04-arm64.zip',
  },
  'ffmpeg': {
    'win-x64': 'builds/ffmpeg/%s/ffmpeg-win64.zip',
    'mac-x64': 'builds/ffmpeg/%s/ffmpeg-mac.zip',
    'mac-arm64': 'builds/ffmpeg/%s/ffmpeg-mac-arm64.zip',
    'linux-x64': 'builds/ffmpeg/%s/ffmpeg-linux.zip',
    'linux-arm64': 'builds/ffmpeg/%s/ffmpeg-linux-arm64.zip',
  },
};

/// Para Chromium CFT (Chrome for Testing), a URL usa browserVersion:
String _cftUrl(String browserVersion, String suffix) {
  return 'builds/cft/$browserVersion/$suffix';
}

const _cftSuffixes = {
  'win-x64': 'win64/chrome-win64.zip',
  'mac-x64': 'mac-x64/chrome-mac-x64.zip',
  'mac-arm64': 'mac-arm64/chrome-mac-arm64.zip',
  'linux-x64': 'linux64/chrome-linux64.zip',
};
```

---

## 6. CLI de Instalação

```dart
// bin/playwright.dart

import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:playwright/src/registry/registry.dart';

void main(List<String> args) {
  final runner = CommandRunner<void>(
    'playwright',
    'Playwright for Dart — Browser automation',
  )
    ..addCommand(InstallCommand())
    ..addCommand(UninstallCommand())
    ..addCommand(ListCommand());
  
  runner.run(args).catchError((error) {
    stderr.writeln('Error: $error');
    exit(1);
  });
}

class InstallCommand extends Command<void> {
  @override String get name => 'install';
  @override String get description => 'Install browser binaries';
  
  InstallCommand() {
    argParser.addFlag('with-deps', help: 'Install system dependencies');
  }
  
  @override
  Future<void> run() async {
    final registry = BrowserRegistry();
    final browsers = argResults!.rest;
    
    if (browsers.isEmpty) {
      // Instalar todos os padrão
      await registry.installAll(onProgress: (browser, progress) {
        stdout.write('\r$browser: ${(progress * 100).toStringAsFixed(1)}%');
      });
    } else {
      for (final browser in browsers) {
        await registry.install(browser, onProgress: (progress) {
          stdout.write('\r$browser: ${(progress * 100).toStringAsFixed(1)}%');
        });
        stdout.writeln();
      }
    }
  }
}

class ListCommand extends Command<void> {
  @override String get name => 'list';
  @override String get description => 'List installed browsers';
  
  @override
  void run() {
    final registry = BrowserRegistry();
    for (final browser in registry.browsers) {
      final installed = registry.isInstalled(browser.name);
      final status = installed ? '✅' : '❌';
      final version = browser.browserVersion ?? browser.revision;
      print('$status ${browser.title ?? browser.name} $version');
    }
  }
}
```

---

## 7. Executáveis por Plataforma

```dart
const _executablePaths = <String, Map<String, List<String>?>>{
  'chromium': {
    'win-x64': ['chrome-win64', 'chrome.exe'],
    'mac-x64': ['chrome-mac-x64', 'Google Chrome for Testing.app', 'Contents', 'MacOS', 'Google Chrome for Testing'],
    'mac-arm64': ['chrome-mac-arm64', 'Google Chrome for Testing.app', 'Contents', 'MacOS', 'Google Chrome for Testing'],
    'linux-x64': ['chrome-linux64', 'chrome'],
    'linux-arm64': ['chrome-linux', 'chrome'],
  },
  'firefox': {
    'win-x64': ['firefox', 'firefox.exe'],
    'mac-x64': ['firefox', 'Nightly.app', 'Contents', 'MacOS', 'firefox'],
    'mac-arm64': ['firefox', 'Nightly.app', 'Contents', 'MacOS', 'firefox'],
    'linux-x64': ['firefox', 'firefox'],
    'linux-arm64': ['firefox', 'firefox'],
  },
  'webkit': {
    'win-x64': ['Playwright.exe'],
    'mac-x64': ['pw_run.sh'],
    'mac-arm64': ['pw_run.sh'],
    'linux-x64': ['pw_run.sh'],
    'linux-arm64': ['pw_run.sh'],
  },
  'ffmpeg': {
    'win-x64': ['ffmpeg-win64.exe'],
    'mac-x64': ['ffmpeg-mac'],
    'mac-arm64': ['ffmpeg-mac'],
    'linux-x64': ['ffmpeg-linux'],
    'linux-arm64': ['ffmpeg-linux'],
  },
};
```

# 09 — Servidor MCP (Model Context Protocol)

## 1. Visão Geral

O `playwright_mcp` é um servidor MCP que expõe o Playwright Dart como ferramentas para agentes de IA (Codex, Claude, Gemini, etc.), permitindo automação de navegador via protocolo MCP sem depender de Node.js.

### 1.1. Cadeia de Execução

```
AI Agent (Codex, Claude, etc.)
       ↓ MCP Protocol (JSON-RPC via stdio)
playwright_mcp (servidor Dart)
       ↓
playwright (API Dart)
       ↓
Chromium / Firefox / WebKit
       ↓
Aplicação web em teste
```

### 1.2. Referência

O MCP oficial da Microsoft (`@playwright/mcp`) fornece ao agente:
- **Snapshots da árvore de acessibilidade** (não screenshots)
- **Comandos de automação** (click, fill, navigate, etc.)
- **Modo sem visão** (baseado em accessibility tree)

---

## 2. Ferramentas MCP

### 2.1. Navegação

```dart
/// navigate — Navegar para uma URL
class NavigateTool extends McpTool {
  @override String get name => 'browser_navigate';
  @override String get description => 'Navigate to a URL';
  
  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'url': {'type': 'string', 'description': 'URL to navigate to'},
    },
    'required': ['url'],
  };
  
  @override
  Future<McpResult> execute(Map<String, dynamic> args) async {
    final url = args['url'] as String;
    await page.goto(url, waitUntil: WaitUntil.domContentLoaded);
    
    // Retornar snapshot da árvore de acessibilidade
    final snapshot = await _getAccessibilitySnapshot();
    return McpResult.text(snapshot);
  }
}
```

### 2.2. Snapshot

```dart
/// snapshot — Capturar snapshot da árvore de acessibilidade
class SnapshotTool extends McpTool {
  @override String get name => 'browser_snapshot';
  @override String get description => 
      'Capture accessibility snapshot of the current page';
  
  @override
  Future<McpResult> execute(Map<String, dynamic> args) async {
    final snapshot = await page.accessibility();
    return McpResult.text(_formatSnapshot(snapshot));
  }
  
  String _formatSnapshot(AccessibilitySnapshot snapshot) {
    final buffer = StringBuffer();
    buffer.writeln('Page: ${page.url}');
    buffer.writeln('Title: ${snapshot.title}');
    buffer.writeln();
    _formatNode(buffer, snapshot.root, 0);
    return buffer.toString();
  }
  
  void _formatNode(StringBuffer buffer, AccessibilityNode node, int indent) {
    final prefix = '  ' * indent;
    final ref = '[ref=${node.ref}]';
    buffer.writeln('$prefix- ${node.role}: "${node.name}" $ref');
    
    if (node.value != null) buffer.writeln('$prefix  value: ${node.value}');
    if (node.description != null) buffer.writeln('$prefix  description: ${node.description}');
    
    for (final child in node.children) {
      _formatNode(buffer, child, indent + 1);
    }
  }
}
```

### 2.3. Ações

```dart
/// click — Clicar em um elemento
class ClickTool extends McpTool {
  @override String get name => 'browser_click';
  @override String get description => 'Click an element on the page';
  
  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'element': {'type': 'string', 'description': 'Element reference from snapshot (e.g., "ref=s1e4")'},
      'ref': {'type': 'string', 'description': 'Reference ID of element to click'},
    },
    'required': ['ref'],
  };
  
  @override
  Future<McpResult> execute(Map<String, dynamic> args) async {
    final ref = args['ref'] as String;
    final locator = _resolveRef(ref);
    await locator.click();
    
    // Retornar novo snapshot após ação
    final snapshot = await _getAccessibilitySnapshot();
    return McpResult.text(snapshot);
  }
}

/// fill — Preencher um campo de texto
class FillTool extends McpTool {
  @override String get name => 'browser_type';
  @override String get description => 'Type text into an input field';
  
  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'ref': {'type': 'string', 'description': 'Reference ID of input element'},
      'text': {'type': 'string', 'description': 'Text to type'},
      'submit': {'type': 'boolean', 'description': 'Whether to press Enter after typing'},
    },
    'required': ['ref', 'text'],
  };
  
  @override
  Future<McpResult> execute(Map<String, dynamic> args) async {
    final ref = args['ref'] as String;
    final text = args['text'] as String;
    final submit = args['submit'] as bool? ?? false;
    
    final locator = _resolveRef(ref);
    await locator.fill(text);
    
    if (submit) {
      await locator.press('Enter');
    }
    
    final snapshot = await _getAccessibilitySnapshot();
    return McpResult.text(snapshot);
  }
}

/// screenshot — Capturar screenshot
class ScreenshotTool extends McpTool {
  @override String get name => 'browser_screenshot';
  @override String get description => 'Take a screenshot of the current page';
  
  @override
  Future<McpResult> execute(Map<String, dynamic> args) async {
    final bytes = await page.screenshot(type: ScreenshotType.png);
    return McpResult.image(bytes, mimeType: 'image/png');
  }
}

/// select — Selecionar opção em um select/dropdown
class SelectOptionTool extends McpTool {
  @override String get name => 'browser_select_option';
  @override String get description => 'Select an option from a dropdown';
  
  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'ref': {'type': 'string', 'description': 'Reference ID of select element'},
      'values': {
        'type': 'array',
        'items': {'type': 'string'},
        'description': 'Values to select',
      },
    },
    'required': ['ref', 'values'],
  };
  
  @override
  Future<McpResult> execute(Map<String, dynamic> args) async {
    final ref = args['ref'] as String;
    final values = (args['values'] as List).cast<String>();
    
    final locator = _resolveRef(ref);
    await locator.selectOption(values);
    
    final snapshot = await _getAccessibilitySnapshot();
    return McpResult.text(snapshot);
  }
}

/// evaluate — Executar JavaScript
class EvaluateTool extends McpTool {
  @override String get name => 'browser_evaluate';
  @override String get description => 'Execute JavaScript in the browser';
  
  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'expression': {'type': 'string', 'description': 'JavaScript expression to evaluate'},
    },
    'required': ['expression'],
  };
  
  @override
  Future<McpResult> execute(Map<String, dynamic> args) async {
    final expression = args['expression'] as String;
    final result = await page.evaluate(expression);
    return McpResult.text(jsonEncode(result));
  }
}

/// goBack — Voltar
class GoBackTool extends McpTool {
  @override String get name => 'browser_go_back';
  @override String get description => 'Go back in browser history';
  
  @override
  Future<McpResult> execute(Map<String, dynamic> args) async {
    await page.goBack();
    final snapshot = await _getAccessibilitySnapshot();
    return McpResult.text(snapshot);
  }
}

/// goForward — Avançar
class GoForwardTool extends McpTool {
  @override String get name => 'browser_go_forward';
  @override String get description => 'Go forward in browser history';
  
  @override
  Future<McpResult> execute(Map<String, dynamic> args) async {
    await page.goForward();
    final snapshot = await _getAccessibilitySnapshot();
    return McpResult.text(snapshot);
  }
}

/// hover — Passar o mouse sobre
class HoverTool extends McpTool {
  @override String get name => 'browser_hover';
  @override String get description => 'Hover over an element';
  
  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'ref': {'type': 'string', 'description': 'Reference ID of element to hover'},
    },
    'required': ['ref'],
  };
  
  @override
  Future<McpResult> execute(Map<String, dynamic> args) async {
    final ref = args['ref'] as String;
    final locator = _resolveRef(ref);
    await locator.hover();
    
    final snapshot = await _getAccessibilitySnapshot();
    return McpResult.text(snapshot);
  }
}

/// drag — Arrastar elemento
class DragTool extends McpTool {
  @override String get name => 'browser_drag';
  @override String get description => 'Drag an element to another element';
  
  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'sourceRef': {'type': 'string', 'description': 'Reference ID of source element'},
      'targetRef': {'type': 'string', 'description': 'Reference ID of target element'},
    },
    'required': ['sourceRef', 'targetRef'],
  };
  
  @override
  Future<McpResult> execute(Map<String, dynamic> args) async {
    final sourceRef = args['sourceRef'] as String;
    final targetRef = args['targetRef'] as String;
    
    final source = _resolveRef(sourceRef);
    final target = _resolveRef(targetRef);
    
    await source.dragTo(target);
    
    final snapshot = await _getAccessibilitySnapshot();
    return McpResult.text(snapshot);
  }
}

/// pressKey — Pressionar tecla
class PressKeyTool extends McpTool {
  @override String get name => 'browser_press_key';
  @override String get description => 'Press a keyboard key';
  
  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'key': {'type': 'string', 'description': 'Key to press (e.g., "Enter", "Tab", "Escape")'},
    },
    'required': ['key'],
  };
  
  @override
  Future<McpResult> execute(Map<String, dynamic> args) async {
    final key = args['key'] as String;
    await page.keyboard.press(key);
    
    final snapshot = await _getAccessibilitySnapshot();
    return McpResult.text(snapshot);
  }
}

/// waitForNavigation — Esperar navegação
class WaitTool extends McpTool {
  @override String get name => 'browser_wait';
  @override String get description => 'Wait for a specified time';
  
  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'time': {'type': 'number', 'description': 'Time to wait in seconds'},
    },
    'required': ['time'],
  };
  
  @override
  Future<McpResult> execute(Map<String, dynamic> args) async {
    final seconds = (args['time'] as num).toDouble();
    await Future.delayed(Duration(milliseconds: (seconds * 1000).toInt()));
    
    final snapshot = await _getAccessibilitySnapshot();
    return McpResult.text(snapshot);
  }
}

/// close — Fechar página
class CloseTool extends McpTool {
  @override String get name => 'browser_close';
  @override String get description => 'Close the current page';
  
  @override
  Future<McpResult> execute(Map<String, dynamic> args) async {
    await page.close();
    return McpResult.text('Page closed');
  }
}
```

---

## 3. Servidor MCP

```dart
// bin/playwright_mcp.dart

import 'dart:io';
import 'dart:convert';

void main(List<String> args) async {
  final server = PlaywrightMcpServer();
  await server.start();
}

class PlaywrightMcpServer {
  late final Playwright _playwright;
  late final Browser _browser;
  late final BrowserContext _context;
  Page? _page;
  
  final _tools = <String, McpTool>{};
  
  Future<void> start() async {
    // 1. Inicializar Playwright
    _playwright = await Playwright.create();
    _browser = await _playwright.chromium.launch(headless: true);
    _context = await _browser.newContext();
    
    // 2. Registrar ferramentas
    _registerTools();
    
    // 3. Escutar stdin (MCP usa stdio)
    await _handleStdio();
  }
  
  void _registerTools() {
    final tools = [
      NavigateTool(),
      SnapshotTool(),
      ClickTool(),
      FillTool(),
      ScreenshotTool(),
      SelectOptionTool(),
      EvaluateTool(),
      GoBackTool(),
      GoForwardTool(),
      HoverTool(),
      DragTool(),
      PressKeyTool(),
      WaitTool(),
      CloseTool(),
    ];
    
    for (final tool in tools) {
      _tools[tool.name] = tool;
    }
  }
  
  Future<void> _handleStdio() async {
    // MCP usa JSON-RPC 2.0 via stdin/stdout
    await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      try {
        final request = jsonDecode(line) as Map<String, dynamic>;
        final response = await _handleRequest(request);
        stdout.writeln(jsonEncode(response));
      } catch (e) {
        stderr.writeln('Error: $e');
      }
    }
  }
  
  Future<Map<String, dynamic>> _handleRequest(Map<String, dynamic> request) async {
    final method = request['method'] as String;
    final id = request['id'];
    
    switch (method) {
      case 'initialize':
        return _handleInitialize(id);
      case 'tools/list':
        return _handleToolsList(id);
      case 'tools/call':
        return await _handleToolsCall(id, request['params'] as Map<String, dynamic>);
      default:
        return {'jsonrpc': '2.0', 'id': id, 'error': {'code': -32601, 'message': 'Method not found'}};
    }
  }
  
  Map<String, dynamic> _handleInitialize(dynamic id) {
    return {
      'jsonrpc': '2.0',
      'id': id,
      'result': {
        'protocolVersion': '2024-11-05',
        'capabilities': {
          'tools': {'listChanged': false},
        },
        'serverInfo': {
          'name': 'playwright-dart-mcp',
          'version': '0.1.0',
        },
      },
    };
  }
  
  Map<String, dynamic> _handleToolsList(dynamic id) {
    return {
      'jsonrpc': '2.0',
      'id': id,
      'result': {
        'tools': _tools.values.map((tool) => {
          'name': tool.name,
          'description': tool.description,
          'inputSchema': tool.inputSchema,
        }).toList(),
      },
    };
  }
  
  Future<Map<String, dynamic>> _handleToolsCall(
    dynamic id, 
    Map<String, dynamic> params
  ) async {
    final toolName = params['name'] as String;
    final toolArgs = params['arguments'] as Map<String, dynamic>? ?? {};
    
    final tool = _tools[toolName];
    if (tool == null) {
      return {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': -32602, 'message': 'Unknown tool: $toolName'},
      };
    }
    
    try {
      // Garantir que temos uma página
      _page ??= await _context.newPage();
      tool.page = _page!;
      
      final result = await tool.execute(toolArgs);
      return {
        'jsonrpc': '2.0',
        'id': id,
        'result': result.toJson(),
      };
    } catch (e) {
      return {
        'jsonrpc': '2.0',
        'id': id,
        'result': {
          'content': [{'type': 'text', 'text': 'Error: $e'}],
          'isError': true,
        },
      };
    }
  }
}
```

---

## 4. Configuração MCP

```json
// Configuração para VS Code / Codex
{
  "mcpServers": {
    "playwright": {
      "command": "dart",
      "args": ["run", "playwright_mcp"],
      "cwd": "/path/to/project"
    }
  }
}
```

Ou como executável compilado:
```json
{
  "mcpServers": {
    "playwright": {
      "command": "playwright-mcp",
      "args": ["--browser", "chromium", "--headless"]
    }
  }
}
```

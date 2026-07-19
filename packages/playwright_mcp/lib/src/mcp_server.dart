import 'dart:io';
import 'dart:convert';
import 'package:playwright/playwright.dart';
import 'mcp_tool.dart';
import 'tools/navigate_tool.dart';
import 'tools/evaluate_tool.dart';
import 'tools/screenshot_tool.dart';
import 'tools/snapshot_tool.dart';
import 'tools/click_tool.dart';
import 'tools/type_tool.dart';

class PlaywrightMcpServer {
  Playwright? _playwright;
  Browser? _browser;
  BrowserContext? _context;
  Page? _page;
  
  final _tools = <String, McpTool>{};
  
  Future<void> start({String browserName = 'chromium'}) async {
    // 1. Inicializar Playwright
    _playwright = await Playwright.create();
    
    BrowserType type;
    switch (browserName.toLowerCase()) {
      case 'firefox':
        type = _playwright!.firefox;
        break;
      case 'webkit':
        type = _playwright!.webkit;
        break;
      case 'chromium':
      default:
        type = _playwright!.chromium;
        break;
    }
    
    _browser = await type.launch(headless: true);
    _context = await _browser!.newContext();
    
    // 2. Registrar ferramentas
    _registerTools();
    
    // 3. Escutar stdin (MCP usa stdio)
    await _handleStdio();
  }
  
  void _registerTools() {
    final tools = [
      NavigateTool(),
      EvaluateTool(),
      ScreenshotTool(),
      SnapshotTool(),
      ClickTool(),
      TypeTool(),
    ];
    
    for (final tool in tools) {
      _tools[tool.name] = tool;
    }
  }
  
  Future<void> _handleStdio() async {
    await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      
      try {
        final request = jsonDecode(line) as Map<String, dynamic>;
        final response = await _handleRequest(request);
        stdout.writeln(jsonEncode(response));
      } catch (e) {
        // Enviar erro JSON-RPC 2.0 genérico se o parsing falhar
        stdout.writeln(jsonEncode({
          'jsonrpc': '2.0',
          'id': null,
          'error': {'code': -32700, 'message': 'Parse error: $e'}
        }));
      }
    }
  }
  
  Future<Map<String, dynamic>> _handleRequest(Map<String, dynamic> request) async {
    final method = request['method'] as String?;
    final id = request['id'];
    
    if (method == null) {
      return {'jsonrpc': '2.0', 'id': id, 'error': {'code': -32600, 'message': 'Invalid Request'}};
    }
    
    switch (method) {
      case 'initialize':
        return _handleInitialize(id);
      case 'tools/list':
        return _handleToolsList(id);
      case 'tools/call':
        return await _handleToolsCall(id, request['params'] as Map<String, dynamic>? ?? {});
      default:
        // Ignore non-essential methods like notifications (e.g., initialized)
        if (id == null) {
           return {}; // It's a notification
        }
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
    final toolName = params['name'] as String?;
    final toolArgs = params['arguments'] as Map<String, dynamic>? ?? {};
    
    if (toolName == null) {
       return {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': -32602, 'message': 'Missing tool name'},
      };
    }

    final tool = _tools[toolName];
    if (tool == null) {
      return {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': -32601, 'message': 'Unknown tool: $toolName'},
      };
    }
    
    try {
      _page ??= await _context!.newPage();
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

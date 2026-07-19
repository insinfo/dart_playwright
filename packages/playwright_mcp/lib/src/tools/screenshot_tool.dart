import '../mcp_tool.dart';

class ScreenshotTool extends McpTool {
  @override
  String get name => 'browser_screenshot';
  
  @override
  String get description => 'Take a screenshot of the current page';
  
  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {},
  };
  
  @override
  Future<McpResult> execute(Map<String, dynamic> args) async {
    final bytes = await page!.screenshot();
    return McpResult.image(bytes, mimeType: 'image/png');
  }
}

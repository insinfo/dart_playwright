import '../mcp_tool.dart';

class NavigateTool extends McpTool {
  @override
  String get name => 'browser_navigate';
  
  @override
  String get description => 'Navigate the browser to a URL';
  
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
    await page!.goto(url);
    final title = await page!.title();
    return McpResult.text('Navigated to $url. Page title is "$title".');
  }
}

import '../mcp_tool.dart';

class ClickTool extends McpTool {
  @override
  String get name => 'browser_click';
  
  @override
  String get description => 'Click on an element matching a CSS selector';
  
  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'selector': {'type': 'string', 'description': 'CSS selector of the element to click'},
    },
    'required': ['selector'],
  };
  
  @override
  Future<McpResult> execute(Map<String, dynamic> args) async {
    final selector = args['selector'] as String;
    // Em uma versão mais avançada, o Locator teria o método click.
    // Como V0.1 não expôs click nativo do CDP ainda, faremos via JS.
    await page!.evaluate('''() => {
      const el = document.querySelector('$selector');
      if (el) el.click();
      else throw new Error("Element not found: $selector");
    }''');
    
    return McpResult.text('Clicked element: $selector');
  }
}

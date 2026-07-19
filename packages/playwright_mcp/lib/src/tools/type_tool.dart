import '../mcp_tool.dart';

class TypeTool extends McpTool {
  @override
  String get name => 'browser_type';
  
  @override
  String get description => 'Type text into an input element matching a CSS selector';
  
  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'selector': {'type': 'string', 'description': 'CSS selector of the input element'},
      'text': {'type': 'string', 'description': 'Text to type into the element'},
    },
    'required': ['selector', 'text'],
  };
  
  @override
  Future<McpResult> execute(Map<String, dynamic> args) async {
    final selector = args['selector'] as String;
    final text = args['text'] as String;
    
    await page!.evaluate('''() => {
      const el = document.querySelector('$selector');
      if (el) {
        el.value = '$text';
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      } else {
        throw new Error("Element not found: $selector");
      }
    }''');
    
    return McpResult.text('Typed "$text" into element: $selector');
  }
}

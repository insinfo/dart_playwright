import 'dart:convert';
import '../mcp_tool.dart';

class EvaluateTool extends McpTool {
  @override
  String get name => 'browser_evaluate';
  
  @override
  String get description => 'Evaluate JavaScript in the browser';
  
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
    final result = await page!.evaluate(expression);
    return McpResult.text('Evaluation result: ${jsonEncode(result)}');
  }
}

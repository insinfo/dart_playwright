import 'package:playwright/playwright.dart';
import '../mcp_tool.dart';

class SnapshotTool extends McpTool {
  @override
  String get name => 'browser_snapshot';
  
  @override
  String get description => 'Capture accessibility snapshot of the current page';
  
  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {},
  };
  
  @override
  Future<McpResult> execute(Map<String, dynamic> args) async {
    final snapshot = await page!.accessibilitySnapshot();
    return McpResult.text(_formatSnapshot(snapshot));
  }
  
  String _formatSnapshot(AccessibilitySnapshot snapshot) {
    final buffer = StringBuffer();
    // In a real scenario we could get the URL, but V0.1 Page doesn't have .url yet
    buffer.writeln('Title: ${snapshot.title}');
    buffer.writeln();
    _formatNode(buffer, snapshot.root, 0);
    return buffer.toString();
  }
  
  void _formatNode(StringBuffer buffer, AccessibilityNode node, int indent) {
    final prefix = '  ' * indent;
    final ref = '[ref=${node.ref}]';
    buffer.writeln('${prefix}- ${node.role}: "${node.name}" $ref');
    
    if (node.value != null && node.value!.isNotEmpty) buffer.writeln('${prefix}  value: ${node.value}');
    if (node.description != null && node.description!.isNotEmpty) buffer.writeln('${prefix}  description: ${node.description}');
    
    for (final child in node.children) {
      _formatNode(buffer, child, indent + 1);
    }
  }
}

class AccessibilityNode {
  final String role;
  final String name;
  final String? value;
  final String? description;
  final List<AccessibilityNode> children;
  
  // Custom ID for reference in MCP (e.g., ref=node_1)
  final String ref;

  AccessibilityNode({
    required this.role,
    required this.name,
    this.value,
    this.description,
    this.children = const [],
    required this.ref,
  });
}

class AccessibilitySnapshot {
  final String title;
  final AccessibilityNode root;

  AccessibilitySnapshot({
    required this.title,
    required this.root,
  });
}

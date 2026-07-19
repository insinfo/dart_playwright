import 'dart:convert';
import 'package:playwright/playwright.dart';

class McpResult {
  final Map<String, dynamic> _data;

  McpResult._(this._data);

  factory McpResult.text(String text) {
    return McpResult._({
      'content': [
        {'type': 'text', 'text': text}
      ],
      'isError': false,
    });
  }

  factory McpResult.image(List<int> bytes, {String mimeType = 'image/png'}) {
    final base64String = base64Encode(bytes);
    return McpResult._({
      'content': [
        {
          'type': 'image',
          'data': base64String,
          'mimeType': mimeType,
        }
      ],
      'isError': false,
    });
  }

  factory McpResult.error(String message) {
    return McpResult._({
      'content': [
        {'type': 'text', 'text': message}
      ],
      'isError': true,
    });
  }

  Map<String, dynamic> toJson() => _data;
}

abstract class McpTool {
  String get name;
  String get description;
  Map<String, dynamic> get inputSchema;

  Page? page;

  Future<McpResult> execute(Map<String, dynamic> args);
}

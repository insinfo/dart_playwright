/// Describes a browser that can be downloaded from the Playwright CDN.
class BrowserDescriptor {
  final String name;
  final String revision;
  final bool installByDefault;
  final String? browserVersion;
  final String? title;
  final Map<String, String>? revisionOverrides;

  BrowserDescriptor({
    required this.name,
    required this.revision,
    required this.installByDefault,
    this.browserVersion,
    this.title,
    this.revisionOverrides,
  });

  factory BrowserDescriptor.fromJson(Map<String, dynamic> json) {
    return BrowserDescriptor(
      name: json['name'] as String,
      revision: json['revision'] as String,
      installByDefault: json['installByDefault'] as bool? ?? false,
      browserVersion: json['browserVersion'] as String?,
      title: json['title'] as String?,
      revisionOverrides: (json['revisionOverrides'] as Map<String, dynamic>?)
          ?.map((k, v) => MapEntry(k, v as String)),
    );
  }

  /// Get the effective revision for a specific platform.
  String effectiveRevision(String platform) {
    return revisionOverrides?[platform] ?? revision;
  }
}

class StorageLocation {
  const StorageLocation({
    required this.path,
    this.pendingPath,
    this.problem,
    this.custom = false,
  });

  final String path;
  final String? pendingPath;
  final String? problem;
  final bool custom;
}

class StorageFolder {
  const StorageFolder(this.path, {this.bookmark});
  final String path;
  final String? bookmark;

  Map<String, dynamic> toJson() => {'path': path, 'bookmark': bookmark};
  factory StorageFolder.fromJson(Map<String, dynamic> json) => StorageFolder(
    json['path'] as String,
    bookmark: json['bookmark'] as String?,
  );
}

class StorageUnavailableException implements Exception {
  const StorageUnavailableException(this.message);
  final String message;
  @override
  String toString() => message;
}

enum StorageHealthStatus { ready, disconnected, unwritable, full, unavailable }

class StorageHealth {
  const StorageHealth(this.status, this.message);
  final StorageHealthStatus status;
  final String message;
  bool get isReady => status == StorageHealthStatus.ready;
}

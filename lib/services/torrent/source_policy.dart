import 'dart:convert';

import '../../models/torrent_models.dart';

class SourcePolicy {
  const SourcePolicy({
    this.blockedDomains = const {},
    this.blockedProviderNames = const {},
    this.blockedSourceIds = const {},
  });

  final Set<String> blockedDomains;
  final Set<String> blockedProviderNames;
  final Set<String> blockedSourceIds;

  factory SourcePolicy.fromJson(Map<String, dynamic> json) {
    Set<String> values(String key) => (json[key] as List<dynamic>? ?? const [])
        .whereType<String>()
        .map(_normalize)
        .where((value) => value.isNotEmpty)
        .toSet();

    return SourcePolicy(
      blockedDomains: values('blockedDomains'),
      blockedProviderNames: values('blockedProviderNames'),
      blockedSourceIds: values('blockedSourceIds'),
    );
  }

  factory SourcePolicy.fromJsonString(String value) {
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Source blocklist must be a JSON object.');
    }
    return SourcePolicy.fromJson(decoded);
  }

  SourcePolicyViolation? check(TorrentSource source) {
    if (blockedSourceIds.contains(_normalize(source.id))) {
      return SourcePolicyViolation('source ID', source.id);
    }
    if (blockedProviderNames.contains(_normalize(source.providerName))) {
      return SourcePolicyViolation('provider', source.providerName);
    }
    for (final host in _sourceHosts(source)) {
      final blocked = blockedDomains.where((domain) {
        return host == domain || host.endsWith('.$domain');
      }).firstOrNull;
      if (blocked != null) return SourcePolicyViolation('domain', blocked);
    }
    return null;
  }

  bool allows(TorrentSource source) => check(source) == null;

  static Iterable<String> _sourceHosts(TorrentSource source) sync* {
    if (source.uri.host.isNotEmpty) yield _normalize(source.uri.host);
    if (source.inputType != TorrentInputType.magnet) return;
    const uriKeys = ['tr', 'ws', 'xs', 'as'];
    for (final key in uriKeys) {
      for (final value in source.uri.queryParametersAll[key] ?? const []) {
        final host = Uri.tryParse(value)?.host;
        if (host != null && host.isNotEmpty) yield _normalize(host);
      }
    }
  }

  static String _normalize(String value) => value.trim().toLowerCase();
}

class SourcePolicyViolation implements Exception {
  const SourcePolicyViolation(this.ruleType, this.value);
  final String ruleType;
  final String value;

  @override
  String toString() =>
      'This torrent source was blocked by the local policy ($ruleType: $value).';
}

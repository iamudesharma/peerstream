String formatBytes(int value) {
  if (value < 1024) return '$value B';
  if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
  if (value < 1024 * 1024 * 1024) {
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String formatSpeed(int bytesPerSecond) => '${formatBytes(bytesPerSecond)}/s';

String formatYear(String? date) {
  if (date == null || date.isEmpty) return '';
  final year = date.split('-').first;
  return RegExp(r'^\d{4}$').hasMatch(year) ? year : '';
}

String formatRating(double rating) {
  if (rating <= 0) return '';
  return rating.toStringAsFixed(1);
}

String formatRuntime(int? minutes) {
  if (minutes == null || minutes <= 0) return '';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  if (hours <= 0) return '${rest}m';
  if (rest == 0) return '${hours}h';
  return '${hours}h ${rest}m';
}

String? formatQuality(String name) {
  final normalized = name.toLowerCase().replaceAll(RegExp(r'[._-]+'), ' ');
  const patterns = [
    r'2160p|4k|uhd',
    r'1080p|1080i|full hd|\bfhd\b',
    r'720p|\bhd\b',
    r'480p|\bsd\b',
    r'\bcam\b|\bhdcam\b|\bts\b|\btc\b',
  ];
  const labels = ['4K', '1080p', '720p', '480p', 'CAM'];
  for (var i = 0; i < patterns.length; i++) {
    if (RegExp(patterns[i]).hasMatch(normalized)) return labels[i];
  }
  return null;
}

String formatPhase(String phase) {
  return switch (phase) {
    'idle' => 'Idle',
    'resolving' => 'Finding file',
    'buffering' => 'Buffering',
    'seeking' => 'Seeking',
    'ready' => 'Ready',
    'playing' => 'Playing',
    'stopped' => 'Stopped',
    'error' => 'Error',
    'unsupported' => 'Unsupported',
    _ => phase.isEmpty ? 'Idle' : phase,
  };
}

String friendlyError(Object error) {
  final text = error.toString();
  if (text.contains('TMDB_READ_TOKEN') ||
      text.contains('TmdbConfigurationException')) {
    return 'Add a TMDB read token at launch to enable browsing.';
  }
  if (text.contains('SocketException') ||
      text.contains('Connection') ||
      text.contains('Timeout') ||
      text.contains('DioException')) {
    return 'Check your connection and try again.';
  }
  final compact = text.replaceFirst('Exception: ', '').trim();
  if (compact.length > 140) return '${compact.substring(0, 137)}...';
  return compact;
}

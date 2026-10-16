import 'package:flutter/material.dart';

class StorageRetryTile extends StatelessWidget {
  const StorageRetryTile({required this.onRetry, super.key});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.folder_off_outlined),
    title: const Text('Preferences unavailable'),
    subtitle: const Text('Reconnect storage, then retry.'),
    trailing: IconButton(
      tooltip: 'Retry loading preferences',
      onPressed: onRetry,
      icon: const Icon(Icons.refresh),
    ),
  );
}

/// Report a failed local write without presenting an unsaved change as success.
Future<bool> runStorageAction(
  BuildContext context,
  Future<void> Function() action, {
  String failureMessage =
      'Could not save this change. Check storage and retry.',
}) async {
  try {
    await action();
    return true;
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(failureMessage)));
    }
    return false;
  }
}

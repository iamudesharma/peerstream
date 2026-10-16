import 'package:flutter/material.dart';

class StorageStartupError extends StatelessWidget {
  const StorageStartupError({required this.onRetry, super.key});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.folder_off_outlined, size: 40),
            const SizedBox(height: 16),
            const Text('Saved data could not be opened.'),
            const SizedBox(height: 8),
            const Text(
              'Reconnect your storage drive, then retry.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    ),
  );
}

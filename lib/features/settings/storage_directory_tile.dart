import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/settings_widgets.dart';
import '../../services/storage/app_storage.dart';

final storageLocationProvider = FutureProvider<StorageLocation>(
  (ref) => appStorage.location(),
);

class StorageDirectoryTile extends ConsumerStatefulWidget {
  const StorageDirectoryTile({super.key});
  @override
  ConsumerState<StorageDirectoryTile> createState() =>
      _StorageDirectoryTileState();
}

class _StorageDirectoryTileState extends ConsumerState<StorageDirectoryTile> {
  bool _busy = false;
  StorageHealth? _health;

  Future<void> _choose() async {
    setState(() => _busy = true);
    try {
      final folder = await appStorage.chooseDirectory();
      if (folder == null) return;
      await appStorage.scheduleMove(folder);
      if (!mounted) return;
      ref.invalidate(storageLocationProvider);
      final location = await appStorage.location();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              location.pendingPath == null ? 'Current storage folder kept.' : 'Folder selected. Restart PeerStream to move your data and use it.',
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not change storage folder: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ref
      .watch(storageLocationProvider)
      .when(
        loading: () => const ListTile(
          title: Text('Storage folder'),
          subtitle: Text('Loading…'),
        ),
        error: (error, _) => SettingsTile(
          title: 'Choose storage folder',
          subtitle: 'Could not read the storage location: $error',
          icon: Icons.folder_outlined,
          onTap: _choose,
          enabled: appStorage.canChooseDirectory && !_busy,
        ),
        data: (location) => Column(
          children: [
            SettingsTile(
              title: 'Storage folder',
              subtitle: location.path,
              icon: Icons.folder_outlined,
              trailing: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.edit_outlined),
              onTap: _choose,
              enabled: appStorage.canChooseDirectory && !_busy,
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                'Saved video, subtitles, artwork, history, saved titles and settings use this folder. Choose an external drive to save space on this device.',
              ),
            ),
            ListTile(
              leading: Icon(
                _health?.isReady == false
                    ? Icons.warning_amber
                    : Icons.storage_outlined,
              ),
              title: Text(_health?.message ?? 'Check storage access'),
              trailing: TextButton(
                onPressed: _busy
                    ? null
                    : () async {
                        final health = await appStorage.checkHealth(
                          checkWritable: true,
                        );
                        if (mounted) setState(() => _health = health);
                        ref.invalidate(storageLocationProvider);
                      },
                child: const Text('Check again'),
              ),
            ),
            if (location.problem != null)
              ListTile(
                leading: const Icon(Icons.error_outline),
                title: Text(location.problem!),
              ),
            if (location.pendingPath != null)
              ListTile(
                leading: const Icon(Icons.restart_alt),
                title: const Text('Restart to apply'),
                subtitle: Text(
                  'New folder: ${location.pendingPath}\nYour saved data will move on the next launch.',
                ),
                trailing: TextButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          await appStorage.cancelMove();
                          ref.invalidate(storageLocationProvider);
                        },
                  child: const Text('Cancel'),
                ),
              ),
          ],
        ),
      );
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/app_providers.dart';
import '../../services/experience/playback_experience.dart';

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});
  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  String _filter = 'All';
  String _collection = 'All collections';
  Map<String, dynamic> _collections = {};
  @override
  void initState() {
    super.initState();
    playbackExperience.load().then((_) {
      if (!mounted) return;
      final prefs = playbackExperience.section('library');
      setState(() {
        _collections = Map<String, dynamic>.from(
          prefs['collections'] as Map? ?? {},
        );
        _filter = ['All', 'Unwatched', 'Watched'].contains(prefs['filter'])
            ? prefs['filter'] as String
            : 'All';
      });
    });
  }

  Future<void> _save() async {
    try {
      await playbackExperience.update(
        (data) =>
            data['library'] = {'filter': _filter, 'collections': _collections},
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not save library changes. Check storage and retry.',
          ),
        ),
      );
    }
  }

  Future<void> _create() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New collection'),
        content: TextField(
          controller: controller,
          maxLength: 48,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null ||
        name.isEmpty ||
        name == 'All collections' ||
        !mounted ||
        _collections.length >= 20) {
      return;
    }
    setState(() => _collections.putIfAbsent(name, () => <String>[]));
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    final saved = ref.watch(myListProvider);
    final watched = playbackExperience.watchedMedia;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          IconButton(
            tooltip: 'New collection',
            onPressed: _collections.length < 20 ? _create : null,
            icon: const Icon(Icons.create_new_folder_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          Wrap(
            spacing: 8,
            children: [
              DropdownButton<String>(
                value: _filter,
                items: [
                  for (final value in ['All', 'Unwatched', 'Watched'])
                    DropdownMenuItem(value: value, child: Text(value)),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _filter = value);
                    _save();
                  }
                },
              ),
              DropdownButton<String>(
                value: _collection,
                items: [
                  for (final value in ['All collections', ..._collections.keys])
                    DropdownMenuItem(value: value, child: Text(value)),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _collection = value);
                },
              ),
              if (_collection != 'All collections')
                IconButton(
                  tooltip: 'Delete collection',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () {
                    setState(() {
                      _collections.remove(_collection);
                      _collection = 'All collections';
                    });
                    _save();
                  },
                ),
            ],
          ),
          Expanded(
            child: saved.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, _) =>
                  const Center(child: Text('Could not load saved titles.')),
              data: (all) {
                final items = all
                    .where(
                      (e) =>
                          (_filter == 'All' ||
                              (_filter == 'Watched') ==
                                  watched.contains(e.key)) &&
                          (_collection == 'All collections' ||
                              (_collections[_collection] as List? ?? [])
                                  .contains(e.key)),
                    )
                    .toList();
                if (items.isEmpty) {
                  return const Center(
                    child: Text('No saved titles match these filters.'),
                  );
                }
                return ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return ListTile(
                      title: Text(item.title),
                      subtitle: Text(
                        watched.contains(item.key)
                            ? (item.media.type.name == 'tv'
                                  ? 'Watched episodes'
                                  : 'Watched')
                            : 'Unwatched',
                      ),
                      onTap: () =>
                          context.push('/details/${item.media.routeKey}'),
                      trailing: PopupMenuButton<String>(
                        tooltip: 'Organize saved title',
                        onSelected: (name) async {
                          final ids = List<String>.from(
                            _collections[name] as List? ?? [],
                          );
                          if (ids.contains(item.key)) {
                            ids.remove(item.key);
                          } else {
                            ids.add(item.key);
                          }
                          setState(() => _collections[name] = ids);
                          await _save();
                        },
                        itemBuilder: (_) => [
                          for (final name in _collections.keys)
                            CheckedPopupMenuItem(
                              value: name,
                              checked: (_collections[name] as List).contains(
                                item.key,
                              ),
                              child: Text(name),
                            ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/models/media_item.dart';
import 'package:peerstream/models/saved_item.dart';
import 'package:peerstream/providers/app_providers.dart';

SavedItem item(int id) => SavedItem(
  key: 'movie/$id',
  media: MediaRef(id: id, type: MediaType.movie),
  title: 'Title $id',
  addedAt: DateTime.utc(2026),
);

void main() {
  test(
    'concurrent saved-title changes serialize before reading the next state',
    () async {
      List<SavedItem> saved = [];
      final entered = Completer<void>();
      final release = Completer<void>();
      var writes = 0;
      final container = ProviderContainer(
        overrides: [
          myListProvider.overrideWith(
            () => MyList(
              read: () async => saved,
              write: (items) async {
                writes++;
                if (writes == 1) {
                  entered.complete();
                  await release.future;
                }
                saved = List.of(items);
              },
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(myListProvider.future);
      final list = container.read(myListProvider.notifier);
      final first = list.add(item(1));
      await entered.future;
      final second = list.add(item(2));
      await Future<void>.delayed(Duration.zero);
      expect(writes, 1);
      release.complete();
      await Future.wait([first, second]);
      expect(saved.map((value) => value.key).toSet(), {'movie/1', 'movie/2'});
    },
  );

  test(
    'failed persistence leaves state unchanged and does not poison retries',
    () async {
      var fail = true;
      final container = ProviderContainer(
        overrides: [
          myListProvider.overrideWith(
            () => MyList(
              read: () async => [],
              write: (_) async {
                if (fail) throw StateError('Storage full');
              },
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(myListProvider.future);
      final list = container.read(myListProvider.notifier);
      await expectLater(list.toggle(item(1)), throwsStateError);
      expect(container.read(myListProvider).value, isEmpty);
      fail = false;
      expect(await list.toggle(item(2)), isTrue);
      expect(container.read(myListProvider).value!.single.key, 'movie/2');
    },
  );
}

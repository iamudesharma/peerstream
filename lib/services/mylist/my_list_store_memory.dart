import '../../models/saved_item.dart';

List<SavedItem> _items = const [];

Future<List<SavedItem>> readMyList() async => List.of(_items);

Future<void> writeMyList(List<SavedItem> items) async {
  _items = normalizeMyList(items);
}

Map<String, dynamic> _data = {};
Future<Map<String, dynamic>> readJournal() async => Map.of(_data);
Future<void> writeJournal(Map<String, dynamic> data) async {
  _data = Map.of(data);
}

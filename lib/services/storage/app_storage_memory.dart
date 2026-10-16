import 'storage_location.dart';

final appStorage = AppStorage();

class AppStorage {
  bool get canChooseDirectory => false;
  Future<void> initialize() async {}
  Future<StorageHealth> checkHealth({bool checkWritable = false}) async =>
      const StorageHealth(
        StorageHealthStatus.ready,
        'Browser storage is ready',
      );
  Future<bool> hasCustomRoot() async => false;
  Future<StorageLocation> location() async =>
      const StorageLocation(path: 'Browser storage');
  Future<StorageFolder?> chooseDirectory() async => null;
  Future<void> scheduleMove(StorageFolder folder) async =>
      throw const StorageUnavailableException(
        'Folder selection is unavailable.',
      );
  Future<void> cancelMove() async {}
  Future<String> dataDirectoryPath() async => '';
  Future<String> cacheDirectoryPath() async => '';
  Future<String> temporaryDirectoryPath() async => '';
  Future<void> clearAuxiliaryCache() async {}
}

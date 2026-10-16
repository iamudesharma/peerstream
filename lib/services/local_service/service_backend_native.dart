import 'dart:io';

import '../storage/app_storage.dart';
import 'service_client.dart';

const serviceExperimentEnabled = bool.fromEnvironment(
  'PEERSTREAM_SERVICE_EXPERIMENTAL',
);
LocalServiceClient? experimentalService;
Future<void> configureExperimentalService() async {
  if (!serviceExperimentEnabled) return;
  if (!Platform.isMacOS) {
    throw UnsupportedError(
      'The service prototype currently supports macOS only.',
    );
  }
  final contents = File(Platform.resolvedExecutable).parent.parent.path;
  final executable = const String.fromEnvironment(
    'PEERSTREAM_SERVICE_BINARY',
    defaultValue: '',
  );
  final library = const String.fromEnvironment(
    'PEERSTREAM_SERVICE_LIBRARY',
    defaultValue: '',
  );
  final location = await appStorage.location();
  final temporaryPath = location.custom
      ? '${location.path}/temp'
      : await appStorage.temporaryDirectoryPath();
  experimentalService = LocalServiceClient(
    executable: executable.isEmpty
        ? '$contents/Helpers/peerstream-service'
        : executable,
    library: library.isEmpty
        ? '$contents/Frameworks/libtorrent_flutter.framework/libtorrent_flutter'
        : library,
    root: '$temporaryPath/service-prototype-v1',
    ensureStorage: () async {
      await appStorage.temporaryDirectoryPath();
    },
  );
}

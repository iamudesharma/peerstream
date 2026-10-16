import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:peerstream/services/local_service/service_client.dart';
import 'package:peerstream/services/storage/app_storage_native.dart';
import 'package:peerstream/services/torrent/native_torrent_engine.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'signed inherited helper can access isolated selected-SSD storage',
    (tester) async {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        const MaterialApp(home: Text('Verifying service access…')),
      );
      await tester.runAsync(() async {
        await appStorage.initialize();
        expect((await appStorage.location()).custom, isTrue);
        final root = await Directory(await appStorage.temporaryDirectoryPath())
            .createTemp('signed-service-test-');
        final contents = File(Platform.resolvedExecutable).parent.parent.path;
        final client = LocalServiceClient(
          executable: '$contents/Helpers/peerstream-service',
          library:
              '$contents/Frameworks/libtorrent_flutter.framework/libtorrent_flutter',
          root: root.path,
        );
        try {
          final health = await client.health();
          expect(health['storageReady'], isTrue);
          expect(health['bridgeVersion'], nativeBridgeVersion);
          await client.command('profile', {'lowMemory': true});
          expect(
            (await client.health())['pieceCacheBudgetBytes'],
            64 * 1024 * 1024,
          );
          await client.command('cacheClear');
          await client.close();
          // Restart with the same root tests lock release and durable session loading.
          expect((await client.health())['storageReady'], isTrue);
          debugPrint(
            '[ServiceVerification] signed-helper SSD access and restart passed',
          );
        } finally {
          await client.close();
          await root.delete(recursive: true);
        }
      });
    },
  );
}

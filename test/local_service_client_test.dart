import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/services/local_service/service_client.dart';

void main() {
  test(
    'shutdown confirms an uncooperative child exited before dropping ownership',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'peerstream-shutdown-test-',
      );
      final script = File('${root.path}/helper.sh');
      await script.writeAsString('''#!/bin/sh
read bootstrap
printf '{"protocol":1,"instance":"shutdown-fixture","port":9}\\n'
exec /bin/sleep 120
''');
      await Process.run('/bin/chmod', ['+x', script.path]);
      final client = LocalServiceClient(
        executable: script.path,
        library: '',
        root: '${root.path}/isolated',
      );
      try {
        await client.start();
        final child = client.processId!;
        expect(client.hasExited, isFalse);
        await client.close().timeout(const Duration(seconds: 15));
        expect(client.hasExited, isTrue);
        expect(client.processId, isNull);
        final alive = await Process.run('/bin/kill', ['-0', '$child']);
        expect(alive.exitCode, isNot(0));
      } finally {
        await client.close();
        await root.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS && !Platform.isLinux,
  );
  test('unavailable selected storage creates no fallback directory and remains retryable', () async {
    final sandbox = await Directory.systemTemp.createTemp(
      'peerstream-service-storage-test-',
    );
    var checks = 0;
    final root = '${sandbox.path}/must-not-be-created';
    final client = LocalServiceClient(
      executable: '/not/launched',
      library: '',
      root: root,
      ensureStorage: () async {
        checks++;
        throw StateError('Drive unavailable');
      },
    );
    try {
      await expectLater(client.start(restart: true), throwsStateError);
      await expectLater(client.start(restart: true), throwsStateError);
      expect(checks, 2);
      expect(await Directory(root).exists(), isFalse);
      expect(client.processId, isNull);
    } finally {
      await client.close();
      await sandbox.delete(recursive: true);
    }
  });
  test(
    'a failed bootstrap can be retried without reusing a failed future',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'peerstream-bootstrap-test-',
      );
      final script = File('${root.path}/helper.sh');
      await script.writeAsString('''#!/bin/sh
read bootstrap
printf x >> "\$0.count"
printf 'invalid readiness\\n'
''');
      await Process.run('/bin/chmod', ['+x', script.path]);
      final client = LocalServiceClient(
        executable: script.path,
        library: '',
        root: '${root.path}/isolated',
      );
      try {
        for (var i = 0; i < 2; i++) {
          await expectLater(client.start(restart: true), throwsFormatException);
        }
        expect(await File('${script.path}.count').readAsString(), 'xx');
        expect(client.processId, isNull);
      } finally {
        await client.close();
        await root.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS && !Platform.isLinux,
  );
}

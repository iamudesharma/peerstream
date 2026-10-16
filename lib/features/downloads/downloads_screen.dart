import 'package:flutter/material.dart';

import '../settings/offline_downloads_section.dart';

class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Downloads')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: const [
        Text(
          'Download a video from its source card. Completed videos stay on your selected storage drive. Use Save file as… to create a standalone copy in a folder of your choice.',
        ),
        SizedBox(height: 20),
        OfflineDownloadsSection(),
      ],
    ),
  );
}

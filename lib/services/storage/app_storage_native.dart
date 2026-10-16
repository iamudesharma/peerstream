import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'storage_location.dart';

final appStorage = AppStorage();

/// Only the locator and macOS security bookmark stay on the internal disk.
/// A pending move runs on the next launch, before any file writers/player open.
class AppStorage {
  AppStorage({
    StorageLocator? locator,
    Future<String> Function()? defaultDataPath,
    Future<String> Function()? defaultCachePath,
    Future<String> Function()? defaultTemporaryPath,
  }) : _locator = locator ?? StorageLocator(),
       _defaultDataPath = defaultDataPath ?? _dataPath,
       _defaultCachePath = defaultCachePath ?? _cachePath,
       _defaultTemporaryPath = defaultTemporaryPath ?? _temporaryPath;

  final StorageLocator _locator;
  final Future<String> Function() _defaultDataPath;
  final Future<String> Function() _defaultCachePath;
  final Future<String> Function() _defaultTemporaryPath;
  Future<void>? _initializing;
  StorageFolder? _current;
  StorageFolder? _pending;
  String? _problem;

  static const _dataNames = [
    'peerstream-watch-history.json',
    'peerstream-my-list.json',
    'peerstream-addons.json',
    'peerstream-settings.json',
    'peerstream-experience.json',
    'peerstream-playback-cache.json',
    'peerstream-playback-v1',
    'subtitles',
  ];
  static const _cacheNames = ['artwork', 'peerstream-session'];

  bool get canChooseDirectory =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  Future<void> initialize() {
    final current = _initializing;
    if (current != null) return current;
    final work = _initialize();
    _initializing = work;
    work.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {
        _initializing = null;
      },
    );
    return work;
  }

  Future<void> _initialize() async {
    final saved = await _locator.read();
    _current = saved.$1;
    _pending = saved.$2;
    try {
      if (_current != null) {
        _current = await _locator.restoreAccess(_current!);
        await _locator.write(_current, _pending);
      }
      if (_pending != null) {
        final selected = await _locator.restoreAccess(_pending!);
        await _move(selected);
      }
    } catch (error) {
      // Keep using the old location when a pending move cannot be completed.
      // A disconnected current drive never falls back to the internal disk.
      _problem =
          'Storage unavailable. Connect the drive or choose a writable '
          'folder in Playback & Storage. $error';
    }
  }

  Future<bool> hasCustomRoot() async {
    await initialize();
    return _current != null;
  }

  Future<StorageHealth> checkHealth({bool checkWritable = false}) async {
    await initialize();
    final root = _current?.path ?? await _defaultDataPath();
    if (!await Directory(root).exists()) {
      return const StorageHealth(
        StorageHealthStatus.disconnected,
        'Storage drive disconnected. Reconnect it or choose another folder.',
      );
    }
    if (checkWritable) {
      final probe = File(
        p.join(
          root,
          '.peerstream-write-check-${DateTime.now().microsecondsSinceEpoch}',
        ),
      );
      try {
        await probe.writeAsString('PeerStream', flush: true);
      } on FileSystemException catch (error) {
        final code = error.osError?.errorCode;
        if (code == 28) {
          return const StorageHealth(
            StorageHealthStatus.full,
            'Storage is full. Free space or choose another folder.',
          );
        }
        if (code == 13 || code == 1 || code == 30) {
          return const StorageHealth(
            StorageHealthStatus.unwritable,
            'Storage is not writable. Reselect the folder to restore access.',
          );
        }
        return const StorageHealth(
          StorageHealthStatus.unavailable,
          'Storage could not be accessed. Reconnect or reselect the folder.',
        );
      } finally {
        if (await probe.exists()) await probe.delete();
      }
    }
    return const StorageHealth(StorageHealthStatus.ready, 'Storage is ready');
  }

  Future<StorageLocation> location() async {
    await initialize();
    var problem = _problem;
    if (_current != null && !await Directory(_current!.path).exists()) {
      problem =
          'The selected storage drive is unavailable. Connect it before '
          'playing or saving data.';
    }
    return StorageLocation(
      path: _current?.path ?? await _defaultDataPath(),
      pendingPath: _pending?.path,
      problem: problem,
      custom: _current != null,
    );
  }

  Future<String> _directory(
    String name,
    Future<String> Function() fallback,
  ) async {
    await initialize();
    final selected = _current;
    if (selected == null) return fallback();
    if (!await Directory(selected.path).exists()) {
      throw const StorageUnavailableException(
        'The storage drive is disconnected. Reconnect it or choose another folder '
        'in Playback & Storage.',
      );
    }
    final directory = Directory(p.join(selected.path, name));
    try {
      await directory.create(recursive: true);
    } on FileSystemException catch (error) {
      final message = switch (error.osError?.errorCode) {
        28 => 'Storage is full. Free space or choose another folder.',
        13 ||
        1 ||
        30 => 'Storage is not writable. Reselect the folder to restore access.',
        _ => 'Storage is unavailable. Reconnect or reselect the folder.',
      };
      throw StorageUnavailableException(message);
    }
    return directory.path;
  }

  Future<String> dataDirectoryPath() => _directory('data', _defaultDataPath);
  Future<String> cacheDirectoryPath() => _directory('cache', _defaultCachePath);
  Future<String> temporaryDirectoryPath() =>
      _directory('temp', _defaultTemporaryPath);

  Future<StorageFolder?> chooseDirectory() async {
    if (!canChooseDirectory) return null;
    return _locator.chooseDirectory();
  }

  Future<void> scheduleMove(StorageFolder selected) async {
    await initialize();
    final path = p.normalize(p.absolute(selected.path));
    if (_current?.path == path) {
      await cancelMove();
      return;
    }
    final folder = StorageFolder(path, bookmark: selected.bookmark);
    await _validateDestination(folder);
    await _locator.write(_current, folder);
    _pending = folder;
    _problem = null;
  }

  Future<void> cancelMove() async {
    await initialize();
    await _locator.write(_current, null);
    _pending = null;
    _problem = null;
  }

  Future<void> _validateDestination(StorageFolder selected) async {
    final directory = Directory(selected.path);
    if (!await directory.exists()) {
      throw const StorageUnavailableException(
        'The selected folder is unavailable.',
      );
    }
    final resolved = await directory.resolveSymbolicLinks();
    final sourceData = _current == null
        ? await _defaultDataPath()
        : p.join(_current!.path, 'data');
    final sourceCache = _current == null
        ? await _defaultCachePath()
        : p.join(_current!.path, 'cache');
    for (final source in [sourceData, sourceCache]) {
      final sourceDirectory = Directory(source);
      final sourcePath = await sourceDirectory.exists()
          ? await sourceDirectory.resolveSymbolicLinks()
          : p.normalize(source);
      if (p.equals(sourcePath, resolved) ||
          p.isWithin(sourcePath, resolved) ||
          p.isWithin(resolved, sourcePath)) {
        throw const StorageUnavailableException(
          'Choose a separate folder outside the current app storage.',
        );
      }
    }
    for (final name in ['data', 'cache', 'temp']) {
      if (await FileSystemEntity.type(
            p.join(selected.path, name),
            followLinks: false,
          ) !=
          FileSystemEntityType.notFound) {
        throw const StorageUnavailableException(
          'Choose an empty folder. It already contains data, cache or temp files.',
        );
      }
    }
    final probe = File(
      p.join(
        selected.path,
        '.peerstream-write-${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    try {
      await probe.writeAsString('PeerStream storage check', flush: true);
    } on FileSystemException {
      throw const StorageUnavailableException(
        'PeerStream cannot write to this folder.',
      );
    } finally {
      if (await probe.exists()) await probe.delete();
    }
  }

  Future<void> _move(StorageFolder selected) async {
    if (_current != null && !await Directory(_current!.path).exists()) {
      throw const StorageUnavailableException(
        'Connect the current storage drive before moving saved data.',
      );
    }
    final oldData = _current == null
        ? await _defaultDataPath()
        : p.join(_current!.path, 'data');
    final oldCache = _current == null
        ? await _defaultCachePath()
        : p.join(_current!.path, 'cache');
    await _recoverInterruptedMove(selected, oldData);
    await _validateDestination(selected);
    final staging = await Directory(selected.path)
        .createTemp('.peerstream-move-');
    final nonce = List.generate(
      16,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final journal = File(p.join(selected.path, '.peerstream-move.json'));
    final installed = <Directory>[];
    var committed = false;
    try {
      await File('${journal.path}.tmp').writeAsString(
        jsonEncode({
          'version': 1,
          'nonce': nonce,
          'destination': selected.path,
          'sourceData': oldData,
          'staging': p.basename(staging.path),
        }),
        flush: true,
      );
      await File('${journal.path}.tmp').rename(journal.path);
      for (final part in [
        ('data', oldData, _dataNames),
        ('cache', oldCache, _cacheNames),
      ]) {
        final destination = await Directory(p.join(staging.path, part.$1))
            .create();
        for (final name in part.$3) {
          await _copyEntity(
            p.join(part.$2, name),
            p.join(destination.path, name),
          );
        }
      }
      await Directory(p.join(staging.path, 'temp')).create();
      final index = File(
        p.join(staging.path, 'data', 'peerstream-playback-cache.json'),
      );
      if (await index.exists()) {
        final state =
            jsonDecode(await index.readAsString()) as Map<String, dynamic>;
        for (final entry
            in (state['entries'] as List? ?? []).whereType<Map>()) {
          final filePath = entry['filePath'];
          if (filePath is String && p.isWithin(oldData, filePath)) {
            entry['filePath'] = p.join(
              selected.path,
              'data',
              p.relative(filePath, from: oldData),
            );
          }
        }
        await index.writeAsString(jsonEncode(state), flush: true);
      }
      for (final name in ['data', 'cache', 'temp']) {
        await File(p.join(staging.path, name, '.peerstream-move-owner'))
            .writeAsString(nonce, flush: true);
      }
      // Copy fully, then install and commit the locator. Never delete the source
      // until the new tree and its remembered security scope are durable.
      for (final name in ['data', 'cache', 'temp']) {
        installed.add(
          await Directory(p.join(staging.path, name))
              .rename(p.join(selected.path, name)),
        );
      }
      await _locator.write(selected, null);
      committed = true;
      _current = selected;
      _pending = null;
      _problem = null;
    } finally {
      if (!committed) {
        for (final directory in installed) {
          if (await directory.exists()) await directory.delete(recursive: true);
        }
      }
      if (await staging.exists()) await staging.delete(recursive: true);
      // A killed process leaves the journal and ownership markers for the
      // next launch. A handled failure has already rolled its copies back.
      if (!committed && await journal.exists()) await journal.delete();
      final journalTemp = File('${journal.path}.tmp');
      if (await journalTemp.exists()) await journalTemp.delete();
    }
    for (final name in ['data', 'cache', 'temp']) {
      final owner = File(p.join(selected.path, name, '.peerstream-move-owner'));
      if (await owner.exists()) await owner.delete();
    }
    if (await journal.exists()) await journal.delete();
    // A cleanup failure must not roll back a successfully committed move.
    try {
      for (final part in [(oldData, _dataNames), (oldCache, _cacheNames)]) {
        for (final name in part.$2) {
          await _deleteEntity(p.join(part.$1, name));
        }
      }
      // The old image cache uses an internal SQL index and is disposable.
      for (final name in ['libCachedImageData', 'peerstream-playback-v1']) {
        await _deleteEntity(p.join(oldCache, name));
      }
      for (final suffix in ['', '-shm', '-wal']) {
        await _deleteEntity(p.join(oldData, 'libCachedImageData.db$suffix'));
      }
    } on FileSystemException {
      _problem =
          'The new folder is active, but some old cache files could not '
          'be removed.';
    }
  }

  /// Only roll back transaction-owned copies. The original remains authoritative
  /// until the locator commits; unrelated folders and symbolic links are refused.
  Future<void> _recoverInterruptedMove(
    StorageFolder selected,
    String oldData,
  ) async {
    final journal = File(p.join(selected.path, '.peerstream-move.json'));
    if (!await journal.exists()) return;
    if (await journal.length() > 4096) {
      throw const StorageUnavailableException(
        'Interrupted move journal is invalid. Original data is preserved.',
      );
    }
    final record = jsonDecode(await journal.readAsString()) as Map;
    final nonce = record['nonce'];
    final stagingName = record['staging'];
    if (record['version'] != 1 ||
        record['destination'] != selected.path ||
        record['sourceData'] != oldData ||
        nonce is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(nonce) ||
        stagingName is! String ||
        !stagingName.startsWith('.peerstream-move-') ||
        p.basename(stagingName) != stagingName) {
      throw const StorageUnavailableException(
        'Interrupted move needs review. Original data is preserved.',
      );
    }
    final owned = <Directory>[];
    for (final name in ['data', 'cache', 'temp']) {
      final path = p.join(selected.path, name);
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.notFound) continue;
      final marker = File(p.join(path, '.peerstream-move-owner'));
      if (type != FileSystemEntityType.directory ||
          await FileSystemEntity.type(marker.path, followLinks: false) !=
              FileSystemEntityType.file ||
          !await marker.exists() ||
          await marker.length() != 32 ||
          await marker.readAsString() != nonce) {
        throw const StorageUnavailableException(
          'Interrupted move contains unrecognized data. Original data is preserved.',
        );
      }
      final allowedNames = <String>{
        '.peerstream-move-owner',
        if (name == 'data') ..._dataNames,
        if (name == 'cache') ..._cacheNames,
      };
      await for (final child in Directory(path).list(followLinks: false)) {
        if (!allowedNames.contains(p.basename(child.path))) {
          throw const StorageUnavailableException(
            'Interrupted move contains unrecognized files. Original data is preserved.',
          );
        }
      }
      owned.add(Directory(path));
    }
    final staging = Directory(p.join(selected.path, stagingName));
    final type = await FileSystemEntity.type(staging.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw const StorageUnavailableException(
        'Interrupted staging folder is invalid. Original data is preserved.',
      );
    }
    for (final directory in owned) {
      await directory.delete(recursive: true);
    }
    if (await staging.exists()) await staging.delete(recursive: true);
    await journal.delete();
  }

  Future<void> clearAuxiliaryCache() async {
    final cache = await cacheDirectoryPath();
    // The live artwork manager clears its files and keeps its empty index.
    for (final name in ['peerstream-session', 'libCachedImageData']) {
      await _deleteEntity(p.join(cache, name));
    }
    await _deleteEntity(p.join(await dataDirectoryPath(), 'subtitles'));
    final temporary = await temporaryDirectoryPath();
    await _deleteEntity(p.join(temporary, 'libCachedImageData'));
  }

  static Future<void> _copyEntity(String source, String destination) async {
    final type = await FileSystemEntity.type(source, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return;
    }
    if (type == FileSystemEntityType.link) {
      throw const StorageUnavailableException(
        'App storage contains a symbolic link. Move it manually first.',
      );
    }
    if (type == FileSystemEntityType.file) {
      final copied = await File(source).copy(destination);
      if (await copied.length() != await File(source).length()) {
        throw const StorageUnavailableException(
          'A file could not be copied completely.',
        );
      }
      return;
    }
    await Directory(destination).create();
    await for (final child in Directory(source).list(followLinks: false)) {
      await _copyEntity(
        child.path,
        p.join(destination, p.basename(child.path)),
      );
    }
  }

  static Future<void> _deleteEntity(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: true);
    } else if (type == FileSystemEntityType.file) {
      await File(path).delete();
    } else if (type == FileSystemEntityType.link) {
      await Link(path).delete();
    }
  }

  static Future<String> _dataPath() async =>
      (await getApplicationSupportDirectory()).path;
  static Future<String> _cachePath() async =>
      (await getApplicationCacheDirectory()).path;
  static Future<String> _temporaryPath() async =>
      (await getTemporaryDirectory()).path;
}

/// macOS bookmarks are resolved before any native engine/cache opens files.
/// Other desktop platforms retain the same locator without security scopes.
class StorageLocator {
  static const _key = 'peerstream.storage.location.v1';
  static const _channel = MethodChannel('dev.peerstream/storage');

  Future<(StorageFolder?, StorageFolder?)> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = prefs.getString(_key);
      if (encoded == null) return (null, null);
      final value = jsonDecode(encoded) as Map<String, dynamic>;
      StorageFolder? folder(String key) => value[key] is Map
          ? StorageFolder.fromJson(Map<String, dynamic>.from(value[key] as Map))
          : null;
      return (folder('current'), folder('pending'));
    } on MissingPluginException {
      return (null, null);
    }
  }

  Future<void> write(StorageFolder? current, StorageFolder? pending) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setString(
      _key,
      jsonEncode({'current': current?.toJson(), 'pending': pending?.toJson()}),
    );
    if (!saved) {
      throw const StorageUnavailableException(
        'Could not remember the storage folder.',
      );
    }
  }

  Future<StorageFolder> restoreAccess(StorageFolder folder) async {
    if (!Platform.isMacOS) return folder;
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'restoreAccess',
      folder.toJson(),
    );
    if (result == null) {
      throw const StorageUnavailableException(
        'Could not restore folder access.',
      );
    }
    return StorageFolder.fromJson(result);
  }

  Future<StorageFolder?> chooseDirectory() async {
    if (Platform.isMacOS) {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'chooseFolder',
      );
      return result == null ? null : StorageFolder.fromJson(result);
    }
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose PeerStream storage folder',
    );
    return path == null ? null : StorageFolder(path);
  }
}

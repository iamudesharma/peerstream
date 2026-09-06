import 'provider_catalog.dart';

List<String> _urls = defaultAddonUrls;
Future<List<String>> readAddonUrls() async => _urls;
Future<void> writeAddonUrls(List<String> urls) async {
  _urls = urls;
}

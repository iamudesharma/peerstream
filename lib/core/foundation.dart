/// Web is not a DartNative target. Memory stores keep the branch so the
/// conditional-export files still type-check.
const bool kIsWeb = false;

const bool kDebugMode = !bool.fromEnvironment('dart.vm.product');

void debugPrint(String? message, {int? wrapWidth}) {
  if (message == null) return;
  // ignore: avoid_print
  print(message);
}

bool listEquals<T>(List<T>? a, List<T>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

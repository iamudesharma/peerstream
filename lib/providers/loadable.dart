import 'dart:async';

import 'package:dartnative/dartnative.dart';

/// Async snapshot that widgets subscribe to with [watch].
class Loadable<T> extends ChangeNotifier {
  Loadable(this._load) {
    unawaited(reload());
  }

  Loadable.seed(T value) : _load = (() async => value) {
    this.value = value;
    loading = false;
  }

  final Future<T> Function() _load;

  T? value;
  Object? error;
  StackTrace? stackTrace;
  bool loading = true;

  bool get hasError => error != null && value == null;
  bool get hasValue => value != null;

  Future<T> get future => _pending ?? reload();
  Future<T>? _pending;

  Future<T> reload() {
    final run = _reload();
    _pending = run;
    return run;
  }

  Future<T> _reload() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      final next = await _load();
      value = next;
      loading = false;
      error = null;
      notifyListeners();
      return next;
    } catch (e, s) {
      error = e;
      stackTrace = s;
      loading = false;
      notifyListeners();
      rethrow;
    }
  }

  void setValue(T next) {
    value = next;
    loading = false;
    error = null;
    notifyListeners();
  }

  R when<R>({
    required R Function() loading,
    required R Function(Object error, StackTrace? stackTrace) error,
    required R Function(T data) data,
    bool skipLoadingOnReload = false,
  }) {
    if (hasError) return error(this.error!, stackTrace);
    if (this.loading && (value == null || !skipLoadingOnReload)) {
      return loading();
    }
    return data(value as T);
  }

  void whenData(void Function(T data) fn) {
    final current = value;
    if (current != null) fn(current);
  }
}

/// Listens to a stream and republishes the latest value.
class StreamLoadable<T> extends ChangeNotifier {
  StreamLoadable(Stream<T> stream, {T? initial}) {
    value = initial;
    if (initial != null) loading = false;
    _sub = stream.listen(
      (event) {
        value = event;
        loading = false;
        error = null;
        notifyListeners();
      },
      onError: (Object e, StackTrace s) {
        error = e;
        stackTrace = s;
        loading = false;
        notifyListeners();
      },
    );
  }

  late final StreamSubscription<T> _sub;
  T? value;
  Object? error;
  StackTrace? stackTrace;
  bool loading = true;

  bool get hasError => error != null && value == null;

  R when<R>({
    required R Function() loading,
    required R Function(Object error, StackTrace? stackTrace) error,
    required R Function(T data) data,
  }) {
    if (hasError) return error(this.error!, stackTrace);
    if (this.loading && value == null) return loading();
    return data(value as T);
  }

  @override
  void dispose() {
    unawaited(_sub.cancel());
    super.dispose();
  }
}

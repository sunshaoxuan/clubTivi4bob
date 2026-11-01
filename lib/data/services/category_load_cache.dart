/// Small, revision-bound LRU. Failed or invalidated reads never become cache
/// entries. Concurrent requests for one scope share the same in-flight work.
class CategoryLoadCache<T> {
  CategoryLoadCache({this.capacity = 4});
  final int capacity;
  final _values = <String, T>{};
  final _pending = <String, Future<T>>{};
  int _revision = 0;

  bool contains(String key) => _values.containsKey(key);

  void invalidate() {
    _revision++;
    _values.clear();
    _pending.clear();
  }

  Future<T> load(String key, Future<T> Function() read) {
    if (_values.containsKey(key)) {
      final value = _values.remove(key) as T;
      _values[key] = value;
      return Future.value(value);
    }
    if (_pending.containsKey(key)) return _pending[key]!;
    final revision = _revision;
    late final Future<T> request;
    request = Future.sync(read)
        .then((value) {
          if (revision == _revision) {
            _values[key] = value;
            while (_values.length > capacity) {
              _values.remove(_values.keys.first);
            }
          }
          return value;
        })
        .whenComplete(() {
          if (identical(_pending[key], request)) _pending.remove(key);
        });
    _pending[key] = request;
    return request;
  }
}

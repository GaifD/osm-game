/// Минимальная двоичная куча (ключ double, значение int).
class MinHeap {
  final List<double> _k = [];
  final List<int> _v = [];
  bool get isNotEmpty => _k.isNotEmpty;
  double get topKey => _k[0];
  void clear() {
    _k.clear();
    _v.clear();
  }

  void push(double k, int v) {
    _k.add(k);
    _v.add(v);
    int i = _k.length - 1;
    while (i > 0) {
      final p = (i - 1) >> 1;
      if (_k[p] <= _k[i]) break;
      _swap(i, p);
      i = p;
    }
  }

  int pop() {
    final top = _v[0];
    final lastK = _k.removeLast();
    final lastV = _v.removeLast();
    if (_k.isNotEmpty) {
      _k[0] = lastK;
      _v[0] = lastV;
      int i = 0;
      final n = _k.length;
      while (true) {
        final l = 2 * i + 1, r = l + 1;
        int m = i;
        if (l < n && _k[l] < _k[m]) m = l;
        if (r < n && _k[r] < _k[m]) m = r;
        if (m == i) break;
        _swap(i, m);
        i = m;
      }
    }
    return top;
  }

  void _swap(int a, int b) {
    final tk = _k[a];
    _k[a] = _k[b];
    _k[b] = tk;
    final tv = _v[a];
    _v[a] = _v[b];
    _v[b] = tv;
  }
}

import 'dart:math' as math;

import '../data/config.dart';
import 'entities.dart';

/// Упрощённый расчёт энергосети.
///
/// Энергия «течёт» от станций к потребителям по самым выгодным путям
/// (с наименьшими потерями), с учётом пропускной способности линий и
/// подстанций. Это не настоящий расчёт перетоков, а быстрая модель,
/// которая ведёт себя правдоподобно и тянется телефоном.
class PowerSolver {
  final GameConfig cfg;
  PowerSolver(this.cfg);

  List<PNode> nodes = [];
  Map<String, int> idx = {};
  List<PLine> lines = [];
  List<List<int>> adj = [];
  List<int> la = [], lb = [];
  List<double> lres = [], lmult = [], lcost = [], nres = [];

  static const double inf = 1e12;
  static const double eps = 1e-3;

  void prepare(Map<String, PNode> nodeMap, Map<String, PLine> lineMap) {
    nodes = nodeMap.values.toList();
    idx = {for (int i = 0; i < nodes.length; i++) nodes[i].id: i};
    lines = [
      for (final l in lineMap.values)
        if (idx.containsKey(l.a) && idx.containsKey(l.b)) l
    ];
    adj = List.generate(nodes.length, (_) => <int>[]);
    final m = lines.length;
    la = List.filled(m, 0);
    lb = List.filled(m, 0);
    lres = List.filled(m, 0.0);
    lmult = List.filled(m, 1.0);
    lcost = List.filled(m, 0.0);
    for (int i = 0; i < m; i++) {
      final l = lines[i];
      la[i] = idx[l.a]!;
      lb[i] = idx[l.b]!;
      adj[la[i]].add(i);
      adj[lb[i]].add(i);
      l.flow = 0;
      l.lossMw = 0;
      if (l.virtual) {
        lres[i] = inf;
        lmult[i] = 1;
      } else {
        final v = cfg.volt(l.kv);
        lres[i] = v.capMw * l.circuits;
        final loss = (v.lossPer100km / 100.0 * l.lenKm / 100.0).clamp(0.0, 0.5);
        lmult[i] = 1 - loss;
      }
      lcost[i] = -math.log(lmult[i]) + 1e-7 * (l.lenKm + 1);
    }
    nres = [
      for (final n in nodes) n.isSub ? (n.def?.capMw ?? inf) : inf,
    ];
  }

  double capOf(PLine l) => l.virtual ? double.infinity : cfg.volt(l.kv).capMw * l.circuits;

  /// gens/loads: индекс узла -> МВт. Значения уменьшаются по мере доставки.
  void run(Map<int, double> gens, Map<int, double> loads) {
    final n = nodes.length;
    if (n == 0 || gens.isEmpty || loads.isEmpty) return;
    final dist = List<double>.filled(n, double.infinity);
    final prev = List<int>.filled(n, -1);
    final src = List<int>.filled(n, -1);
    final heap = _Heap();

    for (int round = 0; round < 60; round++) {
      if (!gens.values.any((g) => g > eps) || !loads.values.any((l) => l > eps)) break;
      for (int i = 0; i < n; i++) {
        dist[i] = double.infinity;
        prev[i] = -1;
        src[i] = -1;
      }
      heap.clear();
      gens.forEach((g, rem) {
        if (rem > eps) {
          dist[g] = 0;
          src[g] = g;
          heap.push(0, g);
        }
      });
      while (heap.isNotEmpty) {
        final d = heap.topKey;
        final u = heap.pop();
        if (d > dist[u]) continue;
        if (src[u] != u && nres[u] <= eps) continue; // через узел не пройти
        for (final li in adj[u]) {
          if (lres[li] <= eps) continue;
          final v = la[li] == u ? lb[li] : la[li];
          final nd = d + lcost[li];
          if (nd < dist[v]) {
            dist[v] = nd;
            prev[v] = li;
            src[v] = src[u];
            heap.push(nd, v);
          }
        }
      }

      final reached = <int>[
        for (final e in loads.entries)
          if (e.value > eps && dist[e.key] < double.infinity) e.key
      ]..sort((a, b) => dist[a].compareTo(dist[b]));

      double delivered = 0;
      final pathLines = <int>[];
      final pathNodes = <int>[];
      for (final l in reached) {
        final s0 = src[l];
        if (s0 < 0) continue;
        final gRem = gens[s0] ?? 0;
        if (gRem <= eps) continue;
        if (s0 == l) {
          final amt = math.min(gRem, loads[l]!);
          gens[s0] = gRem - amt;
          loads[l] = loads[l]! - amt;
          delivered += amt;
          continue;
        }
        pathLines.clear();
        pathNodes.clear();
        int v = l;
        int guard = 0;
        while (v != s0 && guard++ < n) {
          final li = prev[v];
          if (li < 0) break;
          pathLines.add(li);
          pathNodes.add(v);
          v = la[li] == v ? lb[li] : la[li];
        }
        if (v != s0) continue;
        // теперь в порядке от станции к потребителю
        final pl = pathLines.reversed.toList();
        final pn = pathNodes.reversed.toList(); // pn[k] — узел в конце линии pl[k]
        double s = gRem;
        double prefix = 1;
        for (int k = 0; k < pl.length; k++) {
          s = math.min(s, lres[pl[k]] / prefix);
          prefix *= lmult[pl[k]];
          if (k < pl.length - 1) s = math.min(s, nres[pn[k]] / prefix);
        }
        final mult = prefix;
        s = math.min(s, loads[l]! / mult);
        if (s <= eps) continue;
        prefix = 1;
        for (int k = 0; k < pl.length; k++) {
          final li = pl[k];
          final fin = s * prefix;
          lres[li] -= fin;
          lines[li].flow += fin;
          lines[li].lossMw += fin * (1 - lmult[li]);
          prefix *= lmult[li];
          if (k < pl.length - 1) nres[pn[k]] -= s * prefix;
        }
        gens[s0] = gRem - s;
        loads[l] = loads[l]! - s * mult;
        delivered += s * mult;
      }
      if (delivered < eps) break;
    }
  }
}

/// Минимальная двоичная куча (ключ double, значение int).
class _Heap {
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

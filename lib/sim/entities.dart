import 'dart:ui';

import '../data/config.dart';

enum NodeKind { city, building, junction }

/// Любой объект на карте, который участвует в сети: город, здание,
/// подстанция, станция, узел-стык ЛЭП.
class PNode {
  final String id;
  final NodeKind kind;
  String name;
  final Offset pos;
  final Set<int> kv;
  final BuildingDef? def;
  final bool existing; // из OSM
  final double mwOverride; // мощность существующей станции
  final int pop;

  // --- состояние
  final Map<String, double> stock = {};
  double storedMwh = 0;

  // --- результаты последнего расчёта
  double genAvail = 0;
  double genMw = 0;
  double demandMw = 0;
  double suppliedMw = 0;
  double chargeMw = 0;
  double workFrac = 0; // насколько загружено производство (0..1)
  String status = '';

  PNode({
    required this.id,
    required this.kind,
    required this.name,
    required this.pos,
    required this.kv,
    this.def,
    this.existing = false,
    this.mwOverride = 0,
    this.pop = 0,
  });

  double get maxMw => mwOverride > 0 ? mwOverride : (def?.mw ?? 0);
  bool get isCity => kind == NodeKind.city;
  bool get isJunction => kind == NodeKind.junction;
  String get k => def?.kind ?? '';
  bool get isStation => k == 'station';
  bool get isSub => k == 'sub';
  double get supplyFrac => demandMw <= 0.001 ? 1 : (suppliedMw / demandMw).clamp(0.0, 1.0);

  String get icon => isCity ? '●' : (def?.icon ?? '·');
}

class PLine {
  final String id;
  final String a, b;
  final int kv;
  final int circuits;
  final bool virtual; // авто-подключение (без потерь, без лимита)
  final bool existing;
  final List<Offset> pts;
  final double lenKm;

  double flow = 0; // МВт на входе
  double lossMw = 0;

  PLine({
    required this.id,
    required this.a,
    required this.b,
    required this.kv,
    required this.pts,
    required this.lenKm,
    this.circuits = 1,
    this.virtual = false,
    this.existing = false,
  });

  String other(String n) => n == a ? b : a;
}

class Rail {
  final String id, a, b;
  final double lenKm;
  Rail(this.id, this.a, this.b, this.lenKm);
  String other(String n) => n == a ? b : a;
}

class Train {
  final String id;
  final String from, to; // конечные станции
  List<String> path = []; // станции по пути (from ... to)
  int seg = 0; // индекс отрезка path[seg] -> path[seg+1]
  double posKm = 0; // пройдено по текущему отрезку
  String cargo = '';
  double amount = 0;
  double dwell = 0; // часы стоянки
  String status = '';

  Train(this.id, this.from, this.to);
}

/// Автоколонна: возит груз по реальным дорогам от здания к зданию.
class Truck {
  final String id;
  final String from, to;
  List<Offset> route = [];
  List<double> cum = []; // накопленная длина, км
  double pos = 0; // км от начала маршрута
  bool back = false; // едет обратно
  String cargo = '';
  double amount = 0;
  double dwell = 0;
  String status = '';
  bool byRoad = true;

  Truck(this.id, this.from, this.to);

  double get total => cum.isEmpty ? 0 : cum.last;

  void setRoute(List<Offset> pts, {bool road = true}) {
    route = pts;
    byRoad = road;
    cum = [0];
    for (int i = 1; i < pts.length; i++) {
      cum.add(cum.last + (pts[i] - pts[i - 1]).distance);
    }
  }

  Offset? at() {
    if (route.isEmpty) return null;
    if (route.length == 1) return route.first;
    final d = pos.clamp(0.0, total);
    int lo = 0, hi = cum.length - 1;
    while (hi - lo > 1) {
      final m = (lo + hi) >> 1;
      if (cum[m] <= d) {
        lo = m;
      } else {
        hi = m;
      }
    }
    final seg = cum[hi] - cum[lo];
    final t = seg <= 0 ? 0.0 : (d - cum[lo]) / seg;
    return Offset.lerp(route[lo], route[hi], t);
  }
}

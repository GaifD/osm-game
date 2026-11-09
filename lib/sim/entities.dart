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

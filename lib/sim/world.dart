import 'dart:math' as math;
import 'dart:ui';

import '../data/config.dart';
import '../data/geo.dart';
import 'entities.dart';
import 'power.dart';

/// Всё состояние игры и симуляция.
class World {
  final GameConfig cfg;
  final MapData map;
  final bool readyMode; // готовая сеть из OSM

  final Map<String, PNode> nodes = {};
  final Map<String, PLine> lines = {};
  final Map<String, Rail> rails = {};
  final List<Train> trains = [];
  final List<Truck> trucks = [];
  int tutStep = 0; // шаг обучения
  final Set<String> removedExisting = {};

  double hours = 6; // игровое время с начала (старт — 06:00 первого дня)
  double wind = 0.5;
  int _seq = 0;
  final math.Random _rng = math.Random();
  late final PowerSolver _solver = PowerSolver(cfg);

  // итоги последнего расчёта
  double totalGen = 0, totalDemand = 0, totalSupplied = 0, totalLoss = 0, spareMw = 0;
  final Map<String, double> produced = {};
  final Map<String, String> servedBy = {}; // здание -> станция
  final Map<String, List<String>> catchment = {}; // станция -> здания

  World(this.cfg, this.map, {required this.readyMode}) {
    for (int i = 0; i < map.cities.length; i++) {
      final c = map.cities[i];
      nodes['c$i'] = PNode(id: 'c$i', kind: NodeKind.city, name: c.name, pos: c.pos, kv: {110, 35}, pop: c.pop);
    }
    if (readyMode) _loadExisting();
  }

  String newId(String p) => '$p${_seq++}';

  // ------------------------------------------------------------ существующая сеть
  void _loadExisting() {
    for (final g in map.gridNodes) {
      final id = 'x${g.id}';
      if (removedExisting.contains(id)) continue;
      if (g.type == 'sub') {
        nodes[id] = PNode(
            id: id, kind: NodeKind.building, name: g.name.isEmpty ? 'Подстанция' : g.name, pos: g.pos,
            kv: {...g.kv}, def: cfg.existingSubDef(g.kv), existing: true);
      } else if (g.type == 'plant') {
        final def = cfg.buildings[g.plantType];
        if (def == null) continue;
        nodes[id] = PNode(
            id: id, kind: NodeKind.building, name: g.name.isEmpty ? def.name : g.name, pos: g.pos,
            kv: {...g.kv}, def: def, existing: true, mwOverride: g.mw);
      } else {
        nodes[id] = PNode(id: id, kind: NodeKind.junction, name: 'Опора', pos: g.pos, kv: {...g.kv}, existing: true);
      }
    }
    int i = 0;
    for (final e in map.gridEdges) {
      final id = 'xl${i++}';
      final a = 'x${e.a}', b = 'x${e.b}';
      if (!nodes.containsKey(a) || !nodes.containsKey(b)) continue;
      lines[id] = PLine(
          id: id, a: a, b: b, kv: e.kv, pts: e.pts, lenKm: e.lenKm, circuits: e.circuits,
          virtual: e.virtual, existing: true);
    }
    // города подключаем к ближайшим подстанциям со стороной 110 кВ
    // (крупные — к нескольким, как в жизни)
    final subs = nodes.values.where((n) => n.existing && n.isSub && n.kv.contains(110)).toList();
    for (final c in nodes.values.where((n) => n.isCity).toList()) {
      final near = [
        for (final s in subs)
          if ((s.pos - c.pos).distance < 60) s
      ]..sort((a, b) => (a.pos - c.pos).distance.compareTo((b.pos - c.pos).distance));
      final want = c.pop > 1000000 ? 5 : (c.pop > 500000 ? 4 : (c.pop > 150000 ? 2 : 1));
      for (int k = 0; k < near.length && k < want; k++) {
        final s = near[k];
        final id = 'xf${c.id}_$k';
        final d = (s.pos - c.pos).distance;
        lines[id] = PLine(id: id, a: c.id, b: s.id, kv: 110, pts: [c.pos, s.pos], lenKm: d, virtual: true, existing: true);
      }
    }
  }

  // ------------------------------------------------------------ время
  int get day => (hours ~/ 24) + 1;
  double get hourOfDay => hours % 24;
  String get clock {
    final h = hourOfDay.floor();
    final m = ((hourOfDay - h) * 60).floor();
    return 'День $day, ${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  static const _curve = [
    [0.0, 0.62], [4.0, 0.55], [7.0, 0.80], [9.0, 0.92], [13.0, 0.85],
    [17.0, 0.90], [20.0, 1.00], [22.0, 0.85], [24.0, 0.62],
  ];

  double dayCurve(double h) {
    for (int i = 0; i + 1 < _curve.length; i++) {
      final a = _curve[i], b = _curve[i + 1];
      if (h >= a[0] && h <= b[0]) {
        final t = (h - a[0]) / (b[0] - a[0]);
        return a[1] + (b[1] - a[1]) * t;
      }
    }
    return 0.7;
  }

  double genFactor(PNode n) {
    final lat = latOf(n.pos);
    switch (n.def?.gen) {
      case 'nuclear':
        return 0.95;
      case 'hydro':
        return 0.55 + 0.15 * math.sin(day / 7.0);
      case 'solar':
        final h = hourOfDay;
        if (h < 6 || h > 18) return 0;
        final lf = (1 + (50 - lat) * 0.05).clamp(0.8, 1.3);
        return (math.sin(math.pi * (h - 6) / 12) * 0.85 * lf).clamp(0.0, 1.0);
      case 'wind':
        final rf = lat < 47.5 ? 1.2 : 0.85;
        return (wind * rf).clamp(0.0, 1.0);
      default:
        return 1.0;
    }
  }

  // ------------------------------------------------------------ шаг симуляции
  double _pendingH = 0;
  double _sinceSolve = 0;

  /// Вызывается каждый кадр. [gameH] — сколько игровых часов прошло.
  void tick(double gameH, double realDt) {
    if (gameH <= 0) return;
    hours += gameH;
    _pendingH += gameH;
    _sinceSolve += realDt;
    _moveTrains(gameH);
    _moveTrucks(gameH);
    if (_sinceSolve >= 0.25 || _pendingH >= 2) {
      step(_pendingH);
      _pendingH = 0;
      _sinceSolve = 0;
    }
  }

  void step(double dt) {
    if (dt <= 0) return;
    // ветер — случайное блуждание
    wind = (wind + (_rng.nextDouble() - 0.5) * 0.2 * math.min(dt, 3)).clamp(0.05, 1.0);
    _updateCatchment();
    _solvePower(dt);
    _produce(dt);
  }

  void _solvePower(double dt) {
    final s = _solver;
    s.prepare(nodes, lines);
    final gens = <int, double>{};
    final loads = <int, double>{};
    final storages = <int>[];
    final curve = dayCurve(hourOfDay);

    for (int i = 0; i < s.nodes.length; i++) {
      final n = s.nodes[i];
      n.genAvail = 0;
      n.genMw = 0;
      n.suppliedMw = 0;
      n.chargeMw = 0;
      n.demandMw = 0;
      if (n.isCity) {
        n.demandMw = n.pop * cfg.cityKwPerPerson / 1000.0 * curve;
      } else if (n.def != null) {
        final d = n.def!;
        if (d.loadMw > 0) {
          n.demandMw = d.loadMw * (_wantsToWork(n) ? 1.0 : 0.1);
        }
        if (d.kind == 'plant') {
          double avail = n.maxMw * genFactor(n);
          if (!n.existing) {
            d.fuel.forEach((res, perMwh) {
              final have = n.stock[res] ?? 0;
              avail = math.min(avail, have / (perMwh * dt));
            });
          }
          n.genAvail = math.max(0.0, avail);
          if (n.genAvail > 0) gens[i] = n.genAvail;
          n.status = n.genAvail <= 0.01 && d.fuel.isNotEmpty && !n.existing ? 'Нет топлива' : '';
        } else if (d.kind == 'storage') {
          storages.add(i);
        }
      }
      if (n.demandMw > 0) loads[i] = n.demandMw;
    }

    // 1. обычные станции -> потребители
    s.run(gens, loads);
    // 2. ГАЭС разряжаются, если не хватает
    final g2 = <int, double>{};
    for (final i in storages) {
      final n = s.nodes[i];
      final a = math.min(n.maxMw, n.storedMwh / dt);
      if (a > 0.01) g2[i] = a;
    }
    final g2start = Map<int, double>.from(g2);
    if (g2.isNotEmpty && loads.values.any((v) => v > 0.01)) s.run(g2, loads);
    // 3. ГАЭС заряжаются излишками
    final l3 = <int, double>{};
    for (final i in storages) {
      final n = s.nodes[i];
      final used = (g2start[i] ?? 0) - (g2[i] ?? 0);
      if (used > 0.01) continue;
      final room = (n.def!.storeMwh - n.storedMwh) / (n.def!.eff * dt);
      final c = math.min(n.maxMw, room);
      if (c > 0.01) l3[i] = c;
    }
    final l3start = Map<int, double>.from(l3);
    if (l3.isNotEmpty) s.run(gens, l3);

    totalGen = 0;
    totalDemand = 0;
    totalSupplied = 0;
    spareMw = 0;
    for (int i = 0; i < s.nodes.length; i++) {
      final n = s.nodes[i];
      if (gens.containsKey(i) || n.genAvail > 0) {
        n.genMw = n.genAvail - (gens[i] ?? 0);
        spareMw += gens[i] ?? 0;
        // расход топлива
        if (!n.existing) {
          n.def?.fuel.forEach((res, perMwh) {
            n.stock[res] = math.max(0.0, (n.stock[res] ?? 0) - n.genMw * dt * perMwh);
          });
        }
      }
      if (g2start.containsKey(i)) {
        n.genMw = g2start[i]! - (g2[i] ?? 0);
        n.storedMwh = math.max(0.0, n.storedMwh - n.genMw * dt);
      }
      if (l3start.containsKey(i)) {
        n.chargeMw = l3start[i]! - (l3[i] ?? 0);
        n.storedMwh = math.min(n.def!.storeMwh, n.storedMwh + n.chargeMw * dt * n.def!.eff);
      }
      if (n.demandMw > 0) n.suppliedMw = n.demandMw - (loads[i] ?? 0);
      totalGen += n.genMw;
      totalDemand += n.demandMw;
      totalSupplied += n.suppliedMw;
    }
    totalLoss = 0;
    for (final l in s.lines) {
      totalLoss += l.lossMw;
    }
  }

  bool _wantsToWork(PNode n) {
    final d = n.def!;
    for (final r in d.produces.keys) {
      if ((n.stock[r] ?? 0) < d.store - 1) return true;
    }
    return d.produces.isEmpty;
  }

  void _produce(double dt) {
    for (final n in nodes.values) {
      final d = n.def;
      if (d == null) continue;
      if (d.kind != 'producer' && d.kind != 'factory') continue;
      final pf = n.demandMw <= 0.001 ? 0.0 : n.supplyFrac;
      final frac = d.loadMw <= 0 ? 1.0 : pf;
      double best = 0;
      String why = '';
      d.produces.forEach((res, rate) {
        double amt = rate * dt * frac;
        if (frac <= 0.01) why = 'Нет электричества';
        final room = d.store - (n.stock[res] ?? 0);
        if (room < amt) {
          amt = math.max(0.0, room);
          if (amt <= 0.01) why = 'Склад полон — нужен поезд';
        }
        d.inputs.forEach((inRes, per) {
          final have = n.stock[inRes] ?? 0;
          if (have < amt * per) {
            amt = have / per;
            if (amt <= 0.01) why = 'Нет сырья: ${cfg.resName(inRes)}';
          }
        });
        if (amt <= 0) return;
        d.inputs.forEach((inRes, per) {
          n.stock[inRes] = (n.stock[inRes] ?? 0) - amt * per;
        });
        n.stock[res] = (n.stock[res] ?? 0) + amt;
        produced[res] = (produced[res] ?? 0) + amt;
        best = math.max(best, amt / (rate * dt));
      });
      n.workFrac = best;
      n.status = best > 0.01 && why.isEmpty ? '' : why;
      if (best > 0.01 && frac < 0.99) n.status = 'Не хватает электричества';
    }
  }

  // ------------------------------------------------------------ логистика
  void _updateCatchment() {
    servedBy.clear();
    catchment.clear();
    final stations = nodes.values.where((n) => n.isStation).toList();
    for (final s in stations) {
      catchment[s.id] = [];
    }
    if (stations.isEmpty) return;
    for (final n in nodes.values) {
      final d = n.def;
      if (d == null || n.existing) continue;
      if (d.produces.isEmpty && d.accepts.isEmpty) continue;
      PNode? best;
      double bd = double.infinity;
      for (final s in stations) {
        final dist = (s.pos - n.pos).distance;
        if (dist <= (s.def?.radiusKm ?? 25) && dist < bd) {
          bd = dist;
          best = s;
        }
      }
      if (best != null) {
        servedBy[n.id] = best.id;
        catchment[best.id]!.add(n.id);
      }
    }
  }

  Rail? railBetween(String a, String b) {
    for (final r in rails.values) {
      if ((r.a == a && r.b == b) || (r.a == b && r.b == a)) return r;
    }
    return null;
  }

  List<String> findRailPath(String from, String to) {
    final dist = <String, double>{from: 0};
    final prev = <String, String>{};
    final open = <String>{from};
    final done = <String>{};
    while (open.isNotEmpty) {
      String u = open.first;
      for (final o in open) {
        if (dist[o]! < dist[u]!) u = o;
      }
      open.remove(u);
      done.add(u);
      if (u == to) break;
      for (final r in rails.values) {
        if (r.a != u && r.b != u) continue;
        final v = r.other(u);
        if (done.contains(v)) continue;
        final nd = dist[u]! + r.lenKm;
        if (nd < (dist[v] ?? double.infinity)) {
          dist[v] = nd;
          prev[v] = u;
          open.add(v);
        }
      }
    }
    if (!dist.containsKey(to)) return [];
    final path = <String>[to];
    while (path.last != from) {
      path.add(prev[path.last]!);
    }
    return path.reversed.toList();
  }

  void _moveTrains(double h) {
    final speed = cfg.trainSpeedKmh;
    for (final t in trains) {
      if (t.path.length < 2) {
        t.path = findRailPath(t.from, t.to);
        t.seg = 0;
        t.posKm = 0;
        if (t.path.length < 2) {
          t.status = 'Нет пути';
          continue;
        }
      }
      if (t.dwell > 0) {
        t.dwell -= h;
        t.status = 'Погрузка/разгрузка';
        continue;
      }
      double move = speed * h;
      int guard = 0;
      while (move > 0 && guard++ < 50) {
        final r = railBetween(t.path[t.seg], t.path[t.seg + 1]);
        if (r == null) {
          t.path = [];
          t.status = 'Путь разобран';
          break;
        }
        final remain = r.lenKm - t.posKm;
        if (move < remain) {
          t.posKm += move;
          move = 0;
          t.status = t.amount > 0 ? 'Везёт ${cfg.resName(t.cargo)}' : 'Едет порожняком';
        } else {
          move -= remain;
          t.seg++;
          t.posKm = 0;
          if (t.seg >= t.path.length - 1) {
            final here = t.path.last, there = t.path.first;
            _atTerminal(t, here, there);
            t.path = t.path.reversed.toList();
            t.seg = 0;
            t.dwell = 1;
            break;
          }
        }
      }
    }
  }

  void _atTerminal(Train t, String here, String there) {
    final hereB = [for (final id in catchment[here] ?? const <String>[]) nodes[id]].whereType<PNode>().toList();
    final thereB = [for (final id in catchment[there] ?? const <String>[]) nodes[id]].whereType<PNode>().toList();
    // разгрузка
    if (t.amount > 0.5) {
      for (final b in hereB) {
        if (!b.def!.accepts.contains(t.cargo)) continue;
        final room = b.def!.store - (b.stock[t.cargo] ?? 0);
        if (room <= 0) continue;
        final give = math.min(room, t.amount);
        b.stock[t.cargo] = (b.stock[t.cargo] ?? 0) + give;
        t.amount -= give;
        if (t.amount <= 0.5) break;
      }
      if (t.amount <= 0.5) {
        t.amount = 0;
        t.cargo = '';
      }
    }
    // погрузка: что нужно на том конце и есть здесь
    if (t.amount <= 0.5) {
      final need = <String>{};
      for (final b in thereB) {
        for (final r in b.def!.accepts) {
          if ((b.stock[r] ?? 0) < b.def!.store * 0.95) need.add(r);
        }
      }
      String bestRes = '';
      double bestAmt = 0;
      for (final r in need) {
        double sum = 0;
        for (final b in hereB) {
          if (b.def!.produces.containsKey(r)) sum += b.stock[r] ?? 0;
        }
        if (sum > bestAmt) {
          bestAmt = sum;
          bestRes = r;
        }
      }
      if (bestRes.isNotEmpty) {
        double take = cfg.trainCapacityT;
        for (final b in hereB) {
          if (!b.def!.produces.containsKey(bestRes)) continue;
          final have = b.stock[bestRes] ?? 0;
          final g = math.min(have, take);
          b.stock[bestRes] = have - g;
          take -= g;
          if (take <= 0) break;
        }
        t.cargo = bestRes;
        t.amount = cfg.trainCapacityT - take;
      }
    }
  }

  Offset? trainPos(Train t) {
    if (t.path.length < 2) {
      final n = nodes[t.from];
      return n?.pos;
    }
    final a = nodes[t.path[t.seg]], b = nodes[t.path[t.seg + 1]];
    if (a == null || b == null) return null;
    final r = railBetween(a.id, b.id);
    final f = r == null || r.lenKm <= 0 ? 0.0 : (t.posKm / r.lenKm).clamp(0.0, 1.0);
    return Offset.lerp(a.pos, b.pos, f);
  }

  // ------------------------------------------------------------ стройка
  String? canPlace(BuildingDef def, Offset p) {
    if (!map.insideCountry(p)) return 'Строить можно только в Украине';
    for (final n in nodes.values) {
      if (n.isJunction) continue;
      if ((n.pos - p).distance < 3) return 'Слишком близко к «${n.name}»';
    }
    if (def.requires == 'river') {
      if (map.distToRiver(p) > 5) return '${def.name} можно ставить только на реке';
    } else if (def.requires.startsWith('deposit:')) {
      final res = def.requires.substring(8);
      final ok = cfg.deposits.any((d) => d.res == res && (d.pos - p).distance <= d.rKm);
      if (!ok) return 'Здесь нет месторождения: ${cfg.resName(res)}';
    }
    return null;
  }

  String? placeBuilding(BuildingDef def, Offset p) {
    final err = canPlace(def, p);
    if (err != null) return err;
    final id = newId('b');
    final count = nodes.values.where((n) => n.def?.id == def.id && !n.existing).length + 1;
    final n = PNode(id: id, kind: NodeKind.building, name: '${def.name} №$count', pos: p, kv: {...def.kv}, def: def);
    if (def.kind == 'storage') n.storedMwh = def.storeMwh * 0.5;
    nodes[id] = n;
    if (def.loadMw > 0) _autoFeeder(n);
    _updateCatchment();
    return null;
  }

  /// Здания-потребители сами подключаются к ближайшему городу или подстанции
  /// (местная сеть 35/10 кВ).
  void _autoFeeder(PNode n) {
    PNode? best;
    double bd = cfg.autoFeederKm;
    for (final o in nodes.values) {
      if (o.id == n.id || o.isJunction || o.isStation) continue;
      if (!(o.isCity || o.isSub)) continue;
      if (!(o.kv.contains(110) || o.kv.contains(35))) continue;
      final d = (o.pos - n.pos).distance;
      if (d < bd) {
        bd = d;
        best = o;
      }
    }
    if (best == null) {
      n.status = 'Нет сети рядом — протяни ЛЭП 110/35 кВ';
      return;
    }
    final kv = best.kv.contains(35) ? 35 : 110;
    final id = newId('f');
    lines[id] = PLine(id: id, a: n.id, b: best.id, kv: kv, pts: [n.pos, best.pos], lenKm: bd, virtual: true);
  }

  String? addLine(String aId, String bId, int kv) {
    final a = nodes[aId], b = nodes[bId];
    if (a == null || b == null || aId == bId) return 'Выбери два разных объекта';
    if (!a.kv.contains(kv)) return '«${a.name}» не работает с $kv кВ';
    if (!b.kv.contains(kv)) return '«${b.name}» не работает с $kv кВ';
    for (final l in lines.values) {
      if (!l.virtual && l.kv == kv && ((l.a == aId && l.b == bId) || (l.a == bId && l.b == aId))) {
        return 'Такая линия уже есть';
      }
    }
    final len = (a.pos - b.pos).distance * 1.08;
    final id = newId('l');
    lines[id] = PLine(id: id, a: aId, b: bId, kv: kv, pts: [a.pos, b.pos], lenKm: len);
    return null;
  }

  String? addRail(String aId, String bId) {
    final a = nodes[aId], b = nodes[bId];
    if (a == null || b == null || aId == bId) return 'Выбери две разные станции';
    if (!a.isStation || !b.isStation) return 'Пути прокладываются между ЖД-станциями';
    if (railBetween(aId, bId) != null) return 'Эти станции уже соединены';
    final id = newId('r');
    rails[id] = Rail(id, aId, bId, (a.pos - b.pos).distance * 1.1);
    for (final t in trains) {
      if (t.path.length < 2) t.path = [];
    }
    return null;
  }

  String? addTrain(String aId, String bId) {
    if (aId == bId) return 'Выбери две разные станции';
    final path = findRailPath(aId, bId);
    if (path.length < 2) return 'Между станциями нет пути — сначала проложи рельсы';
    final t = Train(newId('t'), aId, bId)..path = path;
    _updateCatchment();
    _atTerminal(t, aId, bId);
    trains.add(t);
    return null;
  }

  // ------------------------------------------------------------ грузовики
  String? addTruck(String aId, String bId) {
    final a = nodes[aId], b = nodes[bId];
    if (a == null || b == null || aId == bId) return 'Выбери два разных здания';
    final ad = a.def, bd = b.def;
    if (ad == null || ad.produces.isEmpty) return '«${a.name}» ничего не производит — начни с шахты, рудника или завода';
    if (bd == null || bd.accepts.isEmpty) return '«${b.name}» не принимает грузы';
    if (!ad.produces.keys.any(bd.accepts.contains)) {
      final what = ad.produces.keys.map(cfg.resName).join(', ');
      return '«${b.name}» не нужен груз «$what»';
    }
    final t = Truck(newId('k'), aId, bId);
    _routeTruck(t);
    trucks.add(t);
    return t.byRoad ? null : 'Дорог рядом нет — колонна поедет напрямик';
  }

  void _routeTruck(Truck t) {
    final a = nodes[t.from], b = nodes[t.to];
    if (a == null || b == null) return;
    final g = map.roads;
    if (!g.isEmpty) {
      final na = g.nearestNode(a.pos, 30), nb = g.nearestNode(b.pos, 30);
      if (na >= 0 && nb >= 0) {
        final r = g.route(na, nb);
        if (r != null) {
          t.setRoute([a.pos, ...r, b.pos]);
          return;
        }
      }
    }
    t.setRoute([a.pos, b.pos], road: false);
  }

  void _moveTrucks(double h) {
    final speed = cfg.truckSpeedKmh;
    for (final t in trucks) {
      final a = nodes[t.from], b = nodes[t.to];
      if (a == null || b == null) continue;
      if (t.route.isEmpty) _routeTruck(t);
      if (t.dwell > 0) {
        t.dwell -= h;
        continue;
      }
      if (!t.back) {
        if (t.pos <= 0 && t.amount < 1) {
          final r = a.def!.produces.keys.firstWhere(b.def!.accepts.contains, orElse: () => '');
          if (r.isNotEmpty) {
            final have = a.stock[r] ?? 0;
            final g = math.min(have, cfg.truckCapacityT);
            a.stock[r] = have - g;
            t.cargo = r;
            t.amount = g;
          }
          if (t.amount < 1) {
            t.status = 'Ждёт груз на «${a.name}»';
            t.dwell = 1;
            continue;
          }
        }
        t.pos += speed * h;
        t.status = 'Везёт ${cfg.resName(t.cargo)}, ${t.amount.toStringAsFixed(0)} т';
        if (t.pos >= t.total) {
          t.pos = t.total;
          final room = b.def!.store - (b.stock[t.cargo] ?? 0);
          final give = math.max(0.0, math.min(room, t.amount));
          b.stock[t.cargo] = (b.stock[t.cargo] ?? 0) + give;
          t.amount -= give;
          if (t.amount < 1) {
            t.amount = 0;
            t.back = true;
            t.dwell = 0.5;
          } else {
            t.status = 'Склад «${b.name}» полон';
            t.dwell = 1;
          }
        }
      } else {
        t.pos -= speed * h;
        t.status = 'Возвращается порожняком';
        if (t.pos <= 0) {
          t.pos = 0;
          t.back = false;
          t.dwell = 0.5;
        }
      }
    }
  }

  void removeTruck(String id) => trucks.removeWhere((t) => t.id == id);

  // ------------------------------------------------------------ советник
  List<Issue> issues() {
    final out = <Issue>[];
    final linesAt = <String, List<PLine>>{};
    for (final l in lines.values) {
      linesAt.putIfAbsent(l.a, () => []).add(l);
      linesAt.putIfAbsent(l.b, () => []).add(l);
    }
    for (final n in nodes.values) {
      final d = n.def;
      if (d == null || n.existing) continue;
      final ls = linesAt[n.id] ?? const <PLine>[];
      if (d.isGenerator) {
        if (ls.isEmpty) {
          out.add(Issue('«${n.name}» не подключена. Протяни ЛЭП ${d.kv.join(" или ")} кВ к подстанции с таким напряжением.',
              node: n.id, sev: 2));
        } else if (n.status.isNotEmpty) {
          out.add(Issue('«${n.name}»: ${n.status}. Привези уголь грузовиком (Транспорт → Грузовик) или поездом.',
              node: n.id, sev: 2));
        } else if (n.genAvail > 5 && n.genMw < n.genAvail * 0.5 && d.kind == 'plant') {
          out.add(Issue('«${n.name}» выдаёт ${n.genMw.toStringAsFixed(0)} из ${n.genAvail.toStringAsFixed(0)} МВт: '
              'мощность некуда отдать. Подключи города или усиль линии.', node: n.id, sev: 1));
        }
      } else if (d.kind == 'sub') {
        final kvs = {for (final l in ls) l.kv};
        if (ls.isEmpty) {
          out.add(Issue('«${n.name}» ни к чему не подключена.', node: n.id, sev: 1));
        } else if (kvs.length == 1) {
          final missing = d.kv.where((k) => !kvs.contains(k)).join('/');
          out.add(Issue('«${n.name}» подключена только на ${kvs.first} кВ. Нужна вторая сторона: $missing кВ.',
              node: n.id, sev: 1));
        }
      } else if (n.status.isNotEmpty) {
        out.add(Issue('«${n.name}»: ${n.status}.', node: n.id, sev: 1));
      }
    }
    for (final l in lines.values) {
      if (l.virtual) continue;
      final cap = cfg.volt(l.kv).capMw * l.circuits;
      if (l.flow > cap * 0.97) {
        out.add(Issue('ЛЭП ${l.kv} кВ перегружена (${l.flow.toStringAsFixed(0)} МВт). Проложи вторую линию или выше напряжение.',
            line: l.id, sev: 1));
      }
    }
    for (final t in trains) {
      if (t.status == 'Нет пути' || t.status == 'Путь разобран') {
        out.add(Issue('Поезд ${nodes[t.from]?.name ?? ""} → ${nodes[t.to]?.name ?? ""}: ${t.status}.', node: t.from, sev: 1));
      }
    }
    final dark = nodes.values.where((n) => n.isCity && n.demandMw > 0 && n.supplyFrac < 0.99).toList()
      ..sort((a, b) => b.pop.compareTo(a.pop));
    if (dark.isNotEmpty) {
      final top = dark.first;
      out.add(Issue(
          'Без света или с отключениями: ${dark.length} городов. Крупнейший — ${top.name} '
          '(${(top.supplyFrac * 100).toStringAsFixed(0)}%). Города подключаются ЛЭП 110 или 35 кВ.',
          node: top.id,
          sev: 0));
    }
    out.sort((a, b) => b.sev.compareTo(a.sev));
    return out;
  }

  void demolishNode(String id) {
    final n = nodes[id];
    if (n == null || n.isCity) return;
    nodes.remove(id);
    if (n.existing) removedExisting.add(id);
    lines.removeWhere((k, l) {
      final hit = l.a == id || l.b == id;
      if (hit && l.existing) removedExisting.add(k);
      return hit;
    });
    rails.removeWhere((k, r) => r.a == id || r.b == id);
    trains.removeWhere((t) => t.from == id || t.to == id);
    trucks.removeWhere((t) => t.from == id || t.to == id);
    for (final t in trains) {
      if (t.path.contains(id)) t.path = [];
    }
    _updateCatchment();
  }

  void demolishLine(String id) {
    final l = lines.remove(id);
    if (l != null && l.existing) removedExisting.add(id);
  }

  void demolishRail(String id) {
    final r = rails.remove(id);
    if (r == null) return;
    for (final t in trains) {
      if (t.path.contains(r.a) && t.path.contains(r.b)) t.path = [];
    }
  }

  void removeTrain(String id) => trains.removeWhere((t) => t.id == id);

  // ------------------------------------------------------------ сохранение
  Map<String, dynamic> toJson() => {
        'v': 1,
        'ready': readyMode,
        'hours': hours,
        'wind': wind,
        'seq': _seq,
        'removed': removedExisting.toList(),
        'produced': produced,
        'nodes': [
          for (final n in nodes.values)
            if (!n.existing && !n.isCity)
              {
                'id': n.id,
                'def': n.def?.id,
                'name': n.name,
                'x': n.pos.dx,
                'y': n.pos.dy,
                'stock': n.stock,
                'mwh': n.storedMwh,
              }
        ],
        'lines': [
          for (final l in lines.values)
            if (!l.existing) {'id': l.id, 'a': l.a, 'b': l.b, 'kv': l.kv, 'v': l.virtual, 'len': l.lenKm}
        ],
        'rails': [
          for (final r in rails.values) {'id': r.id, 'a': r.a, 'b': r.b, 'len': r.lenKm}
        ],
        'trains': [
          for (final t in trains)
            {'id': t.id, 'from': t.from, 'to': t.to, 'cargo': t.cargo, 'amount': t.amount}
        ],
        'trucks': [
          for (final t in trucks)
            {'id': t.id, 'from': t.from, 'to': t.to, 'cargo': t.cargo, 'amount': t.amount}
        ],
        'tut': tutStep,
      };

  static World fromJson(GameConfig cfg, MapData map, Map<String, dynamic> j) {
    final ready = (j['ready'] ?? false) as bool;
    final w = World(cfg, map, readyMode: false);
    // готовую сеть грузим уже с учётом удалённых объектов
    final rw = ready ? (World._empty(cfg, map, ready: true)) : w;
    if (ready) {
      rw.removedExisting.addAll([for (final x in (j['removed'] as List? ?? const [])) x as String]);
      rw.nodes.addAll(w.nodes);
      rw._loadExisting();
      for (final id in rw.removedExisting) {
        rw.lines.remove(id);
      }
    }
    final World r = rw;
    r.hours = ((j['hours'] ?? 6) as num).toDouble();
    r.wind = ((j['wind'] ?? 0.5) as num).toDouble();
    r._seq = ((j['seq'] ?? 0) as num).toInt();
    (j['produced'] as Map? ?? const {}).forEach((k, v) => r.produced[k as String] = (v as num).toDouble());
    for (final n in (j['nodes'] as List? ?? const [])) {
      final def = cfg.buildings[n['def']];
      if (def == null) continue;
      final p = PNode(
          id: n['id'] as String,
          kind: NodeKind.building,
          name: (n['name'] ?? def.name) as String,
          pos: Offset((n['x'] as num).toDouble(), (n['y'] as num).toDouble()),
          kv: {...def.kv},
          def: def);
      (n['stock'] as Map? ?? const {}).forEach((k, v) => p.stock[k as String] = (v as num).toDouble());
      p.storedMwh = ((n['mwh'] ?? 0) as num).toDouble();
      r.nodes[p.id] = p;
    }
    for (final l in (j['lines'] as List? ?? const [])) {
      final a = r.nodes[l['a']], b = r.nodes[l['b']];
      if (a == null || b == null) continue;
      r.lines[l['id'] as String] = PLine(
          id: l['id'] as String,
          a: a.id,
          b: b.id,
          kv: (l['kv'] as num).toInt(),
          pts: [a.pos, b.pos],
          lenKm: (l['len'] as num).toDouble(),
          virtual: (l['v'] ?? false) as bool);
    }
    for (final x in (j['rails'] as List? ?? const [])) {
      if (!r.nodes.containsKey(x['a']) || !r.nodes.containsKey(x['b'])) continue;
      r.rails[x['id'] as String] = Rail(x['id'] as String, x['a'] as String, x['b'] as String, (x['len'] as num).toDouble());
    }
    for (final x in (j['trains'] as List? ?? const [])) {
      final t = Train(x['id'] as String, x['from'] as String, x['to'] as String)
        ..cargo = (x['cargo'] ?? '') as String
        ..amount = ((x['amount'] ?? 0) as num).toDouble();
      r.trains.add(t);
    }
    for (final x in (j['trucks'] as List? ?? const [])) {
      final t = Truck(x['id'] as String, x['from'] as String, x['to'] as String)
        ..cargo = (x['cargo'] ?? '') as String
        ..amount = ((x['amount'] ?? 0) as num).toDouble();
      if (!r.nodes.containsKey(t.from) || !r.nodes.containsKey(t.to)) continue;
      r._routeTruck(t);
      r.trucks.add(t);
    }
    r.tutStep = ((j['tut'] ?? 0) as num).toInt();
    r._updateCatchment();
    r.step(0.01);
    return r;
  }

  World._empty(this.cfg, this.map, {required bool ready}) : readyMode = ready;
}

class Issue {
  final String text;
  final String? node, line;
  final int sev; // 2 — серьёзно, 1 — важно, 0 — инфо
  Issue(this.text, {this.node, this.line, this.sev = 1});
}

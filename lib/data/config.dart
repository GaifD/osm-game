import 'dart:convert';
import 'dart:ui';

import 'package:flutter/services.dart';

import 'geo.dart';

Color parseColor(String s) {
  var h = s.replaceAll('#', '');
  if (h.length == 6) h = 'FF$h';
  return Color(int.parse(h, radix: 16));
}

Map<String, double> _numMap(dynamic m) {
  if (m == null) return {};
  return {for (final e in (m as Map).entries) e.key as String: (e.value as num).toDouble()};
}

class VoltageDef {
  final int kv;
  final double capMw, lossPer100km, width;
  final Color color;
  VoltageDef(this.kv, this.capMw, this.lossPer100km, this.color, this.width);
  String get label => '$kv кВ';
}

class ResourceDef {
  final String id, name, unit;
  final Color color;
  ResourceDef(this.id, this.name, this.unit, this.color);
}

class DepositDef {
  final String res, name;
  final Offset pos;
  final double rKm;
  DepositDef(this.res, this.name, this.pos, this.rKm);
}

class CategoryDef {
  final String id, name, icon;
  CategoryDef(this.id, this.name, this.icon);
}

/// Описание типа здания. Поведение задаётся полем [kind]:
/// plant, storage, sub, producer, factory, station.
class BuildingDef {
  final String id, name, icon, cat, kind, desc;
  final String gen; // nuclear, thermal, hydro, solar, wind, storage
  final double mw; // мощность станции
  final double capMw; // пропускная способность подстанции
  final List<int> kv;
  final Map<String, double> fuel; // ресурс -> т на МВт·ч
  final Map<String, double> produces; // ресурс -> т/ч
  final Map<String, double> inputs; // ресурс -> т на 1 т продукции
  final double loadMw;
  final double store; // склад, т на ресурс
  final String requires; // '', 'river', 'deposit:<res>'
  final double radiusKm;
  final double storeMwh, eff;

  BuildingDef({
    required this.id,
    required this.name,
    required this.icon,
    required this.cat,
    required this.kind,
    this.desc = '',
    this.gen = '',
    this.mw = 0,
    this.capMw = 0,
    this.kv = const [],
    this.fuel = const {},
    this.produces = const {},
    this.inputs = const {},
    this.loadMw = 0,
    this.store = 0,
    this.requires = '',
    this.radiusKm = 0,
    this.storeMwh = 0,
    this.eff = 1,
  });

  factory BuildingDef.fromJson(Map<String, dynamic> j) => BuildingDef(
        id: j['id'] as String,
        name: j['name'] as String,
        icon: (j['icon'] ?? '■') as String,
        cat: (j['cat'] ?? '') as String,
        kind: j['kind'] as String,
        desc: (j['desc'] ?? '') as String,
        gen: (j['gen'] ?? '') as String,
        mw: ((j['mw'] ?? 0) as num).toDouble(),
        capMw: ((j['capMw'] ?? 0) as num).toDouble(),
        kv: [for (final k in (j['kv'] as List? ?? const [])) (k as num).toInt()],
        fuel: _numMap(j['fuel']),
        produces: _numMap(j['produces']),
        inputs: _numMap(j['inputs']),
        loadMw: ((j['loadMw'] ?? 0) as num).toDouble(),
        store: ((j['store'] ?? 0) as num).toDouble(),
        requires: (j['requires'] ?? '') as String,
        radiusKm: ((j['radiusKm'] ?? 0) as num).toDouble(),
        storeMwh: ((j['storeMwh'] ?? 0) as num).toDouble(),
        eff: ((j['eff'] ?? 1) as num).toDouble(),
      );

  bool get isGenerator => kind == 'plant' || kind == 'storage';

  /// Какие ресурсы здание принимает (сырьё или топливо).
  Iterable<String> get accepts => {...inputs.keys, ...fuel.keys};
}

class GameConfig {
  final double cityKwPerPerson, trainCapacityT, trainSpeedKmh, autoFeederKm;
  final List<VoltageDef> voltages;
  final List<ResourceDef> resources;
  final List<DepositDef> deposits;
  final List<CategoryDef> categories;
  final Map<String, BuildingDef> buildings;

  GameConfig(this.cityKwPerPerson, this.trainCapacityT, this.trainSpeedKmh, this.autoFeederKm,
      this.voltages, this.resources, this.deposits, this.categories, this.buildings);

  VoltageDef volt(int kv) =>
      voltages.firstWhere((v) => v.kv == kv, orElse: () => voltages.last);

  ResourceDef? res(String id) {
    for (final r in resources) {
      if (r.id == id) return r;
    }
    return null;
  }

  String resName(String id) => res(id)?.name ?? id;

  /// Определения для существующих объектов из OSM.
  BuildingDef existingSubDef(List<int> kv) {
    final top = kv.isEmpty ? 110 : kv.reduce((a, b) => a > b ? a : b);
    final cap = switch (top) { 750 => 3000.0, 400 => 1200.0, 330 => 800.0, 220 => 400.0, _ => 100.0 };
    return BuildingDef(
        id: 'ps_osm', name: 'Подстанция', icon: '⚡', cat: 'grid', kind: 'sub', kv: kv, capMw: cap,
        desc: 'Существующая подстанция (данные OpenStreetMap).');
  }

  static Future<GameConfig> load() async {
    final j = jsonDecode(await rootBundle.loadString('assets/config/game.json')) as Map<String, dynamic>;
    final volts = [
      for (final v in j['voltages'] as List)
        VoltageDef((v['kv'] as num).toInt(), (v['capMw'] as num).toDouble(),
            (v['lossPer100km'] as num).toDouble(), parseColor(v['color'] as String), (v['width'] as num).toDouble())
    ]..sort((a, b) => b.kv.compareTo(a.kv));
    final res = [
      for (final r in j['resources'] as List)
        ResourceDef(r['id'] as String, r['name'] as String, r['unit'] as String, parseColor(r['color'] as String))
    ];
    final deps = [
      for (final d in j['deposits'] as List)
        DepositDef(d['res'] as String, d['name'] as String,
            proj((d['lon'] as num).toDouble(), (d['lat'] as num).toDouble()), (d['rKm'] as num).toDouble())
    ];
    final cats = [
      for (final c in j['categories'] as List) CategoryDef(c['id'] as String, c['name'] as String, c['icon'] as String)
    ];
    final b = <String, BuildingDef>{};
    for (final x in j['buildings'] as List) {
      final d = BuildingDef.fromJson(x as Map<String, dynamic>);
      b[d.id] = d;
    }
    return GameConfig(
      ((j['cityKwPerPerson'] ?? 0.55) as num).toDouble(),
      ((j['trainCapacityT'] ?? 3000) as num).toDouble(),
      ((j['trainSpeedKmh'] ?? 60) as num).toDouble(),
      ((j['autoFeederKm'] ?? 30) as num).toDouble(),
      volts, res, deps, cats, b,
    );
  }
}

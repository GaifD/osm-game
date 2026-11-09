import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/services.dart';

/// Простая проекция: мировые координаты в километрах от центра Украины.
/// x — на восток, y — на юг (как на экране).
const double kLat0 = 48.5;
const double kLon0 = 31.2;
final double _kx = 111.32 * math.cos(kLat0 * math.pi / 180);
const double _ky = 110.57;

Offset proj(double lon, double lat) => Offset((lon - kLon0) * _kx, -(lat - kLat0) * _ky);
double latOf(Offset p) => -p.dy / _ky + kLat0;
double lonOf(Offset p) => p.dx / _kx + kLon0;

List<Offset> flatToPts(List<dynamic> f) {
  final out = <Offset>[];
  for (int i = 0; i + 1 < f.length; i += 2) {
    out.add(proj((f[i] as num).toDouble(), (f[i + 1] as num).toDouble()));
  }
  return out;
}

double distToSegment(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final l2 = ab.dx * ab.dx + ab.dy * ab.dy;
  if (l2 == 0) return (p - a).distance;
  double t = ((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / l2;
  t = t.clamp(0.0, 1.0);
  return (p - (a + ab * t)).distance;
}

double distToPolyline(Offset p, List<Offset> pts) {
  double best = double.infinity;
  for (int i = 0; i + 1 < pts.length; i++) {
    final d = distToSegment(p, pts[i], pts[i + 1]);
    if (d < best) best = d;
  }
  return best;
}

bool pointInRing(Offset p, List<Offset> ring) {
  bool inside = false;
  for (int i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final a = ring[i], b = ring[j];
    if (((a.dy > p.dy) != (b.dy > p.dy)) &&
        (p.dx < (b.dx - a.dx) * (p.dy - a.dy) / (b.dy - a.dy) + a.dx)) {
      inside = !inside;
    }
  }
  return inside;
}

class Oblast {
  final String name;
  final List<List<Offset>> rings;
  final Path path;
  final Rect bounds;
  Oblast(this.name, this.rings)
      : path = _makePath(rings),
        bounds = _bounds(rings);

  static Path _makePath(List<List<Offset>> rings) {
    final p = Path()..fillType = PathFillType.evenOdd;
    for (final r in rings) {
      if (r.isEmpty) continue;
      p.addPolygon(r, true);
    }
    return p;
  }

  static Rect _bounds(List<List<Offset>> rings) {
    double l = 1e9, t = 1e9, r = -1e9, b = -1e9;
    for (final ring in rings) {
      for (final o in ring) {
        l = math.min(l, o.dx);
        t = math.min(t, o.dy);
        r = math.max(r, o.dx);
        b = math.max(b, o.dy);
      }
    }
    return Rect.fromLTRB(l, t, r, b);
  }

  bool contains(Offset p) {
    if (!bounds.contains(p)) return false;
    for (final r in rings) {
      if (pointInRing(p, r)) return true;
    }
    return false;
  }
}

class River {
  final String name;
  final List<Offset> pts;
  final Rect bounds;
  River(this.name, this.pts) : bounds = _b(pts);
  static Rect _b(List<Offset> pts) {
    double l = 1e9, t = 1e9, r = -1e9, b = -1e9;
    for (final o in pts) {
      l = math.min(l, o.dx);
      t = math.min(t, o.dy);
      r = math.max(r, o.dx);
      b = math.max(b, o.dy);
    }
    return Rect.fromLTRB(l, t, r, b);
  }
}

class CityData {
  final String name;
  final int pop;
  final Offset pos;
  CityData(this.name, this.pop, this.pos);
}

class GridNodeData {
  final String id, type, name;
  final Offset pos;
  final List<int> kv;
  final String plantType;
  final double mw;
  GridNodeData(this.id, this.type, this.name, this.pos, this.kv, this.plantType, this.mw);
}

class GridEdgeData {
  final String a, b;
  final int kv, circuits;
  final bool virtual;
  final double lenKm;
  final List<Offset> pts;
  GridEdgeData(this.a, this.b, this.kv, this.circuits, this.virtual, this.lenKm, this.pts);
}

/// Все статичные данные карты (из assets/data).
class MapData {
  final List<Oblast> oblasts;
  final List<River> rivers;
  final List<CityData> cities;
  final List<GridNodeData> gridNodes;
  final List<GridEdgeData> gridEdges;
  final Rect bounds;

  MapData(this.oblasts, this.rivers, this.cities, this.gridNodes, this.gridEdges)
      : bounds = oblasts.isEmpty
            ? const Rect.fromLTRB(-700, -450, 700, 450)
            : oblasts.map((o) => o.bounds).reduce((a, b) => a.expandToInclude(b));

  bool insideCountry(Offset p) {
    if (oblasts.isEmpty) return true;
    for (final o in oblasts) {
      if (o.contains(p)) return true;
    }
    return false;
  }

  double distToRiver(Offset p) {
    double best = double.infinity;
    for (final r in rivers) {
      if (!r.bounds.inflate(10).contains(p)) continue;
      final d = distToPolyline(p, r.pts);
      if (d < best) best = d;
    }
    return best;
  }

  static Future<dynamic> _json(String name) async =>
      jsonDecode(await rootBundle.loadString('assets/data/$name'));

  static Future<MapData> load() async {
    final obl = <Oblast>[];
    for (final o in (await _json('oblasts.json')) as List) {
      final rings = <List<Offset>>[];
      for (final r in (o['rings'] as List)) {
        rings.add(flatToPts(r as List));
      }
      obl.add(Oblast((o['n'] ?? '') as String, rings));
    }
    final riv = <River>[];
    for (final r in (await _json('rivers.json')) as List) {
      riv.add(River((r['n'] ?? '') as String, flatToPts(r['pts'] as List)));
    }
    final cities = <CityData>[];
    for (final c in (await _json('cities.json')) as List) {
      cities.add(CityData(c['n'] as String, (c['pop'] as num).toInt(),
          proj((c['lon'] as num).toDouble(), (c['lat'] as num).toDouble())));
    }
    final grid = await _json('grid.json') as Map<String, dynamic>;
    final gn = <GridNodeData>[];
    for (final n in (grid['nodes'] as List? ?? const [])) {
      gn.add(GridNodeData(
        n['id'] as String,
        n['t'] as String,
        (n['n'] ?? '') as String,
        proj((n['lon'] as num).toDouble(), (n['lat'] as num).toDouble()),
        [for (final k in (n['kv'] as List? ?? const [])) (k as num).toInt()],
        (n['pt'] ?? '') as String,
        ((n['mw'] ?? 0) as num).toDouble(),
      ));
    }
    final ge = <GridEdgeData>[];
    for (final e in (grid['edges'] as List? ?? const [])) {
      ge.add(GridEdgeData(
        e['a'] as String,
        e['b'] as String,
        (e['kv'] as num).toInt(),
        ((e['c'] ?? 1) as num).toInt(),
        ((e['v'] ?? 0) as num) == 1,
        ((e['len'] ?? 0) as num).toDouble(),
        flatToPts(e['pts'] as List),
      ));
    }
    return MapData(obl, riv, cities, gn, ge);
  }
}

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../sim/entities.dart';
import '../sim/world.dart';
import '../theme.dart';

class Camera {
  Offset center = Offset.zero; // мировые км
  double scale = 0.5; // пикселей на км
  Size size = Size.zero;

  Offset toScreen(Offset w) => (w - center) * scale + Offset(size.width / 2, size.height / 2);
  Offset toWorld(Offset s) => (s - Offset(size.width / 2, size.height / 2)) / scale + center;
  Rect get worldView => Rect.fromCenter(center: center, width: size.width / scale, height: size.height / scale);
}

class Layers {
  bool existingGrid = true;
  bool deposits = true;
  bool labels = true;
  bool feeders = false;
  bool roads = true;
  bool osmRail = true;
  bool kvLabels = true;
}

class MapPainter extends CustomPainter {
  final World world;
  final Camera cam;
  final Layers layers;
  final String? selectedId; // узел/линия/путь
  final String? pendingId; // первая точка при прокладке
  final double pulse;
  final int? highlightKv; // подсветка совместимых объектов при прокладке ЛЭП

  MapPainter({
    this.highlightKv,
    required this.world,
    required this.cam,
    required this.layers,
    required this.selectedId,
    required this.pendingId,
    required this.pulse,
    required Listenable repaint,
  }) : super(repaint: repaint);

  static final Map<String, TextPainter> _tp = {};

  TextPainter _text(String s, double size, Color c, {FontWeight w = FontWeight.w500}) {
    final key = '$s|$size|${c.value}|${w.index}';
    var tp = _tp[key];
    if (tp == null) {
      if (_tp.length > 3000) _tp.clear();
      tp = TextPainter(
        text: TextSpan(
          text: s,
          style: TextStyle(
            fontSize: size,
            color: c,
            fontWeight: w,
            shadows: const [Shadow(color: Colors.black, blurRadius: 3)],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      _tp[key] = tp;
    }
    return tp;
  }

  @override
  void paint(Canvas canvas, Size size) {
    cam.size = size;
    final view = cam.worldView.inflate(50);
    final s = cam.scale;
    canvas.drawRect(Offset.zero & size, Paint()..color = AppColors.bg);

    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(s);
    canvas.translate(-cam.center.dx, -cam.center.dy);

    // --- земля
    final land = Paint()..color = AppColors.land;
    final border = Paint()
      ..color = AppColors.border
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0 / s;
    for (final o in world.map.oblasts) {
      if (!o.bounds.overlaps(view)) continue;
      canvas.drawPath(o.path, land);
      canvas.drawPath(o.path, border);
    }

    // --- месторождения
    if (layers.deposits) {
      for (final d in world.cfg.deposits) {
        final c = world.cfg.res(d.res)?.color ?? Colors.grey;
        canvas.drawCircle(d.pos, d.rKm, Paint()..color = c.withOpacity(0.10));
        canvas.drawCircle(
            d.pos,
            d.rKm,
            Paint()
              ..color = c.withOpacity(0.45)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.2 / s);
      }
    }

    // --- реки
    final rp = Paint()
      ..color = AppColors.river
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.4 / s, 0.6)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final r in world.map.rivers) {
      if (!r.bounds.overlaps(view)) continue;
      final p = Path()..addPolygon(r.pts, false);
      canvas.drawPath(p, rp);
    }

    // --- дороги OSM
    if (layers.roads) {
      final g = world.map.roads;
      const colors = [Color(0xFFE0A040), Color(0xFFB8A070), Color(0xFF6E7781)];
      const widths = [2.2, 1.7, 1.1];
      for (final cls in [2, 1, 0]) {
        if (cls == 2 && s < 0.6) continue;
        final ch = g.chunks[cls];
        if (ch == null) continue;
        final p = Paint()
          ..color = colors[cls].withOpacity(cls == 2 ? 0.55 : 0.75)
          ..style = PaintingStyle.stroke
          ..strokeWidth = widths[cls] / s
          ..strokeJoin = StrokeJoin.round;
        ch.forEach((key, path) {
          final r = g.chunkRect[key];
          if (r != null && r.overlaps(view)) canvas.drawPath(path, p);
        });
      }
    }

    // --- железные дороги OSM
    if (layers.osmRail) {
      final g = world.map.railways;
      for (final cls in [1, 0]) {
        final ch = g.chunks[cls];
        if (ch == null) continue;
        final p = Paint()
          ..color = (cls == 0 ? const Color(0xFF9C7FD0) : const Color(0xFF8D7B6A)).withOpacity(0.7)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3 / s
          ..strokeJoin = StrokeJoin.round;
        ch.forEach((key, path) {
          final r = g.chunkRect[key];
          if (r != null && r.overlaps(view)) canvas.drawPath(path, p);
        });
      }
    }

    // --- ЖД
    final railP = Paint()
      ..color = AppColors.rail
      ..strokeWidth = 3.0 / s
      ..strokeCap = StrokeCap.round;
    final railSel = Paint()
      ..color = AppColors.accent
      ..strokeWidth = 5.0 / s
      ..strokeCap = StrokeCap.round;
    for (final r in world.rails.values) {
      final a = world.nodes[r.a], b = world.nodes[r.b];
      if (a == null || b == null) continue;
      canvas.drawLine(a.pos, b.pos, r.id == selectedId ? railSel : railP);
      // шпалы
      final dir = b.pos - a.pos;
      final len = dir.distance;
      if (len > 0 && s > 0.8) {
        final n = Offset(-dir.dy, dir.dx) / len * (3.5 / s);
        final step = 10 / s;
        final tie = Paint()
          ..color = AppColors.rail.withOpacity(0.7)
          ..strokeWidth = 1.2 / s;
        for (double t = step; t < len; t += step) {
          final c = a.pos + dir * (t / len);
          canvas.drawLine(c - n, c + n, tie);
        }
      }
    }

    // --- ЛЭП
    final showFeeders = layers.feeders || s > 2.5;
    for (final l in world.lines.values) {
      if (l.existing && !layers.existingGrid) continue;
      if (l.virtual && !showFeeders && l.id != selectedId) continue;
      final v = world.cfg.volt(l.kv);
      final cap = l.virtual ? double.infinity : v.capMw * l.circuits;
      final load = cap.isInfinite ? 0.0 : (l.flow / cap);
      Color c = v.color;
      double op = l.virtual ? 0.35 : (0.45 + 0.55 * load.clamp(0.0, 1.0));
      if (load > 0.97) c = Color.lerp(v.color, AppColors.bad, 0.5 + 0.5 * pulse)!;
      final p = Paint()
        ..color = c.withOpacity(op)
        ..style = PaintingStyle.stroke
        ..strokeWidth = (l.virtual ? 1.0 : v.width) / s
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      if (l.id == selectedId) {
        p
          ..color = AppColors.accent
          ..strokeWidth = (v.width + 2) / s;
      }
      if (l.pts.length == 2) {
        canvas.drawLine(l.pts[0], l.pts[1], p);
      } else {
        canvas.drawPath(Path()..addPolygon(l.pts, false), p);
      }
    }
    canvas.restore();

    // ---------------- экранные элементы (фиксированный размер)
    final sv = cam.worldView.inflate(30);

    // подписи напряжения на линиях
    if (layers.kvLabels && s > 1.6) {
      int count = 0;
      for (final l in world.lines.values) {
        if (l.virtual || l.pts.length < 2) continue;
        if (l.existing && !layers.existingGrid) continue;
        final mid = l.pts[l.pts.length ~/ 2 - (l.pts.length.isEven ? 1 : 0)];
        final mid2 = l.pts[l.pts.length ~/ 2];
        final m = Offset.lerp(mid, mid2, 0.5)!;
        if (!sv.contains(m)) continue;
        if (++count > 120) break;
        final v = world.cfg.volt(l.kv);
        final tp = _text('${l.kv}', 9, Colors.black, w: FontWeight.w700);
        final p = cam.toScreen(m);
        final rr = RRect.fromRectAndRadius(
            Rect.fromCenter(center: p, width: tp.width + 6, height: tp.height + 2), const Radius.circular(4));
        canvas.drawRRect(rr, Paint()..color = v.color);
        tp.paint(canvas, p - Offset(tp.width / 2, tp.height / 2));
      }
    }

    // подсветка совместимых объектов при прокладке ЛЭП
    if (highlightKv != null) {
      final c = world.cfg.volt(highlightKv!).color;
      final ring = Paint()
        ..color = c.withOpacity(0.55 + 0.45 * pulse)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5;
      for (final n in world.nodes.values) {
        if (!n.kv.contains(highlightKv)) continue;
        if (n.existing && !layers.existingGrid) continue;
        if (!sv.contains(n.pos)) continue;
        if (n.isJunction && s < 1.5) continue;
        canvas.drawCircle(cam.toScreen(n.pos), n.isJunction ? 6 : 16, ring);
      }
    }

    // подстанции и опоры
    for (final n in world.nodes.values) {
      if (!sv.contains(n.pos)) continue;
      if (n.existing && !layers.existingGrid) continue;
      if (n.isJunction) continue;
      if (!n.isSub) continue;
      final p = cam.toScreen(n.pos);
      final top = n.kv.isEmpty ? 110 : n.kv.reduce(math.max);
      final c = world.cfg.volt(top).color;
      final r = n.existing ? (top >= 330 ? 4.0 : 3.0) : 6.0;
      canvas.drawRect(Rect.fromCenter(center: p, width: r * 2, height: r * 2), Paint()..color = AppColors.bg);
      canvas.drawRect(
          Rect.fromCenter(center: p, width: r * 2, height: r * 2),
          Paint()
            ..color = c
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6);
      if (!n.existing && s > 0.6) {
        final tp = _text('⚡', 9, Colors.white);
        tp.paint(canvas, p - Offset(tp.width / 2, tp.height / 2));
      }
      if (layers.kvLabels && (!n.existing || s > 1.2)) {
        final kvs = (n.kv.toList()..sort((a, b) => b - a)).join('/');
        final tp = _text(kvs, 9, c, w: FontWeight.w700);
        tp.paint(canvas, p + Offset(-tp.width / 2, r + 2));
      }
    }

    // города
    final cities = world.nodes.values.where((n) => n.isCity).toList()
      ..sort((a, b) => a.pop.compareTo(b.pop));
    final popMin = s < 0.35 ? 400000 : (s < 0.7 ? 150000 : (s < 1.5 ? 50000 : 0));
    for (final c in cities) {
      if (!sv.contains(c.pos)) continue;
      final p = cam.toScreen(c.pos);
      final r = (2.0 + math.sqrt(c.pop) / 160).clamp(3.0, 13.0) * (s < 0.4 ? 0.8 : 1.0);
      final f = c.supplyFrac;
      final col = c.demandMw <= 0
          ? AppColors.muted
          : f > 0.99
              ? AppColors.good
              : f > 0.5
                  ? AppColors.warn
                  : AppColors.bad;
      canvas.drawCircle(p, r + 1.5, Paint()..color = Colors.black.withOpacity(0.6));
      canvas.drawCircle(p, r, Paint()..color = col.withOpacity(f < 0.05 ? 0.35 : 0.9));
      if (layers.labels && c.pop >= popMin) {
        final tp = _text(c.name, c.pop > 500000 ? 13 : 11, AppColors.text,
            w: c.pop > 500000 ? FontWeight.w700 : FontWeight.w500);
        tp.paint(canvas, p + Offset(-tp.width / 2, r + 2));
      }
    }

    // здания (станции, шахты, заводы)
    for (final n in world.nodes.values) {
      if (n.isCity || n.isJunction || n.isSub) continue;
      if (!sv.contains(n.pos)) continue;
      if (n.existing && !layers.existingGrid) continue;
      final p = cam.toScreen(n.pos);
      final big = !n.existing || n.maxMw >= 500 || s > 1.2;
      final r = big ? 13.0 : 7.0;
      final ok = n.status.isEmpty;
      canvas.drawCircle(p, r, Paint()..color = AppColors.surface2);
      canvas.drawCircle(
          p,
          r,
          Paint()
            ..color = ok ? AppColors.accent : AppColors.warn
            ..style = PaintingStyle.stroke
            ..strokeWidth = n.existing ? 1.2 : 2);
      if (big) {
        final tp = _text(n.icon, 13, Colors.white);
        tp.paint(canvas, p - Offset(tp.width / 2, tp.height / 2));
      }
      double dy = r + 2;
      if (layers.labels && s > 1.0 && big) {
        final tp = _text(n.name, 10, AppColors.muted);
        tp.paint(canvas, p + Offset(-tp.width / 2, dy));
        dy += tp.height;
      }
      if (layers.kvLabels && n.def != null && n.def!.isGenerator && n.kv.isNotEmpty && (!n.existing || s > 1.2)) {
        final kvs = (n.kv.toList()..sort((a, b) => b - a));
        final tp = _text('${kvs.join("/")} кВ', 9, world.cfg.volt(kvs.first).color, w: FontWeight.w700);
        tp.paint(canvas, p + Offset(-tp.width / 2, dy));
      }
    }

    // поезда
    for (final t in world.trains) {
      final wp = world.trainPos(t);
      if (wp == null || !sv.contains(wp)) continue;
      final p = cam.toScreen(wp);
      final rr = RRect.fromRectAndRadius(Rect.fromCenter(center: p, width: 22, height: 14), const Radius.circular(4));
      canvas.drawRRect(rr, Paint()..color = t.amount > 0 ? (world.cfg.res(t.cargo)?.color ?? AppColors.accent) : AppColors.surface2);
      canvas.drawRRect(
          rr,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2);
      final tp = _text('🚂', 10, Colors.white);
      tp.paint(canvas, p - Offset(tp.width / 2, tp.height / 2));
    }

    // грузовики
    for (final t in world.trucks) {
      final wp = t.at();
      if (wp == null || !sv.contains(wp)) continue;
      final p = cam.toScreen(wp);
      final col = t.amount > 0 ? (world.cfg.res(t.cargo)?.color ?? AppColors.accent) : AppColors.surface2;
      canvas.drawCircle(p, 9, Paint()..color = col);
      canvas.drawCircle(
          p,
          9,
          Paint()
            ..color = t.id == selectedId ? AppColors.accent : Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = t.id == selectedId ? 2.5 : 1.2);
      final tp = _text('🚚', 10, Colors.white);
      tp.paint(canvas, p - Offset(tp.width / 2, tp.height / 2));
    }
    // маршрут выбранного грузовика
    for (final t in world.trucks) {
      if (t.id != selectedId || t.route.length < 2) continue;
      final path = Path()..addPolygon([for (final q in t.route) cam.toScreen(q)], false);
      canvas.drawPath(
          path,
          Paint()
            ..color = AppColors.accent.withOpacity(0.8)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3);
    }

    // выделение
    for (final id in [selectedId, pendingId]) {
      if (id == null) continue;
      final n = world.nodes[id];
      if (n == null) continue;
      final p = cam.toScreen(n.pos);
      canvas.drawCircle(
          p,
          18 + 3 * pulse,
          Paint()
            ..color = AppColors.accent
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5);
    }
  }

  @override
  bool shouldRepaint(covariant MapPainter old) => true;
}

/// Поиск объектов по касанию.
class HitTester {
  final World world;
  final Camera cam;
  final Layers layers;
  HitTester(this.world, this.cam, this.layers);

  PNode? node(Offset screen, {bool Function(PNode)? where, double radius = 28}) {
    PNode? best;
    double bd = radius;
    for (final n in world.nodes.values) {
      if (n.isJunction) continue;
      if (n.existing && !layers.existingGrid) continue;
      if (where != null && !where(n)) continue;
      final d = (cam.toScreen(n.pos) - screen).distance;
      if (d < bd) {
        bd = d;
        best = n;
      }
    }
    return best;
  }

  /// Ближайший узел-стык (опора) — для подключения к существующим линиям.
  PNode? junction(Offset screen, {double radius = 20}) {
    PNode? best;
    double bd = radius;
    for (final n in world.nodes.values) {
      if (!n.isJunction) continue;
      final d = (cam.toScreen(n.pos) - screen).distance;
      if (d < bd) {
        bd = d;
        best = n;
      }
    }
    return best;
  }

  PLine? line(Offset screen, {double radius = 12}) {
    final w = cam.toWorld(screen);
    final tol = radius / cam.scale;
    PLine? best;
    double bd = tol;
    for (final l in world.lines.values) {
      if (l.existing && !layers.existingGrid) continue;
      if (l.virtual && !(layers.feeders || cam.scale > 2.5)) continue;
      double d = double.infinity;
      for (int i = 0; i + 1 < l.pts.length; i++) {
        final a = l.pts[i], b = l.pts[i + 1];
        final ab = b - a;
        final l2 = ab.dx * ab.dx + ab.dy * ab.dy;
        double t = l2 == 0 ? 0 : (((w.dx - a.dx) * ab.dx + (w.dy - a.dy) * ab.dy) / l2).clamp(0.0, 1.0);
        final dd = (w - (a + ab * t)).distance;
        if (dd < d) d = dd;
      }
      if (d < bd) {
        bd = d;
        best = l;
      }
    }
    return best;
  }

  Rail? rail(Offset screen, {double radius = 12}) {
    final w = cam.toWorld(screen);
    final tol = radius / cam.scale;
    Rail? best;
    double bd = tol;
    for (final r in world.rails.values) {
      final a = world.nodes[r.a], b = world.nodes[r.b];
      if (a == null || b == null) continue;
      final ab = b.pos - a.pos;
      final l2 = ab.dx * ab.dx + ab.dy * ab.dy;
      final t = l2 == 0 ? 0.0 : (((w.dx - a.pos.dx) * ab.dx + (w.dy - a.pos.dy) * ab.dy) / l2).clamp(0.0, 1.0);
      final d = (w - (a.pos + ab * t)).distance;
      if (d < bd) {
        bd = d;
        best = r;
      }
    }
    return best;
  }

  Truck? truck(Offset screen, {double radius = 16}) {
    Truck? best;
    double bd = radius;
    for (final t in world.trucks) {
      final p = t.at();
      if (p == null) continue;
      final d = (cam.toScreen(p) - screen).distance;
      if (d < bd) {
        bd = d;
        best = t;
      }
    }
    return best;
  }

  Train? train(Offset screen, {double radius = 18}) {
    Train? best;
    double bd = radius;
    for (final t in world.trains) {
      final p = world.trainPos(t);
      if (p == null) continue;
      final d = (cam.toScreen(p) - screen).distance;
      if (d < bd) {
        bd = d;
        best = t;
      }
    }
    return best;
  }
}

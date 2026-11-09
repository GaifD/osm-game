import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../data/config.dart';
import '../main.dart';
import '../save.dart';
import '../sim/world.dart';
import '../theme.dart';
import 'info_panel.dart';
import 'map_painter.dart';

enum Tool { none, build, line, rail, train, demolish }

class GameScreen extends StatefulWidget {
  final GameData data;
  final World world;
  const GameScreen({super.key, required this.data, required this.world});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _ticker;
  final _frame = ValueNotifier<int>(0);
  final cam = Camera();
  final layers = Layers();
  bool _camInit = false;

  World get w => widget.world;
  GameConfig get cfg => widget.data.cfg;

  int _speed = 1; // 0 пауза, 1, 5, 20 игровых часов в секунду
  static const _speeds = [0, 1, 5, 20];
  Duration _last = Duration.zero;
  double _hudTimer = 0;
  double _saveTimer = 0;
  double _pulseT = 0;

  Tool _tool = Tool.none;
  BuildingDef? _buildDef;
  int _lineKv = 330;
  String? _openCat;
  String? _pending; // первая точка линии/пути/поезда
  String? _selected; // id выбранного объекта
  String _selKind = ''; // node, line, rail, train

  // жесты
  double _startScale = 1;
  Offset _lastFocal = Offset.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    w.step(0.01);
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) _save(silent: true);
  }

  void _onTick(Duration now) {
    final dt = _last == Duration.zero ? 0.016 : (now - _last).inMicroseconds / 1e6;
    _last = now;
    final rdt = math.min(dt, 0.1);
    w.tick(_speeds[_speed] * rdt, rdt);
    _pulseT += rdt;
    _frame.value++;
    _hudTimer += rdt;
    if (_hudTimer > 0.3) {
      _hudTimer = 0;
      if (mounted) setState(() {});
    }
    _saveTimer += rdt;
    if (_saveTimer > 60) {
      _saveTimer = 0;
      _save(silent: true);
    }
  }

  Future<void> _save({bool silent = false}) async {
    try {
      await SaveStore.save(w.toJson());
      if (!silent && mounted) _toast('Игра сохранена');
    } catch (e) {
      if (!silent && mounted) _toast('Не удалось сохранить: $e');
    }
  }

  void _toast(String s) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(s), duration: const Duration(seconds: 2)));
  }

  void _initCam(Size size) {
    if (_camInit || size.isEmpty) return;
    _camInit = true;
    cam.size = size;
    final b = w.map.bounds;
    cam.center = b.center;
    cam.scale = math.min(size.width / b.width, size.height / b.height) * 0.95;
  }

  // ------------------------------------------------------------ касания
  void _onTap(Offset pos) {
    final hit = HitTester(w, cam, layers);
    switch (_tool) {
      case Tool.none:
        final t = hit.train(pos);
        if (t != null) return _select(t.id, 'train');
        final n = hit.node(pos);
        if (n != null) return _select(n.id, 'node');
        final l = hit.line(pos);
        if (l != null) return _select(l.id, 'line');
        final r = hit.rail(pos);
        if (r != null) return _select(r.id, 'rail');
        _select(null, '');
      case Tool.build:
        final def = _buildDef;
        if (def == null) return;
        final err = w.placeBuilding(def, cam.toWorld(pos));
        if (err != null) {
          _toast(err);
        } else {
          w.step(0.01);
          setState(() {});
        }
      case Tool.line:
        final n = hit.node(pos) ?? hit.junction(pos);
        if (n == null) return _toast('Коснись подстанции, станции, города или опоры');
        if (!n.kv.contains(_lineKv)) {
          return _toast('«${n.name}» не работает с $_lineKv кВ (есть: ${n.kv.join("/")})');
        }
        if (_pending == null) {
          setState(() => _pending = n.id);
        } else {
          final err = w.addLine(_pending!, n.id, _lineKv);
          if (err != null) {
            _toast(err);
          } else {
            w.step(0.01);
          }
          setState(() => _pending = n.id); // можно тянуть дальше цепочкой
        }
      case Tool.rail:
      case Tool.train:
        final n = hit.node(pos, where: (x) => x.isStation);
        if (n == null) return _toast('Коснись ЖД-станции');
        if (_pending == null) {
          setState(() => _pending = n.id);
        } else {
          final err = _tool == Tool.rail ? w.addRail(_pending!, n.id) : w.addTrain(_pending!, n.id);
          if (err != null) _toast(err);
          setState(() => _pending = _tool == Tool.rail ? n.id : null);
          if (err == null && _tool == Tool.train) _toast('Поезд запущен');
        }
      case Tool.demolish:
        final t = hit.train(pos);
        if (t != null) {
          w.removeTrain(t.id);
          return setState(() {});
        }
        final n = hit.node(pos, where: (x) => !x.isCity);
        if (n != null) {
          w.demolishNode(n.id);
          w.step(0.01);
          return setState(() {});
        }
        final l = hit.line(pos);
        if (l != null) {
          w.demolishLine(l.id);
          w.step(0.01);
          return setState(() {});
        }
        final r = hit.rail(pos);
        if (r != null) {
          w.demolishRail(r.id);
          return setState(() {});
        }
    }
  }

  void _select(String? id, String kind) {
    setState(() {
      _selected = id;
      _selKind = kind;
    });
  }

  void _setTool(Tool t, {BuildingDef? def}) {
    setState(() {
      _tool = t;
      _buildDef = def;
      _pending = null;
      _selected = null;
      _openCat = null;
    });
  }

  String get _hint {
    switch (_tool) {
      case Tool.build:
        return 'Коснись карты: ${_buildDef?.name}';
      case Tool.line:
        return _pending == null
            ? 'ЛЭП $_lineKv кВ: выбери первый объект'
            : 'ЛЭП $_lineKv кВ: выбери следующий объект';
      case Tool.rail:
        return _pending == null ? 'Рельсы: выбери первую станцию' : 'Рельсы: выбери следующую станцию';
      case Tool.train:
        return _pending == null ? 'Поезд: станция отправления' : 'Поезд: станция назначения';
      case Tool.demolish:
        return 'Снос: коснись объекта, линии или поезда';
      case Tool.none:
        return '';
    }
  }

  // ------------------------------------------------------------ UI
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(builder: (context, box) {
        _initCam(Size(box.maxWidth, box.maxHeight));
        return Stack(children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => _onTap(d.localPosition),
              onScaleStart: (d) {
                _startScale = cam.scale;
                _lastFocal = d.localFocalPoint;
              },
              onScaleUpdate: (d) {
                final before = cam.toWorld(d.localFocalPoint);
                cam.scale = (_startScale * d.scale).clamp(0.15, 40.0);
                final after = cam.toWorld(d.localFocalPoint);
                cam.center += before - after;
                cam.center -= (d.localFocalPoint - _lastFocal) / cam.scale;
                _lastFocal = d.localFocalPoint;
                _frame.value++;
              },
              child: CustomPaint(
                painter: MapPainter(
                  world: w,
                  cam: cam,
                  layers: layers,
                  selectedId: _selected,
                  pendingId: _pending,
                  pulse: (math.sin(_pulseT * 6) + 1) / 2,
                  repaint: _frame,
                ),
                size: Size.infinite,
              ),
            ),
          ),
          Positioned(left: 0, right: 0, top: 0, child: SafeArea(child: _topBar())),
          Positioned(left: 0, right: 0, bottom: 0, child: SafeArea(child: _bottom())),
        ]);
      }),
    );
  }

  Widget _card({required Widget child, EdgeInsets padding = const EdgeInsets.all(10)}) => Container(
        margin: const EdgeInsets.fromLTRB(8, 6, 8, 0),
        padding: padding,
        decoration: BoxDecoration(
          color: AppColors.surface.withOpacity(0.94),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border.withOpacity(0.6)),
        ),
        child: child,
      );

  Widget _topBar() {
    final f = w.totalDemand <= 0 ? 1.0 : w.totalSupplied / w.totalDemand;
    final fc = f > 0.99 ? AppColors.good : (f > 0.8 ? AppColors.warn : AppColors.bad);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      _card(
        padding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
        child: Column(children: [
          Row(children: [
            IconButton(
              icon: const Icon(Icons.menu, color: AppColors.text),
              onPressed: _menu,
              visualDensity: VisualDensity.compact,
            ),
            Expanded(
              child: Text(w.clock, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
            ),
            for (int i = 0; i < _speeds.length; i++)
              _speedBtn(i, const ['⏸', '▶', '▶▶', '▶▶▶'][i]),
          ]),
          const SizedBox(height: 2),
          Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
            _stat('Генерация', fmtMw(w.totalGen), AppColors.accent),
            _stat('Спрос', fmtMw(w.totalDemand), AppColors.text),
            _stat('Обеспечено', '${(f * 100).toStringAsFixed(f > 0.999 ? 0 : 1)}%', fc),
            _stat('Потери', fmtMw(w.totalLoss), AppColors.muted),
          ]),
        ]),
      ),
      if (_tool != Tool.none)
        _card(
          padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
          child: Row(children: [
            Expanded(child: Text(_hint, style: const TextStyle(color: AppColors.accent, fontWeight: FontWeight.w600))),
            IconButton(
              icon: const Icon(Icons.close, color: AppColors.text),
              visualDensity: VisualDensity.compact,
              onPressed: () => _setTool(Tool.none),
            ),
          ]),
        ),
    ]);
  }

  Widget _speedBtn(int i, String label) {
    final on = _speed == i;
    return GestureDetector(
      onTap: () => setState(() => _speed = i),
      child: Container(
        margin: const EdgeInsets.only(left: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: on ? AppColors.accent : AppColors.surface2,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(label,
            style: TextStyle(fontSize: 11, color: on ? Colors.black : AppColors.text, fontWeight: FontWeight.w700)),
      ),
    );
  }

  Widget _stat(String label, String value, Color c) => Column(children: [
        Text(value, style: TextStyle(color: c, fontWeight: FontWeight.w700, fontSize: 14)),
        Text(label, style: const TextStyle(color: AppColors.muted, fontSize: 10)),
      ]);

  Widget _bottom() {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      if (_selected != null && _tool == Tool.none)
        InfoPanel(
          world: w,
          id: _selected!,
          kind: _selKind,
          onClose: () => _select(null, ''),
          onDemolish: () {
            switch (_selKind) {
              case 'node':
                w.demolishNode(_selected!);
              case 'line':
                w.demolishLine(_selected!);
              case 'rail':
                w.demolishRail(_selected!);
              case 'train':
                w.removeTrain(_selected!);
            }
            w.step(0.01);
            _select(null, '');
          },
        ),
      if (_openCat != null) _catItems(_openCat!),
      _card(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final c in cfg.categories) _catBtn(c.id, c.icon, c.name),
            _catBtn('_demolish', '🗑', 'Снос'),
            _catBtn('_layers', '🗺', 'Слои'),
          ]),
        ),
      ),
      const SizedBox(height: 6),
    ]);
  }

  Widget _catBtn(String id, String icon, String name) {
    final on = _openCat == id || (id == '_demolish' && _tool == Tool.demolish);
    return GestureDetector(
      onTap: () {
        if (id == '_demolish') {
          _setTool(_tool == Tool.demolish ? Tool.none : Tool.demolish);
          return;
        }
        setState(() {
          _openCat = _openCat == id ? null : id;
          _selected = null;
        });
      },
      child: Container(
        width: 66,
        padding: const EdgeInsets.symmetric(vertical: 6),
        margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          color: on ? AppColors.accent.withOpacity(0.18) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(icon, style: const TextStyle(fontSize: 20)),
          const SizedBox(height: 2),
          Text(name,
              style: TextStyle(fontSize: 11, color: on ? AppColors.accent : AppColors.text),
              overflow: TextOverflow.ellipsis),
        ]),
      ),
    );
  }

  Widget _item(String icon, String title, String sub, bool on, VoidCallback onTap, {Color? color}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 128,
        margin: const EdgeInsets.symmetric(horizontal: 3),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: on ? AppColors.accent.withOpacity(0.2) : AppColors.surface2,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: on ? AppColors.accent : (color ?? Colors.transparent), width: 1.4),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Text(icon, style: const TextStyle(fontSize: 18)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(title,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
            ),
          ]),
          const SizedBox(height: 4),
          Text(sub, style: const TextStyle(color: AppColors.muted, fontSize: 10), maxLines: 3, overflow: TextOverflow.ellipsis),
        ]),
      ),
    );
  }

  Widget _catItems(String cat) {
    final items = <Widget>[];
    if (cat == '_layers') {
      items.addAll([
        _item('🗺', 'Сеть OSM', layers.existingGrid ? 'показана' : 'скрыта', layers.existingGrid,
            () => setState(() => layers.existingGrid = !layers.existingGrid)),
        _item('⛏', 'Месторождения', layers.deposits ? 'показаны' : 'скрыты', layers.deposits,
            () => setState(() => layers.deposits = !layers.deposits)),
        _item('🔤', 'Подписи', layers.labels ? 'показаны' : 'скрыты', layers.labels,
            () => setState(() => layers.labels = !layers.labels)),
        _item('〰', 'Местные сети', layers.feeders ? 'показаны' : 'при приближении', layers.feeders,
            () => setState(() => layers.feeders = !layers.feeders)),
      ]);
    } else {
      if (cat == 'grid') {
        for (final v in cfg.voltages) {
          items.add(_item('〰', 'ЛЭП ${v.kv} кВ',
              'до ${fmtMw(v.capMw)}, потери ${v.lossPer100km}%/100 км',
              _tool == Tool.line && _lineKv == v.kv, () {
            _setTool(Tool.line);
            setState(() => _lineKv = v.kv);
          }, color: v.color.withOpacity(0.6)));
        }
      }
      for (final d in cfg.buildings.values.where((b) => b.cat == cat)) {
        String sub = d.desc;
        if (d.kind == 'plant' || d.kind == 'storage') sub = '${fmtMw(d.mw)} · ${d.kv.join("/")} кВ\n${d.desc}';
        if (d.kind == 'sub') sub = '${d.kv.join("/")} кВ · ${fmtMw(d.capMw)}';
        items.add(_item(d.icon, d.name, sub, _tool == Tool.build && _buildDef?.id == d.id,
            () => _setTool(Tool.build, def: d)));
      }
      if (cat == 'rail') {
        items.add(_item('🛤', 'Рельсы', 'Соедини две станции', _tool == Tool.rail, () => _setTool(Tool.rail)));
        items.add(_item('🚂', 'Поезд', 'Возит грузы между двумя станциями туда-обратно', _tool == Tool.train,
            () => _setTool(Tool.train)));
      }
    }
    return Container(
      height: 104,
      margin: const EdgeInsets.only(top: 6),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: items,
      ),
    );
  }

  void _menu() {
    final old = _speed;
    setState(() => _speed = 0);
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.save, color: AppColors.accent),
            title: const Text('Сохранить'),
            onTap: () {
              Navigator.pop(ctx);
              _save();
            },
          ),
          ListTile(
            leading: const Icon(Icons.bar_chart, color: AppColors.accent),
            title: const Text('Сводка'),
            onTap: () {
              Navigator.pop(ctx);
              _summary();
            },
          ),
          ListTile(
            leading: const Icon(Icons.center_focus_strong, color: AppColors.accent),
            title: const Text('Показать всю страну'),
            onTap: () {
              Navigator.pop(ctx);
              _camInit = false;
              _initCam(cam.size);
              _frame.value++;
            },
          ),
          ListTile(
            leading: const Icon(Icons.exit_to_app, color: AppColors.accent),
            title: const Text('Сохранить и выйти в меню'),
            onTap: () async {
              Navigator.pop(ctx);
              await _save(silent: true);
              if (mounted) Navigator.of(context).pop();
            },
          ),
        ]),
      ),
    ).then((_) {
      if (mounted && _speed == 0) setState(() => _speed = old);
    });
  }

  void _summary() {
    final byType = <String, double>{};
    final capByType = <String, double>{};
    for (final n in w.nodes.values) {
      final d = n.def;
      if (d == null || !d.isGenerator) continue;
      byType[d.name] = (byType[d.name] ?? 0) + n.genMw;
      capByType[d.name] = (capByType[d.name] ?? 0) + n.maxMw;
    }
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Сводка', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            const Text('Генерация по типам', style: TextStyle(color: AppColors.muted)),
            for (final e in byType.entries)
              Row(children: [
                Expanded(child: Text(e.key)),
                Text('${fmtMw(e.value)} / ${fmtMw(capByType[e.key] ?? 0)}'),
              ]),
            if (byType.isEmpty) const Text('Пока нет станций'),
            const SizedBox(height: 12),
            const Text('Произведено всего', style: TextStyle(color: AppColors.muted)),
            for (final r in cfg.resources)
              Row(children: [Expanded(child: Text(r.name)), Text(fmtT(w.produced[r.id] ?? 0))]),
            const SizedBox(height: 12),
            Text('Ветер: ${(w.wind * 100).round()}% · Резерв мощности: ${fmtMw(w.spareMw)}',
                style: const TextStyle(color: AppColors.muted)),
            Text('Поездов: ${w.trains.length} · Станций: ${w.nodes.values.where((n) => n.isStation).length}',
                style: const TextStyle(color: AppColors.muted)),
          ]),
        ),
      ),
    );
  }
}

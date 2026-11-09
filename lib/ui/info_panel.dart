import 'package:flutter/material.dart';

import '../sim/entities.dart';
import '../sim/world.dart';
import '../theme.dart';

/// Карточка с информацией о выбранном объекте.
class InfoPanel extends StatelessWidget {
  final World world;
  final String id;
  final String kind;
  final VoidCallback onClose;
  final VoidCallback onDemolish;

  const InfoPanel({
    super.key,
    required this.world,
    required this.id,
    required this.kind,
    required this.onClose,
    required this.onDemolish,
  });

  @override
  Widget build(BuildContext context) {
    String title = '';
    String icon = '';
    final rows = <(String, String, Color?)>[];
    String note = '';
    bool canDemolish = true;

    switch (kind) {
      case 'node':
        final n = world.nodes[id];
        if (n == null) return const SizedBox.shrink();
        title = n.name;
        icon = n.isCity ? '🏙' : n.icon;
        if (n.isCity) {
          canDemolish = false;
          rows.add(('Население', fmtPop(n.pop), null));
          rows.add(('Спрос', fmtMw(n.demandMw), null));
          rows.add(('Получает', fmtMw(n.suppliedMw), _fracColor(n.supplyFrac)));
          rows.add(('Обеспечено', '${(n.supplyFrac * 100).toStringAsFixed(0)}%', _fracColor(n.supplyFrac)));
          if (n.supplyFrac < 0.99) note = n.supplyFrac < 0.05 ? 'Город без света!' : 'Веерные отключения';
        } else {
          final d = n.def;
          if (n.existing) rows.add(('Источник', 'OpenStreetMap', AppColors.muted));
          if (d != null && (d.kind == 'plant' || d.kind == 'storage')) {
            rows.add(('Выдаёт', '${fmtMw(n.genMw)} из ${fmtMw(n.maxMw)}', AppColors.accent));
            if (n.genAvail > 0 && d.kind == 'plant') rows.add(('Доступно сейчас', fmtMw(n.genAvail), null));
          }
          if (d?.kind == 'storage') {
            rows.add(('Запас', '${n.storedMwh.toStringAsFixed(0)} / ${d!.storeMwh.toStringAsFixed(0)} МВт·ч', null));
            if (n.chargeMw > 0) rows.add(('Заряжается', fmtMw(n.chargeMw), AppColors.accent));
          }
          if (d?.kind == 'sub') rows.add(('Мощность', fmtMw(d!.capMw), null));
          if (n.kv.isNotEmpty) rows.add(('Напряжения', '${(n.kv.toList()..sort((a, b) => b - a)).join("/")} кВ', null));
          if (n.demandMw > 0) {
            rows.add(('Потребляет', '${fmtMw(n.suppliedMw)} из ${fmtMw(n.demandMw)}', _fracColor(n.supplyFrac)));
          }
          if (d != null && d.produces.isNotEmpty) {
            rows.add(('Работает на', '${(n.workFrac * 100).toStringAsFixed(0)}%', null));
          }
          if (d != null) {
            final res = {...d.produces.keys, ...d.inputs.keys, ...d.fuel.keys};
            for (final r in res) {
              if (n.existing) continue;
              rows.add(('Склад: ${world.cfg.resName(r)}', '${fmtT(n.stock[r] ?? 0)} / ${fmtT(d.store)}', null));
            }
            if (n.existing && d.fuel.isNotEmpty) note = 'Существующая станция: топливо по контракту';
          }
          if (n.isStation) {
            final c = world.catchment[n.id] ?? const [];
            rows.add(('Обслуживает', '${c.length} зданий', null));
            rows.add(('Поездов', '${world.trains.where((t) => t.from == n.id || t.to == n.id).length}', null));
          } else if (d != null && (d.produces.isNotEmpty || d.accepts.isNotEmpty) && !n.existing) {
            final st = world.servedBy[n.id];
            rows.add(('ЖД-станция', st == null ? 'нет рядом' : (world.nodes[st]?.name ?? ''),
                st == null ? AppColors.warn : null));
          }
          if (n.status.isNotEmpty) note = n.status;
          if (d != null && d.desc.isNotEmpty && note.isEmpty && !n.existing) note = d.desc;
        }
      case 'line':
        final l = world.lines[id];
        if (l == null) return const SizedBox.shrink();
        final v = world.cfg.volt(l.kv);
        icon = '〰';
        title = l.virtual ? 'Местная сеть ${l.kv} кВ' : 'ЛЭП ${l.kv} кВ${l.circuits > 1 ? " (${l.circuits} цепи)" : ""}';
        rows.add(('Длина', '${l.lenKm.toStringAsFixed(0)} км', null));
        rows.add(('Переток', fmtMw(l.flow), AppColors.accent));
        if (!l.virtual) {
          final cap = v.capMw * l.circuits;
          final load = l.flow / cap;
          rows.add(('Пропускная', fmtMw(cap), null));
          rows.add(('Загрузка', '${(load * 100).toStringAsFixed(0)}%', _fracColor(1 - load + 0.5)));
          rows.add(('Потери', fmtMw(l.lossMw), AppColors.muted));
          if (load > 0.97) note = 'Линия перегружена — нужна ещё одна или выше напряжение';
        } else {
          note = 'Авто-подключение по местной сети (10/35 кВ), без потерь';
        }
        final a = world.nodes[l.a], b = world.nodes[l.b];
        rows.add(('Соединяет', '${a?.name ?? "?"} — ${b?.name ?? "?"}', null));
        if (l.existing) rows.add(('Источник', 'OpenStreetMap', AppColors.muted));
      case 'rail':
        final r = world.rails[id];
        if (r == null) return const SizedBox.shrink();
        icon = '🛤';
        title = 'ЖД-путь';
        rows.add(('Длина', '${r.lenKm.toStringAsFixed(0)} км', null));
        rows.add(('Соединяет', '${world.nodes[r.a]?.name ?? "?"} — ${world.nodes[r.b]?.name ?? "?"}', null));
      case 'train':
        Train? t;
        for (final x in world.trains) {
          if (x.id == id) t = x;
        }
        if (t == null) return const SizedBox.shrink();
        icon = '🚂';
        title = 'Поезд ${world.nodes[t.from]?.name ?? ""} ⇄ ${world.nodes[t.to]?.name ?? ""}';
        rows.add(('Груз', t.amount > 0 ? '${world.cfg.resName(t.cargo)}, ${fmtT(t.amount)}' : 'пусто', null));
        rows.add(('Состояние', t.status, null));
        note = 'Сам решает, что везти: берёт то, что нужно на другом конце.';
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 0),
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 12),
      decoration: BoxDecoration(
        color: AppColors.surface.withOpacity(0.96),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.accent.withOpacity(0.4)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Text(icon, style: const TextStyle(fontSize: 22)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(title,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
          ),
          if (canDemolish)
            IconButton(
              tooltip: 'Снести',
              icon: const Icon(Icons.delete_outline, color: AppColors.bad),
              onPressed: onDemolish,
              visualDensity: VisualDensity.compact,
            ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: onClose,
            visualDensity: VisualDensity.compact,
          ),
        ]),
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.only(top: 3, right: 8),
            child: Row(children: [
              Expanded(child: Text(r.$1, style: const TextStyle(color: AppColors.muted, fontSize: 13))),
              Flexible(
                child: Text(r.$2,
                    textAlign: TextAlign.right,
                    style: TextStyle(color: r.$3 ?? AppColors.text, fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ]),
          ),
        if (note.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8, right: 8),
            child: Text(note, style: const TextStyle(color: AppColors.warn, fontSize: 12)),
          ),
      ]),
    );
  }

  Color _fracColor(double f) => f > 0.99 ? AppColors.good : (f > 0.5 ? AppColors.warn : AppColors.bad);
}

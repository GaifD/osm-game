import 'package:flutter/material.dart';

import '../main.dart';
import '../save.dart';
import '../sim/world.dart';
import '../theme.dart';
import 'game_screen.dart';

class MenuScreen extends StatefulWidget {
  final GameData data;
  const MenuScreen({super.key, required this.data});

  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen> {
  bool _hasSave = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final e = await SaveStore.exists();
    if (mounted) setState(() => _hasSave = e);
  }

  void _start(World w) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => GameScreen(data: widget.data, world: w)))
        .then((_) => _check());
  }

  Future<void> _continue() async {
    final j = await SaveStore.load();
    if (j == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Сохранение не найдено')));
      return;
    }
    try {
      _start(World.fromJson(widget.data.cfg, widget.data.map, j));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось загрузить: $e')));
    }
  }

  void _newGame() {
    final hasGrid = widget.data.map.gridEdges.isNotEmpty;
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Новая игра', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              const Text('Режим: песочница. Экономика — в следующих версиях.',
                  style: TextStyle(color: AppColors.muted)),
              const SizedBox(height: 16),
              _option(ctx, '🌱', 'С нуля', 'Реальные города и география, сеть строишь сам', () {
                Navigator.pop(ctx);
                _start(World(widget.data.cfg, widget.data.map, readyMode: false));
              }),
              const SizedBox(height: 10),
              _option(
                  ctx,
                  '🗺',
                  'Готовая сеть (OSM)',
                  hasGrid
                      ? 'Реальные ЛЭП 220–750 кВ, подстанции и станции из OpenStreetMap'
                      : 'Данные сети не скачались при сборке — будет пусто',
                  () {
                Navigator.pop(ctx);
                _start(World(widget.data.cfg, widget.data.map, readyMode: true));
              }),
            ],
          ),
        ),
      ),
    );
  }

  Widget _option(BuildContext ctx, String icon, String title, String sub, VoidCallback onTap) {
    return Material(
      color: AppColors.surface2,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Text(icon, style: const TextStyle(fontSize: 28)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(sub, style: const TextStyle(color: AppColors.muted, fontSize: 13)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.data.map;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              const Text('⚡', style: TextStyle(fontSize: 56), textAlign: TextAlign.center),
              const SizedBox(height: 8),
              const Text('OSM Game',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 32, fontWeight: FontWeight.w800, color: AppColors.accent)),
              const SizedBox(height: 6),
              const Text('Энергетика, промышленность и логистика\nна реальной карте Украины',
                  textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted)),
              const Spacer(),
              if (_hasSave) ...[
                FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 16)),
                  onPressed: _continue,
                  child: const Text('Продолжить', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ),
                const SizedBox(height: 12),
              ],
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.accent,
                    side: const BorderSide(color: AppColors.accent),
                    padding: const EdgeInsets.symmetric(vertical: 16)),
                onPressed: _newGame,
                child: const Text('Новая игра', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(height: 20),
              Text(
                'Данные: ${m.oblasts.length} обл. · ${m.cities.length} городов · '
                '${m.gridEdges.length} ЛЭП · ${m.gridNodes.length} узлов\n© участники OpenStreetMap',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.muted, fontSize: 11),
              ),
              const SizedBox(height: 4),
              const Text('v0.1 — тестовая', textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.muted, fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import 'data/config.dart';
import 'data/geo.dart';
import 'theme.dart';
import 'ui/menu_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OsmGameApp());
}

class GameData {
  final GameConfig cfg;
  final MapData map;
  GameData(this.cfg, this.map);

  static Future<GameData> load() async => GameData(await GameConfig.load(), await MapData.load());
}

class OsmGameApp extends StatelessWidget {
  const OsmGameApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OSM Game',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: FutureBuilder<GameData>(
        future: GameData.load(),
        builder: (context, snap) {
          if (snap.hasError) {
            return Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('Ошибка загрузки данных:\n${snap.error}',
                      style: const TextStyle(color: AppColors.bad)),
                ),
              ),
            );
          }
          if (!snap.hasData) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator(color: AppColors.accent)),
            );
          }
          return MenuScreen(data: snap.data!);
        },
      ),
    );
  }
}

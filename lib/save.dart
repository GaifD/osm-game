import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class SaveStore {
  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/save1.json');
  }

  static Future<bool> exists() async {
    try {
      return (await _file()).exists();
    } catch (_) {
      return false;
    }
  }

  static Future<void> save(Map<String, dynamic> data) async {
    final f = await _file();
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(data));
    await tmp.rename(f.path);
  }

  static Future<Map<String, dynamic>?> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return null;
      return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }
}

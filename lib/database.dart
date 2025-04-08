import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:logging/logging.dart';

class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  factory DatabaseHelper() => _instance;
  DatabaseHelper._internal();

  static Database? _database;
  final _logger = Logger('DatabaseHelper');
  final _urlCache = <String, bool>{};
  static const String _lastUpdateKey = 'last_phishing_db_update';
  static const Duration _updateInterval = Duration(days: 1);
  static const String _apiKey = ''; // PhishTank API key if needed

  Future<Database> get database async {
    _database ??= await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'qr_checker.db');

    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE phishing_sites(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            url TEXT NOT NULL,
            verified INTEGER DEFAULT 0,
            online INTEGER DEFAULT 1,
            target TEXT,
            submission_time TEXT,
            last_checked TEXT
          )
        ''');
        await db.execute('CREATE INDEX url_index ON phishing_sites(url)');
      },
    );
  }

  Future<void> updatePhishingDatabase() async {
    final prefs = await SharedPreferences.getInstance();
    final lastUpdate = DateTime.fromMillisecondsSinceEpoch(
      prefs.getInt(_lastUpdateKey) ?? 0,
    );
    final now = DateTime.now();

    if (now.difference(lastUpdate) < _updateInterval) {
      _logger.info('База данных актуальна, пропускаем обновление');
      return;
    }

    try {
      // Получаем последние записи через API
      final response = await http.get(
        Uri.parse('https://api.phishtank.com/phish/recent/'),
        headers: {
          'Accept': 'application/json',
          if (_apiKey.isNotEmpty) 'Api-Key': _apiKey,
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final db = await database;

        await db.transaction((txn) async {
          // Очищаем старые записи
          await txn.delete('phishing_sites', 
            where: "submission_time < ?",
            whereArgs: [DateTime.now().subtract(const Duration(days: 30)).toIso8601String()]
          );

          // Добавляем новые записи
          for (final entry in data) {
            await txn.insert(
              'phishing_sites',
              {
                'url': entry['url'],
                'verified': entry['verified'] ? 1 : 0,
                'online': entry['online'] ? 1 : 0,
                'target': entry['target'] ?? '',
                'submission_time': entry['submission_time'] ?? DateTime.now().toIso8601String(),
                'last_checked': DateTime.now().toIso8601String(),
              },
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
        });

        await prefs.setInt(_lastUpdateKey, now.millisecondsSinceEpoch);
        _logger.info('База данных успешно обновлена');
      } else {
        _logger.warning('Ошибка API: ${response.statusCode}');
      }
    } catch (e) {
      _logger.warning('Ошибка обновления базы: $e');
    }
  }

  Future<bool> isPhishingSite(String url) async {
    // Проверяем кэш
    if (_urlCache.containsKey(url)) {
      return _urlCache[url]!;
    }

    try {
      // Проверяем локальную базу
      final db = await database;
      final result = await db.query(
        'phishing_sites',
        where: 'url = ? AND online = 1',
        whereArgs: [url],
        limit: 1,
      );

      if (result.isNotEmpty) {
        _urlCache[url] = true;
        return true;
      }

      // Проверяем через API
      final response = await http.post(
        Uri.parse('https://api.phishtank.com/check.php'),
        body: {
          'url': url,
          'format': 'json',
          if (_apiKey.isNotEmpty) 'api_key': _apiKey,
        },
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final isPhishing = data['results']['in_database'] ?? false;

        if (isPhishing) {
          // Добавляем в локальную базу
          await db.insert(
            'phishing_sites',
            {
              'url': url,
              'verified': 1,
              'online': 1,
              'submission_time': DateTime.now().toIso8601String(),
              'last_checked': DateTime.now().toIso8601String(),
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }

        _urlCache[url] = isPhishing;
        return isPhishing;
      }
    } catch (e) {
      _logger.warning('Ошибка проверки URL: $e');
      // В случае ошибки проверяем только локальную базу
      final db = await database;
      final result = await db.query(
        'phishing_sites',
        where: 'url = ? AND online = 1',
        whereArgs: [url],
        limit: 1,
      );
      
      final isPhishing = result.isNotEmpty;
      _urlCache[url] = isPhishing;
      return isPhishing;
    }

    _urlCache[url] = false;
    return false;
  }

  // Очистка кэша
  void clearCache() {
    _urlCache.clear();
  }

  // Получение статистики
  Future<Map<String, dynamic>> getDatabaseStats() async {
    final db = await database;
    final totalCount = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM phishing_sites')
    ) ?? 0;
    final verifiedCount = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM phishing_sites WHERE verified = 1')
    ) ?? 0;
    final onlineCount = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM phishing_sites WHERE online = 1')
    ) ?? 0;

    return {
      'total': totalCount,
      'verified': verifiedCount,
      'online': onlineCount,
      'last_update': DateTime.fromMillisecondsSinceEpoch(
        (await SharedPreferences.getInstance()).getInt(_lastUpdateKey) ?? 0
      ).toIso8601String(),
    };
  }
} 
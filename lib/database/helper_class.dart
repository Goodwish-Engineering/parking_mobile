import 'dart:io';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:csv/csv.dart';
import 'package:synchronized/synchronized.dart';

class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  static Database? _database;
  final _lock = Lock();

  factory DatabaseHelper() => _instance;

  DatabaseHelper._internal();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    Directory documentsDirectory = await getApplicationDocumentsDirectory();
    String path = join(documentsDirectory.path, 'parking_data.db');
    return await openDatabase(
      path,
      version: 3,
      onCreate: _onCreate,
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) {
          await db.execute(
            'ALTER TABLE parking_records ADD COLUMN payment_method TEXT',
          );
        }
        if (oldV < 3) {
          await db.execute(
            'ALTER TABLE parking_records ADD COLUMN card_uid TEXT',
          );
        }
      },
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE parking_records(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        receipt_id TEXT NOT NULL,
        vehicle_number TEXT NOT NULL,
        vehicle_type TEXT NOT NULL,
        checkin_time TEXT,
        checkout_time TEXT,
        checkedin_by TEXT,
        checkedout_by TEXT,
        amount REAL,
        duration TEXT,
        is_synced INTEGER DEFAULT 0,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP,
        payment_method TEXT,
        card_uid TEXT
      )
    ''');
  }

  Future<int> insertCheckInRecord(Map<String, dynamic> record) async {
    final db = await database;
    return await _lock.synchronized(() async {
      return await db.insert('parking_records', {
        'receipt_id': record['receipt_id'],
        'vehicle_number': record['vehicle_number'],
        'vehicle_type': record['vehicle_type'],
        'checkin_time': record['checkin_time'],
        'checkedin_by': record['checkedin_by'],
        'card_uid': record['card_uid']?.toString().toUpperCase(),
        'is_synced': 0,
      });
    });
  }

  Future<Map<String, dynamic>?> getRecordByReceiptId(String receiptId) async {
    final db = await database;
    final results = await db.query(
      'parking_records',
      where: 'receipt_id = ?',
      whereArgs: [receiptId],
      limit: 1,
    );
    if (results.isNotEmpty) return results.first;
    return null;
  }

  Future<Map<String, dynamic>?> getRecordByCardUid(String cardUid) async {
    final db = await database;
    final results = await db.query(
      'parking_records',
      where: 'card_uid = ? AND checkout_time IS NULL',
      whereArgs: [cardUid.toUpperCase()],
      orderBy: 'id DESC',
      limit: 1,
    );
    if (results.isNotEmpty) return results.first;
    return null;
  }

  Future<bool> isCardCurrentlyInside(String cardUid) async {
    final record = await getRecordByCardUid(cardUid);
    return record != null;
  }

  Future<void> closeOpenSessionForCard(String cardUid) async {
    final db = await database;
    await _lock.synchronized(() async {
      await db.update(
        'parking_records',
        {
          'checkout_time': DateTime.now().toIso8601String(),
          'checkedout_by': 'RECYCLED_AUTO',
          'is_synced': 1,
        },
        where: 'card_uid = ? AND checkout_time IS NULL',
        whereArgs: [cardUid.toUpperCase()],
      );
    });
  }

  Future<List<Map<String, dynamic>>> searchVehicleLocally(
    String query,
  ) async {
    final db = await database;
    return await db.query(
      'parking_records',
      where: 'vehicle_number LIKE ? OR card_uid = ?',
      whereArgs: ['%$query%', query.toUpperCase()],
      orderBy: '(checkout_time IS NULL) DESC, id DESC',
    );
  }

  Future<int> updateCheckOutRecord(Map<String, dynamic> record) async {
    final db = await database;
    return await _lock.synchronized(() async {
      final updated = await db.update(
        'parking_records',
        {
          'checkout_time': record['checkout_time'],
          'checkedout_by': record['checkedout_by'],
          'amount': record['amount'],
          'duration': record['duration'],
          'payment_method': record['payment_method'],
          'is_synced': 0,
        },
        where: 'receipt_id = ?',
        whereArgs: [record['receipt_id']],
      );

      // If record does not exist on this POS (e.g. check-in was on another POS offline),
      // insert it so this POS can sync the checkout and collected amount to server!
      if (updated == 0) {
        await db.insert('parking_records', {
          'receipt_id': record['receipt_id'],
          'vehicle_number': record['vehicle_number'] ?? '',
          'vehicle_type': record['vehicle_type'] ?? '',
          'checkin_time': record['checkin_time'],
          'checkout_time': record['checkout_time'],
          'checkedout_by': record['checkedout_by'],
          'amount': record['amount'],
          'duration': record['duration'],
          'payment_method': record['payment_method'],
          'is_synced': 0,
        });
        return 1;
      }
      return updated;
    });
  }

  Future<List<Map<String, dynamic>>> getUnsyncedRecords() async {
    final db = await database;
    return await db.query('parking_records', where: 'is_synced = 0');
  }

  Future<void> markRecordsAsSynced(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    await _lock.synchronized(() async {
      await db.rawUpdate(
        'UPDATE parking_records SET is_synced = 1 WHERE id IN (${List.filled(ids.length, '?').join(',')})',
        ids,
      );
    });
  }

  Future<String> exportToCsv() async {
    final db = await database;
    final records = await db.query('parking_records', where: 'is_synced = 0');

    if (records.isEmpty) return '';

    List<List<dynamic>> rows = [];
    rows.add([
      'receipt_id',
      'vehicle_number',
      'vehicle_type',
      'checkin_time',
      'checkout_time',
      'checkedin_by',
      'checkedout_by',
      'amount',
      'duration',
      'payment_method',
    ]);

    for (var record in records) {
      rows.add([
        record['receipt_id'],
        record['vehicle_number'],
        record['vehicle_type'],
        record['checkin_time'],
        record['checkout_time'],
        record['checkedin_by'],
        record['checkedout_by'],
        record['amount'],
        record['duration'],
        record['payment_method'],
      ]);
    }

    return const ListToCsvConverter().convert(rows);
  }

  Future<Map<String, dynamic>> getGateStatistics() async {
    final db = await database;
    final now = DateTime.now();
    final todayPrefix =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

    final parkedCountResult = await db.rawQuery(
      'SELECT COUNT(*) as count FROM parking_records WHERE checkout_time IS NULL',
    );
    final parkedCount = Sqflite.firstIntValue(parkedCountResult) ?? 0;

    final exitedResult = await db.rawQuery(
      'SELECT COUNT(*) as count, COALESCE(SUM(amount), 0) as total FROM parking_records WHERE checkout_time IS NOT NULL AND checkout_time LIKE ?',
      ['$todayPrefix%'],
    );

    final exitedCount =
        exitedResult.isNotEmpty ? (exitedResult.first['count'] as int? ?? 0) : 0;
    final totalCollection = exitedResult.isNotEmpty
        ? (exitedResult.first['total'] as num? ?? 0.0).toDouble()
        : 0.0;

    return {
      'parkedCount': parkedCount,
      'exitedCount': exitedCount,
      'totalCollection': totalCollection,
    };
  }
}

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:parking/auth/api_endpoints.dart';
import 'package:parking/auth/auth_service.dart';
import 'package:parking/database/helper_class.dart';
import 'package:synchronized/synchronized.dart';

class SyncService {
  // Singleton pattern
  static final SyncService _instance = SyncService._internal();
  factory SyncService() => _instance;
  SyncService._internal();

  final DatabaseHelper _dbHelper = DatabaseHelper();
  Timer? _syncTimer;
  Timer? _midnightCleanupTimer;
  final _lock = Lock(reentrant: true); // For synchronizing database operations
  bool _isSyncStarted = false; // Flag to prevent duplicate startAutoSync calls

  void startAutoSync({int intervalMinutes = 1}) {
    if (_isSyncStarted) return; // Prevent duplicate calls
    _isSyncStarted = true;

    // 1. Check startup sync & purge old synced records from yesterday
    _checkStartupSyncAndCleanup();

    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(Duration(minutes: intervalMinutes), (timer) {
      _syncData();
    });

    // Start the midnight cleanup scheduler
    _scheduleMidnightCleanup();
  }

  void stopAutoSync() {
    _isSyncStarted = false;
    _syncTimer?.cancel();
    _syncTimer = null;
    _midnightCleanupTimer?.cancel();
    _midnightCleanupTimer = null;
  }

  Future<void> _checkStartupSyncAndCleanup() async {
    try {
      await _syncData();
      await _cleanupOldSyncedRecords();
    } catch (e) {
      debugPrint('Startup sync/cleanup error: $e');
    }
  }

  Future<void> _syncData() async {
    debugPrint("awaiting lock");
    await _lock.synchronized(() async {
      try {
        // One read: the file sent and the records marked afterwards are the same ones
        final records = await _dbHelper.getUnsyncedRecords();
        if (records.isEmpty) return;

        final failedRows =
            await SyncService.syncParkingData(_dbHelper.toCsv(records));
        if (failedRows == null) return; // not delivered: all stay unsent

        // Rows the server could not save stay unsent and are retried; the rest are done
        final sent = [
          for (var i = 0; i < records.length; i++)
            if (!failedRows.contains(i + 1)) records[i],
        ];
        await _dbHelper.markRecordsAsSynced(sent);
        debugPrint('Synced ${sent.length} of ${records.length} records');
      } catch (e) {
        debugPrint('Sync error: $e');
      }
    });
  }

  void _scheduleMidnightCleanup() {
    _midnightCleanupTimer?.cancel(); // Cancel any existing timer

    // Use local time for clean trigger
    final now = DateTime.now();
    final nextMidnight = DateTime(now.year, now.month, now.day + 1, 0, 0, 5);
    var durationUntilMidnight = nextMidnight.difference(now);

    if (durationUntilMidnight.inSeconds <= 0) {
      final nextDayMidnight =
          DateTime(now.year, now.month, now.day + 2, 0, 0, 5);
      durationUntilMidnight = nextDayMidnight.difference(now);
    }

    _midnightCleanupTimer = Timer(durationUntilMidnight, () async {
      debugPrint("MIDNIGHT CLEANUP TRIGGERED");
      await _cleanupOldSyncedRecords();
      _scheduleMidnightCleanup(); // Schedule next cleanup
    });
  }

  Future<void> _cleanupOldSyncedRecords() async {
    await _lock.synchronized(() async {
      try {
        // 1. Sync pending records before cleaning
        await _syncData();

        final now = DateTime.now();
        final todayPrefix =
            '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

        // 14-day retention cutoff for abandoned / un-checked-out vehicles
        final fourteenDaysAgo = now.subtract(const Duration(days: 14));
        final cutoff14DaysStr =
            '${fourteenDaysAgo.year}-${fourteenDaysAgo.month.toString().padLeft(2, '0')}-${fourteenDaysAgo.day.toString().padLeft(2, '0')} '
            '${fourteenDaysAgo.hour.toString().padLeft(2, '0')}:${fourteenDaysAgo.minute.toString().padLeft(2, '0')}:${fourteenDaysAgo.second.toString().padLeft(2, '0')}';

        final db = await _dbHelper.database;

        // A. Safe Daily Cleanup:
        // Delete records that are already synced (is_synced = 1), already checked out, and not from today.
        final completedCount = await db.delete(
          'parking_records',
          where:
              'is_synced = 1 AND checkout_time IS NOT NULL AND checkout_time NOT LIKE ?',
          whereArgs: ['$todayPrefix%'],
        );

        // B. Standard 14-Day Retention Rule for Abandoned / Runaway Vehicles:
        // Delete records that are already synced (is_synced = 1), never checked out (checkout_time IS NULL), but entered > 14 days ago.
        final abandonedCount = await db.delete(
          'parking_records',
          where:
              'is_synced = 1 AND checkout_time IS NULL AND checkin_time < ?',
          whereArgs: [cutoff14DaysStr],
        );

        debugPrint(
          'Cleanup: Deleted $completedCount completed records and $abandonedCount abandoned (>14d) records',
        );
      } catch (e) {
        debugPrint('Safe cleanup error: $e');
      }
    });
  }

  /// Row numbers (1 = first record) the server could not save, from its reply to an
  /// upload; null when the upload as a whole was not accepted, so nothing was saved.
  static Set<int>? failedRows(int statusCode, String body) {
    if (statusCode == 200 || statusCode == 201) return {};
    if (statusCode != 207) return null; // 207: saved, except the rows listed
    try {
      final errors = (jsonDecode(body) as Map<String, dynamic>)['errors'] as List;
      return {for (final e in errors) (e as Map<String, dynamic>)['row_number'] as int};
    } catch (_) {
      return null; // can't tell which rows: send them all again
    }
  }

  static Future<Set<int>?> syncParkingData(String csvContent) async {
    final token = await SecureStorage.getAccessToken();

    try {
      final uri = Uri.parse(
        '${ApiEndpoints.baseUrl}sync/upload-parking-details/',
      );

      final request = http.MultipartRequest('POST', uri)
        ..headers.addAll({'Authorization': 'Bearer $token'});

      request.files.add(
        http.MultipartFile.fromString(
          'file',
          csvContent,
          filename: 'parking_data.csv',
          contentType: http.MediaType('text', 'csv'),
        ),
      );

      request.fields['meta'] = jsonEncode({'extra_info': 'some_value'});

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      debugPrint('Status: ${response.statusCode}');
      debugPrint('Body: ${response.body}');

      return failedRows(response.statusCode, response.body);
    } catch (e) {
      debugPrint('Upload error: $e');
      return null;
    }
  }
}

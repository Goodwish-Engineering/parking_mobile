import 'package:flutter_test/flutter_test.dart';
import 'package:parking/database/background_sync.dart';

void main() {
  group('failedRows: which records stay unsent after an upload', () {
    test('all saved: none', () {
      expect(SyncService.failedRows(201, '{"errors": []}'), <int>{});
      expect(SyncService.failedRows(200, ''), <int>{});
    });

    test('saved except some rows: only those', () {
      const body = '{"created": 48, "errors": [{"row_number": 2, "errors": "x"}, {"row_number": 7, "errors": "y"}]}';
      expect(SyncService.failedRows(207, body), {2, 7});
    });

    test('not accepted: all of them', () {
      expect(SyncService.failedRows(400, '{"error": "File must be a CSV"}'), isNull);
      expect(SyncService.failedRows(500, ''), isNull);
      expect(SyncService.failedRows(401, ''), isNull);
    });

    test("a reply it can't read: all of them", () {
      expect(SyncService.failedRows(207, 'not json'), isNull);
    });
  });
}

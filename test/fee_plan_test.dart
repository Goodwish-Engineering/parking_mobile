import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parking/services/fee_plan.dart';

/// This app's formula before fee plans (checkout_screen.dart calculateParkingFee), kept here
/// to prove the fallback for an older server still charges exactly the same.
double oldBlueFee(int duration, int freeTime, double hourly, double half, double quarter) {
  if (quarter == 0) {
    if (duration <= freeTime) return 0;
    if (duration <= 30) return half;
    if (duration <= 60) return hourly;
    final intervals = (duration / 30).ceil();
    return (intervals ~/ 2) * hourly + (intervals % 2) * half;
  }
  if (duration <= freeTime) return 0;
  final completedHours = duration ~/ 60;
  final remaining = duration % 60;
  var total = remaining == 0 ? completedHours * hourly : (completedHours + 1) * hourly;
  if (remaining > 0 && remaining <= 15) {
    total = completedHours * hourly + quarter;
  } else if (remaining > 15 && remaining <= 30) {
    total = completedHours * hourly + half;
  } else if (remaining > 30) {
    total = (completedHours + 1) * hourly;
  }
  if (total < hourly) total = hourly;
  return total;
}

void main() {
  group('the server\'s shared cases (test/fee_cases.json)', () {
    final cases = jsonDecode(File('test/fee_cases.json').readAsStringSync()) as List<dynamic>;
    for (final raw in cases) {
      final testCase = Map<String, dynamic>.from(raw as Map);
      test(testCase['name'], () {
        final plan = FeePlan.fromJson(Map<String, dynamic>.from(testCase['plan'] as Map));
        for (final pair in testCase['expect'] as List<dynamic>) {
          final minutes = (pair[0] as num).toInt();
          expect(plan.fee(minutes), (pair[1] as num).toDouble(), reason: '$minutes min');
        }
      });
    }
  });

  test('an older server\'s rates are charged exactly as before, minute by minute for two days', () {
    for (final r in [
      [25.0, 25.0, 15.0, 0], // 24 Wheels bike
      [80.0, 80.0, 40.0, 0], // 24 Wheels car
      [20.0, 15.0, 12.0, 1], // Bhotebahal
      [25.0, 15.0, 0.0, 1], // no quarter rate
    ]) {
      final plan = FeePlan.fromBlueRates(
        hourly: r[0] as double,
        halfHourly: r[1] as double,
        quarterHourly: r[2] as double,
        freeMinutes: r[3] as int,
      );
      for (var minute = 0; minute <= 2 * 24 * 60; minute++) {
        expect(
          plan.fee(minute),
          oldBlueFee(minute, r[3] as int, r[0] as double, r[1] as double, r[2] as double),
          reason: '$r at $minute min',
        );
      }
    }
  });

  test('stay minutes drop leftover seconds', () {
    final checkIn = DateTime(2026, 10, 5, 14, 0, 0);
    expect(FeePlan.stayMinutes(checkIn, checkIn.add(const Duration(minutes: 30, seconds: 59))), 30);
    expect(FeePlan.stayMinutes(checkIn, checkIn.subtract(const Duration(minutes: 1))), 0);
  });
}

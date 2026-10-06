import 'package:intl/intl.dart';
import 'package:parking/services/fee_plan.dart';

/// The wording of times and durations on slips, the same as the NB55 app's receipts.
/// Text only: printing stays with each screen, for this device's printer.
class SlipText {
  /// e.g. "2026-09-16 20:16:42": 24-hour with seconds, so the times visibly add up to the
  /// duration (which counts whole minutes) and the line fits the slip
  static String time(DateTime time) => DateFormat('yyyy-MM-dd HH:mm:ss').format(time.toLocal());

  /// e.g. "4 min", "1 hr 5 min"
  static String duration(DateTime checkIn, DateTime checkOut) {
    final minutes = FeePlan.stayMinutes(checkIn, checkOut);
    final hours = minutes ~/ 60;
    if (hours == 0) return '$minutes min';
    return '$hours hr ${minutes % 60} min';
  }

  /// e.g. "Total: Rs. 15"
  static String total(double amount) => 'Total: Rs. ${amount.toStringAsFixed(0)}';
}

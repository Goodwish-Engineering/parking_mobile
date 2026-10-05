import 'package:parking/services/fee_plan.dart';

class VehicleRate {
  final int id;
  final String vehicleType;
  final String? icon;
  final double hourlyRate;
  final double halfHourlyRate;
  final double quarterHourlyRate;
  final bool status;
  /// Set by the mall's admin; null only from a server older than fee plans.
  final FeePlan? feePlan;

  VehicleRate({
    required this.id,
    required this.vehicleType,
    this.icon,
    required this.hourlyRate,
    required this.halfHourlyRate,
    required this.quarterHourlyRate,
    required this.status,
    this.feePlan,
  });

  factory VehicleRate.fromJson(Map<String, dynamic> json) {
    return VehicleRate(
      id: json['id'],
      vehicleType: json['vehicle_type'],
      icon: json['icon'],
      hourlyRate: (json['hourly_rate'] as num).toDouble(),
      halfHourlyRate: (json['half_hourly_rate'] as num).toDouble(),
      quarterHourlyRate: (json['quarter_hourly_rate'] as num).toDouble(),
      status: json['status'],
      feePlan: json['fee_plan'] is Map
          ? FeePlan.fromJson(Map<String, dynamic>.from(json['fee_plan'] as Map))
          : null,
    );
  }

  /// The plan to price a stay by; an older server's rates are read the way this app always did.
  FeePlan plan({required int freeTime}) =>
      feePlan ??
      FeePlan.fromBlueRates(
        hourly: hourlyRate,
        halfHourly: halfHourlyRate,
        quarterHourly: quarterHourlyRate,
        freeMinutes: freeTime,
      );

  @override
  String toString() {
    return 'VehicleRate('
        'id: $id, '
        'vehicleType: $vehicleType, '
        'icon: $icon, '
        'hourlyRate: $hourlyRate, '
        'halfHourlyRate: $halfHourlyRate, '
        'quarterHourlyRate: $quarterHourlyRate, '
        'status: $status'
        ')';
  }
}

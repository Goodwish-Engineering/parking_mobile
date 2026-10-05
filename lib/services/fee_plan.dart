/// How a vehicle type is charged, as the mall's admin set it on the website.
///
/// The plan arrives in the login response with each rate (`fee_plan`). This is a line-for-line
/// copy of the server's parkinginfo/fees.py: the POS shows the price, the server bills the same
/// figure, and test/fee_plan_test.dart runs the server's shared cases (test/fee_cases.json)
/// so the two can never disagree.
class FeeStep {
  final int upTo; // minutes counted
  final double price; // the total for a stay up to [upTo] counted minutes

  const FeeStep(this.upTo, this.price);

  factory FeeStep.fromJson(Map<String, dynamic> json) =>
      FeeStep((json['up_to'] as num).toInt(), (json['price'] as num).toDouble());
}

class FeePlan {
  static const minutesPerDay = 24 * 60;

  final int freeMinutes;
  final bool countAfterFree; // "after_free": minute 6 is minute 1 of the tariff
  final List<FeeStep> first;
  final int? repeatEvery;
  final List<FeeStep> repeatSteps;
  final int graceMinutes;
  final double? dailyMax;

  const FeePlan({
    required this.freeMinutes,
    required this.countAfterFree,
    required this.first,
    this.repeatEvery,
    this.repeatSteps = const [],
    this.graceMinutes = 0,
    this.dailyMax,
  });

  static List<FeeStep> _steps(Object? raw) => (raw as List<dynamic>)
      .map((s) => FeeStep.fromJson(Map<String, dynamic>.from(s as Map)))
      .toList();

  factory FeePlan.fromJson(Map<String, dynamic> json) {
    final repeat = json['repeat'] == null ? null : Map<String, dynamic>.from(json['repeat'] as Map);
    return FeePlan(
      freeMinutes: (json['free_minutes'] as num?)?.toInt() ?? 0,
      countAfterFree: json['count_from'] == 'after_free',
      first: _steps(json['first']),
      repeatEvery: (repeat?['every'] as num?)?.toInt(),
      repeatSteps: repeat == null ? const [] : _steps(repeat['steps']),
      graceMinutes: (json['grace_minutes'] as num?)?.toInt() ?? 0,
      dailyMax: (json['daily_max'] as num?)?.toDouble(),
    );
  }

  /// What the blue app (24 Wheels) charged before plans existed, for a server that does not
  /// send one yet: with a quarter rate, a full hour for even one minute and then per extra hour
  /// up to 15 minutes the quarter rate, up to 30 the half rate, more the hourly rate; without
  /// one, half rate up to 30 minutes, hourly up to 60, then 30-minute blocks.
  factory FeePlan.fromBlueRates({
    required double hourly,
    required double halfHourly,
    required double quarterHourly,
    required int freeMinutes,
  }) {
    List<FeeStep> merged(List<FeeStep> steps) {
      final out = <FeeStep>[];
      for (final step in steps) {
        if (out.isNotEmpty && out.last.price == step.price) out.removeLast();
        out.add(step);
      }
      return out;
    }

    double atLeastHourly(double value) => value > hourly ? value : hourly;
    final first = quarterHourly != 0
        ? merged([
            FeeStep(15, atLeastHourly(quarterHourly)),
            FeeStep(30, atLeastHourly(halfHourly)),
            FeeStep(60, hourly),
          ])
        : merged([FeeStep(30, halfHourly), FeeStep(60, hourly)]);
    final repeat = quarterHourly != 0
        ? merged([FeeStep(15, quarterHourly), FeeStep(30, halfHourly), FeeStep(60, hourly)])
        : merged([FeeStep(30, halfHourly), FeeStep(60, hourly)]);
    return FeePlan(
      freeMinutes: freeMinutes,
      countAfterFree: false,
      first: first,
      repeatEvery: 60,
      repeatSteps: repeat,
    );
  }

  /// What the NB80 app (Kathmandu mall) charged before plans existed: 5 free minutes, then
  /// 30-minute blocks counted after them, alternating the half-hour and the hourly rate.
  factory FeePlan.fromNb80Rates({required double hourly, required double halfHourly}) {
    final blocks = halfHourly == hourly
        ? [FeeStep(60, hourly)]
        : [FeeStep(30, halfHourly), FeeStep(60, hourly)];
    return FeePlan(
      freeMinutes: 5,
      countAfterFree: true,
      first: blocks,
      repeatEvery: 60,
      repeatSteps: blocks,
    );
  }

  static double _stepPrice(List<FeeStep> steps, int minutes) =>
      steps.firstWhere((s) => minutes <= s.upTo, orElse: () => steps.last).price;

  double _feeWithoutCap(int minutes) {
    if (minutes <= freeMinutes) return 0;
    var counted = minutes;
    if (countAfterFree) counted -= freeMinutes;
    counted = counted - graceMinutes < 1 ? 1 : counted - graceMinutes;

    final firstPeriod = first.last.upTo;
    if (counted <= firstPeriod) return _stepPrice(first, counted);

    final total = first.last.price;
    final every = repeatEvery;
    if (every == null || repeatSteps.isEmpty) return total;
    final extra = counted - firstPeriod;
    final wholePeriods = (extra - 1) ~/ every;
    return total + wholePeriods * repeatSteps.last.price + _stepPrice(repeatSteps, extra - wholePeriods * every);
  }

  /// What a stay of [minutes] whole minutes costs.
  double fee(int minutes) {
    final stay = minutes < 0 ? 0 : minutes;
    final cap = dailyMax;
    if (cap == null) return _feeWithoutCap(stay);
    // The cap applies to each 24 hours of the stay on its own.
    var total = 0.0;
    for (var dayStart = 0; dayStart < stay; dayStart += minutesPerDay) {
      final dayEnd = stay < dayStart + minutesPerDay ? stay : dayStart + minutesPerDay;
      final charged = _feeWithoutCap(dayEnd) - _feeWithoutCap(dayStart);
      total += charged < cap ? charged : cap;
    }
    return total;
  }

  /// Whole minutes parked; leftover seconds are not billed (the server counts the same way).
  static int stayMinutes(DateTime checkIn, DateTime checkOut) {
    final minutes = checkOut.difference(checkIn).inMinutes;
    return minutes < 0 ? 0 : minutes;
  }
}

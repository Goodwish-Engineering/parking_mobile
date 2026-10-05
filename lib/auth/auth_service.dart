import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorage {
  static const _storage = FlutterSecureStorage();

  // Keys
  static const accessTokenKey = 'access_token';
  static const refreshTokenKey = 'refresh_token';
  static const fullNameKey = 'full_name';
  static const roleKey = 'role';
  static const idkey = 'id';
  static const baseUrlKey = 'base_url';
  static const freeTimeKey = 'free_time'; 

  // Parking slip heading keys
  static const heading1Key = 'parking_slip_heading1';
  static const heading2Key = 'parking_slip_heading2';
  static const heading3Key = 'parking_slip_heading3';
  static const heading4Key = 'parking_slip_heading4';
  static const footerTextKey = 'parking_slip_footer_text';

  static Future<void> saveBaseUrl(String baseUrl) async {
    await _storage.write(key: baseUrlKey, value: baseUrl);
  }

  static Future<String?> getBaseUrl() async {
    return await _storage.read(key: baseUrlKey);
  }

  /// Save login response
  static Future<void> saveLoginData({
    required String accessToken,
    required String refreshToken,
    required String fullName,
    required String role,
    required String id,
    required int freeTime, 
  }) async {
    await _storage.write(key: idkey, value: id);
    await _storage.write(key: accessTokenKey, value: accessToken);
    await _storage.write(key: refreshTokenKey, value: refreshToken);
    await _storage.write(key: fullNameKey, value: fullName);
    await _storage.write(key: roleKey, value: role);
    await _storage.write(key: freeTimeKey, value: freeTime.toString()); // 👈 Added
  }

  /// Save parking slip details
  static Future<void> saveParkingSlipDetails({
    required String heading1,
    required String heading2,
    required String heading3,
    required String heading4,
    required String footerText,
  }) async {
    await _storage.write(key: heading1Key, value: heading1);
    await _storage.write(key: heading2Key, value: heading2);
    await _storage.write(key: heading3Key, value: heading3);
    await _storage.write(key: heading4Key, value: heading4);
    await _storage.write(key: footerTextKey, value: footerText);
  }

  static Future<void> saveParkingRates(List<dynamic> parkingRates) async {
    await _storage.write(key: 'parking_rates', value: jsonEncode(parkingRates));
  }

  static Future<List<dynamic>> getParkingRates() async {
    final rates = await _storage.read(key: 'parking_rates');
    if (rates != null) {
      return jsonDecode(rates);
    }
    return [];
  }

  /// Get parking slip details
  static Future<Map<String, String>> getParkingSlipDetails() async {
    final heading1 = await _storage.read(key: heading1Key);
    final heading2 = await _storage.read(key: heading2Key);
    final heading3 = await _storage.read(key: heading3Key);
    final heading4 = await _storage.read(key: heading4Key);
    final footerText = await _storage.read(key: footerTextKey);
    final fullName = await _storage.read(key: fullNameKey);
    final id = await _storage.read(key: idkey);

    return {
      'heading1': heading1 ?? '',
      'heading2': heading2 ?? '',
      'heading3': heading3 ?? '',
      'heading4': heading4 ?? '',
      'footerText': footerText ?? '',
      'full_name': fullName ?? '',
      'id': id ?? '',
    };
  }

  static Future<String?> getAccessToken() async {
    return await _storage.read(key: accessTokenKey);
  }

  static Future<String?> getRefreshToken() async {
    return await _storage.read(key: refreshTokenKey);
  }

  static Future<String?> getFullName() async {
    return await _storage.read(key: fullNameKey);
  }

  /// Get free time (returns int, defaults to 0 if not set) 👈 Added
  static Future<int> getFreeTime() async {
    final value = await _storage.read(key: freeTimeKey);
    return int.tryParse(value ?? '') ?? 0;
  }

  static Future<void> clear() async {
    await _storage.deleteAll();
  }

  /// Logout: forget the operator and their login tokens. The tenant server, slip
  /// layout and rates stay, so the next operator only enters their login. Parking
  /// records live in the local database, not here, so unsynced exits are kept and
  /// upload after the next login.
  static Future<void> clearLogin() async {
    for (final key in [accessTokenKey, refreshTokenKey, idkey, fullNameKey, roleKey, freeTimeKey]) {
      await _storage.delete(key: key);
    }
  }
}
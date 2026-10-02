import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:parking/auth/api_endpoints.dart';
import 'package:parking/auth/auth_service.dart';

class VehicleService {
  Future<Map<String, dynamic>> checkIn({
    required String receiptId,
    required String vehicleNumber,
    required String vehicleType,
    required String checkinTime,
  }) async {
    final url = Uri.parse('${ApiEndpoints.baseUrl}parkinginfo/checkin/');
    final body = json.encode({
      'receipt_id': receiptId,
      'vehicle_number': vehicleNumber,
      'vehicle_type': vehicleType,
      'checkin_time': checkinTime,
    });

    try {
      final token = await SecureStorage.getAccessToken();
      final response = await http.post(
        url,
        headers: {
          "Content-Type": "application/json",
          "Authorization": "Bearer $token",
        },
        body: body,
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        return json.decode(response.body);
      } else {
        return {
          'status_code': response.statusCode,
          'response_body': response.body,
        };
      }
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  // Updated checkOut method to be async
  Future<Map<String, dynamic>> checkOut({
    required String receiptId,
    required String vehicleNumber,
    required String vehicleType,
    required String checkoutTime,
    required double amount,
    required String paymentMethod,
    // IRD Annex 6: with a buyer's PAN the slip prints as a TAX INVOICE, which is the only
    // version the buyer's employer can reclaim the VAT on. Without one it is an
    // ABBREVIATED TAX INVOICE, which is what a visitor wants and all a visitor needs.
    String customerName = '',
    String customerAddress = '',
    String customerPan = '',
  }) async {
    final url = Uri.parse('${ApiEndpoints.baseUrl}parkinginfo/checkout/');
    final body = json.encode({
      'receipt_id': receiptId,
      'vehicle_number': vehicleNumber,
      'vehicle_type': vehicleType,
      'checkout_time': checkoutTime,
      'amount': amount,
      'payment_method': paymentMethod,
      if (customerName.trim().isNotEmpty) 'customer_name': customerName.trim(),
      if (customerAddress.trim().isNotEmpty) 'customer_address': customerAddress.trim(),
      if (customerPan.trim().isNotEmpty) 'customer_pan': customerPan.trim(),
    });

    try {
      final token = await SecureStorage.getAccessToken();

      final response = await http.post(
        url,
        headers: {
          "Content-Type": "application/json",
          "Authorization": "Bearer $token",
        },
        body: body,
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        return json.decode(response.body);
      } else {
        return {
          'error': 'Failed to check out',
          'status_code': response.statusCode,
          'response_body': response.body,
        };
      }
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  Future<List<dynamic>> searchVehicle({required String query}) async {
    try {
      final token = await SecureStorage.getAccessToken();
      final response = await http
          .get(
            Uri.parse(
              '${ApiEndpoints.baseUrl}parkinginfo/parking-details/search-vehicle/?query=$query',
            ),
            headers: {
              "Content-Type": "application/json",
              "Authorization": "Bearer $token",
            },
          )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = json.decode(response.body);
        if (data is List) return data;
        return [];
      }
      return [];
    } catch (_) {
      return [];
    }
  }
}

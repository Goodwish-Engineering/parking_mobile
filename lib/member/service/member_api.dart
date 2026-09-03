import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:parking/auth/api_endpoints.dart';
import 'package:parking/auth/auth_service.dart';

class ReportService {
  static Future<Map<String, dynamic>> fetchMemberData({
    required int page,
    required int pageSize,
    String? searchQuery,
  }) async {
    try {
      final token = await SecureStorage.getAccessToken();
      final queryParams = {
        'page': page.toString(),
        'page_size': pageSize.toString(),
        if (searchQuery != null && searchQuery.isNotEmpty)
          'search': searchQuery,
      };

      // Build the URI with query parameters
      final uri = Uri.parse(
        '${ApiEndpoints.baseUrl}membership/members/get-membership-data/',
      ).replace(queryParameters: queryParams);

      // Make the GET request
      final response = await http
          .get(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () {
              throw Exception('Request timeout');
            },
          );

      // Check if request was successful
      if (response.statusCode == 200) {
        final Map<String, dynamic> data = json.decode(response.body);

        // Validate response structure
        if (!data.containsKey('results') || !data.containsKey('total_pages')) {
          throw Exception('Invalid response format');
        }

        return {
          'results': data['results'] ?? [],
          'meta': {
            'count': data['count'] ?? 0,
            'page_size': data['page_size'] ?? pageSize,
            'total_pages': data['total_pages'] ?? 1,
            'next': data['next'],
            'previous': data['previous'],
          },
        };
      } else if (response.statusCode == 401) {
        throw Exception('Unauthorized - Please login again');
      } else if (response.statusCode == 500) {
        throw Exception('Server error - Please try again later');
      } else {
        throw Exception('Failed to load data');
      }
    } on http.ClientException catch (e) {
      throw Exception('Network error: ${e.message}');
    } on FormatException catch (e) {
      throw Exception('Invalid data format: ${e.message}');
    } catch (e) {
      throw Exception('Error fetching member data');
    }
  }

  static Future<Map<String, dynamic>> replaceCard({
    required int memberId,
    required String newCardUid,
    double fee = 0.0,
    String paymentMethod = 'CASH',
    String receivedBy = '',
  }) async {
    try {
      final token = await SecureStorage.getAccessToken();
      final uri = Uri.parse(
        '${ApiEndpoints.baseUrl}membership/members/$memberId/replace-card/',
      );
      final response = await http.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: json.encode({
          'new_card_uid': newCardUid,
          'fee': fee,
          'payment_method': paymentMethod,
          'received_by': receivedBy,
        }),
      );
      final data = json.decode(response.body);
      if (response.statusCode == 200) {
        return {
          'success': true,
          'message': 'Card replaced successfully',
          'data': data,
        };
      } else {
        return {
          'success': false,
          'message':
              data['error'] ?? data['message'] ?? 'Failed to replace card',
        };
      }
    } catch (e) {
      return {'success': false, 'message': e.toString()};
    }
  }
}

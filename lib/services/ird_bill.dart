import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:parking/auth/api_endpoints.dart';
import 'package:parking/auth/auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// IRD bills on the POS. The server makes the bill at checkout (bill number,
/// VAT, sending it to IRD); the POS only prints what the server returns.
class IrdBill {
  static const _billingOnKey = 'ird_billing_on';
  static const divider = '------------------------';

  /// Printed on a slip made while offline: the server issues the real bill
  /// when the checkout is uploaded, so this paper must not look like one.
  static const provisionalLines = [
    'PROVISIONAL RECEIPT',
    'NOT A TAX INVOICE',
    'The VAT bill is issued when',
    'the POS is back online.',
    'Ask the counter for it.',
  ];

  /// The bill to print after a checkout, or null when there is none (billing
  /// off, nothing charged, offline or an older server). The print is recorded
  /// on the server first, so only the first print is the original and later
  /// ones say "Copy of Original (n)".
  static Future<Map<String, dynamic>?> billToPrint(
    Map<String, dynamic> checkoutResponse,
    double amount,
  ) async {
    if (checkoutResponse.containsKey('error')) return null;
    final bill = checkoutResponse['bill'];
    await _rememberBillingOn(checkoutResponse, amount);
    if (bill is! Map) return null;

    final checkoutBill = Map<String, dynamic>.from(bill);
    return await _recordPrint(checkoutBill['bill_id']) ?? checkoutBill;
  }

  /// A network error (no HTTP status) means the checkout was saved offline.
  static bool isOffline(Map<String, dynamic> checkoutResponse) =>
      checkoutResponse.containsKey('error') &&
      !checkoutResponse.containsKey('status_code');

  /// Whether this mall issues IRD bills, as learnt from its last online checkouts.
  static Future<bool> isOn() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_billingOnKey) ?? false;
  }

  static Future<void> _rememberBillingOn(
    Map<String, dynamic> response,
    double amount,
  ) async {
    final bool? billingOn;
    if (response['bill'] is Map) {
      billingOn = true;
    } else if (amount > 0) {
      billingOn = false; // charged but no bill: billing is off (or the server is older)
    } else {
      billingOn = null; // Rs 0 exits never get a bill, so they tell nothing
    }
    if (billingOn == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_billingOnKey, billingOn);
  }

  static Future<Map<String, dynamic>?> _recordPrint(Object? billId) async {
    if (billId == null) return null;
    try {
      final token = await SecureStorage.getAccessToken();
      final response = await http
          .post(
            Uri.parse('${ApiEndpoints.baseUrl}billing/bills/$billId/print/'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        return Map<String, dynamic>.from(json.decode(response.body));
      }
      debugPrint('Bill print not recorded: ${response.statusCode}');
    } catch (e) {
      debugPrint('Bill print not recorded: $e');
    }
    return null;
  }

  /// Seller, invoice type and copy label: the top of the bill (IRD Annex 6).
  static List<String> headingLines(Map<String, dynamic> bill) {
    final seller = Map<String, dynamic>.from(bill['seller'] ?? const {});
    return [
      if (_text(seller['name']).isNotEmpty) _text(seller['name']),
      if (_text(seller['address']).isNotEmpty) _text(seller['address']),
      'PAN/VAT No: ${_text(seller['pan'])}',
      if (_text(seller['phone']).isNotEmpty) 'Phone: ${_text(seller['phone'])}',
      '',
      _text(bill['invoice_title']),
      if (_text(bill['copy_label']).isNotEmpty) _text(bill['copy_label']),
      if (bill['is_bill_active'] == false) '*** CANCELLED ***',
    ];
  }

  /// Bill number, dates, buyer, items and the VAT split.
  static List<String> detailLines(Map<String, dynamic> bill) {
    final items = (bill['items'] as List? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map));
    final saleDate = _text(bill['transaction_date_bs']);
    final issueDate = _text(bill['invoice_issue_date_bs']);
    return [
      'Bill No: ${_text(bill['bill_no'])}',
      'Fiscal Year: ${_text(bill['fiscal_year'])}',
      'Date: $issueDate (BS)',
      if (saleDate.isNotEmpty && saleDate != issueDate) 'Sale Date: $saleDate (BS)',
      if (_text(bill['customer_name']).isNotEmpty) 'Buyer: ${_text(bill['customer_name'])}',
      if (_text(bill['customer_pan']).isNotEmpty) 'Buyer PAN: ${_text(bill['customer_pan'])}',
      divider,
      for (final item in items) ...[
        _text(item['description']),
        '${_text(item['quantity'])} x Rs ${_text(item['rate'])} = Rs ${_text(item['amount'])}',
      ],
      divider,
      if (_text(bill['discount']) != '0.00') 'Discount: Rs ${_text(bill['discount'])}',
      'Taxable Amount: Rs ${_text(bill['taxable_amount'])}',
      if (_text(bill['vat_rate']) != '0') 'VAT ${_text(bill['vat_rate'])}%: Rs ${_text(bill['vat_amount'])}',
      'Total: Rs ${_text(bill['total_amount'])}',
      _text(bill['total_in_words']),
      'Paid by: ${_text(bill['payment_method']) == 'QR' ? 'QR' : 'Cash'}',
    ];
  }

  static String _text(Object? value) => (value ?? '').toString().trim();
}

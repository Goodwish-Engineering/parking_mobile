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

  /// Shown when a paid exit is tried without internet at a mall that issues IRD bills.
  static const offlineBillMessage =
      'No internet. The bill cannot be made offline. Turn on hotspot or mobile data and press again.';

  /// Whether this exit has to wait for the internet. Only the server can make the IRD bill,
  /// and the tax office does not allow a provisional receipt in its place, so a paid exit at
  /// a billing mall is not finished offline: nothing is printed or saved, and pressing again
  /// once connected makes the real bill. Free exits, and malls that do not bill, still
  /// finish offline as before.
  static Future<bool> mustWaitForInternet(
    Map<String, dynamic> checkoutResponse,
    double amount,
  ) async =>
      isOffline(checkoutResponse) && amount > 0 && await isOn();

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

  /// Whether this mall issues IRD bills, as learnt at login and from online checkouts.
  static Future<bool> isOn() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_billingOnKey) ?? false;
  }

  /// Saves what the server says at login, so even a new or reinstalled POS
  /// marks its offline slips correctly. An older server says nothing.
  static Future<void> rememberFromLogin(Map<String, dynamic> loginResponse) async {
    final billingOn = loginResponse['ird_billing_enabled'];
    if (billingOn is! bool) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_billingOnKey, billingOn);
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
      // Under the company, never instead of it. A mall running several car parks
      // bills them all under one PAN and one number series, with the branch named
      // here -- the tax office's own instruction. Blank for a single-lot mall.
      if (_text(seller['branch']).isNotEmpty) 'Branch: ${_text(seller['branch'])}',
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
      // Annex 6 prints these three on BOTH the tax invoice and the abbreviated one, so
      // the labels are always here and simply stand empty for a visitor who gave nothing.
      "Purchaser's Name: ${_text(bill['customer_name'])}",
      'Address: ${_text(bill['customer_address'])}',
      "Purchaser's PAN: ${_text(bill['customer_pan'])}",
      divider,
      for (final item in items) ...[
        _text(item['description']),
        '${_text(item['quantity'])} x Rs ${_text(item['rate'])} = Rs ${_text(item['amount'])}',
      ],
      divider,
      if (_text(bill['discount']) != '0.00') 'Discount: Rs ${_text(bill['discount'])}',
      'Taxable Amount: Rs ${_text(bill['taxable_amount'])}',
      // Only the full tax invoice carries a VAT line: Annex 6's abbreviated layout goes
      // straight from the taxable amount to the total. The server decides which this is,
      // because the same rule has to hold on the website's print.
      if (bill['show_vat_line'] == true)
        'VAT ${_text(bill['vat_rate'])}%: Rs ${_text(bill['vat_amount'])}',
      'Total: Rs ${_text(bill['total_amount'])}',
      _text(bill['total_in_words']),
      'Paid by: ${_text(bill['payment_method']) == 'QR' ? 'QR' : 'Cash'}',
    ];
  }

  static String _text(Object? value) => (value ?? '').toString().trim();
}

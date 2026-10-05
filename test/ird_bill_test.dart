import 'package:flutter_test/flutter_test.dart';
import 'package:parking/services/ird_bill.dart';
import 'package:shared_preferences/shared_preferences.dart';

// A bill as the server returns it at checkout (billing/services.printable)
final bill = <String, dynamic>{
  'bill_id': 7,
  'invoice_title': 'ABBREVIATED TAX INVOICE',
  'copy_label': '',
  'seller': {'name': 'City Mall Parking', 'pan': '301234567', 'address': 'Kathmandu', 'phone': ''},
  'fiscal_year': '2083.084',
  'bill_no': 12,
  'transaction_date_bs': '2083.06.02',
  'invoice_issue_date_bs': '2083.06.02',
  'customer_name': '',
  'customer_pan': '',
  'items': [
    {'description': 'Parking fee - Bike BA1PA0001', 'quantity': 1, 'rate': '88.50', 'amount': '88.50'},
  ],
  'discount': '0.00',
  'taxable_amount': '88.50',
  'vat_rate': '13',
  'vat_amount': '11.50',
  'total_amount': '100.00',
  'total_in_words': 'One Hundred Rupees Only',
  'payment_method': 'CASH',
  'is_bill_active': true,
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('an abbreviated invoice shows the total with VAT included, and no VAT line', () {
    expect(IrdBill.headingLines(bill), [
      'City Mall Parking',
      'Kathmandu',
      'PAN/VAT No: 301234567',
      '',
      'ABBREVIATED TAX INVOICE',
    ]);
    final lines = IrdBill.detailLines(bill);
    expect(lines, containsAll(<String>[
      'Bill No: 12',
      'Fiscal Year: 2083.084',
      'Date: 2083.06.02 (BS)',
      '1 x Rs 88.50 = Rs 88.50',
      'Taxable Amount: Rs 88.50',
      'Total: Rs 100.00',
      'One Hundred Rupees Only',
      'Paid by: Cash',
    ]));
    // Annex 6: only the full tax invoice splits out the VAT
    expect(lines.any((line) => line.startsWith('VAT')), isFalse);
    expect(lines.any((line) => line.startsWith('Discount')), isFalse);
  });

  test('a full tax invoice shows the VAT line', () {
    final full = {...bill, 'invoice_title': 'TAX INVOICE', 'show_vat_line': true, 'customer_pan': '601234567'};
    expect(IrdBill.detailLines(full), contains('VAT 13%: Rs 11.50'));
  });

  test('a paid exit at a billing mall waits for the internet; others finish offline', () async {
    const offline = {'error': 'SocketException'};
    await IrdBill.rememberFromLogin({'ird_billing_enabled': true});
    expect(await IrdBill.mustWaitForInternet(offline, 100), isTrue);
    expect(await IrdBill.mustWaitForInternet(offline, 0), isFalse); // free exit: no bill needed
    expect(await IrdBill.mustWaitForInternet({'detail': 'Checkout successful', 'bill': null}, 100), isFalse);

    await IrdBill.rememberFromLogin({'ird_billing_enabled': false});
    expect(await IrdBill.mustWaitForInternet(offline, 100), isFalse); // mall does not bill
  });

  test('reprints and cancelled bills say so', () {
    final copy = {...bill, 'copy_label': 'Copy of Original (1)', 'is_bill_active': false};
    expect(IrdBill.headingLines(copy), containsAllInOrder(['Copy of Original (1)', '*** CANCELLED ***']));
  });

  test('no bill to print when offline or billing is off', () async {
    expect(await IrdBill.billToPrint({'error': 'SocketException'}, 100), isNull);
    expect(IrdBill.isOffline({'error': 'SocketException'}), isTrue);
    expect(IrdBill.isOffline({'error': 'Failed', 'status_code': 400}), isFalse);

    expect(await IrdBill.billToPrint({'detail': 'Checkout successful', 'bill': null}, 100), isNull);
    expect(await IrdBill.isOn(), isFalse);
  });

  test('learns at login whether the mall bills', () async {
    await IrdBill.rememberFromLogin({'ird_billing_enabled': true});
    expect(await IrdBill.isOn(), isTrue);

    await IrdBill.rememberFromLogin({'access': 'token'}); // older server: no answer, no change
    expect(await IrdBill.isOn(), isTrue);

    await IrdBill.rememberFromLogin({'ird_billing_enabled': false});
    expect(await IrdBill.isOn(), isFalse);
  });

  test('remembers billing is on, and a free exit does not change that', () async {
    // The print cannot be recorded in a test, so the checkout's own copy is printed
    final printed = await IrdBill.billToPrint({'bill': bill}, 100);
    expect(printed?['bill_no'], 12);
    expect(await IrdBill.isOn(), isTrue);

    await IrdBill.billToPrint({'bill': null}, 0);
    expect(await IrdBill.isOn(), isTrue);
  });
}

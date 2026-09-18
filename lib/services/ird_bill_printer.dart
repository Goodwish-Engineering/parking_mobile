import 'package:flutter/services.dart';
import 'package:parking/services/ird_bill.dart';

/// Prints IRD bills on the Blue POS printer, in the font sizes of its checkout slips.
class IrdBillPrinter {
  static const _channel = MethodChannel('com.example.test/printer');

  /// Prints the bill the server issued at checkout. Returns false when there is
  /// none (billing off, Rs 0, offline), so the screen prints its usual slip.
  static Future<bool> printIfBilled({
    required Map<String, dynamic> checkoutResponse,
    required double amount,
    required List<String> parkingLines,
  }) async {
    final bill = await IrdBill.billToPrint(checkoutResponse, amount);
    if (bill == null) return false;

    await _channel.invokeMethod('setPrinterPrintAlignment', {'alignment': 1});
    await _channel.invokeMethod('setPrinterPrintFontSize', {'fontSize': 30});
    await _channel.invokeMethod('printText', {
      'text': IrdBill.headingLines(bill).join('\n'),
    });
    await _channel.invokeMethod('printerPerformPrint', {'feedLines': 2});

    await _channel.invokeMethod('setPrinterPrintFontSize', {'fontSize': 25});
    await _channel.invokeMethod('setPrinterPrintAlignment', {'alignment': 0});
    await _channel.invokeMethod('printText', {
      'text': [
        ...IrdBill.detailLines(bill),
        IrdBill.divider,
        ...parkingLines,
      ].join('\n'),
    });
    await _channel.invokeMethod('printerPerformPrint', {'feedLines': 85});
    return true;
  }

  /// Printed under an offline slip when the mall issues IRD bills: the bill is
  /// issued when the checkout is uploaded, so this slip is not a tax invoice.
  static Future<void> printProvisionalNote({
    required Map<String, dynamic> checkoutResponse,
    required double amount,
  }) async {
    if (!IrdBill.isOffline(checkoutResponse) || amount <= 0) return;
    if (!await IrdBill.isOn()) return;
    await _channel.invokeMethod('printerPerformPrint', {'feedLines': 2});
    await _channel.invokeMethod('setPrinterPrintAlignment', {'alignment': 1});
    await _channel.invokeMethod('setPrinterPrintFontSize', {'fontSize': 25});
    await _channel.invokeMethod('printText', {
      'text': IrdBill.provisionalLines.join('\n'),
    });
  }
}

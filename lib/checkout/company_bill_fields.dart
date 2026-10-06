import 'package:flutter/material.dart';

/// What the operator typed for a company that wants a VAT bill (TAX INVOICE).
///
/// Left off, the exit prints an ABBREVIATED TAX INVOICE, which is right for a visitor.
/// Asked at the exit because an issued bill is frozen: a PAN added later would mean
/// cancelling the bill with a credit note and issuing another.
class CompanyBill {
  bool on = false;
  final name = TextEditingController();
  final address = TextEditingController();
  final pan = TextEditingController();

  String get customerName => on ? name.text : '';
  String get customerAddress => on ? address.text : '';
  String get customerPan => on ? pan.text : '';

  /// A new vehicle: start from an empty, unticked box.
  void clear() {
    on = false;
    name.clear();
    address.clear();
    pan.clear();
  }

  void dispose() {
    name.dispose();
    address.dispose();
    pan.dispose();
  }
}

/// The "Company bill (VAT invoice)" tick box and, once ticked, the buyer's details.
class CompanyBillFields extends StatelessWidget {
  final CompanyBill bill;
  final bool enabled;
  final VoidCallback onChanged;

  const CompanyBillFields({
    super.key,
    required this.bill,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: bill.on,
          activeColor: Colors.green,
          title: const Text('Company bill (VAT invoice)', style: TextStyle(fontSize: 14)),
          subtitle: const Text('Only if the customer asks for one', style: TextStyle(fontSize: 11)),
          onChanged: enabled
              ? (checked) {
                  bill.on = checked ?? false;
                  onChanged();
                }
              : null,
        ),
        if (bill.on) ...[
          _field(bill.name, 'Company name'),
          const SizedBox(height: 8),
          _field(bill.address, 'Address'),
          const SizedBox(height: 8),
          _field(bill.pan, 'Company PAN', keyboardType: TextInputType.number),
          if (bill.pan.text.trim().isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'Without the PAN this still prints as an abbreviated invoice, '
                'and the company cannot claim the VAT.',
                style: TextStyle(fontSize: 11, color: Colors.deepOrange),
              ),
            ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    TextInputType keyboardType = TextInputType.text,
  }) {
    return TextField(
      controller: controller,
      enabled: enabled,
      keyboardType: keyboardType,
      style: const TextStyle(fontSize: 14),
      // The warning under the PAN field follows what has been typed so far
      onChanged: (_) => onChanged(),
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}

/// For screens that list several vehicles: asks for the company's details, then how
/// the customer paid. Returns 'CASH' or 'QR', or null if the operator cancelled.
Future<String?> askCompanyBill(BuildContext context, CompanyBill bill) {
  bill.clear();
  bill.on = true;
  return showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Company bill (VAT invoice)'),
        content: SingleChildScrollView(
          child: CompanyBillFields(
            bill: bill,
            enabled: true,
            onChanged: () => setState(() {}),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: bill.on ? () => Navigator.pop(context, 'CASH') : null,
            child: const Text('Cash'),
          ),
          ElevatedButton(
            onPressed: bill.on ? () => Navigator.pop(context, 'QR') : null,
            child: const Text('QR'),
          ),
        ],
      ),
    ),
  );
}

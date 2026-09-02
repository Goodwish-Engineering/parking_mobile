import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:parking/api/checkincheckout.dart';
import 'package:parking/database/helper_class.dart';
import 'package:parking/home/models/vehicleratemodel.dart';
import 'package:parking/models/ticket_model.dart';
import 'package:parking/services/nfc_service.dart';

class VehicleDetailsScreen extends StatefulWidget {
  final VehicleRate vehicleRate;
  final Map<String, String> parkingSlipDetails;

  const VehicleDetailsScreen({
    super.key,
    required this.vehicleRate,
    required this.parkingSlipDetails,
  });

  @override
  State<VehicleDetailsScreen> createState() => _VehicleDetailsScreenState();
}

class _VehicleDetailsScreenState extends State<VehicleDetailsScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  static const platform = MethodChannel('com.example.test/printer');
  final DatabaseHelper _dbHelper = DatabaseHelper();
  final NfcCardService _nfcService = NfcCardService();
  final VehicleService vehicleService = VehicleService();

  final TextEditingController _vcontroller = TextEditingController();
  StreamSubscription<NfcCardResult>? _nfcSubscription;
  bool _isProcessingCheckIn = false;
  bool _isNfcAvailable = false;
  String? _currentPendingPayload;
  String? _currentPendingReceiptId;
  String? _currentPendingCheckInIso;

  String vn = '';
  String rid = '';
  String vt = '';

  late String heading1;
  late String heading2;
  late String heading3;
  late String heading4;
  String? footerText;
  late String firstname;
  late String lastname;
  late String id;

  @override
  void initState() {
    super.initState();
    _initializeData();
    _loadAllData();
    _initNfcListener();
    _vcontroller.addListener(_onVehicleNumberChanged);
  }

  void _initializeData() {
    heading1 = widget.parkingSlipDetails['heading1'] ?? '';
    heading2 = widget.parkingSlipDetails['heading2'] ?? '';
    heading3 = widget.parkingSlipDetails['heading3'] ?? '';
    heading4 = widget.parkingSlipDetails['heading4'] ?? '';
    footerText = widget.parkingSlipDetails['footerText'];
    id = widget.parkingSlipDetails['id'] ?? '';

    String fullName = widget.parkingSlipDetails['full_name'] ?? '';
    List<String> nameParts = fullName.split(' ');
    firstname = nameParts.isNotEmpty ? nameParts[0] : '';
    lastname = nameParts.length > 1 ? nameParts.sublist(1).join(' ') : '';
  }

  void _onVehicleNumberChanged() {
    final vehicleNo = _vcontroller.text.trim();
    if (vehicleNo.isNotEmpty) {
      _currentPendingReceiptId = Ticket.generateReceiptID();
      _currentPendingCheckInIso = DateTime.now().toIso8601String();
      final vt = widget.vehicleRate.vehicleType;
      _currentPendingPayload =
          "$vehicleNo;$vt;$_currentPendingReceiptId;$_currentPendingCheckInIso";
      _nfcService.setPendingWriteData(_currentPendingPayload!);
    } else {
      _currentPendingPayload = null;
      _currentPendingReceiptId = null;
      _currentPendingCheckInIso = null;
      _nfcService.clearPendingWriteData();
    }
  }

  Future<void> _initNfcListener() async {
    _isNfcAvailable = await _nfcService.isNfcAvailable();
    if (mounted) setState(() {});
    await _nfcService.startListening();

    _nfcSubscription = _nfcService.onCardScanned.listen((result) {
      _handleCardScanned(result);
    });
  }

  @override
  void dispose() {
    _vcontroller.removeListener(_onVehicleNumberChanged);
    _nfcSubscription?.cancel();
    _nfcService.clearPendingWriteData();
    _nfcService.stopListening();
    _vcontroller.dispose();
    super.dispose();
  }

  Future<void> _loadAllData() async {
    try {
      await platform.invokeMethod('bindPrinterService');
      await platform.invokeMethod('initializePrinter');
    } catch (_) {}
  }

  String formatDateTime(DateTime dateTime) {
    return '${dateTime.year}-${dateTime.month.toString().padLeft(2, '0')}-${dateTime.day.toString().padLeft(2, '0')} '
        '${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}:${dateTime.second.toString().padLeft(2, '0')}';
  }

  Future<void> _handleCardScanned(NfcCardResult result) async {
    if (_isProcessingCheckIn) return;

    final vehicleNo = _vcontroller.text.trim();
    if (vehicleNo.isEmpty) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('⚠️ Please enter vehicle number first, then tap card.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // 0. Verify that data was successfully written to the physical MIFARE chip
    if (!result.writeSuccess) {
      if (_currentPendingPayload != null) {
        _nfcService.setPendingWriteData(_currentPendingPayload!);
      }
      if (!mounted) return;
      HapticFeedback.vibrate();
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('⚠️ Card write failed! Please hold card firmly and tap again.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() => _isProcessingCheckIn = true);

    try {
      final cardUid = result.cardUid;

      // 1. Auto-reconcile any previous unclosed local session for this returned card (Multi-POS support)
      await _dbHelper.closeOpenSessionForCard(cardUid);

      // 2. Perform Card Check-In
      await _executeCardCheckIn(
        cardUid: cardUid,
        vehicleNo: vehicleNo,
        receiptId: _currentPendingReceiptId ?? Ticket.generateReceiptID(),
        checkInIso: _currentPendingCheckInIso ?? DateTime.now().toIso8601String(),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text('Card check-in failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessingCheckIn = false);
    }
  }

  Future<void> _executeCardCheckIn({
    required String cardUid,
    required String vehicleNo,
    required String receiptId,
    required String checkInIso,
  }) async {
    vn = vehicleNo;
    rid = receiptId;
    vt = widget.vehicleRate.vehicleType;
    final checkInTime = DateTime.tryParse(checkInIso) ?? DateTime.now();
    final ctt = formatDateTime(checkInTime);

    // 1. Save to local SQLite with card_uid
    await _dbHelper.insertCheckInRecord({
      'receipt_id': rid,
      'vehicle_number': vn,
      'vehicle_type': vt,
      'checkin_time': ctt,
      'checkedin_by': id,
      'card_uid': cardUid,
    });

    // 2. Clear input controller
    _vcontroller.clear();

    // 3. Online sync attempt
    try {
      await vehicleService.checkIn(
        receiptId: rid,
        vehicleNumber: vn,
        vehicleType: vt,
        checkinTime: checkInIso,
      );
    } catch (_) {}

    if (!mounted) return;
    HapticFeedback.heavyImpact();

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text('✅ Smart Card Written & Assigned!\nVehicle: $vn | Card: $cardUid'),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 2),
      ),
    );

    Navigator.pop(context);
  }

  Future<void> printtext({required String vehicleType}) async {
    if (_vcontroller.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('Please enter a vehicle number'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _isProcessingCheckIn = true);

    vn = _vcontroller.text.trim();
    rid = Ticket.generateReceiptID();
    vt = vehicleType;
    String ct = DateTime.now().toIso8601String();

    DateTime now = DateTime.now();
    String ctt = formatDateTime(now);
    String formattedDate = "${now.year}/${now.month}/${now.day}";

    String hour = (now.hour % 12 == 0) ? '12' : (now.hour % 12).toString();
    String amPm = now.hour < 12 ? 'AM' : 'PM';
    String formattedTime =
        "$hour:${now.minute.toString().padLeft(2, '0')} $amPm";

    try {
      await platform.invokeMethod('setPrinterPrintAlignment', {'alignment': 1});
      await platform.invokeMethod('printText', {
        'text': '$heading1\n$heading2\n$heading3\n$heading4',
      });
      await platform.invokeMethod('setPrinterPrintFontSize', {'fontSize': 24});
      await platform.invokeMethod('printerPerformPrint', {'feedLines': 2});

      String detailsText =
          'Vehicle Number: $vn\nVehicle Type: $vt\nReceipt ID: $rid\n'
          'Check-in BY: $firstname $lastname\nDate: $formattedDate\n'
          'Time: $formattedTime';

      await platform.invokeMethod('printText', {'text': detailsText});
      await platform.invokeMethod('printerPerformPrint', {'feedLines': 20});

      // Print QR code
      await platform.invokeMethod('printQRCode', {
        'data': '$vn;$vt;$rid;$ct',
        'moduleSize': 12,
        'errorCorrectionLevel': 0,
      });

      await platform.invokeMethod('printerPerformPrint', {'feedLines': 40});

      if (footerText != null && footerText!.isNotEmpty) {
        await platform.invokeMethod('printText', {'text': footerText!});
      }

      await platform.invokeMethod('printerPerformPrint', {'feedLines': 85});

      // Save to local database
      await _dbHelper.insertCheckInRecord({
        'receipt_id': rid,
        'vehicle_number': vn,
        'vehicle_type': vt,
        'checkin_time': ctt,
        'checkedin_by': id,
      });

      _vcontroller.clear();
      try {
        await vehicleService.checkIn(
          receiptId: rid,
          vehicleNumber: vn,
          vehicleType: vt,
          checkinTime: ct,
        );
      } catch (_) {}

      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(
              'An error occurred while printing. Please try again.',
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessingCheckIn = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: const Color(0xFF6E93B3),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            children: [
              const SizedBox(height: 16),
              const Text(
                "Vehicle Check-In",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        widget.vehicleRate.icon != null &&
                                widget.vehicleRate.icon!.isNotEmpty
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: Image.network(
                                  widget.vehicleRate.icon!,
                                  width: 30,
                                  height: 30,
                                  fit: BoxFit.cover,
                                ),
                              )
                            : const Icon(
                                Icons.directions_car,
                                color: Colors.black,
                                size: 30,
                              ),
                        const SizedBox(width: 8),
                        Text(
                          widget.vehicleRate.vehicleType,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF7F7EA),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            "Vehicle Number",
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _vcontroller,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                            decoration: InputDecoration(
                              hintText: "Enter Vehicle No (e.g. 1234)",
                              filled: true,
                              fillColor: Colors.white,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(6),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    // NFC Card Tap Guidance Banner
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.blue.shade200),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.nfc, color: Colors.blue.shade700, size: 28),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _isNfcAvailable
                                      ? "Ready: Tap MIFARE Card on POS"
                                      : "Tap MIFARE Card on POS",
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.blue.shade900,
                                    fontSize: 13,
                                  ),
                                ),
                                Text(
                                  "Enter vehicle number & tap plastic card against POS back",
                                  style: TextStyle(
                                    color: Colors.blue.shade800,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),

                    // Print Slip Button
                    SizedBox(
                      width: double.infinity,
                      height: 60,
                      child: ElevatedButton.icon(
                        onPressed: _isProcessingCheckIn
                            ? null
                            : () => printtext(vehicleType: widget.vehicleRate.vehicleType),
                        icon: const Icon(Icons.print, color: Colors.white),
                        label: const Text(
                          "Print Paper Slip",
                          style: TextStyle(color: Colors.white, fontSize: 18),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF004DE8),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 12),

                    // Cancel Button
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        style: OutlinedButton.styleFrom(
                          backgroundColor: const Color(0xFFDFDFDF),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        child: const Text(
                          "Cancel",
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Colors.black,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

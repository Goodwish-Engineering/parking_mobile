// ignore_for_file: avoid_print
import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:parking/api/checkincheckout.dart';
import 'package:parking/auth/auth_service.dart';
import 'package:parking/database/helper_class.dart';
import 'package:parking/home/models/vehicleratemodel.dart';
import 'package:parking/main.dart';
import 'package:intl/intl.dart';

import 'package:parking/services/nfc_service.dart';

class CheckoutScreen extends StatefulWidget {
  final List<VehicleRate> vehicleRates;
  final Map<String, String> parkingSlipDetails;
  const CheckoutScreen({
    super.key,
    required this.parkingSlipDetails,
    required this.vehicleRates,
  });

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen>
    with WidgetsBindingObserver {
  static const printerChannel = MethodChannel('com.example.test/printer');
  static const scannerChannel = MethodChannel('com.example.test/scanner');

  // State variables
  Map<String, dynamic>? ticketData;
  double? parkingFee;
  bool isLoading = false;
  bool _isProcessingScan = false;
  bool _shouldShowDetails = false;
  bool _alreadyCheckedOut = false;
  String? apiResponseMessage;
  CameraController? _cameraController;
  bool _isCameraInitialized = false;
  final bool _showCamera = true;
  final DatabaseHelper _dbHelper = DatabaseHelper();
  final VehicleService vehicleService = VehicleService();
  final NfcCardService _nfcService = NfcCardService();
  StreamSubscription<NfcCardResult>? _nfcSubscription;
  int freeTime = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeCamera();
    _setupScannerListener();
    _setupNfcListener();
    _initPrinter();
    fetchfreetime();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _nfcSubscription?.cancel();
    _nfcService.stopListening();
    // Do NOT dispose _cameraController here since it's managed by CameraManager
    super.dispose();
  }

  Future<void> fetchfreetime() async {
    final value = await SecureStorage.getFreeTime();

    setState(() {
      freeTime = value;
    });
  }

  Future<void> _initializeCamera() async {
    try {
      // Use pre-initialized camera from CameraManager
      final cameraManager = CameraManager();
      if (cameraManager.isInitialized) {
        _cameraController = cameraManager.controller;
        if (mounted) {
          setState(() => _isCameraInitialized = true);
        }
      } else {
        // Fallback: Initialize camera if not already initialized
        await cameraManager.initialize();
        _cameraController = cameraManager.controller;
        if (mounted) {
          setState(() => _isCameraInitialized = true);
        }
      }
    } catch (e) {
      print("Camera initialization error: $e");
    }
  }

  Future<void> _initPrinter() async {
    try {
      await printerChannel.invokeMethod('bindPrinterService');
      await printerChannel.invokeMethod('initializePrinter');
    } catch (e) {
      print('Printer initialization error: $e');
    }
  }

  void _setupScannerListener() {
    scannerChannel.setMethodCallHandler((call) async {
      if (call.method == "onScanData") {
        final scanData = call.arguments as String;
        if (scanData.isNotEmpty) {
          _processScanData(scanData);
        }
      }
      return null;
    });

    scannerChannel.invokeMethod('startScanner');
  }

  void _setupNfcListener() {
    _nfcService.startListening();
    _nfcSubscription = _nfcService.onCardScanned.listen((result) {
      _processCardScan(result);
    });
  }

  Future<void> _processCardScan(NfcCardResult result) async {
    if (_isProcessingScan) return;

    setState(() {
      _isProcessingScan = true;
      apiResponseMessage = null;
    });

    try {
      final cardUid = result.cardUid;
      final rawTicket = result.ticketData;
      Map<String, dynamic>? parsedData;

      // 1. PRIMARY (100% OFFLINE MULTI-POS): Read directly from Card internal chip!
      if (rawTicket.isNotEmpty && rawTicket.contains(';')) {
        parsedData = _parseQRCode(rawTicket);
        if (parsedData != null) {
          parsedData['cardUid'] = cardUid;
        }
      }

      // 2. SECONDARY: Look up in local SQLite for active card checkin
      if (parsedData == null) {
        final record = await _dbHelper.getRecordByCardUid(cardUid);
        if (record != null) {
          final checkInTimeStr = record['checkin_time']?.toString() ?? '';
          final checkInTime =
              DateTime.tryParse(checkInTimeStr) ?? DateTime.now();

          parsedData = {
            'vehicleNumber': record['vehicle_number']?.toString() ?? '',
            'vehicleType': record['vehicle_type']?.toString() ?? '',
            'receiptID': record['receipt_id']?.toString() ?? '',
            'checkInTime': checkInTime,
            'cardUid': cardUid,
          };
        }
      }

      // 3. TERTIARY: Search online backend if not found locally
      if (parsedData == null) {
        try {
          final searchResults =
              await vehicleService.searchVehicle(query: cardUid);
          if (searchResults.isNotEmpty) {
            final s = searchResults[0];
            final checkInTimeStr = s['checkin_time']?.toString() ?? '';
            final checkInTime =
                DateTime.tryParse(checkInTimeStr) ?? DateTime.now();

            parsedData = {
              'vehicleNumber': s['vehicle_number']?.toString() ?? '',
              'vehicleType': s['vehicle_type']?.toString() ?? '',
              'receiptID': s['receipt_id']?.toString() ?? '',
              'checkInTime': checkInTime,
              'cardUid': cardUid,
            };
            _alreadyCheckedOut = s['checkout_status'] == true;
          }
        } catch (_) {}
      }

      if (parsedData != null) {
        setState(() {
          ticketData = parsedData;
          parkingFee = calculateParkingFee(parsedData!)?.toDouble();
          _shouldShowDetails = true;
          _alreadyCheckedOut = false;
        });
        HapticFeedback.heavyImpact();
        return;
      }

      // If not found anywhere
      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('❌ No active parking session found for Card $cardUid'),
          backgroundColor: Colors.red,
        ),
      );
    } catch (e) {
      print('Card checkout error: $e');
    } finally {
      if (mounted) setState(() => _isProcessingScan = false);
    }
  }

  Future<void> _processScanData(String scanData) async {
    if (_isProcessingScan) return;

    setState(() {
      _isProcessingScan = true;
      apiResponseMessage = null;
    });

    try {
      final parsedData = _parseQRCode(scanData);
      if (parsedData == null) {
        setState(() {
          apiResponseMessage = 'Invalid QR Code format';
          _shouldShowDetails = false;
        });
        return;
      }

      setState(() {
        ticketData = parsedData;
        parkingFee = calculateParkingFee(parsedData)?.toDouble();
        _shouldShowDetails = true;
        _alreadyCheckedOut = false;
      });
    } catch (e) {
      print('Scan processing error: $e');
      setState(() {
        apiResponseMessage = 'Error processing QR code: ${e.toString()}';
        _shouldShowDetails = false;
      });
    } finally {
      setState(() {
        _isProcessingScan = false;
      });
    }
  }

  Map<String, dynamic>? _parseQRCode(String data) {
    try {
      final parts = data.split(';').map((part) => part.trim()).toList();
      if (parts.length < 4) throw Exception("Invalid QR format");

      return {
        'vehicleNumber': parts[0],
        'vehicleType': parts[1],
        'receiptID': parts[2],
        'checkInTime': DateTime.parse(parts[3]),
      };
    } catch (e) {
      print("QR parsing error: $e");
      return null;
    }
  }

  double? calculateParkingFee(Map<String, dynamic> data) {
    try {
      final checkInTime = data['checkInTime'] as DateTime;
      final vehicleType = data['vehicleType'] as String;
      final now = DateTime.now();
      final duration = now.difference(checkInTime).inMinutes;

      // Find matching vehicle rate from the passed vehicleRates list
      final vehicleRate = widget.vehicleRates.firstWhere(
        (v) => v.vehicleType == vehicleType,
        orElse: () => throw Exception('Vehicle type not found'),
      );
      final useSimpleRateStructure = vehicleRate.quarterHourlyRate == 0;

      if (useSimpleRateStructure) {
        final hourlyRate = vehicleRate.hourlyRate;
        final halfHourlyRate = vehicleRate.halfHourlyRate;

        if (duration <= freeTime) {
          return 0.0;
        } else if (duration <= 30) {
          return halfHourlyRate;
        } else if (duration <= 60) {
          return hourlyRate;
        } else {
          int intervals = (duration / 30).ceil();
          return ((intervals ~/ 2) * hourlyRate +
              (intervals % 2) * halfHourlyRate);
        }
      } else {
        final quarterHourlyRate = vehicleRate.quarterHourlyRate;
        final halfHourlyRate = vehicleRate.halfHourlyRate;
        final hourlyRate = vehicleRate.hourlyRate;

        if (duration <= freeTime) {
          return 0.0;
        }

        // Number of completed hours
        final completedHours = duration ~/ 60;

        // Remaining minutes after full hours
        final remainingMinutes = duration % 60;

        double total = 0;

        // Base hourly charge
        if (remainingMinutes == 0) {
          total = completedHours * hourlyRate;
        } else {
          total = (completedHours + 1) * hourlyRate;
        }

        // Adjust slab pricing
        if (remainingMinutes > 0 && remainingMinutes <= 15) {
          total = (completedHours * hourlyRate) + quarterHourlyRate;
        } else if (remainingMinutes > 15 && remainingMinutes <= 30) {
          total = (completedHours * hourlyRate) + halfHourlyRate;
        } else if (remainingMinutes > 30) {
          total = (completedHours + 1) * hourlyRate;
        }

        // Minimum 1 hour charge
        if (total < hourlyRate) {
          total = hourlyRate;
        }

        return total;
      }
    } catch (e) {
      print('Error calculating parking fee: $e');
      return null;
    }
  }

  Future<void> handleCheckoutAndPrint({required String paymentMethod}) async {
    if (ticketData == null || parkingFee == null) return;
    if (_alreadyCheckedOut) return;

    setState(() => isLoading = true);

    try {
      final id = widget.parkingSlipDetails['id'] ?? '';
      final checkoutTime = DateTime.now();
      final receiptId = ticketData!['receiptID'];
      final vehicleNumber = ticketData!['vehicleNumber'];
      final vehicleType = ticketData!['vehicleType'];
      final checkInTime = ticketData!['checkInTime'] as DateTime;
      final amount = parkingFee!;

      // 1) Ask the backend to check out FIRST. The server rejects an already
      //    checked-out receipt ("Vehicle already checked out"), so we never
      //    print a duplicate bill or record a duplicate for a closed receipt.
      //    VehicleService.checkOut() returns the decoded body on success, a
      //    map WITH 'status_code' on an HTTP error, and a map with only
      //    'error' (no 'status_code') on a network failure (offline).
      final response = await vehicleService.checkOut(
        receiptId: receiptId,
        vehicleNumber: vehicleNumber,
        vehicleType: vehicleType,
        checkoutTime: checkoutTime.toString(),
        amount: amount,
        paymentMethod: paymentMethod,
      );
      print('Checkout response: $response');

      final bool serverRejected = response.containsKey('status_code');
      if (serverRejected) {
        final body = (response['response_body'] ?? '').toString().toLowerCase();
        final bool alreadyOut = body.contains('already checked out');
        if (!mounted) return;
        if (alreadyOut) setState(() => _alreadyCheckedOut = true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              alreadyOut
                  ? 'This receipt is already checked out — cannot check out again.'
                  : 'Checkout was rejected by the server. Please retry.',
            ),
            backgroundColor: alreadyOut ? Colors.orange : Colors.red,
          ),
        );
        return; // do NOT print or record a duplicate
      }

      // 2) Success (2xx) OR offline (network error) -> finalize locally.
      //    Offline-first: when the server is unreachable we still print and
      //    record, and the CSV sync reconciles later.
      await _printReceipt(
        vehicleNumber: vehicleNumber,
        vehicleType: vehicleType,
        receiptId: receiptId,
        checkInTime: checkInTime,
        checkoutTime: checkoutTime,
        amount: amount,
        paymentMethod: paymentMethod,
      );

      await _dbHelper.updateCheckOutRecord({
        'checkedout_by': id,
        'receipt_id': receiptId,
        'vehicle_number': vehicleNumber,
        'vehicle_type': vehicleType,
        'checkout_time': checkoutTime.toString(),
        'amount': amount,
        'checkin_time': checkInTime.toString(),
        'duration': '${checkoutTime.difference(checkInTime).inMinutes} mins',
        'payment_method': paymentMethod,
      });

      if (ticketData?['cardUid'] != null) {
        await _nfcService.prepareClearCard();
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Checkout successful — '
            '${paymentMethod == 'QR' ? 'QR' : 'Cash'} '
            'Rs. ${amount.toStringAsFixed(0)}',
          ),
          backgroundColor: Colors.green,
        ),
      );

      gotoHome();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Checkout failed: ${e.toString()}'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<void> _printReceipt({
    required String vehicleNumber,
    required String vehicleType,
    required String receiptId,
    required DateTime checkInTime,
    required DateTime checkoutTime,
    required double amount,
    required String paymentMethod,
  }) async {
    try {
      // Get heading details from parkingSlipDetails
      final heading1 = widget.parkingSlipDetails['heading1'] ?? '';
      final heading2 = widget.parkingSlipDetails['heading2'] ?? '';
      final heading3 = widget.parkingSlipDetails['heading3'] ?? '';
      final heading4 = widget.parkingSlipDetails['heading4'] ?? '';
      final fullName = widget.parkingSlipDetails['full_name'] ?? 'Operator';

      await printerChannel.invokeMethod('setPrinterPrintAlignment', {
        'alignment': 1,
      });
      await printerChannel.invokeMethod('setPrinterPrintFontSize', {
        'fontSize': 35,
      });
      await printerChannel.invokeMethod('printText', {
        'text': '$heading1\n$heading2\n$heading3\n$heading4',
      });
      await printerChannel.invokeMethod('printerPerformPrint', {
        'feedLines': 2,
      });

      await printerChannel.invokeMethod('setPrinterPrintFontSize', {
        'fontSize': 25,
      });
      await printerChannel.invokeMethod('printText', {
        'text':
            '''
Vehicle Number: $vehicleNumber
Vehicle Type: $vehicleType
Receipt ID: $receiptId
Check-out BY: $fullName
Check-in: ${DateFormat('yyyy/MM/dd HH:mm').format(checkInTime)}
Check-out: ${DateFormat('yyyy/MM/dd HH:mm').format(checkoutTime)}
Duration: ${checkoutTime.difference(checkInTime).inHours}h ${checkoutTime.difference(checkInTime).inMinutes.remainder(60)}m
Paid by: ${paymentMethod == 'QR' ? 'QR' : 'Cash'}
''',
      });

      await printerChannel.invokeMethod('printerPerformPrint', {
        'feedLines': 1,
      });
      await printerChannel.invokeMethod('setPrinterPrintFontSize', {
        'fontSize': 80,
      });
      await printerChannel.invokeMethod('printText', {
        'text': 'Total: Rs $amount',
      });
      await printerChannel.invokeMethod('printerPerformPrint', {
        'feedLines': 85,
      });
    } catch (e) {
      print('Printing error: $e');
      throw Exception('Printing failed');
    }
  }

  void gotoHome() {
    // Return to the AppShell (which draws the top nav bar) instead of pushing
    // a bare Homepage with no header. CheckoutScreen was pushed on top of the
    // AppShell, so popping back to the first route restores the nav bar.
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Exit Parking")),
      body: Stack(
        children: [
          // Camera preview (behind other content)
          if (_showCamera && _isCameraInitialized && _cameraController != null)
            Positioned.fill(child: CameraPreview(_cameraController!)),

          // Semi-transparent overlay with alignment frame
          if (_showCamera)
            Positioned.fill(
              child: Container(
                color: Colors.black.withValues(alpha: 0.3),
                child: Column(
                  children: [
                    SizedBox(height: 20),
                    Container(
                      width: 260,
                      height: 260,
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.white, width: 2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Center(
                        child: Text(
                          'Scan QR Ticket\n— OR —\nTap Smart Card',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Your existing content
          Column(
            children: [
              // Scanner status
              if (_isProcessingScan) LinearProgressIndicator(),

              // Main content
              Expanded(
                child: Center(
                  child: _shouldShowDetails && ticketData != null
                      ? _buildTicketDetails()
                      : Container(), // Empty container when no details to show
                ),
              ),

              // Already-checked-out banner (read-only — no checkout allowed)
              if (_shouldShowDetails &&
                  ticketData != null &&
                  _alreadyCheckedOut)
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.95),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.info_outline, color: Colors.white),
                        SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'Already checked out — view only',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              // Payment method buttons (hidden once already checked out)
              if (_shouldShowDetails &&
                  ticketData != null &&
                  !_alreadyCheckedOut)
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Tap how the customer paid',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 14, color: Colors.white70),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: SizedBox(
                              height: 70,
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.green,
                                  disabledBackgroundColor: Colors.green
                                      .withValues(alpha: 0.5),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                                icon: isLoading
                                    ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          color: Colors.white,
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(
                                        Icons.payments,
                                        color: Colors.white,
                                      ),
                                label: const Text(
                                  'CASH',
                                  style: TextStyle(
                                    fontSize: 20,
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                onPressed: isLoading
                                    ? null
                                    : () => handleCheckoutAndPrint(
                                        paymentMethod: 'CASH',
                                      ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: SizedBox(
                              height: 70,
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF004DE8),
                                  disabledBackgroundColor: const Color(
                                    0xFF004DE8,
                                  ).withValues(alpha: 0.5),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                                icon: isLoading
                                    ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          color: Colors.white,
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(
                                        Icons.qr_code,
                                        color: Colors.white,
                                      ),
                                label: const Text(
                                  'QR',
                                  style: TextStyle(
                                    fontSize: 20,
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                onPressed: isLoading
                                    ? null
                                    : () => handleCheckoutAndPrint(
                                        paymentMethod: 'QR',
                                      ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTicketDetails() {
    final checkInTime = ticketData!['checkInTime'] as DateTime;
    final duration = DateTime.now().difference(checkInTime);

    return SingleChildScrollView(
      padding: EdgeInsets.all(16),
      child: Card(
        elevation: 4,
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Parking Receipt',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              Divider(),
              _buildDetailRow('Vehicle Number:', ticketData!['vehicleNumber']),
              _buildDetailRow('Vehicle Type:', ticketData!['vehicleType']),
              _buildDetailRow('Receipt ID:', ticketData!['receiptID']),
              _buildDetailRow(
                'Check-in Time:',
                DateFormat('MMM dd, yyyy HH:mm').format(checkInTime),
              ),
              _buildDetailRow(
                'Duration:',
                '${duration.inHours}h ${duration.inMinutes.remainder(60)}m',
              ),
              Divider(),
              Text(
                'Total Fee: Rs. ${parkingFee?.toStringAsFixed(2) ?? '0.00'}',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Text(label, style: TextStyle(fontWeight: FontWeight.bold)),
          SizedBox(width: 8),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

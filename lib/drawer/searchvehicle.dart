// ignore_for_file: avoid_print, unused_field
import 'package:parking/services/fee_plan.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:parking/api/checkincheckout.dart';
import 'package:parking/auth/api_endpoints.dart';
import 'package:parking/auth/auth_service.dart';
import 'package:parking/database/helper_class.dart';
import 'package:parking/home/models/vehicleratemodel.dart';
import 'package:parking/services/ird_bill_printer.dart';

class SearchLostVehicleScreen extends StatefulWidget {
  const SearchLostVehicleScreen({super.key});

  @override
  State<SearchLostVehicleScreen> createState() =>
      _SearchLostVehicleScreenState();
}

class _SearchLostVehicleScreenState extends State<SearchLostVehicleScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  static const _channel = MethodChannel('com.example.test/printer');
  final DatabaseHelper _dbHelper = DatabaseHelper();
  final VehicleService vehicleService = VehicleService();

  final TextEditingController _vehicleNumberController =
      TextEditingController();
  List<dynamic> _searchResults = [];
  bool _isLoading = false;
  bool _isOffline = false;
  bool _isCheckingOut = false;
  String _selectedFilter = 'ALL'; // ALL | PARKED | CHECKED_OUT
  int freeTime = 0;

  List<VehicleRate> vehicleRates = [];
  Map<String, String> parkingSlipDetails = {};

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  @override
  void dispose() {
    _vehicleNumberController.dispose();
    super.dispose();
  }

  Future<void> _loadInitialData() async {
    try {
      final slip = await SecureStorage.getParkingSlipDetails();
      final ft = await SecureStorage.getFreeTime();
      final rawRates = await SecureStorage.getParkingRates();
      final rates = <VehicleRate>[];
      for (final item in rawRates) {
        try {
          rates.add(VehicleRate.fromJson(item));
        } catch (_) {}
      }

      if (mounted) {
        setState(() {
          parkingSlipDetails = slip;
          freeTime = ft;
          vehicleRates = rates;
        });
      }
    } catch (e) {
      debugPrint("Error loading search initial data: $e");
    }
  }

  /// The price so far, from the vehicle type's fee plan (the same one checkout uses).
  double? calculateParkingFee(Map<String, dynamic> data) {
    try {
      final checkInTimeStr = data['checkin_time'] ?? data['checkInTime'];
      if (checkInTimeStr == null) return null;

      final checkInTime = checkInTimeStr is DateTime
          ? checkInTimeStr
          : DateTime.parse(checkInTimeStr.toString());

      final vehicleType = data['vehicle_type']?.toString() ?? '';
      final vehicleRate = vehicleRates.firstWhere(
        (v) => v.vehicleType.toLowerCase() == vehicleType.toLowerCase(),
        orElse: () => throw Exception('Vehicle type not found'),
      );
      return vehicleRate
          .plan(freeTime: freeTime)
          .fee(FeePlan.stayMinutes(checkInTime, DateTime.now()));
    } catch (_) {
      return null;
    }
  }

  Future<void> _searchVehicle() async {
    FocusScope.of(context).unfocus();
    final query = _vehicleNumberController.text.trim();
    if (query.isEmpty) return;

    setState(() {
      _isLoading = true;
      _searchResults = [];
    });

    try {
      await _searchVehicleOnline(query);
      if (mounted) setState(() => _isOffline = false);
    } catch (e) {
      debugPrint('Online search failed, trying offline: $e');
      try {
        await _searchVehicleOffline(query);
        if (mounted) setState(() => _isOffline = true);
      } catch (offlineErr) {
        if (mounted) {
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              behavior: SnackBarBehavior.floating,
              content: Text('No matching records found online or locally.'),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _searchVehicleOnline(String query) async {
    final token = await SecureStorage.getAccessToken();
    final response = await http
        .get(
          Uri.parse(
            '${ApiEndpoints.baseUrl}parkinginfo/parking-details/search-vehicle/?query=$query',
          ),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
        )
        .timeout(const Duration(seconds: 8));

    if (response.statusCode == 200 || response.statusCode == 201) {
      final data = json.decode(response.body);
      if (data is List && data.isNotEmpty) {
        setState(() {
          _searchResults = data.map((v) {
            final m = Map<String, dynamic>.from(v);
            m['checkout_status'] =
                m['checkout_status'] == true || m['checkout_time'] != null;
            return m;
          }).toList();
        });
      } else {
        throw Exception('No results');
      }
    } else {
      throw Exception('Server error: ${response.statusCode}');
    }
  }

  Future<void> _searchVehicleOffline(String query) async {
    final localResults = await _dbHelper.searchVehicleLocally(query);
    if (localResults.isEmpty) {
      throw Exception('No local records found');
    }
    setState(() {
      _searchResults = localResults.map((record) {
        return {
          'receipt_id': record['receipt_id'],
          'vehicle_number': record['vehicle_number'],
          'vehicle_type': record['vehicle_type'],
          'checkin_time': record['checkin_time'],
          'checkout_time': record['checkout_time'],
          'checkout_status': record['checkout_time'] != null,
          'checkedin_by': record['checkedin_by'],
          'amount': record['amount'],
          'payment_method': record['payment_method'],
        };
      }).toList();
    });
  }

  String formatDateTime(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }

  Future<void> handleCheckoutAndPrint({
    required Map<String, dynamic> item,
    required String paymentMethod,
  }) async {
    final fee = calculateParkingFee(item);
    if (fee == null) return;

    setState(() => _isCheckingOut = true);

    try {
      final heading1 = parkingSlipDetails['heading1'] ?? '';
      final heading2 = parkingSlipDetails['heading2'] ?? '';
      final heading3 = parkingSlipDetails['heading3'] ?? '';
      final heading4 = parkingSlipDetails['heading4'] ?? '';
      final footerText = parkingSlipDetails['footerText'];
      final fullName = parkingSlipDetails['full_name'] ?? 'Operator';
      final opId = parkingSlipDetails['id'] ?? '';
      final now = DateTime.now();
      final ctt = formatDateTime(now);

      final rId = item['receipt_id']?.toString() ?? '';
      final vNo = item['vehicle_number']?.toString() ?? '';
      final vType = item['vehicle_type']?.toString() ?? '';
      final cIn =
          DateTime.tryParse(item['checkin_time']?.toString() ?? '') ?? now;

      final diff = now.difference(cIn);
      final duration = '${diff.inHours}h ${diff.inMinutes.remainder(60)}m';

      // 1. Check out on the server first (same as the card screen): it rejects
      //    receipts that are already checked out, so no duplicate is printed,
      //    and it returns the IRD bill. Offline (no status_code) still
      //    completes locally and is uploaded later.
      final response = await vehicleService.checkOut(
        receiptId: rId,
        vehicleNumber: vNo,
        vehicleType: vType,
        checkoutTime: now.toIso8601String(),
        amount: fee,
        paymentMethod: paymentMethod,
      );
      if (response.containsKey('status_code')) {
        final body = (response['response_body'] ?? '').toString().toLowerCase();
        final alreadyOut = body.contains('already checked out');
        if (!mounted) return;
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(
              alreadyOut
                  ? 'This receipt is already checked out.'
                  : 'Checkout was rejected by server. Please retry.',
            ),
            backgroundColor: alreadyOut ? Colors.orange : Colors.red,
          ),
        );
        if (alreadyOut) _searchVehicle();
        return;
      }

      // 2. Print the IRD bill, or the usual slip when there is none
      try {
        final billed = await IrdBillPrinter.printIfBilled(
          checkoutResponse: response,
          amount: fee,
          parkingLines: [
            'Vehicle Number: $vNo',
            'Vehicle Type: $vType',
            'Receipt ID: $rId',
            'Check-out BY: $fullName',
            'Check-in: ${formatDateTime(cIn)}',
            'Check-out: $ctt',
            'Duration: $duration',
          ],
        );
        if (!billed) {
          await _channel.invokeMethod('setPrinterPrintFontSize', {'fontSize': 35});
          await _channel.invokeMethod('setPrinterPrintAlignment', {'alignment': 1});
          await _channel.invokeMethod('printText', {'text': '$heading1\n$heading2\n$heading3\n$heading4'});
          await _channel.invokeMethod('printerPerformPrint', {'feedLines': 20});

          await _channel.invokeMethod('setPrinterPrintFontSize', {'fontSize': 25});
          await _channel.invokeMethod('setPrinterPrintAlignment', {'alignment': 0});
          await _channel.invokeMethod('printText', {
            'text': 'Vehicle Number: $vNo\n'
                'Vehicle Type: $vType\n'
                'Receipt ID: $rId\n'
                'Check-out BY: $fullName\n'
                'Check-in: ${formatDateTime(cIn)}\n'
                'Check-out: $ctt\n'
                'Duration: $duration\n'
                'Paid by: ${paymentMethod == 'QR' ? 'QR' : 'Cash'}',
          });
          await _channel.invokeMethod('printerPerformPrint', {'feedLines': 20});

          await _channel.invokeMethod('setPrinterPrintFontSize', {'fontSize': 35});
          await _channel.invokeMethod('setPrinterPrintAlignment', {'alignment': 1});
          await _channel.invokeMethod('printText', {'text': 'Total Fee: Rs. ${fee.toStringAsFixed(0)}'});
          if (footerText != null && footerText.isNotEmpty) {
            await _channel.invokeMethod('printerPerformPrint', {'feedLines': 10});
            await _channel.invokeMethod('setPrinterPrintFontSize', {'fontSize': 22});
            await _channel.invokeMethod('printText', {'text': footerText});
          }
          await IrdBillPrinter.printProvisionalNote(
            checkoutResponse: response,
            amount: fee,
          );
          await _channel.invokeMethod('printerPerformPrint', {'feedLines': 80});
        }
      } catch (printErr) {
        debugPrint("Printing failed: $printErr");
      }

      // 3. Save in local database
      await _dbHelper.updateCheckOutRecord({
        'receipt_id': rId,
        'vehicle_number': vNo,
        'vehicle_type': vType,
        'checkin_time': formatDateTime(cIn),
        'checkout_time': ctt,
        'amount': fee,
        'duration': duration,
        'checkedout_by': opId,
        'payment_method': paymentMethod,
      });


      if (!mounted) return;
      HapticFeedback.heavyImpact();

      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.green,
          content: Text(
            '✅ Checkout Successful: $vNo | ${paymentMethod == 'QR' ? 'QR' : 'Cash'} Rs. ${fee.toStringAsFixed(0)}',
          ),
          duration: const Duration(seconds: 2),
        ),
      );

      // Refresh search list
      _searchVehicle();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text('Checkout failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isCheckingOut = false);
    }
  }

  List<dynamic> get _filteredResults {
    if (_selectedFilter == 'PARKED') {
      return _searchResults.where((v) => v['checkout_status'] != true).toList();
    } else if (_selectedFilter == 'CHECKED_OUT') {
      return _searchResults.where((v) => v['checkout_status'] == true).toList();
    }
    return _searchResults;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: const Color(0xFF6E93B3),
      body: SafeArea(
        child: Column(
          children: [
            // Search Input Header Card
            Container(
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black12,
                    blurRadius: 6,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _vehicleNumberController,
                          decoration: InputDecoration(
                            hintText: "Enter vehicle number (e.g. 1234)",
                            prefixIcon: const Icon(Icons.search, color: Colors.black54),
                            filled: true,
                            fillColor: const Color(0xFFF0F4F8),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide.none,
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 12,
                            ),
                          ),
                          onSubmitted: (_) => _searchVehicle(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        height: 48,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF004DE8),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          onPressed: _isLoading ? null : _searchVehicle,
                          child: _isLoading
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text(
                                  "Search",
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                        ),
                      ),
                    ],
                  ),

                  if (_searchResults.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        _filterChip("ALL (${_searchResults.length})", 'ALL'),
                        const SizedBox(width: 6),
                        _filterChip(
                          "PARKED (${_searchResults.where((v) => v['checkout_status'] != true).length})",
                          'PARKED',
                        ),
                        const SizedBox(width: 6),
                        _filterChip(
                          "EXITED (${_searchResults.where((v) => v['checkout_status'] == true).length})",
                          'CHECKED_OUT',
                        ),
                        const Spacer(),
                        if (_isOffline)
                          const Text(
                            "📴 Local Results",
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: Colors.orange,
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),

            // Search Results List
            Expanded(
              child: _searchResults.isEmpty && !_isLoading
                  ? const Center(
                      child: Text(
                        "Enter a vehicle number or plate to search",
                        style: TextStyle(color: Colors.white, fontSize: 14),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      itemCount: _filteredResults.length,
                      itemBuilder: (context, index) {
                        final vehicle = _filteredResults[index];
                        final isCheckedOut = vehicle['checkout_status'] == true;
                        final fee = calculateParkingFee(vehicle);

                        return Card(
                          margin: const EdgeInsets.symmetric(vertical: 5),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          elevation: 2,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF090044),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        vehicle['vehicle_number']?.toString() ?? '',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 15,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      vehicle['vehicle_type']?.toString() ?? '',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        color: Colors.grey.shade700,
                                      ),
                                    ),
                                    const Spacer(),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isCheckedOut
                                            ? Colors.grey.shade200
                                            : Colors.green.shade100,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        isCheckedOut ? "CHECKED OUT" : "PARKED INSIDE",
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: isCheckedOut
                                              ? Colors.grey.shade800
                                              : Colors.green.shade900,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  "Check-in: ${vehicle['checkin_time'] ?? ''}",
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade600,
                                  ),
                                ),
                                if (vehicle['receipt_id'] != null)
                                  Text(
                                    "Receipt ID: ${vehicle['receipt_id']}",
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey.shade500,
                                    ),
                                  ),
                                const Divider(height: 16),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      isCheckedOut
                                          ? "Amount: Rs. ${vehicle['amount'] ?? '0'}"
                                          : "Fee Due: Rs. ${fee?.toStringAsFixed(0) ?? '0'}",
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        color: isCheckedOut
                                            ? Colors.grey.shade800
                                            : Colors.green.shade800,
                                      ),
                                    ),
                                    if (!isCheckedOut && fee != null)
                                      Row(
                                        children: [
                                          ElevatedButton.icon(
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: Colors.green.shade800,
                                              padding: const EdgeInsets.symmetric(
                                                horizontal: 10,
                                                vertical: 6,
                                              ),
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                              ),
                                            ),
                                            icon: const Icon(
                                              Icons.payments,
                                              size: 15,
                                              color: Colors.white,
                                            ),
                                            label: const Text(
                                              "CASH",
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.bold,
                                                fontSize: 12,
                                              ),
                                            ),
                                            onPressed: _isCheckingOut
                                                ? null
                                                : () => handleCheckoutAndPrint(
                                                      item: vehicle,
                                                      paymentMethod: 'CASH',
                                                    ),
                                          ),
                                          const SizedBox(width: 6),
                                          ElevatedButton.icon(
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: const Color(0xFF004DE8),
                                              padding: const EdgeInsets.symmetric(
                                                horizontal: 10,
                                                vertical: 6,
                                              ),
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                              ),
                                            ),
                                            icon: const Icon(
                                              Icons.qr_code,
                                              size: 15,
                                              color: Colors.white,
                                            ),
                                            label: const Text(
                                              "QR",
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.bold,
                                                fontSize: 12,
                                              ),
                                            ),
                                            onPressed: _isCheckingOut
                                                ? null
                                                : () => handleCheckoutAndPrint(
                                                      item: vehicle,
                                                      paymentMethod: 'QR',
                                                    ),
                                          ),
                                        ],
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _filterChip(String label, String value) {
    final isSelected = _selectedFilter == value;
    return InkWell(
      onTap: () => setState(() => _selectedFilter = value),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF090044) : Colors.grey.shade200,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: isSelected ? Colors.white : Colors.black87,
          ),
        ),
      ),
    );
  }
}

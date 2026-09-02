import 'dart:async';
import 'package:flutter/services.dart';

class NfcCardResult {
  final String cardUid;
  final String ticketData;
  final bool writeSuccess;

  NfcCardResult({
    required this.cardUid,
    required this.ticketData,
    required this.writeSuccess,
  });

  factory NfcCardResult.fromMap(Map<dynamic, dynamic> map) {
    return NfcCardResult(
      cardUid: map['cardUid']?.toString().trim() ?? '',
      ticketData: map['ticketData']?.toString().trim() ?? '',
      writeSuccess: map['writeSuccess'] == true,
    );
  }
}

class NfcCardService {
  static final NfcCardService _instance = NfcCardService._internal();
  static const MethodChannel _nfcChannel = MethodChannel('com.example.test/nfc');

  final StreamController<NfcCardResult> _cardScanStreamController =
      StreamController<NfcCardResult>.broadcast();

  Stream<NfcCardResult> get onCardScanned =>
      _cardScanStreamController.stream;

  factory NfcCardService() => _instance;

  NfcCardService._internal() {
    _nfcChannel.setMethodCallHandler((call) async {
      if (call.method == 'onCardScanned') {
        if (call.arguments is Map) {
          final result = NfcCardResult.fromMap(call.arguments as Map);
          _cardScanStreamController.add(result);
        } else if (call.arguments is String) {
          final uid = call.arguments.toString().trim();
          _cardScanStreamController.add(
            NfcCardResult(cardUid: uid, ticketData: '', writeSuccess: false),
          );
        }
      }
      return null;
    });
  }

  Future<bool> isNfcAvailable() async {
    try {
      final available = await _nfcChannel.invokeMethod<bool>('isNfcAvailable');
      return available ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> startListening() async {
    try {
      await _nfcChannel.invokeMethod('startNfcListener');
    } catch (_) {}
  }

  Future<void> stopListening() async {
    try {
      await _nfcChannel.invokeMethod('stopNfcListener');
    } catch (_) {}
  }

  Future<void> setPendingWriteData(String data) async {
    try {
      await _nfcChannel.invokeMethod('setPendingWriteData', {'data': data});
    } catch (_) {}
  }

  Future<void> clearPendingWriteData() async {
    try {
      await _nfcChannel.invokeMethod('clearPendingWriteData');
    } catch (_) {}
  }


  void dispose() {
    _cardScanStreamController.close();
  }
}

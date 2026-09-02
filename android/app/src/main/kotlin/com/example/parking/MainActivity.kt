package com.example.parking

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.ServiceConnection
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.MifareClassic
import android.os.Bundle
import android.os.IBinder
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.iposprinter.iposprinterservice.IPosPrinterService
import com.iposprinter.iposprinterservice.IPosPrinterCallback

class MainActivity : FlutterActivity(), NfcAdapter.ReaderCallback {
    private val CHANNEL = "com.example.test/printer"
    private val SCANNER_CHANNEL = "com.example.test/scanner"
    private val NFC_CHANNEL = "com.example.test/nfc"

    private var mIPosPrinterService: IPosPrinterService? = null
    private var nfcAdapter: NfcAdapter? = null
    private var isNfcListening = false

    @Volatile
    private var pendingWriteData: String? = null


    // Printer callback
    private val printerCallback = object : IPosPrinterCallback.Stub() {
        override fun onRunResult(isSuccess: Boolean) {
            println("onRunResult: $isSuccess")
        }

        override fun onReturnString(result: String?) {
            println("onReturnString: $result")
        }
    }

    // Printer service connection
    private val printerServiceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            mIPosPrinterService = IPosPrinterService.Stub.asInterface(service)
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            mIPosPrinterService = null
        }
    }

    // Scanner broadcast receiver
    private val scannerBroadcastReceiver: BroadcastReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == "com.android.scanservice.scan.broadcast" || 
                intent.action == "com.android.action.GETDATA_FROM_UART") {
                val scanData = intent.getStringExtra("scan_data") 
                          ?: intent.getStringExtra("data") 
                          ?: intent.getStringExtra("uart_data")
                
                if (!scanData.isNullOrEmpty()) {
                    flutterEngine?.dartExecutor?.binaryMessenger?.let { messenger ->
                        MethodChannel(messenger, SCANNER_CHANNEL)
                            .invokeMethod("onScanData", scanData.trim())
                    }
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        nfcAdapter = NfcAdapter.getDefaultAdapter(this)

        // Register scanner receiver
        val filter = IntentFilter().apply {
            addAction("com.android.scanservice.scan.broadcast")
            addAction("com.android.action.GETDATA_FROM_UART")
            priority = IntentFilter.SYSTEM_HIGH_PRIORITY
        }
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(scannerBroadcastReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(scannerBroadcastReceiver, filter)
        }
    }

    override fun onResume() {
        super.onResume()
        if (isNfcListening) {
            enableNfcReaderMode()
        }
    }

    override fun onPause() {
        super.onPause()
        disableNfcReaderMode()
    }

    private fun enableNfcReaderMode() {
        nfcAdapter?.let { adapter ->
            if (adapter.isEnabled) {
                val flags = NfcAdapter.FLAG_READER_NFC_A or
                            NfcAdapter.FLAG_READER_NFC_B or
                            NfcAdapter.FLAG_READER_NFC_F or
                            NfcAdapter.FLAG_READER_NFC_V or
                            NfcAdapter.FLAG_READER_NO_PLATFORM_SOUNDS
                adapter.enableReaderMode(this, this, flags, null)
            }
        }
    }

    private fun disableNfcReaderMode() {
        nfcAdapter?.disableReaderMode(this)
    }

    private fun writeMifareData(mifare: MifareClassic, text: String): Boolean {
        val key = MifareClassic.KEY_DEFAULT
        val bytes = text.toByteArray(Charsets.UTF_8)
        val maxBytes = 64
        val paddedBytes = ByteArray(maxBytes)
        System.arraycopy(bytes, 0, paddedBytes, 0, minOf(bytes.size, maxBytes))

        // Write Sector 1 (Blocks 4, 5, 6)
        if (mifare.authenticateSectorWithKeyA(1, key)) {
            mifare.writeBlock(4, paddedBytes.copyOfRange(0, 16))
            mifare.writeBlock(5, paddedBytes.copyOfRange(16, 32))
            mifare.writeBlock(6, paddedBytes.copyOfRange(32, 48))
        } else {
            return false
        }

        // Write Sector 2 (Block 8)
        if (mifare.authenticateSectorWithKeyA(2, key)) {
            mifare.writeBlock(8, paddedBytes.copyOfRange(48, 64))
        }
        return true
    }

    private fun readMifareData(mifare: MifareClassic): String {
        val key = MifareClassic.KEY_DEFAULT
        val output = ByteArray(64)
        var readLen = 0

        // Read Sector 1 (Blocks 4, 5, 6)
        if (mifare.authenticateSectorWithKeyA(1, key)) {
            val b4 = mifare.readBlock(4)
            val b5 = mifare.readBlock(5)
            val b6 = mifare.readBlock(6)
            System.arraycopy(b4, 0, output, 0, 16)
            System.arraycopy(b5, 0, output, 16, 16)
            System.arraycopy(b6, 0, output, 32, 16)
            readLen = 48
        } else {
            return ""
        }

        // Read Sector 2 (Block 8)
        if (mifare.authenticateSectorWithKeyA(2, key)) {
            val b8 = mifare.readBlock(8)
            System.arraycopy(b8, 0, output, 48, 16)
            readLen = 64
        }

        val validBytes = output.take(readLen).takeWhile { it != 0.toByte() }.toByteArray()
        return String(validBytes, Charsets.UTF_8).trim()
    }


    override fun onTagDiscovered(tag: Tag?) {
        if (tag == null) return
        val tagId = tag.id
        if (tagId == null || tagId.isEmpty()) return
        val hexUid = tagId.joinToString("") { "%02X".format(it) }

        var ticketData = ""
        var writeSuccess = false
        val mifare = MifareClassic.get(tag)

        if (mifare != null) {
            try {
                mifare.connect()
                val writeText = pendingWriteData
                if (writeText != null && writeText.isNotEmpty()) {
                    writeSuccess = writeMifareData(mifare, writeText)
                    ticketData = writeText
                    pendingWriteData = null
                } else {
                    ticketData = readMifareData(mifare)
                }
            } catch (e: Exception) {
                println("MIFARE operation error: $e")
            } finally {
                try {
                    mifare.close()
                } catch (_: Exception) {}
            }
        }

        val resultMap = mapOf(
            "cardUid" to hexUid,
            "ticketData" to ticketData,
            "writeSuccess" to writeSuccess
        )

        runOnUiThread {
            flutterEngine?.dartExecutor?.binaryMessenger?.let { messenger ->
                MethodChannel(messenger, NFC_CHANNEL).invokeMethod("onCardScanned", resultMap)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Printer channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "bindPrinterService" -> {
                        val intent = Intent().apply {
                            setPackage("com.iposprinter.iposprinterservice")
                            action = "com.iposprinter.iposprinterservice.IPosPrintService"
                        }
                        bindService(intent, printerServiceConnection, Context.BIND_AUTO_CREATE)
                        result.success(null)
                    }
                    "initializePrinter" -> {
                        mIPosPrinterService?.printerInit(printerCallback)
                        result.success(null)
                    }
                    "getPrinterStatus" -> {
                        val status = mIPosPrinterService?.getPrinterStatus() ?: -1
                        result.success(status)
                    }
                    "setPrinterPrintFontSize" -> {
                        val fontSize = call.argument<Int>("fontSize") ?: 24
                        mIPosPrinterService?.setPrinterPrintFontSize(fontSize, printerCallback)
                        result.success(null)
                    }
                    "setPrinterPrintAlignment" -> {
                        val alignment = call.argument<Int>("alignment") ?: 1
                        mIPosPrinterService?.setPrinterPrintAlignment(alignment, printerCallback)
                        result.success(null)
                    }
                    "printText" -> {
                        val text = call.argument<String>("text") ?: ""
                        mIPosPrinterService?.printText(text, printerCallback)
                        result.success(null)
                    }
                    "printerPerformPrint" -> {
                        val feedLines = call.argument<Int>("feedLines") ?: 0
                        mIPosPrinterService?.printerPerformPrint(feedLines, printerCallback)
                        result.success(null)
                    }
                    "printQRCode" -> {
                        val data = call.argument<String>("data") ?: ""
                        val moduleSize = call.argument<Int>("moduleSize") ?: 6
                        val errorCorrectionLevel = call.argument<Int>("errorCorrectionLevel") ?: 1
                        mIPosPrinterService?.printQRCode(
                            data,
                            moduleSize,
                            errorCorrectionLevel,
                            printerCallback
                        )
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("PRINTER_ERROR", "Printer operation failed", e.toString())
            }
        }

        // Scanner channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SCANNER_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startScanner" -> {
                    sendBroadcast(Intent("com.android.scanservice.start"))
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // NFC / MIFARE Card Channel with Sector Read/Write
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NFC_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isNfcAvailable" -> {
                    val available = nfcAdapter != null && nfcAdapter!!.isEnabled
                    result.success(available)
                }
                "startNfcListener" -> {
                    isNfcListening = true
                    enableNfcReaderMode()
                    result.success(true)
                }
                "stopNfcListener" -> {
                    isNfcListening = false
                    disableNfcReaderMode()
                    result.success(true)
                }
                "setPendingWriteData" -> {
                    val data = call.argument<String>("data")
                    pendingWriteData = data
                    result.success(true)
                }
                "clearPendingWriteData" -> {
                    pendingWriteData = null
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        disableNfcReaderMode()
        try {
            unregisterReceiver(scannerBroadcastReceiver)
            unbindService(printerServiceConnection)
        } catch (e: Exception) {
            // Handle cases where receiver wasn't registered or service wasn't bound
        }
    }
}
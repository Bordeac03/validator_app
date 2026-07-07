package com.transurban.transurban_validator

import android.app.Activity
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import com.cloudpos.scanserver.aidl.IScanService
import com.cloudpos.scanserver.aidl.ScanParameter
import com.cloudpos.scanserver.aidl.ScanResult
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Native bridge between the Flutter "Validator Mode" UI and the WizarPOS
 * CloudPOS hardware (WizarPOS Ticket Validator, Secure Android 14).
 * Built against CloudPOS SDK 1.8.2.24 (skipRATS + low-power card detect +
 * getCardTypeValue), with graceful reflection fallbacks for older AARs.
 *
 * Design goals:
 *  - SAFE EVERYWHERE: all calls into the proprietary CloudPOS RFCardReader SDK
 *    go through reflection, so this code compiles and runs on ANY Android device
 *    (and the APK still builds even if the .aar is not linked on the build host).
 *    On a real Q3 the classes are present and everything works; on a normal phone
 *    the methods report `available:false` and the Flutter UI degrades gracefully.
 *  - The QR scanner uses the device's system AIDL service
 *    (com.cloudpos.scanserver) exactly like the official BusPassDemo.
 *  - Kiosk (Lock Task) helpers mirror the official KioskDemo.
 *
 * Channel: "transurban/validator"
 *
 * Methods:
 *   hardwareInfo()                 -> { nfc:Bool, scanner:Bool, model:String }
 *   readNfcOnce(timeoutMs:Int)     -> { ok:Bool, uid:String?, cardType:String? }
 *   scanQrOnce(timeoutMs:Int)      -> { ok:Bool, text:String? }
 *   startKiosk() / stopKiosk()     -> Bool
 *   beep(success:Bool)             -> null   (UI feedback handled in Dart)
 */
class ValidatorHardwarePlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {

    companion object {
        private const val TAG = "ValidatorHW"
        private const val CHANNEL = "transurban/validator"

        // Real device-name string used by the working BusPassDemo (NOT the
        // "com.cloudpos.device.*" form shown in the JavaDoc).
        private const val RF_DEVICE_NAME = "cloudpos.device.rfcardreader"

        private const val SCAN_PKG = "com.cloudpos.scanserver"
        private const val SCAN_CLS = "com.cloudpos.scanserver.service.ScannerService"
        private const val SCAN_DESC = "com.cloudpos.scanserver.aidl.IScanService"
    }

    private var channel: MethodChannel? = null
    private var appContext: Context? = null
    private var activity: Activity? = null
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    // ---- FlutterPlugin ----
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    // ---- ActivityAware ----
    override fun onAttachedToActivity(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivity() { activity = null }
    override fun onDetachedFromActivityForConfigChanges() { activity = null }

    // ---- MethodCallHandler ----
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hardwareInfo" -> result.success(hardwareInfo())
            "readNfcOnce" -> {
                val timeout = (call.argument<Int>("timeoutMs")) ?: 10000
                io.execute {
                    val r = readNfcOnce(timeout)
                    main.post { result.success(r) }
                }
            }
            "scanQrOnce" -> {
                val timeout = (call.argument<Int>("timeoutMs")) ?: 15000
                io.execute {
                    val r = scanQrOnce(timeout)
                    main.post { result.success(r) }
                }
            }
            "startKiosk" -> result.success(setKiosk(true))
            "stopKiosk" -> result.success(setKiosk(false))
            else -> result.notImplemented()
        }
    }

    // -------------------- Capability detection --------------------

    private fun hardwareInfo(): Map<String, Any?> {
        val hasSdk = try {
            Class.forName("com.cloudpos.POSTerminal"); true
        } catch (_: Throwable) { false }
        val hasScanner = appContext?.packageManager
            ?.getLaunchIntentForPackage(SCAN_PKG) != null ||
            isPackageInstalled(SCAN_PKG)
        return mapOf(
            "nfc" to hasSdk,
            "scanner" to hasScanner,
            "model" to (android.os.Build.MODEL ?: "unknown"),
            "manufacturer" to (android.os.Build.MANUFACTURER ?: "unknown"),
        )
    }

    private fun isPackageInstalled(pkg: String): Boolean = try {
        appContext?.packageManager?.getPackageInfo(pkg, 0) != null
    } catch (_: Throwable) { false }

    // -------------------- NFC / contactless (reflection) --------------------

    /**
     * Opens the RF reader, waits up to [timeoutMs] for a single card, reads its
     * UID, then closes. Mirrors BusPassDemo's CycleWaitThread but for one shot.
     * All SDK access via reflection so the module never hard-depends on the AAR.
     */
    private fun readNfcOnce(timeoutMs: Int): Map<String, Any?> {
        val ctx = appContext ?: return fail("no_context")
        var device: Any? = null
        return try {
            val posTerminalCls = Class.forName("com.cloudpos.POSTerminal")
            val getInstance = posTerminalCls.getMethod("getInstance", Context::class.java)
            val terminal = getInstance.invoke(null, ctx)
            val getDevice = posTerminalCls.getMethod("getDevice", String::class.java)
            device = getDevice.invoke(terminal, RF_DEVICE_NAME)
                ?: return fail("no_device")

            val deviceCls = device.javaClass
            // open()  (no-arg form, as used in the working demo)
            try {
                deviceCls.getMethod("open").invoke(device)
            } catch (_: NoSuchMethodException) {
                // fall back to open(int, int) with logicalID 0 + MODE_AUTO(0)
                deviceCls.getMethod("open", Int::class.javaPrimitiveType, Int::class.javaPrimitiveType)
                    .invoke(device, 0, 0)
            }

            // --- SDK 1.8.2.24 optimizations (all best-effort, ignored if absent) ---
            // skipRATS(): avoid entering ISO14443-4, faster UID-only reads for transit.
            invokeOptional(device, deviceCls, "skipRATS")
            // enableLowPowerCardDetect(): the validator is mounted 24/7, save power.
            invokeOptional(device, deviceCls, "enableLowPowerCardDetect")

            val waitForCardPresent = deviceCls.getMethod(
                "waitForCardPresent", Int::class.javaPrimitiveType
            )
            val opResult = waitForCardPresent.invoke(device, timeoutMs)
                ?: return fail("timeout")

            // OperationResult.getResultCode() == OperationResult.SUCCESS (0)
            val resultCode = opResult.javaClass.getMethod("getResultCode").invoke(opResult) as? Int
            if (resultCode != 0) return fail("no_card")

            val card = opResult.javaClass.getMethod("getCard").invoke(opResult)
                ?: return fail("no_card")
            val idBytes = card.javaClass.getMethod("getID").invoke(card) as? ByteArray
            val uid = idBytes?.joinToString("") { "%02X".format(it) } ?: ""

            // getCardTypeValue(): int[] describing detected card technology (1.7.7+).
            val cardType = readCardType(device, deviceCls)

            mapOf("ok" to uid.isNotEmpty(), "uid" to uid, "cardType" to cardType)
        } catch (t: Throwable) {
            Log.w(TAG, "readNfcOnce failed: ${t.message}")
            fail(if (t is ClassNotFoundException) "unavailable" else "error")
        } finally {
            if (device != null) {
                // Revert low-power mode then close, both best-effort.
                invokeOptional(device, device.javaClass, "disableLowPowerCardDetect")
                try { device.javaClass.getMethod("close").invoke(device) } catch (_: Throwable) {}
            }
        }
    }

    private fun fail(reason: String) = mapOf("ok" to false, "uid" to null, "reason" to reason)

    /**
     * Invokes a no-arg method by name if it exists on the device; silently
     * ignores it otherwise. Lets us call SDK 1.8.2.24 helpers (skipRATS,
     * enable/disableLowPowerCardDetect) without breaking on older AAR builds.
     */
    private fun invokeOptional(target: Any, cls: Class<*>, method: String) {
        try {
            cls.getMethod(method).invoke(target)
        } catch (_: NoSuchMethodException) {
            // Method not present in this SDK version - fine.
        } catch (t: Throwable) {
            Log.d(TAG, "$method() ignored: ${t.message}")
        }
    }

    /**
     * Reads getCardTypeValue() (int[]) and maps the first entry to a readable
     * technology label. Falls back to "RF" when unavailable.
     */
    private fun readCardType(device: Any, cls: Class<*>): String {
        return try {
            val values = cls.getMethod("getCardTypeValue").invoke(device) as? IntArray
            when (values?.firstOrNull()) {
                1 -> "TYPE_A"
                2 -> "TYPE_B"
                3 -> "FELICA"
                4 -> "MIFARE"
                5 -> "ISO15693"
                else -> "RF"
            }
        } catch (_: Throwable) {
            "RF"
        }
    }

    // -------------------- QR scanner (system AIDL service) --------------------

    /**
     * Binds the CloudPOS scanner service and performs ONE blocking scan.
     * Returns the decoded text or ok:false on timeout/unavailable.
     */
    private fun scanQrOnce(timeoutMs: Int): Map<String, Any?> {
        val ctx = appContext ?: return mapOf("ok" to false, "reason" to "no_context")
        if (!isPackageInstalled(SCAN_PKG)) {
            return mapOf("ok" to false, "reason" to "unavailable")
        }
        val lock = Object()
        var bound = false
        var scanText: String? = null
        var conn: ServiceConnection? = null
        try {
            conn = object : ServiceConnection {
                override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
                    try {
                        val desc = service?.interfaceDescriptor
                        if (desc == SCAN_DESC && service != null) {
                            val scanService = IScanService.Stub.asInterface(service)
                            val p = ScanParameter()
                            // Headless, driver-less scan: no on-screen scanner UI,
                            // the validator's own Flutter screen stays visible.
                            p.set(ScanParameter.KEY_UI_WINDOW_WIDTH, 0)
                            p.set(ScanParameter.KEY_UI_WINDOW_HEIGHT, 0)
                            p.set(ScanParameter.KEY_SCAN_MODE, "overlay")
                            p.set(ScanParameter.KEY_ENABLE_MIRROR_SCAN, true)
                            p.set(ScanParameter.KEY_SCAN_TIME_OUT, timeoutMs)
                            // Suppress the built-in scanner beep (we give our own
                            // audio/visual feedback in Flutter) and hide any UI.
                            trySet(p, "KEY_ENABLE_SOUND", false)
                            trySet(p, "KEY_DISABLE_UI", true)
                            val res: ScanResult? = scanService.scanBarcode(p)
                            if (res != null && res.resultCode == ScanResult.SCAN_SUCCESS) {
                                // getText() = the decoded barcode payload
                                // (res.toString() would return the object dump).
                                val decoded = res.text
                                if (!decoded.isNullOrBlank()) scanText = decoded.trim()
                            }
                        }
                    } catch (t: Throwable) {
                        Log.w(TAG, "scan onConnected failed: ${t.message}")
                    } finally {
                        synchronized(lock) { lock.notifyAll() }
                    }
                }
                override fun onServiceDisconnected(name: ComponentName?) {}
            }
            val intent = Intent().apply { component = ComponentName(SCAN_PKG, SCAN_CLS) }
            bound = ctx.bindService(intent, conn, Context.BIND_AUTO_CREATE)
            ctx.startService(intent)
            if (!bound) return mapOf("ok" to false, "reason" to "bind_failed")

            synchronized(lock) { lock.wait((timeoutMs + 3000).toLong()) }
            return mapOf("ok" to (scanText != null), "text" to scanText)
        } catch (t: Throwable) {
            Log.w(TAG, "scanQrOnce failed: ${t.message}")
            return mapOf("ok" to false, "reason" to "error")
        } finally {
            try { if (bound && conn != null) ctx.unbindService(conn) } catch (_: Throwable) {}
        }
    }

    /**
     * Sets a ScanParameter boolean key referenced by its static field name,
     * ignoring it if the constant is absent in this SDK build. Keeps us
     * forward/backward compatible across CloudPOS scanner versions.
     */
    private fun trySet(p: ScanParameter, fieldName: String, value: Boolean) {
        try {
            val key = ScanParameter::class.java.getField(fieldName).get(null) as? String
            if (key != null) p.set(key, value)
        } catch (_: Throwable) {
            // Key not available in this SDK - fine.
        }
    }

    // -------------------- Kiosk / Lock Task --------------------

    private fun setKiosk(enable: Boolean): Boolean {
        val act = activity ?: return false
        return try {
            if (enable) {
                val dpm = act.getSystemService(Context.DEVICE_POLICY_SERVICE) as? DevicePolicyManager
                val admin = ComponentName(act, ValidatorDeviceAdminReceiver::class.java)
                if (dpm != null && dpm.isDeviceOwnerApp(act.packageName)) {
                    dpm.setLockTaskPackages(admin, arrayOf(act.packageName))
                }
                act.startLockTask()
            } else {
                act.stopLockTask()
            }
            true
        } catch (t: Throwable) {
            Log.w(TAG, "setKiosk($enable) failed: ${t.message}")
            false
        }
    }
}

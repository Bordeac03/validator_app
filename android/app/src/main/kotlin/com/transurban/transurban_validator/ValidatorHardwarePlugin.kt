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

        // Official CloudPOS RF reader device name. NOTE the "com." prefix — an
        // earlier build used "cloudpos.device.rfcardreader" (no prefix) which
        // getDevice() does not recognise, so the reader was never obtained.
        // We resolve POSTerminal.DEVICE_NAME_RF_CARD_READER reflectively at
        // runtime and only fall back to these literals.
        private const val RF_DEVICE_NAME = "com.cloudpos.device.rfcardreader"
        private val RF_DEVICE_NAME_CANDIDATES = listOf(
            "com.cloudpos.device.rfcardreader",
            "cloudpos.device.rfcardreader",
        )

        private const val SCAN_PKG = "com.cloudpos.scanserver"
        private const val SCAN_CLS = "com.cloudpos.scanserver.service.ScannerService"
        private const val SCAN_DESC = "com.cloudpos.scanserver.aidl.IScanService"
    }

    private var channel: MethodChannel? = null
    private var appContext: Context? = null
    private var activity: Activity? = null
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    // ---- Persistent scanner service (bound ONCE, reused for every scan) ----
    // Binding/unbinding on every scan (every ~2.5s) leaked ServiceConnections
    // and eventually crashed the app; and calling scanBarcode() inside
    // onServiceConnected blocked the main Binder thread => ANR. We now keep a
    // single long-lived connection and only ever run scanBarcode() on the
    // background `io` executor.
    private val scanLock = Object()
    private var scanConn: ServiceConnection? = null
    @Volatile private var scanService: IScanService? = null
    @Volatile private var scanBound = false

    // ---- Persistent RF card reader (opened ONCE, reused for every read) ----
    // The CloudPOS RF reader is a process singleton over a native JNI layer.
    // We open it ONCE (cached in rfDevice) and, after every read, end the
    // native search session via waitForCardAbsent() so the next poll can search
    // again. rfLock serializes every RF operation so two poll cycles never race
    // on the shared native lock. See the big comment above readNfcOnce().
    private val rfLock = Object()
    @Volatile private var rfDevice: Any? = null
    @Volatile private var rfDeviceCls: Class<*>? = null
    // Human-readable trace of the last RF init/read so the Flutter UI (and
    // logcat) can show WHERE it fails on the real WizarPOS device.
    @Volatile private var rfDiag: String = "not started"

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
        // Release shared hardware handles so we never leak them.
        releaseScannerService()
        recycleRfDevice()
        io.shutdownNow()
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
            "warmUpNfc" -> io.execute {
                // Pre-open the RF reader + clear any stale search session so the
                // very first poll after boot doesn't hit "no open window".
                warmUpRf()
                val d = rfDiag
                main.post { result.success(d) }
            }
            "nfcDiag" -> io.execute {
                // Force an open attempt so the diag reflects the real device
                // state (device found? opened ok?) without needing a card.
                synchronized(rfLock) { ensureRfDevice() }
                val d = rfDiag
                main.post { result.success(d) }
            }
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

    // ============================================================
    // WHY THE READER "READ ONCE THEN STOPPED" (root cause, from AAR bytecode)
    // ------------------------------------------------------------
    // RFCardReaderDeviceImpl is a *process singleton* wrapping the native JNI
    // layer (com.cloudpos.jniinterface.RFCardInterface, guarded by a static
    // rfcardinterfaceLock). getDevice() ALWAYS returns the same object, so
    // "open a fresh handle per read" is an illusion — you get the same singleton
    // with the same stale native search state.
    //
    // waitForCardPresent() internally does: clear() -> searchBegin() ->
    // waitUntilCardPresent() -> getCard(). It NEVER calls searchEnd() on the
    // success path. The ONLY correct way to end that native search session is
    // the device's own waitForCardAbsent(), which (via checkSearchEndEvent)
    // calls the *member* searchEnd() that properly balances searchBegin().
    //
    // Two earlier mistakes:
    //  * close()/reopen per read — close() calls checkNotOpened() and tears down
    //    native state in a way that then failed the next searchBegin().
    //  * calling the *static native* RFCardInterface.searchEnd() directly — it
    //    corrupted the singleton's bookkeeping so nothing scanned at all.
    //
    // Correct pattern (this version):
    //  1) open the singleton ONCE (cached), skipRATS.
    //  2) each cycle: waitForCardPresent -> read UID -> waitForCardAbsent()
    //     (short timeout) to cleanly close the search session so the NEXT
    //     waitForCardPresent can searchBegin() again.
    //  3) only on a *hard* error do we close()+reopen to fully recover.
    // ============================================================

    /**
     * Returns the cached, already-open RF singleton, opening it once if needed.
     * Runs under rfLock on the io thread. Returns null (and sets rfDiag) when
     * the SDK / device is unavailable.
     */
    private fun ensureRfDevice(): Any? {
        rfDevice?.let { return it }
        val ctx = appContext ?: run { rfDiag = "no_context"; return null }
        try {
            val posTerminalCls = Class.forName("com.cloudpos.POSTerminal")
            val getInstance = posTerminalCls.getMethod("getInstance", Context::class.java)
            val terminal = getInstance.invoke(null, ctx)
                ?: run { rfDiag = "POSTerminal.getInstance()=null"; return null }

            // Prefer the SDK's own DEVICE_NAME_RF_CARD_READER constant, then fall
            // back to our known-name candidates.
            val names = LinkedHashSet<String>()
            try {
                (posTerminalCls.getField("DEVICE_NAME_RF_CARD_READER").get(null) as? String)
                    ?.let { names.add(it) }
            } catch (_: Throwable) {}
            names.addAll(RF_DEVICE_NAME_CANDIDATES)

            val getDevice = posTerminalCls.getMethod("getDevice", String::class.java)
            var device: Any? = null
            var usedName = ""
            for (n in names) {
                try {
                    val d = getDevice.invoke(terminal, n)
                    if (d != null) { device = d; usedName = n; break }
                } catch (e: Throwable) {
                    Log.d(TAG, "getDevice('$n') threw: ${e.message}")
                }
            }
            if (device == null) {
                val listed = try {
                    (posTerminalCls.getMethod("listDevices").invoke(terminal) as? Array<*>)
                        ?.joinToString(",") { it.toString() } ?: "?"
                } catch (_: Throwable) { "listDevices_unavailable" }
                rfDiag = "getDevice null for all names; listDevices=[$listed]"
                Log.w(TAG, "RF: $rfDiag")
                return null
            }
            val deviceCls = device.javaClass

            // Open the reader. no-arg open() delegates to open(0,0)=MODE_AUTO.
            // Already-open is benign — keep the handle.
            try {
                deviceCls.getMethod("open").invoke(device)
            } catch (e: java.lang.reflect.InvocationTargetException) {
                Log.d(TAG, "rf open() note: ${e.targetException?.message}") // likely already open
            } catch (_: NoSuchMethodException) {
                try {
                    deviceCls.getMethod(
                        "open",
                        Int::class.javaPrimitiveType,
                        Int::class.javaPrimitiveType
                    ).invoke(device, 0, 0)
                } catch (e: java.lang.reflect.InvocationTargetException) {
                    Log.d(TAG, "rf open(0,0) note: ${e.targetException?.message}")
                }
            }

            // Best-effort: faster UID reads (skip RATS handshake).
            invokeOptional(device, deviceCls, "skipRATS")

            rfDevice = device
            rfDeviceCls = deviceCls
            if (rfDiag == "not started" || rfDiag.startsWith("getDevice null") ||
                rfDiag.startsWith("ensureRfDevice error") || rfDiag.startsWith("open error")) {
                rfDiag = "open ok via '$usedName'"
            }
            Log.i(TAG, "RF: opened via '$usedName' -> ${deviceCls.name}")
            return device
        } catch (t: Throwable) {
            rfDiag = "ensureRfDevice error: ${t.javaClass.simpleName}: ${t.message}"
            Log.w(TAG, rfDiag)
            return null
        }
    }

    /** Fully closes + clears the cached RF singleton so the next read reopens. */
    private fun recycleRfDevice() {
        synchronized(rfLock) {
            val device = rfDevice
            if (device != null) {
                try { device.javaClass.getMethod("close").invoke(device) } catch (t: Throwable) {
                    Log.d(TAG, "RF: close note: ${t.message}")
                }
            }
            rfDevice = null
            rfDeviceCls = null
        }
    }

    /**
     * Ends the native search session started by waitForCardPresent() by calling
     * the SDK's OWN private *member* searchEnd() reflectively.
     *
     * Why the member (not the static native, not waitForCardAbsent):
     *  - RFCardReaderDeviceImpl.searchEnd() (private, no state guard) does
     *    exactly: RFCardInterface.searchEnd() + throwsExceptionByErrorResult().
     *    This is precisely what cancelRequest()/the absent path run internally
     *    to balance searchBegin(). Calling it directly is the safe, quiescent
     *    way to end the search.
     *  - The static native RFCardInterface.searchEnd() (patch 8) skipped the
     *    error-result handling and desynced the wrapper -> nothing scanned.
     *  - waitForCardAbsent() only reaches searchEnd() while the card is still
     *    present; if the card was already lifted it loops+times out WITHOUT
     *    ending the search -> reader wedged after the 1st read. That was the
     *    "reads once then stops" regression.
     *  - cancelRequest() throws (-4) when idle (checkNotRun requires an active
     *    wait), so it can't be used here either.
     */
    private fun endSearchSession(device: Any, cls: Class<*>) {
        try {
            val m = findDeclaredMethod(cls, "searchEnd")
            if (m != null) {
                m.isAccessible = true
                m.invoke(device)
                Log.d(TAG, "RF: member searchEnd ok (search ended)")
            } else {
                // Fallback: the raw native searchEnd. Less ideal (no wrapper
                // bookkeeping) but better than leaving the search open.
                Class.forName("com.cloudpos.jniinterface.RFCardInterface")
                    .getMethod("searchEnd").invoke(null)
                Log.d(TAG, "RF: native searchEnd fallback ok")
            }
        } catch (t: Throwable) {
            // If ending the search fails we can't trust the native state —
            // recycle so the next cycle reopens cleanly instead of wedging.
            Log.d(TAG, "RF: searchEnd note: ${t.message} -> recycling")
            recycleRfDevice()
        }
    }

    /**
     * Finds a declared method by name on [cls] or any superclass (needed for
     * the private searchEnd() on RFCardReaderDeviceImpl, which getMethod()
     * can't see). Ignores parameter types (searchEnd is no-arg).
     */
    private fun findDeclaredMethod(cls: Class<*>, name: String): java.lang.reflect.Method? {
        var c: Class<*>? = cls
        while (c != null) {
            try {
                return c.getDeclaredMethod(name)
            } catch (_: NoSuchMethodException) {
                c = c.superclass
            }
        }
        return null
    }

    /**
     * Best-effort warm-up: open the RF singleton ahead of time and immediately
     * end any residual search session, so the FIRST real poll after boot isn't
     * the one that hits an uninitialised reader ("no open window"). Safe to call
     * repeatedly; runs under rfLock on the io thread.
     */
    private fun warmUpRf() {
        synchronized(rfLock) {
            val device = ensureRfDevice() ?: return
            val cls = rfDeviceCls ?: device.javaClass
            // Clear any stale native search state left from a previous process
            // instance, then leave the reader open and idle, ready to poll.
            endSearchSession(device, cls)
            Log.i(TAG, "RF: warm-up complete ($rfDiag)")
        }
    }

    /**
     * Waits up to [timeoutMs] for a single card on the cached (open) RF
     * singleton, reads UID + type, then ends the native search session via the
     * private member searchEnd() (see endSearchSession) so the NEXT poll can
     * searchBegin() again. Without this the reader reads exactly once and then
     * never again.
     *
     * Always invoked from the background io thread (see onMethodCall), so the
     * blocking calls never touch the UI thread — no ANR.
     */
    private fun readNfcOnce(timeoutMs: Int): Map<String, Any?> {
        synchronized(rfLock) {
            val device = ensureRfDevice() ?: return fail("unavailable")
            val deviceCls = rfDeviceCls ?: device.javaClass
            return try {
                val opResult = deviceCls
                    .getMethod("waitForCardPresent", Int::class.javaPrimitiveType)
                    .invoke(device, timeoutMs)
                    ?: run { rfDiag = "poll timeout (no card in window)"; return fail("timeout") }

                // CloudPOS OperationResult.SUCCESS == 1 (0 == NONE/idle).
                val resultCode = (opResult.javaClass.getMethod("getResultCode").invoke(opResult) as? Int) ?: -1
                val successCode = operationSuccessCode()   // == 1 on this SDK
                Log.d(TAG, "RF: waitForCardPresent resultCode=$resultCode (success=$successCode)")
                if (resultCode != successCode && resultCode == operationTimeoutCode()) {
                    rfDiag = "poll timeout (no card in window)"
                    // Nothing was found, but searchBegin() DID run inside
                    // waitForCardPresent — balance it so the next poll is clean.
                    endSearchSession(device, deviceCls)
                    return fail("timeout")
                }

                val card = opResult.javaClass.getMethod("getCard").invoke(opResult)
                    ?: run {
                        rfDiag = "resultCode=$resultCode but getCard()=null"
                        endSearchSession(device, deviceCls)
                        return fail("no_card")
                    }
                val idBytes = card.javaClass.getMethod("getID").invoke(card) as? ByteArray
                val uid = idBytes?.joinToString("") { "%02X".format(it) } ?: ""
                if (uid.isEmpty()) {
                    rfDiag = "card present but empty UID"
                    endSearchSession(device, deviceCls)
                    return fail("no_card")
                }

                val cardType = readCardType(device, deviceCls)
                rfDiag = "CARD READ ok uid=$uid type=$cardType"
                Log.i(TAG, "RF: $rfDiag")

                // CRITICAL: end the search session the SDK-sanctioned way so the
                // NEXT waitForCardPresent() can start a fresh search. Without
                // this the reader reads exactly once and then never again.
                endSearchSession(device, deviceCls)

                mapOf("ok" to true, "uid" to uid, "cardType" to cardType)
            } catch (t: Throwable) {
                rfDiag = "readNfcOnce error: ${t.javaClass.simpleName}: ${t.message}"
                Log.w(TAG, rfDiag)
                // Hard failure -> drop the handle so the next read reopens clean.
                recycleRfDevice()
                fail(if (t is ClassNotFoundException) "unavailable" else "error")
            }
        }
    }

    /**
     * Reads com.cloudpos.OperationResult.SUCCESS reflectively. On CloudPOS
     * SDK 1.8.2.24 this is 1 (0 is NONE). Falls back to 1 if unavailable.
     */
    private fun operationSuccessCode(): Int = try {
        Class.forName("com.cloudpos.OperationResult").getField("SUCCESS").getInt(null)
    } catch (_: Throwable) { 1 }

    /** com.cloudpos.OperationResult.ERR_TIMEOUT (== -4). Fallback -4. */
    private fun operationTimeoutCode(): Int = try {
        Class.forName("com.cloudpos.OperationResult").getField("ERR_TIMEOUT").getInt(null)
    } catch (_: Throwable) { -4 }

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
     * Performs ONE scan using the shared, long-lived scanner service.
     *
     * IMPORTANT: this method is always invoked from the background `io`
     * executor (see onMethodCall), so the blocking scanBarcode() call NEVER
     * runs on the main/UI thread. The service is bound only once (lazily) and
     * then reused for every subsequent scan, so there is no bind/unbind churn.
     */
    private fun scanQrOnce(timeoutMs: Int): Map<String, Any?> {
        val ctx = appContext ?: return mapOf("ok" to false, "reason" to "no_context")
        if (!isPackageInstalled(SCAN_PKG)) {
            return mapOf("ok" to false, "reason" to "unavailable")
        }

        // Ensure the service is bound (blocks the background thread, not UI).
        val svc = ensureScannerService()
            ?: return mapOf("ok" to false, "reason" to "bind_failed")

        return try {
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

            // Blocking call - safe here because we are on the io thread.
            val res: ScanResult? = svc.scanBarcode(p)
            if (res != null && res.resultCode == ScanResult.SCAN_SUCCESS) {
                val decoded = res.text
                if (!decoded.isNullOrBlank()) {
                    return mapOf("ok" to true, "text" to decoded.trim())
                }
            }
            mapOf("ok" to false, "text" to null)
        } catch (t: Throwable) {
            Log.w(TAG, "scanQrOnce failed: ${t.message}")
            // The service may have died (process restart); drop the cached
            // reference so the next call rebinds cleanly.
            if (t is android.os.DeadObjectException || t is android.os.RemoteException) {
                releaseScannerService()
            }
            mapOf("ok" to false, "reason" to "error")
        }
    }

    /**
     * Lazily binds the CloudPOS scanner AIDL service ONCE and caches the
     * IScanService. Called from the background io thread; blocks up to ~5s for
     * the connection to be established the first time, then returns the cached
     * instance instantly for every subsequent scan.
     */
    private fun ensureScannerService(): IScanService? {
        scanService?.let { return it }
        val ctx = appContext ?: return null
        synchronized(scanLock) {
            // Double-checked: another thread may have bound while we waited.
            scanService?.let { return it }
            if (scanConn == null) {
                val conn = object : ServiceConnection {
                    override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
                        synchronized(scanLock) {
                            scanService = try {
                                if (service != null) IScanService.Stub.asInterface(service) else null
                            } catch (t: Throwable) {
                                Log.w(TAG, "asInterface failed: ${t.message}")
                                null
                            }
                            scanLock.notifyAll()
                        }
                    }
                    override fun onServiceDisconnected(name: ComponentName?) {
                        synchronized(scanLock) {
                            scanService = null
                            scanLock.notifyAll()
                        }
                    }
                }
                scanConn = conn
                val intent = Intent().apply { component = ComponentName(SCAN_PKG, SCAN_CLS) }
                scanBound = try {
                    ctx.bindService(intent, conn, Context.BIND_AUTO_CREATE)
                } catch (t: Throwable) {
                    Log.w(TAG, "bindService failed: ${t.message}")
                    false
                }
                if (!scanBound) {
                    scanConn = null
                    return null
                }
            }
            // Wait for onServiceConnected (only the first time).
            if (scanService == null) {
                try { scanLock.wait(5000) } catch (_: InterruptedException) {}
            }
            return scanService
        }
    }

    /** Unbinds and clears the shared scanner service (on error/lifecycle end). */
    private fun releaseScannerService() {
        synchronized(scanLock) {
            val ctx = appContext
            val conn = scanConn
            if (scanBound && conn != null && ctx != null) {
                try { ctx.unbindService(conn) } catch (_: Throwable) {}
            }
            scanConn = null
            scanService = null
            scanBound = false
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

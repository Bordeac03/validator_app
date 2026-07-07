package com.transurban.transurban_validator

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Register the WizarPOS validator hardware bridge (NFC + scanner + kiosk).
        // Safe on all devices: degrades gracefully when CloudPOS SDK absent.
        flutterEngine.plugins.add(ValidatorHardwarePlugin())
    }
}

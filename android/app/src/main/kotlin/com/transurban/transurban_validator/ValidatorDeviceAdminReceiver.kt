package com.transurban.transurban_validator

import android.app.admin.DeviceAdminReceiver

/**
 * Device-admin receiver required so the app can enter Lock Task (kiosk) mode
 * on the Q3 validator. Mirrors the official WizarPOS KioskDemo. Harmless on
 * normal phones (only used when the app is provisioned as device owner).
 */
class ValidatorDeviceAdminReceiver : DeviceAdminReceiver()

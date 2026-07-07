import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Capability snapshot of the device the validator runs on.
class ValidatorCapabilities {
  final bool nfc;
  final bool scanner;
  final String model;
  final String manufacturer;

  const ValidatorCapabilities({
    required this.nfc,
    required this.scanner,
    required this.model,
    required this.manufacturer,
  });

  /// True on a real Q3 validator (has CloudPOS NFC + scanner service).
  bool get isValidatorDevice => nfc || scanner;

  static const ValidatorCapabilities none = ValidatorCapabilities(
    nfc: false,
    scanner: false,
    model: 'unknown',
    manufacturer: 'unknown',
  );
}

/// Outcome of a single NFC read.
class NfcReadResult {
  final bool ok;
  final String? uid;

  /// Detected card technology, e.g. `TYPE_A`, `MIFARE`, `FELICA`.
  final String? cardType;
  final String? reason;
  const NfcReadResult({
    required this.ok,
    this.uid,
    this.cardType,
    this.reason,
  });
}

/// Outcome of a single QR scan.
class QrScanResult {
  final bool ok;
  final String? text;
  final String? reason;
  const QrScanResult({required this.ok, this.text, this.reason});
}

/// Dart wrapper over the native `transurban/validator` MethodChannel that
/// talks to the WizarPOS Q3 hardware (NFC reader + barcode scanner + kiosk).
///
/// Everything degrades gracefully: on web or a normal phone the native side
/// reports `unavailable` and these methods return `ok:false`, so the Validator
/// UI can show a clear "hardware not present" state instead of crashing.
class ValidatorHardware {
  ValidatorHardware._();
  static final ValidatorHardware instance = ValidatorHardware._();

  static const MethodChannel _channel = MethodChannel('transurban/validator');

  /// Whether the platform can even host the validator hardware (Android only).
  bool get isSupportedPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<ValidatorCapabilities> capabilities() async {
    if (!isSupportedPlatform) return ValidatorCapabilities.none;
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>(
        'hardwareInfo',
      );
      if (res == null) return ValidatorCapabilities.none;
      return ValidatorCapabilities(
        nfc: res['nfc'] == true,
        scanner: res['scanner'] == true,
        model: (res['model'] ?? 'unknown').toString(),
        manufacturer: (res['manufacturer'] ?? 'unknown').toString(),
      );
    } catch (_) {
      return ValidatorCapabilities.none;
    }
  }

  /// Wait for a single contactless card and return its UID (hex).
  Future<NfcReadResult> readNfcOnce({int timeoutMs = 10000}) async {
    if (!isSupportedPlatform) {
      return const NfcReadResult(ok: false, reason: 'unavailable');
    }
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>(
        'readNfcOnce',
        {'timeoutMs': timeoutMs},
      );
      return NfcReadResult(
        ok: res?['ok'] == true,
        uid: res?['uid']?.toString(),
        cardType: res?['cardType']?.toString(),
        reason: res?['reason']?.toString(),
      );
    } catch (e) {
      return NfcReadResult(ok: false, reason: e.toString());
    }
  }

  /// Perform a single QR/barcode scan via the system scanner service.
  Future<QrScanResult> scanQrOnce({int timeoutMs = 15000}) async {
    if (!isSupportedPlatform) {
      return const QrScanResult(ok: false, reason: 'unavailable');
    }
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>(
        'scanQrOnce',
        {'timeoutMs': timeoutMs},
      );
      return QrScanResult(
        ok: res?['ok'] == true,
        text: res?['text']?.toString(),
        reason: res?['reason']?.toString(),
      );
    } catch (e) {
      return QrScanResult(ok: false, reason: e.toString());
    }
  }

  /// Pre-opens the RF reader and clears any stale native search session so the
  /// FIRST poll after boot doesn't hit "no open window". Returns the resulting
  /// diagnostic string. Safe to call multiple times.
  Future<String> warmUpNfc() async {
    if (!isSupportedPlatform) return 'unsupported platform';
    try {
      return (await _channel.invokeMethod<String>('warmUpNfc')) ?? '(null)';
    } catch (e) {
      return 'warmup error: $e';
    }
  }

  /// Returns a human-readable trace of the last RF init/read attempt, so the
  /// UI can show WHERE NFC fails on the real WizarPOS (device list, open error,
  /// timeout, etc.). Empty string on unsupported platforms.
  Future<String> nfcDiag() async {
    if (!isSupportedPlatform) return 'unsupported platform';
    try {
      return (await _channel.invokeMethod<String>('nfcDiag')) ?? '(null)';
    } catch (e) {
      return 'diag error: $e';
    }
  }

  /// Returns the rolling, timestamped native RF step log (open/close/
  /// waitForCardPresent/resultCode/searchEnd) so the user can screenshot
  /// exactly what happens on read #1 vs read #2.
  Future<String> nfcTrace() async {
    if (!isSupportedPlatform) return 'unsupported platform';
    try {
      return (await _channel.invokeMethod<String>('nfcTrace')) ?? '(null)';
    } catch (e) {
      return 'trace error: $e';
    }
  }

  /// Lists which native RF methods exist on THIS device's SDK build (✓/✗),
  /// used to stop guessing which reset primitives are available.
  Future<String> nfcMethods() async {
    if (!isSupportedPlatform) return 'unsupported platform';
    try {
      return (await _channel.invokeMethod<String>('nfcMethods')) ?? '(null)';
    } catch (e) {
      return 'methods error: $e';
    }
  }

  Future<bool> startKiosk() async {
    if (!isSupportedPlatform) return false;
    try {
      return (await _channel.invokeMethod<bool>('startKiosk')) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> stopKiosk() async {
    if (!isSupportedPlatform) return false;
    try {
      return (await _channel.invokeMethod<bool>('stopKiosk')) ?? false;
    } catch (_) {
      return false;
    }
  }
}

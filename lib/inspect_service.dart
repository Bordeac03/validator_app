import 'dart:convert';
import 'package:http/http.dart' as http;

/// Result of a single validation (ticket QR or subscription NFC card).
class InspectResult {
  /// True when the ticket/card is valid and travel is allowed.
  final bool valid;

  /// Short machine code (VALID, EXPIRED, ALREADY_USED, NOT_FOUND…).
  final String code;

  /// Human-readable, server-localized message to show on the validator.
  final String message;

  /// Optional metadata for display.
  final String? fareName;
  final String? expiresAt;

  const InspectResult({
    required this.valid,
    required this.code,
    required this.message,
    this.fareName,
    this.expiresAt,
  });

  factory InspectResult.fromJson(Map<String, dynamic> json) => InspectResult(
        valid: json['valid'] == true,
        code: (json['code'] ?? (json['valid'] == true ? 'VALID' : 'INVALID'))
            .toString(),
        message: (json['message'] ?? '').toString(),
        fareName: json['fare_name']?.toString(),
        expiresAt: json['expires_at']?.toString(),
      );

  /// Local fallback when the backend is unreachable (network error).
  factory InspectResult.networkError() => const InspectResult(
        valid: false,
        code: 'NETWORK_ERROR',
        message: 'Fără conexiune. Încercați din nou.',
      );
}

/// Minimal HTTP client for the validator: only the `/api/inspect` endpoint.
///
/// The heavy passenger app talks to the full backend; this dedicated validator
/// app only needs to POST a scanned credential and render the verdict.
class InspectService {
  /// Production REST API host (JSON only).
  static const String baseUrl = 'https://api.transurban.ro';

  /// This validator's identity (set at provisioning / from device settings).
  final String vehicleId;
  final String routeId;
  final String? validatorToken;

  const InspectService({
    this.vehicleId = 'VALIDATOR-01',
    this.routeId = '',
    this.validatorToken,
  });

  /// Validates a credential coming from either the QR scanner or the NFC reader.
  ///
  /// [credential]      the scanned QR text or the NFC card UID (hex)
  /// [credentialType]  'qr' or 'nfc'
  Future<InspectResult> inspect({
    required String credential,
    required String credentialType,
  }) async {
    final uri = Uri.parse('$baseUrl/api/inspect');
    try {
      final res = await http
          .post(
            uri,
            headers: {
              'Accept': 'application/json',
              'Content-Type': 'application/json',
              'Accept-Language': 'ro',
              if (validatorToken != null)
                'Authorization': 'Bearer $validatorToken',
            },
            body: jsonEncode({
              'credential': credential,
              'type': credentialType,
              'vehicle_id': vehicleId,
              'route_id': routeId,
            }),
          )
          .timeout(const Duration(seconds: 8));

      // Only hard server errors (5xx) are treated as failures; an invalid
      // ticket still returns 200 with { ok:true, valid:false }.
      if (res.statusCode >= 500) {
        return const InspectResult(
          valid: false,
          code: 'SERVER_ERROR',
          message: 'Eroare server. Anunțați operatorul.',
        );
      }

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      // Backend envelope: { ok:true, valid:.., code:.., message:.. }
      return InspectResult.fromJson(body);
    } catch (_) {
      return InspectResult.networkError();
    }
  }
}

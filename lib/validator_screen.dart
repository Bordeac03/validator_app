import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';
import 'validator_hardware.dart';
import 'widgets/roman_crest.dart';

/// The single, always-on validator page (premium dark theme, animated).
///
/// Physical layout of the WizarPOS Ticket Validator (portrait):
///   ┌──────────────────┐
///   │   ZONA SCANARE    │  ← NFC antenna behind the top glass + red beam
///   │   (unde radio)    │
///   ├──────────────────┤
///   │   BRAND + STEMA   │
///   │  "Validează       │
///   │    călătoria"     │
///   │  ┌─────┬─────┐    │
///   │  │ NFC │ QR  │    │  ← two ways to validate
///   │  └─────┴─────┘    │
///   │  terminal pregătit │
///   ├──────────────────┤
///   │   QR SCANNER      │  ← hold ticket QR here (bottom window)
///   └──────────────────┘
///
/// A continuous loop alternates a short QR scan and a short NFC read; whichever
/// fires first is validated against `/api/inspect`, the verdict is shown
/// full-screen for a couple of seconds, then it returns to idle.
class ValidatorScreen extends StatefulWidget {
  const ValidatorScreen({super.key});

  @override
  State<ValidatorScreen> createState() => _ValidatorScreenState();
}

/// Either waiting for a card/QR (idle) or momentarily paused while the
/// scan-result alert is shown (checking).
enum _Phase { idle, checking }

class _ValidatorScreenState extends State<ValidatorScreen>
    with TickerProviderStateMixin {
  final _hw = ValidatorHardware.instance;

  _Phase _phase = _Phase.idle;
  ValidatorCapabilities _caps = ValidatorCapabilities.none;
  bool _looping = false;
  bool _busy = false;
  String _diag = ''; // last NFC/RF diagnostic trace (hidden unless present)

  late final AnimationController _pulse; // NFC ring pulse
  late final AnimationController _breathe; // gentle status dot

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
    _breathe = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _caps = await _hw.capabilities();
      await _hw.startKiosk(); // no-op unless provisioned as device owner
      // Warm up the RF reader BEFORE the first poll so the initial read doesn't
      // hit an uninitialised reader ("no open window") on cold boot.
      if (_caps.nfc) {
        _diag = await _hw.warmUpNfc();
      } else {
        _diag = await _hw.nfcDiag();
      }
      if (mounted) setState(() {});
      _startLoop();
    });
  }

  @override
  void dispose() {
    _looping = false;
    _pulse.dispose();
    _breathe.dispose();
    _hw.stopKiosk();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  // ─────────────────────────── scan loop ───────────────────────────

  void _startLoop() {
    if (_looping) return;
    _looping = true;
    _loopTick();
  }

  Future<void> _loopTick() async {
    while (_looping && mounted) {
      if (_busy || _phase != _Phase.idle) {
        await Future.delayed(const Duration(milliseconds: 250));
        continue;
      }

      // 1) short QR scan window
      if (_caps.scanner) {
        final qr = await _hw.scanQrOnce(timeoutMs: 2500);
        if (!_looping) break;
        if (qr.ok && (qr.text?.isNotEmpty ?? false)) {
          await _showScanAlert(type: 'qr', content: qr.text!);
          continue;
        }
      }

      // 2) short NFC read window
      if (_caps.nfc) {
        final nfc = await _hw.readNfcOnce(timeoutMs: 2500);
        if (!_looping) break;
        if (nfc.ok && (nfc.uid?.isNotEmpty ?? false)) {
          await _showScanAlert(
            type: 'nfc',
            content: nfc.uid!,
            cardType: nfc.cardType,
          );
          continue;
        }
        // Refresh the on-screen diagnostic so we can see why RF isn't firing
        // (device list / open error / timeout) without needing adb logcat.
        final d = await _hw.nfcDiag();
        if (mounted && d != _diag) setState(() => _diag = d);
      }

      // If no hardware at all (web / normal phone), idle politely.
      if (!_caps.nfc && !_caps.scanner) {
        await Future.delayed(const Duration(milliseconds: 600));
      } else {
        // Small breather between cycles: lets the UI thread render the
        // idle animations smoothly and keeps CPU/heat low on the 24/7 device.
        await Future.delayed(const Duration(milliseconds: 120));
      }
    }
  }

  /// Shows an alert with the raw content read from the card / QR code.
  ///
  /// This is a diagnostics / demo step: no server validation yet — we simply
  /// display exactly what the hardware decoded so it can be confirmed on-device.
  Future<void> _showScanAlert({
    required String type,
    required String content,
    String? cardType,
  }) async {
    if (_busy || !mounted) return;
    _busy = true;
    HapticFeedback.mediumImpact();
    setState(() => _phase = _Phase.checking);

    final isNfc = type == 'nfc';
    final accent = isNfc ? const Color(0xFFFFB300) : MovaColors.heraldicRed;

    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha: 0.72),
      builder: (ctx) {
        return Dialog(
          backgroundColor: const Color(0xFF1A1620),
          insetPadding: const EdgeInsets.symmetric(horizontal: 24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: BorderSide(color: accent.withValues(alpha: 0.35), width: 1.2),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 74,
                  height: 74,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: accent.withValues(alpha: 0.14),
                    border: Border.all(color: accent.withValues(alpha: 0.5)),
                  ),
                  child: Icon(
                    isNfc ? Icons.contactless_rounded : Icons.qr_code_2_rounded,
                    color: accent,
                    size: 40,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  isNfc ? 'Card citit' : 'Cod QR citit',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  isNfc
                      ? 'Tehnologie: ${cardType ?? 'RF'}'
                      : 'Bilet digital scanat',
                  style: const TextStyle(
                    color: Color(0xFF9A93A6),
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 18),
                // Raw decoded content, selectable & scrollable.
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 180),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      content,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        fontFamily: 'monospace',
                        height: 1.35,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(30),
                      ),
                    ),
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text(
                      'Închide',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    HapticFeedback.heavyImpact();
    if (!mounted) {
      _busy = false;
      return;
    }
    setState(() => _phase = _Phase.idle);
    _busy = false;
  }

  // ─────────────────────────── UI ───────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MovaColors.darkBg,
      body: _idleScreen(),
    );
  }

  // ════════════════════════ IDLE (main) SCREEN ════════════════════════

  Widget _idleScreen() {
    return Stack(
      key: const ValueKey('idle'),
      fit: StackFit.expand,
      children: [
        _backgroundDecor(),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(26, 18, 26, 24),
            child: Column(
              children: [
                _brandRow(), // top: crest │ Primăria Municipiului Roman
                Expanded(child: _idleBody()), // headline + dual icons
                _statusPill(), // bottom: gold-outlined "Terminal pregătit"
                _diagLine(), // tiny NFC/RF diagnostic (only if present)
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Deep charcoal-to-black background with a faint dot-matrix texture in the
  /// lower-left corner (matches the WizarPOS "Validează călătoria" mockup).
  Widget _backgroundDecor() {
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0, -0.15),
              radius: 1.1,
              colors: [Color(0xFF141414), Color(0xFF0B0B0B)],
              stops: [0.0, 1.0],
            ),
          ),
        ),
        // Faint dot texture, anchored to the lower-left corner.
        Positioned.fill(child: CustomPaint(painter: _DotFieldPainter())),
      ],
    );
  }

  /// Top brand row: crest · vertical red divider · institution name + accent.
  Widget _brandRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const RomanCrest(size: 54, withShadow: true),
        const SizedBox(width: 18),
        // Thin vertical divider in a muted heraldic-red tone.
        Container(
          width: 1.5,
          height: 52,
          color: const Color(0xFFA62C2C),
        ),
        const SizedBox(width: 18),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Primăria',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w600,
                height: 1.18,
              ),
            ),
            const Text(
              'Municipiului Roman',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w600,
                height: 1.18,
              ),
            ),
            const SizedBox(height: 7),
            Container(
              width: 40,
              height: 2.5,
              decoration: BoxDecoration(
                color: MovaColors.heraldicRed,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _idleBody() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // ── Big headline (white / gold second line) ──
        const Text(
          'Validează',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontSize: 56,
            fontWeight: FontWeight.w900,
            letterSpacing: -1.8,
            height: 1.0,
          ),
        ),
        ShaderMask(
          shaderCallback: (r) => const LinearGradient(
            colors: [Color(0xFFFFD54F), Color(0xFFFFB300)],
          ).createShader(r),
          child: const Text(
            'călătoria',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 56,
              fontWeight: FontWeight.w900,
              letterSpacing: -1.8,
              height: 1.08,
            ),
          ),
        ),
        const SizedBox(height: 20),
        // Centered red accent line beneath the headline.
        Container(
          width: 44,
          height: 3.5,
          decoration: BoxDecoration(
            color: MovaColors.heraldicRed,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(height: 22),
        const Text(
          'Apropie abonamentul, cardul,\ntelefonul sau codul QR',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Color(0xFFCFCFCF),
            fontSize: 19,
            fontWeight: FontWeight.w400,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 50),
        // ── Dual icons floating directly on the background (no card) ──
        _dualIconRow(),
      ],
    );
  }

  /// The two validation methods presented as line-art icons floating directly
  /// on the dark background, separated by a faint vertical divider.
  Widget _dualIconRow() {
    return IntrinsicHeight(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: _optionColumn(
              animatedNfc: true,
              label: 'NFC / Contactless',
              sub: 'Abonament, card, telefon',
            ),
          ),
          Container(
            width: 1,
            margin: const EdgeInsets.symmetric(vertical: 4),
            color: Colors.white.withValues(alpha: 0.10),
          ),
          Expanded(
            child: _optionColumn(
              animatedNfc: false,
              label: 'Cod QR',
              sub: 'Bilet digital',
            ),
          ),
        ],
      ),
    );
  }

  Widget _optionColumn({
    required bool animatedNfc,
    required String label,
    required String sub,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 92,
          width: 124,
          child: animatedNfc
              ? AnimatedBuilder(
                  animation: _pulse,
                  builder: (context, _) =>
                      CustomPaint(painter: _NfcHandPainter(_pulse.value)),
                )
              : CustomPaint(painter: _QrScanPainter()),
        ),
        const SizedBox(height: 18),
        Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Color(0xFFFFB300),
            fontSize: 16.5,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.2,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          sub,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Color(0xFF888888),
            fontSize: 14,
            fontWeight: FontWeight.w400,
          ),
        ),
      ],
    );
  }

  /// Bottom gold-outlined status pill with a glowing amber indicator dot.
  ///
  /// Only shown when the terminal actually has NFC / scanner hardware — in
  /// web preview (no hardware) it is hidden entirely.
  Widget _statusPill() {
    final ok = _caps.nfc || _caps.scanner;
    if (!ok) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 17),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.02),
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: const Color(0xFF4A3E23), width: 1.2),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _breathe,
            builder: (context, _) => Container(
              width: 11,
              height: 11,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFFFB300),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFFFB300)
                        .withValues(alpha: 0.4 + 0.5 * _breathe.value),
                    blurRadius: 8 + 5 * _breathe.value,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 13),
          Flexible(
            child: Text(
              'Terminal pregătit pentru validare',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFFDDDDDD),
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Tiny diagnostic line shown under the status pill. Tap it to force a fresh
  /// RF init and refresh the trace. Only visible on the real device (when a
  /// diagnostic string exists and NFC hardware is expected).
  Widget _diagLine() {
    if (_diag.isEmpty || _diag == 'unsupported platform') {
      return const SizedBox.shrink();
    }
    final good = _diag.startsWith('CARD READ') || _diag.startsWith('open ok');
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: GestureDetector(
        onTap: () async {
          final d = await _hw.nfcDiag();
          if (mounted) setState(() => _diag = d);
        },
        child: Text(
          'NFC: $_diag',
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: good
                ? const Color(0xFF6FCF97)
                : MovaColors.darkTextSecondary.withValues(alpha: 0.7),
            fontSize: 11,
            fontFamily: 'monospace',
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────── painters ───────────────────────────

/// A faint dot-matrix texture anchored to the lower-left corner, fading out
/// toward the centre — the subtle background grain in the WizarPOS mockup.
class _DotFieldPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const spacing = 18.0;
    const dotRadius = 1.0;
    // Anchor point (lower-left) from which the dots fade out.
    final anchor = Offset(size.width * 0.12, size.height * 0.92);
    final maxDist = size.width * 0.75;
    final paintDot = Paint()..color = Colors.white;
    for (double y = size.height * 0.45; y < size.height; y += spacing) {
      for (double x = 0; x < size.width * 0.6; x += spacing) {
        final d = (Offset(x, y) - anchor).distance;
        final t = (1 - (d / maxDist)).clamp(0.0, 1.0);
        if (t <= 0.02) continue;
        paintDot.color = Colors.white.withValues(alpha: 0.06 * t);
        canvas.drawCircle(Offset(x, y), dotRadius, paintDot);
      }
    }
  }

  @override
  bool shouldRepaint(_DotFieldPainter old) => false;
}

/// NFC / Contactless icon: a hand cradling a payment card (tilted, front) and
/// a smartphone (upright, behind), with animated gold contactless waves
/// radiating from the upper area. Clean white line-art matching the mockup.
class _NfcHandPainter extends CustomPainter {
  final double t; // 0..1 wave animation
  _NfcHandPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..color = Colors.white;

    // ── Big prominent gold contactless waves radiating up-right ──
    final waveCenter = Offset(w * 0.30, h * 0.44);
    for (int i = 0; i < 3; i++) {
      final phase = (t + i / 3) % 1.0;
      final radius = 8 + phase * 20;
      final opacity = (1 - phase);
      final wave = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6
        ..strokeCap = StrokeCap.round
        ..shader = const LinearGradient(
          colors: [Color(0xFFFFD54F), Color(0xFFFFB300)],
        ).createShader(Rect.fromCircle(center: waveCenter, radius: radius));
      // arcs opening toward the upper-right (~70° pointing up-right)
      canvas.drawArc(
        Rect.fromCircle(center: waveCenter, radius: radius),
        -math.pi * 0.62, // start upper area
        math.pi * 0.62, // sweep down to the right
        false,
        wave..color = const Color(0xFFFFB300).withValues(alpha: opacity),
      );
    }

    // ── Payment card (tilted, front-left) ──
    canvas.save();
    canvas.translate(w * 0.42, h * 0.60);
    canvas.rotate(-0.32);
    final card = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset.zero, width: w * 0.36, height: h * 0.24),
      const Radius.circular(3),
    );
    canvas.drawRRect(card, line);
    // chip
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(-w * 0.10, -h * 0.01),
          width: w * 0.07,
          height: h * 0.07,
        ),
        const Radius.circular(1.5),
      ),
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
    canvas.restore();

    // ── Smartphone (upright, tilted, behind-right) ──
    canvas.save();
    canvas.translate(w * 0.66, h * 0.54);
    canvas.rotate(0.22);
    final phone = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset.zero, width: w * 0.24, height: h * 0.52),
      const Radius.circular(5),
    );
    canvas.drawRRect(phone, line);
    // speaker notch
    canvas.drawLine(
      Offset(-w * 0.035, -h * 0.21),
      Offset(w * 0.035, -h * 0.21),
      Paint()
        ..color = Colors.white
        ..strokeWidth = 1.4
        ..strokeCap = StrokeCap.round,
    );
    canvas.restore();

    // ── Hand cradling both from below ──
    final hand = Path()
      ..moveTo(w * 0.14, h * 0.66)
      ..quadraticBezierTo(w * 0.08, h * 0.98, w * 0.42, h * 0.98)
      ..lineTo(w * 0.70, h * 0.98)
      ..quadraticBezierTo(w * 0.88, h * 0.98, w * 0.86, h * 0.70);
    canvas.drawPath(hand, line);
    // thumb curving up on the left
    final thumb = Path()
      ..moveTo(w * 0.14, h * 0.66)
      ..quadraticBezierTo(w * 0.04, h * 0.56, w * 0.12, h * 0.46);
    canvas.drawPath(thumb, line);
  }

  @override
  bool shouldRepaint(_NfcHandPainter old) => old.t != t;
}

/// A white QR code on a dark field framed by four red L-shaped scanner
/// corner brackets — matching the WizarPOS mockup's "Cod QR" icon.
class _QrScanPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final cx = w / 2, cy = h / 2;
    final qr = math.min(w, h) * 0.60; // qr square side

    final white = Paint()..color = Colors.white;
    final ox = cx - qr / 2, oy = cy - qr / 2;

    // ── Finder patterns (three corner squares) ──
    final fs = qr * 0.30; // finder square size
    void finder(double fx, double fy) {
      // outer ring
      canvas.drawRect(Rect.fromLTWH(fx, fy, fs, fs), white);
      // knock out inner
      canvas.drawRect(
        Rect.fromLTWH(fx + fs * 0.18, fy + fs * 0.18, fs * 0.64, fs * 0.64),
        Paint()..color = const Color(0xFF0B0B0B),
      );
      // solid centre
      canvas.drawRect(
        Rect.fromLTWH(fx + fs * 0.34, fy + fs * 0.34, fs * 0.32, fs * 0.32),
        white,
      );
    }

    finder(ox, oy); // top-left
    finder(ox + qr - fs, oy); // top-right
    finder(ox, oy + qr - fs); // bottom-left

    // ── Scattered data modules ──
    final m = qr * 0.09; // module size
    final dots = <Offset>[
      Offset(0.55, 0.10), Offset(0.72, 0.14), Offset(0.90, 0.10),
      Offset(0.55, 0.28), Offset(0.86, 0.30),
      Offset(0.10, 0.55), Offset(0.28, 0.55), Offset(0.10, 0.72),
      Offset(0.50, 0.52), Offset(0.68, 0.58), Offset(0.86, 0.54),
      Offset(0.55, 0.72), Offset(0.72, 0.72), Offset(0.90, 0.72),
      Offset(0.50, 0.90), Offset(0.70, 0.88), Offset(0.88, 0.90),
    ];
    for (final d in dots) {
      canvas.drawRect(
        Rect.fromLTWH(ox + d.dx * qr - m / 2, oy + d.dy * qr - m / 2, m, m),
        white,
      );
    }

    // ── Red scanner corner brackets ──
    final bracket = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = MovaColors.heraldicRed;
    final b = qr / 2 + 8; // bracket half-extent from centre
    final len = qr * 0.30; // arm length
    void corner(double sx, double sy, double dx, double dy) {
      final p = Path()
        ..moveTo(cx + sx + dx, cy + sy)
        ..lineTo(cx + sx, cy + sy)
        ..lineTo(cx + sx, cy + sy + dy);
      canvas.drawPath(p, bracket);
    }

    corner(-b, -b, len, len); // top-left
    corner(b, -b, -len, len); // top-right
    corner(-b, b, len, -len); // bottom-left
    corner(b, b, -len, -len); // bottom-right
  }

  @override
  bool shouldRepaint(_QrScanPainter old) => false;
}

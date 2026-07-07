# ─────────────────────────────────────────────────────────────────────────
# CloudPOS / WizarPOS SDK keep rules.
#
# The whole native bridge (ValidatorHardwarePlugin) talks to the CloudPOS SDK
# via REFLECTION using the original, fully-qualified class + method names
# (e.g. Class.forName("com.cloudpos.POSTerminal").getMethod("getInstance", ...)).
# If R8/ProGuard renames or removes those classes/methods, the reflective
# lookup throws NoSuchMethodException / ClassNotFoundException (seen on device
# as "ensureRfDevice error: NoSuchMethodException c.b.getInstance ...").
#
# The SDK ships an EMPTY proguard.txt, so we must keep everything ourselves.
# ─────────────────────────────────────────────────────────────────────────

# Keep every CloudPOS class and ALL its members (fields + methods), un-renamed.
-keep class com.cloudpos.** { *; }
-keepnames class com.cloudpos.** { *; }
-keep interface com.cloudpos.** { *; }

# Keep the scanner AIDL stubs/interfaces used by the QR path.
-keep class com.cloudpos.scanserver.** { *; }
-keep class com.wizarpos.** { *; }

# Do not warn about SDK internals we don't reference directly.
-dontwarn com.cloudpos.**
-dontwarn com.wizarpos.**

# Flutter embedding (standard).
-keep class io.flutter.** { *; }
-dontwarn io.flutter.**

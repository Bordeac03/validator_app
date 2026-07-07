plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.transurban.transurban_validator"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    // AIDL classes for the CloudPOS scanner are bundled in the AAR.
    buildFeatures {
        aidl = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.transurban.transurban_validator"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(flutter.minSdkVersion, 23) // CloudPOS SDK requires API 23+
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")

            // The CloudPOS SDK is accessed entirely via reflection with the
            // ORIGINAL class/method names, and the SDK ships an empty
            // proguard.txt. If R8 obfuscates/strips those classes the reflective
            // calls fail (NoSuchMethodException c.b.getInstance ...), so we
            // disable code shrinking/obfuscation for the release build and also
            // provide explicit keep rules as a safety net.
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // WizarPOS CloudPOS SDK (NFC RFCardReader + barcode scanner AIDL + kiosk).
    implementation(files("libs/cloudpossdkV1.8.2.24_Standard.aar"))
}

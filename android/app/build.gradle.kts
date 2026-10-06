import java.util.Base64

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Stored in the signed APK, so update selection never infers the scanner from
// installed libraries (both scanner plugins are linked into these builds).
val updateDefines: Map<String, String> = (project.findProperty("dart-defines") as? String)
    ?.split(",")?.associate {
        val pair = String(Base64.getDecoder().decode(it)).split("=", limit = 2)
        pair[0] to pair.getOrElse(1) { "" }
    } ?: emptyMap()
val updateScanner = updateDefines["UPDATE_SCANNER"] ?: "fdroid"
require(updateScanner in setOf("fdroid", "mlkit")) { "Invalid UPDATE_SCANNER" }
val updatePackaging = if (project.findProperty("split-per-abi") == "true") "split" else "universal"

android {
    namespace = "com.github.futpib.iroh_ssh_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.github.futpib.iroh_ssh_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["updateScanner"] = updateScanner
        manifestPlaceholders["updatePackaging"] = updatePackaging
        manifestPlaceholders["updateBaseCode"] = flutter.versionCode.toString()
    }

    signingConfigs {
        val keystorePath = System.getenv("KEYSTORE_PATH")
        if (keystorePath != null) {
            create("release") {
                storeFile = file(keystorePath)
                storePassword = "android"
                keyAlias = "release"
                keyPassword = "android"
            }
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
        }
        release {
            signingConfig = if (signingConfigs.names.contains("release")) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

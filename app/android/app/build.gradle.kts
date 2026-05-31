import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Load release signing config from key.properties (kept out of version control).
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.jawnstoninc.jawnremote"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.jawnstoninc.jawnremote"
        // google_mobile_ads (GMA SDK) requires API 24+.
        minSdk = maxOf(24, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Use the upload key when key.properties exists; otherwise fall back to
            // debug signing so `flutter run --release` still works without it.
            signingConfig = if (keystorePropertiesFile.exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")

            // Keep R8 OFF for release.
            // Flutter 3.44 + AGP 8 run R8 in "full mode" by default, which strips
            // Room's generated WorkDatabase_Impl. The AdMob SDK pulls in
            // androidx.work (WorkManager), which auto-initializes that Room DB at
            // launch via androidx.startup — so a minified build crashes instantly
            // with "Failed to create an instance of androidx.work.impl.WorkDatabase".
            // On a Flutter app R8 only shrinks the small Java/Kotlin layer (the bulk
            // is libflutter.so + libapp.so, which R8 never touches), so disabling it
            // costs ~nothing and removes a whole class of release-only crashes.
            // If you ever re-enable minify, add keep rules for Room/WorkManager
            // (and the GMA + Play Billing SDKs) or set android.enableR8.fullMode=false.
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

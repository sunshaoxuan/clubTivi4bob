plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "io.github.clubanderson.clubtivi"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.briconbric.bobtv"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // Visible build counters may restart at a new release. Android install
        // codes must still increase, including upgrades from the legacy scheme.
        val parts = flutter.versionName.split('.').map { it.toInt() }
        val counter = flutter.versionCode
        versionCode = if (parts[0] > 1 || parts[0] == 1 && parts[1] >= 3) {
            require(parts[0] in 0..20 && parts[1] in 0..99 && parts[2] in 0..99 && counter in 0..999)
            ((parts[0] * 100 + parts[1]) * 100 + parts[2]) * 10000 + counter
        } else counter
        versionName = flutter.versionName
    }

    packaging { jniLibs { useLegacyPackaging = true } }

    signingConfigs {
        create("bobtvRelease") {
            System.getenv("BOBTV_ANDROID_KEYSTORE")?.let { storeFile = file(it) }
            storePassword = System.getenv("BOBTV_ANDROID_STORE_PASSWORD")
            keyAlias = System.getenv("BOBTV_ANDROID_KEY_ALIAS")
            keyPassword = System.getenv("BOBTV_ANDROID_KEY_PASSWORD")
        }
    }
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("bobtvRelease")
        }
    }
}

flutter {
    source = "../.."
}

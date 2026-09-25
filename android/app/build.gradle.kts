plugins {
    id("com.android.application")
    id("kotlin-android")
    // The DartNative Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("com.dartnative.gradle-plugin")
}

android {
    namespace = "dev.peerstream.peerstream"
    compileSdk = dartnative.compileSdkVersion
    ndkVersion = dartnative.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.peerstream.peerstream"
        // You can update the following values to match your application needs.
        // dartnative_video_player requires 26. Keep the higher of that and
        // the engine minimum.
        minSdk = maxOf(26, dartnative.minSdkVersion)
        targetSdk = dartnative.targetSdkVersion
        versionCode = dartnative.versionCode
        versionName = dartnative.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `dn run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

dartnative {
    source = "../.."
}

// Packages the prebuilt libtorrent bridge as liblibtorrent_flutter.so so
// DynamicLibrary.open can load it. The Flutter plugin gradle is not used.
val fetchLibtorrent = tasks.register<Exec>("fetchLibtorrent") {
    val script = rootProject.projectDir.parentFile.resolve("tool/fetch_libtorrent_android.sh")
    commandLine("sh", script.absolutePath)
}

tasks.named("preBuild").configure {
    dependsOn(fetchLibtorrent)
}

dependencies {
    // dartnative MainActivity extends DartNativeActivity (AppCompat-based);
    // com.dartnative.* classes come transitively from the dartnative_android
    // dependency via the plugin auto-inclusion.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("androidx.appcompat:appcompat:1.6.1")
    implementation("androidx.core:core-ktx:1.12.0")
}

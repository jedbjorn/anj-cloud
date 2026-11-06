import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// AnJ Cloud for Android (spec #28 A2; Build, Sign, Install). The release id is the
// stable technical id cloud.anj.anj_cloud (#30). Every debug and profile build is the QA build
// cloud.anj.anj_cloud.qa (#108 Q8): debuggable, with its own app id, profile and (from
// A5) provider authority, so agent checks never touch the real profile or its grants.
// Release signing (A8, spec #40 R1, decision #108 Q6): the key lives on the VM host only, outside every
// worktree (~/.local/share/anj-cloud/signing/android/). tool/android/release_android.py build
// names its properties file in ANJ_ANDROID_SIGNING; without it a release build stays unsigned.
// ANJ_SOURCE_HEAD is the commit a release was built from, stamped into the manifest as
// cloud.anj.source_head so deploy/release.py can check it is on main (empty otherwise).
val releaseSigning: Properties? = System.getenv("ANJ_ANDROID_SIGNING")?.takeIf { it.isNotBlank() }?.let { path ->
    Properties().apply { file(path).inputStream().use { load(it) } }
}

android {
    namespace = "cloud.anj.anj_cloud"
    compileSdk = 36
    ndkVersion = "28.2.13676358" // decision #102

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "cloud.anj.anj_cloud"
        minSdk = 31 // Android 12 (#108 Q7); A1 found nothing that needs more
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Generic ABI baselines (#12): arm64-v8a for phones, x86_64 for the VM host emulator.
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
        externalNativeBuild { ndkBuild { abiFilters("arm64-v8a", "x86_64") } }
        manifestPlaceholders["appLabel"] = "AnJ Cloud"
        manifestPlaceholders["sourceHead"] = System.getenv("ANJ_SOURCE_HEAD") ?: ""
    }

    // No encrypted dependency metadata in the APK signing block: it is random per build (the
    // release would not be reproducible) and only Google Play reads it.
    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
    }

    signingConfigs {
        if (releaseSigning != null) {
            create("release") {
                storeFile = file(releaseSigning.getProperty("storeFile"))
                storePassword = releaseSigning.getProperty("storePassword")
                keyAlias = releaseSigning.getProperty("keyAlias")
                keyPassword = releaseSigning.getProperty("keyPassword")
                storeType = "PKCS12"
            }
        }
    }

    // libanj_rootfs.so: the shared anj_* boundary (native/posix/rootfs.cc) with the
    // Android primitives of decision #123 (native/posix/compat_android.h).
    externalNativeBuild { ndkBuild { path = file("../../native/android/Android.mk") } }

    buildTypes {
        debug {
            applicationIdSuffix = ".qa"
            manifestPlaceholders["appLabel"] = "AnJ Cloud QA"
        }
        // Flutter's plugin creates `profile` with initWith(debug) before this block runs,
        // so it would keep the release id and the debug key: an APK that blocks the
        // signed release from updating over it (PR #60 F4). Profile builds are QA builds.
        getByName("profile") {
            applicationIdSuffix = ".qa"
            manifestPlaceholders["appLabel"] = "AnJ Cloud QA"
        }
        release {
            signingConfig = if (releaseSigning != null) signingConfigs.getByName("release") else null
            // R8 (minify) as Flutter configures it, plus the app's own keep rules.
            proguardFiles("proguard-rules.pro")
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

// Background sync (spec #28 A4, decision #108 Q3): WorkManager's periodic and expedited
// work, which persists across reboots.
dependencies {
    implementation("androidx.work:work-runtime-ktx:2.10.5")
    testImplementation("junit:junit:4.13.2")
}

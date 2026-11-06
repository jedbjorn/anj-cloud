// Test apps for the AnJ Cloud documents provider (spec #28 A5, emulator seat E). Adapted from the
// A1 probe's grantee (apps/android-probe on main). Not shipped.
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
plugins {
    id("com.android.application") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}
rootProject.name = "anj-a5-grantee"
include(":app")

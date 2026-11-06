plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "cloud.anj.grantee"
    buildFeatures { resValues = true }
    compileSdk = 36
    defaultConfig {
        minSdk = 31
        targetSdk = 36
        versionCode = 1
        versionName = "a5-grantee"
        // The QA build's provider authority (cloud.anj.anj_cloud.qa, #108 Q8).
        manifestPlaceholders["anjAuthority"] = "cloud.anj.anj_cloud.qa.documents"
    }
    // Three independent apps: g1 and g2 are approved for folders; g3 picks a folder and is never approved.
    flavorDimensions += "app"
    productFlavors {
        create("g1") { dimension = "app"; applicationId = "cloud.anj.anj_cloud.qa.grantee1"; resValue("string", "app_name", "AnJ Grantee 1") }
        create("g2") { dimension = "app"; applicationId = "cloud.anj.anj_cloud.qa.grantee2"; resValue("string", "app_name", "AnJ Grantee 2") }
        create("g3") { dimension = "app"; applicationId = "cloud.anj.anj_cloud.qa.grantee3"; resValue("string", "app_name", "AnJ Grantee 3") }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin { compilerOptions { jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17 } }

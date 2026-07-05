plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.tono.app"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.tono.app"
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = "0.1.0"

        // 10.0.2.2 is the Android emulator's alias for the host machine's
        // localhost — matches `uvicorn Backend.server:app --port 8765` run
        // from apps/backend on your dev machine. Override per build variant
        // (or via -PtonoApiUrl=...) for a real device or deployed backend.
        buildConfigField("String", "TONO_API_URL", "\"http://10.0.2.2:8765\"")
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }
    composeOptions {
        kotlinCompilerExtensionVersion = "1.5.14"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.activity:activity-compose:1.9.1")
    // FragmentActivity (BiometricPrompt's host requirement) + the actual
    // Face/Fingerprint/PIN prompt API — see ui/BiometricGate.kt.
    implementation("androidx.fragment:fragment-ktx:1.8.2")
    implementation("androidx.biometric:biometric:1.1.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.4")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.4")
    implementation(platform("androidx.compose:compose-bom:2024.06.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    // Chrome Custom Tabs, for opening Stripe's hosted Checkout/Portal pages —
    // an in-app OkHttp client can't render them, and a plain WebView would
    // fail Stripe's iframe/redirect handling.
    implementation("androidx.browser:browser:1.8.0")
}

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.tono.ime"
    // Bumped 34 → 35 for the ML Kit GenAI (Gemini Nano) on-device rewrite
    // boundary (`com.google.mlkit:genai-rewriting`), which requires an API 35
    // compile SDK. minSdk stays 26 (ML Kit GenAI's own floor is also API 26).
    compileSdk = 35

    defaultConfig { minSdk = 26 }

    buildFeatures { compose = true }
    composeOptions { kotlinCompilerExtensionVersion = "1.5.8" }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
        // ML Kit GenAI (genai-rewriting:1.0.0-beta1) ships Kotlin 2.1.0 metadata;
        // this project is on Kotlin 1.9.22. Relax ONLY the metadata-version gate
        // so we can call ML Kit's (simple, Java-facing) API surface without
        // dragging the whole toolchain to Kotlin 2.x — which would churn the
        // Compose compiler pin and every module. Compile-only; no runtime effect.
        freeCompilerArgs = freeCompilerArgs + "-Xskip-metadata-version-check"
    }
}

dependencies {
    implementation(project(":shared"))
    implementation(platform("androidx.compose:compose-bom:2024.04.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.7.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.7.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.7.0")
    implementation("androidx.savedstate:savedstate:1.2.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")

    // ML Kit GenAI — the Gemini Nano on-device rewrite engine (via AICore).
    // This is the ONLY module that links ML Kit: the provider/router/availability
    // seams live in :shared as pure Kotlin so they are JVM-unit-testable without
    // a device. Beta channel: on-device generation is DEVICE_VERIFIED = NO here
    // (no AICore/Gemini Nano on CI). See docs/google-intelligence-readiness.md.
    implementation("com.google.mlkit:genai-rewriting:1.0.0-beta1")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.7.3")
}

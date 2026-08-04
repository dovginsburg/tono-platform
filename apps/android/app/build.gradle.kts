// Load keystore credentials from keystore.properties (gitignored) — never commit literal passwords
import java.util.Properties
val keystorePropsFile = rootProject.file("keystore.properties")
val keystoreProps = Properties()
if (keystorePropsFile.exists()) {
    keystorePropsFile.inputStream().use { keystoreProps.load(it) }
}

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.serialization")
}

android {
    namespace = "com.tono.app"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.tono.myapp"
        minSdk = 26
        targetSdk = 35
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // Android Build 120 makes coupon redemption canonical-account based while
        // preserving the Build 118 IME attach repair. iOS remains
        // CFBundleVersion 117 because this is an Android-only repair successor.
        //
        // Source floor is 114 (Build 114 alignment commit); codes 16–113 were
        // burned by that jump and cannot be reused. Live codes observed on
        // Google Play: 13 (internal) and 15 (alpha draft); 119 strictly exceeds
        // both.
        //
        // One-way door: Google Play requires versionCode to increase strictly.
        versionCode = 120
        versionName = "1.1"
    }

    signingConfigs {
        create("release") {
            storeFile = file("../tono-release.keystore")
            storePassword = keystoreProps.getProperty("storePassword", "")
            keyAlias = keystoreProps.getProperty("keyAlias", "tono")
            keyPassword = keystoreProps.getProperty("keyPassword", "")
        }
    }

    buildTypes {
        debug {
            isDebuggable = true
            buildConfigField("String", "BACKEND_URL", "\"http://10.0.2.2:8765\"")
            // RevenueCat canary kill switch (Build 123). Empty = dormant by
            // default; the publishable goog_ key is injected per build/environment
            // and never committed. Backend stays the sole entitlement authority.
            buildConfigField("String", "REVENUECAT_PUBLIC_SDK_KEY", "\"\"")
            // RevenueCat canary routing mode (Build 126): off | shadow |
            // authoritative. Default off preserves the existing Play billing path;
            // it mirrors the backend TONO_REVENUECAT_MODE and the web
            // NEXT_PUBLIC_REVENUECAT_MODE. Injected per environment, never committed.
            buildConfigField("String", "REVENUECAT_MODE", "\"off\"")
        }
        release {
            isMinifyEnabled = true
            signingConfig = signingConfigs.getByName("release")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            buildConfigField("String", "BACKEND_URL", "\"https://api.tonoit.com\"")
            buildConfigField("String", "REVENUECAT_PUBLIC_SDK_KEY", "\"\"")
            buildConfigField("String", "REVENUECAT_MODE", "\"off\"")
            lint {
                abortOnError = false
            }
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }
    composeOptions { kotlinCompilerExtensionVersion = "1.5.8" }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    implementation(project(":shared"))
    implementation(project(":ime"))

    implementation(platform("androidx.compose:compose-bom:2024.04.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.navigation:navigation-compose:2.7.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.7.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.7.0")
    implementation("androidx.activity:activity-compose:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.3")

    // Google Play Billing (mirrors StoreKit 2 on iOS)
    implementation("com.android.billingclient:billing-ktx:6.2.1")

    // RevenueCat canary (Build 123). 7.x is pinned deliberately: it uses Play
    // Billing 6.x, so it does NOT force-upgrade the existing PlayBillingManager's
    // billing-ktx 6.2.1 (8.x would pull Billing 7.x). Additive + kill-switched;
    // the existing Play billing path is unchanged and backend stays authoritative.
    implementation("com.revenuecat.purchases:purchases:7.12.0")

    // Fragment — pinned to fix InvalidFragmentVersionForActivityResult lint error
    implementation("androidx.fragment:fragment-ktx:1.6.2")

    // WorkManager — weekly digest background scheduling
    implementation("androidx.work:work-runtime-ktx:2.9.0")

    testImplementation("junit:junit:4.13.2")

    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.test:core-ktx:1.5.0")

    androidTestImplementation("androidx.test.ext:junit:1.1.5")
    androidTestImplementation("androidx.test:runner:1.5.2")
    androidTestImplementation("androidx.test:rules:1.5.0")
    androidTestImplementation("androidx.test:core-ktx:1.5.0")
    androidTestImplementation("androidx.test.uiautomator:uiautomator:2.3.0")
}

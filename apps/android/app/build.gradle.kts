// Load keystore credentials from keystore.properties (gitignored) — never commit literal passwords
import java.util.Properties
val keystorePropsFile = rootProject.file("keystore.properties")
val keystoreProps = Properties()
if (keystorePropsFile.exists()) {
    keystorePropsFile.inputStream().use { keystoreProps.load(it) }
}

// RevenueCat release-injection seam (Build 126). The publishable `goog_` key and
// the canary routing mode are supplied at BUILD time from an explicit CI Gradle
// property (`-P<name>`) or an environment variable — NEVER committed. Precedence:
// Gradle property > environment variable > fail-closed default. Both defaults
// fail closed: an empty key leaves RevenueCat dormant (kill switch off), and an
// absent/blank mode is `off` (the existing Play billing path). The runtime
// `RevenueCatMode.parse` additionally fails closed on any unknown value, so an
// invalid injected mode can never enable RevenueCat. The returned value is escaped
// so it is always a safe Java String literal inside `buildConfigField`.
fun revenueCatInjected(gradleProp: String, envVar: String, fallback: String): String {
    val raw = (project.findProperty(gradleProp) as String?)?.takeIf { it.isNotBlank() }
        ?: System.getenv(envVar)?.takeIf { it.isNotBlank() }
        ?: fallback
    return raw.replace("\\", "\\\\").replace("\"", "\\\"")
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
        //
        // 121 (Ari blank-letters blocker): versionCode 120 is ALREADY CONSUMED on
        // Google Play (bundle present on the package; internal track shipped it).
        // The QWERTY letter-key keyboard landed on 2026-08-02 (2358de9) — three
        // days AFTER 120 was set (2026-07-30, 0cba6da) — and did not bump the
        // code, so the artifact testers can install as 120 predates letter keys
        // and Play refuses to accept a replacement under the same code. Shipping
        // the keyboard to a device therefore REQUIRES a new code; this is that
        // code. Do not lower it back to 120: that would silently re-block the fix.
        versionCode = 121
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
            // RevenueCat canary kill switch (Build 123) + routing mode (Build 126),
            // both injected at build time and never committed. Fail-closed defaults:
            // key "" (dormant), mode "off" (existing Play path). See
            // revenueCatInjected above for the property/env precedence.
            buildConfigField("String", "REVENUECAT_PUBLIC_SDK_KEY", "\"${revenueCatInjected("revenueCatPublicSdkKey", "REVENUECAT_PUBLIC_SDK_KEY", "")}\"")
            buildConfigField("String", "REVENUECAT_MODE", "\"${revenueCatInjected("revenueCatMode", "REVENUECAT_MODE", "off")}\"")
        }
        release {
            isMinifyEnabled = true
            signingConfig = signingConfigs.getByName("release")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            buildConfigField("String", "BACKEND_URL", "\"https://api.tonoit.com\"")
            // Release injection seam (Build 126): CI supplies the publishable goog_
            // key and the off/shadow/authoritative mode via Gradle property or env
            // var; both fail closed (key "" dormant, mode "off") when unset.
            buildConfigField("String", "REVENUECAT_PUBLIC_SDK_KEY", "\"${revenueCatInjected("revenueCatPublicSdkKey", "REVENUECAT_PUBLIC_SDK_KEY", "")}\"")
            buildConfigField("String", "REVENUECAT_MODE", "\"${revenueCatInjected("revenueCatMode", "REVENUECAT_MODE", "off")}\"")
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

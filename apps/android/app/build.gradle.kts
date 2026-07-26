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
        // Build 114. Aligned with the iOS CFBundleVersion so one release number
        // describes the whole product — the Android email account lane and the
        // iOS one ship the same contract, and a support question that arrives as
        // "build 114" must mean the same thing on either platform.
        //
        // One-way door: Google Play requires versionCode to increase strictly and
        // forever, so codes 16–113 are burned by this jump and cannot be reused.
        // Nothing is uploaded by this change; the number simply becomes the floor
        // for every future Android release.
        versionCode = 114
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
        }
        release {
            isMinifyEnabled = true
            signingConfig = signingConfigs.getByName("release")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            buildConfigField("String", "BACKEND_URL", "\"https://api.tonoit.com\"")
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

    // Fragment — pinned to fix InvalidFragmentVersionForActivityResult lint error
    implementation("androidx.fragment:fragment-ktx:1.6.2")

    // WorkManager — weekly digest background scheduling
    implementation("androidx.work:work-runtime-ktx:2.9.0")

    testImplementation("junit:junit:4.13.2")

    debugImplementation("androidx.compose.ui:ui-tooling")
}

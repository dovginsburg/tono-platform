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

    // ── App Functions EAP gate (default OFF; the checked-in build never sets it) ──
    //
    // Android App Functions is an experimental preview: it needs Android 16
    // (compileSdk 36), the alpha `androidx.appfunctions` library + a KSP
    // compiler that requires Kotlin 2.x, and — critically — admission to
    // Google's Early Access Program before any system agent (Gemini included)
    // can invoke a function end-to-end. As of May 2026 that integration is a
    // private preview with trusted testers. None of that contract is met on the
    // checked-in toolchain (Kotlin 1.9.22), so the annotated `@AppFunction`
    // service under src/appFunctionsEap/ is NOT compiled by default and the
    // runtime seam fails closed (AppFunctionGate → DISABLED_BY_BUILD).
    //
    // A developer admitted to the EAP, on Kotlin 2.x + KSP + Android 16, flips
    // `-Ptono.appfunctions.eap=true` and follows docs/google-intelligence-
    // readiness.md to add the alpha deps, the KSP compiler, compileSdk 36, and
    // the service manifest entry. Until then, this block only wires the source
    // directory so the integration point is discoverable, and warns about the
    // manual toolchain steps.
    if ((project.findProperty("tono.appfunctions.eap") as? String)?.toBoolean() == true) {
        logger.warn(
            "tono.appfunctions.eap=true: App Functions EAP source is included, but it " +
            "additionally requires Kotlin 2.x, the androidx.appfunctions alpha + KSP " +
            "compiler, compileSdk 36, EAP admission, and the service manifest entry " +
            "(see docs/google-intelligence-readiness.md). It will NOT compile on the " +
            "checked-in Kotlin 1.9.22 toolchain.",
        )
        sourceSets.getByName("main").java.srcDir("src/appFunctionsEap/java")
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
    kotlinOptions {
        jvmTarget = "17"
        // ML Kit GenAI (pulled transitively from :ime at runtime/lint time) ships
        // Kotlin 2.1.0 metadata; this project is on Kotlin 1.9.22. Relax ONLY the
        // metadata-version gate so lint's classpath analysis does not choke on it.
        // Compile-only; :app links no ML Kit symbol directly. Same rationale as :ime.
        freeCompilerArgs = freeCompilerArgs + "-Xskip-metadata-version-check"
    }
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
    debugImplementation("androidx.test:core-ktx:1.5.0")

    androidTestImplementation("androidx.test.ext:junit:1.1.5")
    androidTestImplementation("androidx.test:runner:1.5.2")
    androidTestImplementation("androidx.test:rules:1.5.0")
    androidTestImplementation("androidx.test:core-ktx:1.5.0")
    androidTestImplementation("androidx.test.uiautomator:uiautomator:2.3.0")
}

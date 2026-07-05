// Root build file. Per-module config lives in app/build.gradle.kts — this
// file only pins plugin versions once so the module resolves a consistent
// Kotlin/AGP/Compose toolchain. The IME (keyboard) and the companion UI
// live in the single :app module, same APK, same manifest — unlike iOS,
// Android input methods are just a Service, not a separate app extension
// target, so there's no structural reason to split them.
plugins {
    id("com.android.application") version "8.5.2" apply false
    id("org.jetbrains.kotlin.android") version "1.9.24" apply false
}

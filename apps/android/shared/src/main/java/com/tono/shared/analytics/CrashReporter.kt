package com.tono.shared.analytics

import android.content.Context

// Mirrors ios/Shared/CrashReporter.swift
// No-op stub today. Firebase Crashlytics activates when the firebase-crashlytics
// Gradle plugin and google-services.json are added.
//
// ─── ANDROID SETUP (one-time, when adding Firebase) ──────────────────────────
// 1. Add to root build.gradle.kts:
//      id("com.google.gms.google-services") version "4.4.1" apply false
//      id("com.google.firebase.crashlytics") version "3.0.1" apply false
//
// 2. Apply in app/build.gradle.kts:
//      id("com.google.gms.google-services")
//      id("com.google.firebase.crashlytics")
//
// 3. Add to app/build.gradle.kts dependencies:
//      implementation(platform("com.google.firebase:firebase-bom:32.8.1"))
//      implementation("com.google.firebase:firebase-crashlytics-ktx")
//
// 4. Download google-services.json from the Firebase console and place it
//    in android/app/google-services.json.
//
// 5. In TonoApplication.onCreate(), call CrashReporter.configure(this).
//    For the IME service, call it in TonoImeService.onCreate().
//
// ─── EXTENSION MEMORY NOTE ────────────────────────────────────────────────────
// Unlike iOS, Android IME services share the app process, so Crashlytics
// has no additional footprint in the keyboard vs the host app.
// ─────────────────────────────────────────────────────────────────────────────

object CrashReporter {

    fun configure(context: Context) {
        // Firebase.initialize(context) — uncomment after adding Firebase dependency
    }

    fun setCustomKey(value: Any, key: String) {
        // FirebaseCrashlytics.getInstance().setCustomKey(key, value.toString())
    }

    fun addBreadcrumb(message: String) {
        // FirebaseCrashlytics.getInstance().log(message)
    }

    fun setUserId(id: String) {
        // FirebaseCrashlytics.getInstance().setUserId(id)
    }
}

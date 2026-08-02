package com.tono.shared.intelligence

import com.tono.shared.storage.SharedStore

// Google-intelligence readiness — the App Functions availability gate and the
// one-shot navigation signal. Android mirror of the Apple App-Intents pieces:
// the availability half mirrors `PrivateCloudCompute.swift`'s fail-closed
// PCC seam (a capability the current toolchain cannot honestly claim), and the
// route signal mirrors `AppIntentRouting.swift` one-for-one.
//
// HONEST FRAMING FIRST. Per Google's own documentation (developer.android.com/
// ai/appfunctions, read 2026-08-02):
//   • AppFunctions is "in an experimental preview ... subject to change".
//   • It is "available on devices running Android 16 or higher" and requires
//     `compileSdk` API level 36+.
//   • "As of May 2026, AppFunctions integration with Gemini is in a private
//     preview with trusted testers." Only "a limited number of apps and system
//     agents can access the entire pipeline", gated behind an Early Access
//     Program: registering interest does NOT grant access.
//   • Callers need the `EXECUTE_APP_FUNCTIONS` permission; the service is bound
//     with `android.permission.BIND_APP_FUNCTION_SERVICE`.
//   • The library is `androidx.appfunctions:appfunctions:1.0.0-alpha10` plus a
//     KSP `appfunctions-compiler`, which requires Kotlin 2.x — this module is on
//     Kotlin 1.9.22.
//
// So the system-agent contract is NOT met on the checked-in build, and Tono
// must NOT claim Gemini can invoke its functions end-to-end. This file
// implements the SEAM and the STATES, fail-closed, and the real @AppFunction
// service is quarantined out of every compiled source set (see
// app/src/appFunctionsEap/ and docs/google-intelligence-readiness.md). Compiling
// an annotation is not the same as a system agent being able to invoke it.

// MARK: - Availability (fail-closed)

/**
 * What the App Functions seam reports about itself. Only [SUPPORTED] means a
 * system agent could actually discover and invoke Tono's functions; every other
 * case is a distinct, honest reason it cannot. There is no "unknown = maybe"
 * state — the whole contract is fail-closed, and on the checked-in build the
 * honest answer is always one of the not-supported cases.
 */
enum class AppFunctionAvailability(val reasonCode: String) {
    /** Below Android 16 (API 36): the platform has no App Functions surface. */
    UNSUPPORTED_OS("unsupported_os"),

    /**
     * The App Functions code was compiled OUT of this build (the checked-in
     * default). The `@AppFunction` service, its alpha dependency, and its KSP
     * processor are all behind the `tono.appfunctions.eap` Gradle flag, which is
     * off. Nothing to invoke because nothing was built.
     */
    DISABLED_BY_BUILD("disabled_by_build"),

    /** Android 16+, but `AppFunctionManager` reported the feature unsupported. */
    MANAGER_UNAVAILABLE("manager_unavailable"),

    /**
     * Everything is present, but this app is not admitted to the Early Access
     * Program, so no system agent (Gemini included) can reach the pipeline. Per
     * Google: EAP admission is required and is not automatic.
     */
    EAP_NOT_ADMITTED("eap_not_admitted"),

    /**
     * Fully wired AND admitted: a system agent can discover and invoke Tono's
     * functions. Unreachable on the current toolchain; present so the gate has a
     * true state to return once every condition is genuinely met.
     */
    SUPPORTED("supported");

    /** The single gate. Only [SUPPORTED] permits exposing App Functions. */
    val isAvailable: Boolean get() = this == SUPPORTED
}

/**
 * The pure, total decision for App Functions availability. Fail-closed: every
 * unmet condition short-circuits to the honest reason, in the order a caller
 * can actually observe them (built? OS? manager? admitted?). Same inputs →
 * same output, no I/O — so the whole matrix is unit-testable on a plain JVM.
 */
object AppFunctionGate {

    // The facts, named as constants rather than inlined, so tests and docs cite
    // the exact values and nothing hard-codes a guessed string.
    const val MINIMUM_ANDROID_SDK = 36          // Android 16
    const val LIBRARY_COORDINATE = "androidx.appfunctions:appfunctions:1.0.0-alpha10"
    const val COMPILER_COORDINATE = "androidx.appfunctions:appfunctions-compiler:1.0.0-alpha10"
    const val EXECUTE_PERMISSION = "android.permission.EXECUTE_APP_FUNCTIONS"
    const val BIND_PERMISSION = "android.permission.BIND_APP_FUNCTION_SERVICE"

    /**
     * Whether the `@AppFunction` service is compiled into THIS build. The
     * checked-in build never defines `tono.appfunctions.eap`, so this is always
     * `false` here. A source constant is not a capability: it reports the build,
     * it does not grant one. (Mirror of iOS `PCCEntitlement.isGrantedInThisBuild`.)
     */
    const val COMPILED_INTO_THIS_BUILD = false

    /**
     * Decide App Functions availability, fail-closed.
     *
     * @param compiledIntoBuild whether the EAP source set was built in.
     * @param osSdkInt the running platform SDK int (Build.VERSION.SDK_INT).
     * @param managerPresent whether `AppFunctionManager` resolved non-null.
     * @param eapAdmitted whether Google admitted this app to the EAP. There is
     *   no way to assert this true on the checked-in build; it is an input so
     *   the gate can be exercised in tests, never a self-granted claim.
     */
    fun decide(
        compiledIntoBuild: Boolean,
        osSdkInt: Int,
        managerPresent: Boolean,
        eapAdmitted: Boolean,
    ): AppFunctionAvailability = when {
        !compiledIntoBuild             -> AppFunctionAvailability.DISABLED_BY_BUILD
        osSdkInt < MINIMUM_ANDROID_SDK -> AppFunctionAvailability.UNSUPPORTED_OS
        !managerPresent                -> AppFunctionAvailability.MANAGER_UNAVAILABLE
        !eapAdmitted                   -> AppFunctionAvailability.EAP_NOT_ADMITTED
        else                           -> AppFunctionAvailability.SUPPORTED
    }

    /**
     * The availability of the checked-in build, computed from the honest
     * constants. Always [AppFunctionAvailability.DISABLED_BY_BUILD] because the
     * EAP source set is not compiled in. Fail-closed by construction.
     */
    fun currentBuildAvailability(osSdkInt: Int): AppFunctionAvailability =
        decide(
            compiledIntoBuild = COMPILED_INTO_THIS_BUILD,
            osSdkInt = osSdkInt,
            managerPresent = false,
            eapAdmitted = false,
        )
}

// MARK: - One-shot navigation signal (route only, never text)

/**
 * A screen an App Function can ask the host app to show. Closed set on purpose:
 * a function may only request a known destination, never an arbitrary deep link
 * or any payload. Mirror of iOS `AppIntentRoute`.
 */
enum class AppFunctionRoute(val id: String) {
    /** The keyboard setup screen (enable Tono in Settings). Entirely local. */
    KEYBOARD_SETUP("keyboard_setup");

    companion object {
        fun from(raw: String?): AppFunctionRoute? = entries.firstOrNull { it.id == raw }
    }
}

/**
 * Persistence for a single pending route. One-shot by contract: [consumePending]
 * reads AND clears, so a route presents its screen once rather than on every
 * foreground. It carries a route ENUM and nothing else — never message text,
 * never a draft, never account data. Mirror of iOS `AppIntentRouteSignal`.
 */
object AppFunctionRouteSignal {
    const val KEY = "tc.appFunctionPendingRoute.v1"

    /** Record a pending route. An App Function calls this, then returns. */
    fun request(route: AppFunctionRoute) = SharedStore.putString(KEY, route.id)

    /** Read WITHOUT clearing. For tests and diagnostics. */
    fun peekPending(): AppFunctionRoute? = AppFunctionRoute.from(SharedStore.getString(KEY))

    /** Read AND clear. The app calls this once per foreground. */
    fun consumePending(): AppFunctionRoute? {
        val route = AppFunctionRoute.from(SharedStore.getString(KEY))
        SharedStore.remove(KEY)
        return route
    }

    /** Drop any pending route without acting on it. */
    fun clear() = SharedStore.remove(KEY)
}

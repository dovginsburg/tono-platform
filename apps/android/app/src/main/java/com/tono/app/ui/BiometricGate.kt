package com.tono.app.ui

import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL
import androidx.biometric.BiometricPrompt
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity

private const val ALLOWED_AUTHENTICATORS = BIOMETRIC_STRONG or DEVICE_CREDENTIAL

/**
 * Face ID / fingerprint / Windows-Hello-equivalent for Android: gates the
 * Coach screen behind BiometricPrompt (Face/Fingerprint, falling back to
 * device PIN/pattern if no biometric is enrolled) before showing anything.
 *
 * Deliberately account-agnostic for now — it gates every launch, not just
 * ones where a Pro account is linked. A follow-up could make this an
 * opt-in "App Lock" setting or only trigger when `/v1/me` reports a linked
 * account, but doing that requires a network round-trip before the UI can
 * decide whether to gate at all, which is worse for the common case (an
 * anonymous free user who's never signed in) than just always gating on
 * devices that already have biometrics set up for something else.
 *
 * Devices with no biometric hardware, or a user who's never enrolled one,
 * skip the gate entirely — this must never lock someone out of the app
 * their only unlock method doesn't support.
 */
@Composable
fun BiometricGate(content: @Composable () -> Unit) {
    val context = LocalContext.current
    val activity = context as? FragmentActivity

    val canAuthenticate = remember {
        BiometricManager.from(context).canAuthenticate(ALLOWED_AUTHENTICATORS) ==
            BiometricManager.BIOMETRIC_SUCCESS
    }

    // Nothing to gate with — show the app directly rather than blocking access.
    if (!canAuthenticate || activity == null) {
        content()
        return
    }

    var unlocked by remember { mutableStateOf(false) }
    var promptShown by remember { mutableStateOf(false) }

    fun launchPrompt() {
        val executor = ContextCompat.getMainExecutor(context)
        val prompt = BiometricPrompt(
            activity,
            executor,
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    unlocked = true
                }
                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    // User canceled or hit an error (e.g. too many attempts) —
                    // leave `unlocked = false` so the lock screen's retry
                    // button is what re-triggers the prompt, not a loop.
                }
            },
        )
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle("Unlock Tono")
            .setSubtitle("Confirm it's you before coaching your messages")
            .setAllowedAuthenticators(ALLOWED_AUTHENTICATORS)
            .build()
        prompt.authenticate(info)
    }

    LaunchedEffect(Unit) {
        if (!promptShown) {
            promptShown = true
            launchPrompt()
        }
    }

    if (unlocked) {
        content()
    } else {
        Column(
            modifier = Modifier.fillMaxSize(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Text("tono is locked", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(16.dp))
            Button(onClick = { launchPrompt() }) {
                Text("unlock")
            }
        }
    }
}

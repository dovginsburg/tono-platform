package com.tono.app.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.tono.shared.account.EmailAccountAction
import com.tono.shared.account.EmailAccountCopy
import com.tono.shared.account.EmailAccountPolicy
import com.tono.shared.account.EmailAddress
import com.tono.shared.account.EmailAuthException
import com.tono.shared.account.EmailAuthOutcome
import com.tono.shared.network.TonoBackend
import com.tono.shared.storage.SecureStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import androidx.compose.runtime.rememberCoroutineScope

/**
 * Build 114 — the Android email account surface. Parity with
 * `ios/App/OnboardingEntryPointsView.swift` `EmailSignInSheet`.
 *
 * Create an account, confirm the address, sign in, resend the confirmation, and
 * recover a forgotten password — the same five things, against the same account
 * lane the iOS client uses, so a person who signed up on iPhone signs in here
 * and lands on the identical canonical account.
 *
 * Three properties this composable holds:
 *
 *   1. **Confirmation is mandatory.** Nothing here writes the signed-in address.
 *      Only `TonoBackend.signInWithEmail` does, and only after the server says
 *      the address is proven. An unconfirmed sign-in lands on [Step.ConfirmSent]
 *      instead of reporting success.
 *   2. **It is not an account oracle.** Creating an account, resending, and
 *      resetting all render the SAME sentence whether or not the address is
 *      registered, because [EmailAccountCopy] gives them the same one.
 *   3. **No implementation detail reaches the screen.** Every sentence comes
 *      from [EmailAccountCopy.message], which takes an outcome and an action —
 *      never an exception, a status code, or a response body.
 */

private enum class Step { SignIn, CreateAccount, ConfirmSent }

@Composable
fun EmailAccountSheet(
    onSignedIn: () -> Unit,
    onDismiss: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var step by remember { mutableStateOf(Step.SignIn) }
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var isWorking by remember { mutableStateOf(false) }
    // The last thing that happened, as a shape. Never an exception.
    var outcome by remember { mutableStateOf<EmailAuthOutcome?>(null) }
    var action by remember { mutableStateOf(EmailAccountAction.SIGN_IN) }

    val addressLooksUsable = EmailAddress.isUsable(email)
    val canSubmit = addressLooksUsable &&
        EmailAccountPolicy.passwordIsUsable(password) && !isWorking

    /**
     * Run one account operation, recording only the SHAPE of what happened.
     *
     * The `catch` never reads the failure beyond its outcome, and `isWorking` is
     * always cleared, so a thrown failure cannot leave the sheet stuck busy.
     */
    fun run(next: EmailAccountAction, operation: suspend () -> Unit) {
        action = next
        outcome = null
        isWorking = true
        scope.launch {
            val result = runCatching { withContext(Dispatchers.IO) { operation() } }
            isWorking = false
            result.onFailure { failure ->
                val shape = (failure as? EmailAuthException)?.outcome
                    ?: TonoBackend.outcomeForTransport(failure)
                outcome = shape
                // An unconfirmed address is not a rejected sign-in. The person
                // has an account and a link already waiting for them, so this
                // lands on the confirmation step — where resending is one tap —
                // rather than leaving them to retype a password that was right.
                if (shape == EmailAuthOutcome.VERIFICATION_REQUIRED) step = Step.ConfirmSent
            }
        }
    }

    Column(
        Modifier
            .fillMaxWidth()
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            when (step) {
                Step.SignIn -> "Sign in"
                Step.CreateAccount -> "Create your account"
                Step.ConfirmSent -> "Confirm your email"
            },
            style = MaterialTheme.typography.titleLarge,
        )

        when (step) {
            Step.SignIn -> Text(
                "Sign in so your subscription follows you if you reinstall or switch devices.",
                color = Color.Gray,
                fontSize = 14.sp,
            )
            Step.CreateAccount -> Text(
                "Your email keeps your subscription and your style memory recoverable. " +
                    "Pick a password of at least ${EmailAccountPolicy.MINIMUM_PASSWORD_LENGTH} characters.",
                color = Color.Gray,
                fontSize = 14.sp,
            )
            Step.ConfirmSent -> Text(
                "Open the link on this device, then come back and sign in.",
                color = Color.Gray,
                fontSize = 14.sp,
            )
        }

        if (step != Step.ConfirmSent) {
            OutlinedTextField(
                value = email,
                onValueChange = { email = it },
                label = { Text("Email address") },
                singleLine = true,
                enabled = !isWorking,
                keyboardOptions = KeyboardOptions(
                    keyboardType = KeyboardType.Email,
                    imeAction = ImeAction.Next,
                ),
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = password,
                onValueChange = { password = it },
                label = { Text("Password") },
                singleLine = true,
                enabled = !isWorking,
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(
                    keyboardType = KeyboardType.Password,
                    imeAction = ImeAction.Done,
                ),
                modifier = Modifier.fillMaxWidth(),
            )
        }

        // The one rendered notice surface. It reads a mapped sentence, so there
        // is no path from a transport failure to these pixels.
        outcome?.let { shown ->
            Text(
                EmailAccountCopy.message(shown, action),
                color = if (shown.isAccepted) Color.Gray else MaterialTheme.colorScheme.error,
                fontSize = 13.sp,
            )
        }

        if (isWorking) {
            LinearProgressIndicator(Modifier.fillMaxWidth())
        }

        when (step) {
            Step.SignIn -> {
                Button(
                    onClick = {
                        run(EmailAccountAction.SIGN_IN) {
                            TonoBackend.signInWithEmail(email, password)
                            withContext(Dispatchers.Main) {
                                password = ""
                                onSignedIn()
                            }
                        }
                    },
                    enabled = canSubmit,
                    modifier = Modifier.fillMaxWidth(),
                ) { Text("Sign in") }

                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    TextButton(
                        onClick = {
                            run(EmailAccountAction.RESEND_CONFIRMATION) {
                                TonoBackend.resendVerification(email)
                                withContext(Dispatchers.Main) {
                                    outcome = EmailAuthOutcome.CHECK_YOUR_EMAIL
                                    step = Step.ConfirmSent
                                }
                            }
                        },
                        enabled = addressLooksUsable && !isWorking,
                    ) { Text("Send a new confirmation link") }
                }
                TextButton(
                    onClick = {
                        run(EmailAccountAction.RESET_PASSWORD) {
                            TonoBackend.requestPasswordReset(email)
                            withContext(Dispatchers.Main) {
                                outcome = EmailAuthOutcome.CHECK_YOUR_EMAIL
                            }
                        }
                    },
                    enabled = addressLooksUsable && !isWorking,
                ) { Text("Forgot your password?") }
                TextButton(
                    onClick = { step = Step.CreateAccount; outcome = null },
                    enabled = !isWorking,
                ) { Text("Create an account instead") }
            }

            Step.CreateAccount -> {
                Button(
                    onClick = {
                        run(EmailAccountAction.CREATE_ACCOUNT) {
                            TonoBackend.registerWithEmail(email, password)
                            withContext(Dispatchers.Main) {
                                outcome = EmailAuthOutcome.CHECK_YOUR_EMAIL
                                step = Step.ConfirmSent
                            }
                        }
                    },
                    enabled = canSubmit,
                    modifier = Modifier.fillMaxWidth(),
                ) { Text("Create account") }
                TextButton(
                    onClick = { step = Step.SignIn; outcome = null },
                    enabled = !isWorking,
                ) { Text("I already have an account") }
            }

            Step.ConfirmSent -> {
                Button(
                    onClick = { step = Step.SignIn; outcome = null },
                    enabled = !isWorking,
                    modifier = Modifier.fillMaxWidth(),
                ) { Text("Sign in") }
                TextButton(
                    onClick = {
                        run(EmailAccountAction.RESEND_CONFIRMATION) {
                            TonoBackend.resendVerification(email)
                            withContext(Dispatchers.Main) {
                                outcome = EmailAuthOutcome.CHECK_YOUR_EMAIL
                            }
                        }
                    },
                    enabled = !isWorking,
                ) { Text("Send a new link") }
            }
        }

        TextButton(onClick = onDismiss, enabled = !isWorking) { Text("Close") }
    }
}

/**
 * The Account rows in Settings: who this device is signed in as, and the one
 * action that changes it.
 *
 * Signing out lives here rather than beside anything destructive: they are
 * opposite acts, and a person handing a phone to someone else should not have to
 * read a delete-everything screen to find the harmless one.
 */
@Composable
fun EmailAccountRows(
    accountId: String?,
    onOpenSheet: () -> Unit,
    onSignedOut: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var signedInEmail by remember { mutableStateOf(SecureStore.signedInEmail()) }
    var isSigningOut by remember { mutableStateOf(false) }

    val address = signedInEmail
    if (address != null) {
        Row(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text("Email")
            Text(address, color = Color.Gray)
        }
        TextButton(
            onClick = {
                isSigningOut = true
                scope.launch {
                    // `signOutEmail` clears local state whether or not the call
                    // it makes first succeeds, so there is no failure branch to
                    // render and no way to end up half signed in.
                    withContext(Dispatchers.IO) { TonoBackend.signOutEmail() }
                    isSigningOut = false
                    signedInEmail = null
                    onSignedOut()
                }
            },
            enabled = !isSigningOut,
            modifier = Modifier.padding(horizontal = 8.dp),
        ) { Text(if (isSigningOut) "Signing out…" else "Sign out") }
    } else {
        TextButton(onClick = onOpenSheet, modifier = Modifier.padding(horizontal = 8.dp)) {
            Text("Sign in with email", color = Color(0xFF9B59B6))
        }
        Text(
            "Confirming an email keeps your subscription and your saved style recoverable if you " +
                "reinstall or switch devices. It does not by itself unlock Pro.",
            color = Color.Gray,
            fontSize = 12.sp,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
        )
    }

    // Stated where a person can act on it: the purchase gate reads exactly this
    // pair, so saying so here is the difference between a disabled button and a
    // mystery.
    if (address != null && accountId.isNullOrBlank()) {
        Text(
            "Finishing setup on this device — reopen Tono in a moment if a purchase is blocked.",
            color = Color.Gray,
            fontSize = 12.sp,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
        )
    }
}

package com.tono.app.ui

import android.app.Activity
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.tono.app.BuildConfig
import com.tono.app.billing.PlayBillingManager
import com.tono.app.notifications.DigestScheduler
import com.tono.shared.flags.FeatureFlag
import com.tono.shared.flags.FeatureFlags
import com.tono.shared.network.TonoBackend
import com.tono.shared.network.TonoMe
import com.tono.shared.storage.RecipientMemory
import com.tono.shared.storage.SharedKeys
import com.tono.shared.storage.SharedStore
import com.tono.shared.storage.UserMemory
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// Mirrors ios/App/SettingsView.swift
// Voice, memory, feature toggles, plan status — no Stripe on Android (Play Billing).

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    onNavigateToMemory: () -> Unit = {},
    onNavigateToRecipients: () -> Unit = {},
) {
    val scope   = rememberCoroutineScope()
    var me      by remember { mutableStateOf<TonoMe?>(null) }
    var meError by remember { mutableStateOf<String?>(null) }
    val billing by PlayBillingManager.state.collectAsState()

    var voiceField  by remember { mutableStateOf(SharedStore.getString(SharedKeys.PREFERRED_VOICE) ?: "") }
    var memoryCount by remember { mutableIntStateOf(UserMemory.all().size) }

    var featureToggles by remember {
        mutableStateOf(
            FeatureFlag.entries.filter { it.isUserControllable }
                .associateWith { FeatureFlags.isEnabled(it) }
        )
    }

    // Build 114 — the account sheet, and a nonce that forces the Account rows to
    // re-read the shared state after a sign-in or a sign-out so the keyboard and
    // this screen agree on the same pass rather than at the next launch.
    var showAccountSheet by remember { mutableStateOf(false) }
    var accountRevision by remember { mutableIntStateOf(0) }

    suspend fun reloadMe() {
        runCatching { me = TonoBackend.me() }
            // Build 114: this used to name the backend on a consumer screen.
            // A person cannot act on where a failure happened, only on what to
            // do next.
            .onFailure { meError = "Couldn't load your account just now. Try again in a moment." }
    }

    LaunchedEffect(accountRevision) { reloadMe() }

    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
    ) {
        // Account section
        SettingsSection(title = "Account") {
            SettingsRow("Status", if (me != null) "Connected" else "Not connected")
            me?.let { u ->
                SettingsRow("Plan", if (u.isPro) "Pro" else "Subscription required")
                if (!u.isPro) {
                    SettingsRow("Today", "${u.usedToday} / ${u.dailyLimit} rewrites")
                }
            }
            meError?.let {
                Text(it, color = MaterialTheme.colorScheme.error, fontSize = 12.sp,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
            }

            key(accountRevision) {
                EmailAccountRows(
                    accountId = me?.accountId ?: SharedStore.getString(SharedKeys.ACCOUNT_ID),
                    onOpenSheet = { showAccountSheet = true },
                    onSignedOut = {
                        me = null
                        meError = null
                        // A sign-out leaves this device holding no credential at
                        // all, so it is returned to an anonymous registration on
                        // the same pass. Waiting until the next launch would
                        // leave Coach, the keyboard and this screen failing with
                        // nothing a person could act on — and would have Play's
                        // still-active purchase re-verified against no account,
                        // which surfaces as a verification failure they did not
                        // cause. Registering first, then refreshing, means the
                        // entitlement is re-read against the account that now
                        // owns this device.
                        scope.launch {
                            runCatching {
                                withContext(Dispatchers.IO) {
                                    TonoBackend.registerIfNeeded(
                                        appVersion = BuildConfig.VERSION_NAME,
                                    )
                                }
                            }
                            accountRevision++
                            PlayBillingManager.refresh()
                        }
                    },
                )
            }

            Text(
                // Build 114: the old sentence named the backend and an API key.
                // What a person actually owns is the draft, and the fact that it
                // is not kept.
                "Your draft is only used for coaching, and only when you ask. It isn't kept.",
                color = Color.Gray,
                fontSize = 12.sp,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            )
        }

        if (showAccountSheet) {
            ModalBottomSheet(onDismissRequest = { showAccountSheet = false }) {
                EmailAccountSheet(
                    onSignedIn = {
                        showAccountSheet = false
                        // A sign-in converges this device on the canonical
                        // account, so the entitlement it already owns is
                        // re-read here: a returning subscriber must not have to
                        // tap Restore to stop seeing the paywall.
                        accountRevision++
                        PlayBillingManager.refresh()
                    },
                    onDismiss = { showAccountSheet = false },
                )
            }
        }

        // Voice section
        SettingsSection(title = "Voice") {
            OutlinedTextField(
                value         = voiceField,
                onValueChange = {
                    voiceField = it
                    SharedStore.putString(SharedKeys.PREFERRED_VOICE, it.takeIf { s -> s.isNotBlank() })
                },
                label       = { Text("Preferred voice") },
                placeholder = { Text("e.g. direct, warm, terse", color = Color.Gray) },
                modifier    = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                singleLine  = true,
            )
            Text(
                "Passed to the model so rewrites match how you actually talk.",
                color    = Color.Gray,
                fontSize = 12.sp,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            )
        }

        // Memory section
        SettingsSection(title = "Memory") {
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text("Facts Tono knows about you")
                Text(
                    "$memoryCount fact${if (memoryCount == 1) "" else "s"}",
                    color = Color.Gray,
                    fontSize = 14.sp,
                )
            }
            TextButton(
                onClick  = onNavigateToMemory,
                modifier = Modifier.padding(horizontal = 8.dp),
            ) {
                Text("View and manage memories →", color = Color(0xFF9B59B6), fontSize = 14.sp)
            }
            Text(
                "Tono learns from your rewrite choices. These hints are sent to personalize rewrites.",
                color    = Color.Gray,
                fontSize = 12.sp,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            )
        }

        // Recipients section
        val recipientCount = remember { RecipientMemory.all().size }
        SettingsSection(title = "Recipients") {
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text("People you message most")
                Text(
                    if (recipientCount > 0) "$recipientCount added" else "None yet",
                    color = Color.Gray,
                    fontSize = 14.sp,
                )
            }
            TextButton(
                onClick  = onNavigateToRecipients,
                modifier = Modifier.padding(horizontal = 8.dp),
            ) {
                Text("Manage recipients →", color = Color(0xFF9B59B6), fontSize = 14.sp)
            }
            Text(
                "Add a voice hint per person (e.g. \"prefers formal\") and Tono will factor it in for every rewrite to that recipient.",
                color    = Color.Gray,
                fontSize = 12.sp,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            )
        }

        // Feature toggles
        val context = LocalContext.current
        val controllable = FeatureFlag.entries.filter { it.isUserControllable }
        if (controllable.isNotEmpty()) {
            SettingsSection(title = "Preferences") {
                controllable.forEach { flag ->
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 4.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                    ) {
                        Text(flag.displayName, Modifier.weight(1f))
                        Switch(
                            checked         = featureToggles[flag] ?: FeatureFlags.isEnabled(flag),
                            onCheckedChange = { enabled ->
                                FeatureFlags.setUserPreference(flag, enabled)
                                featureToggles = featureToggles.toMutableMap().also { it[flag] = enabled }
                                // Mirror iOS: schedule / cancel digest notification on toggle
                                if (flag == FeatureFlag.WEEKLY_DIGEST) {
                                    if (enabled) DigestScheduler.schedule(context)
                                    else DigestScheduler.cancel(context)
                                }
                                // Sync preference to server (fire-and-forget; local value already saved)
                                scope.launch {
                                    runCatching {
                                        TonoBackend.setFeaturePreference(flag.key, enabled)
                                    }
                                }
                            },
                        )
                    }
                }
            }
        }

        // Plan section
        val isPro = billing.isPro
        SettingsSection(title = "Plan") {
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(if (isPro) "Pro ✓" else "Subscription required", fontWeight = FontWeight.SemiBold)
                Text(
                    if (isPro) "Verified" else "Google Play",
                    color = Color.Gray,
                    fontSize = 14.sp,
                )
            }
            if (isPro) {
                TextButton(
                    onClick = { (context as? Activity)?.let(PlayBillingManager::manageSubscriptions) },
                    modifier = Modifier.padding(horizontal = 8.dp),
                ) {
                    Text("Manage subscription in Google Play →")
                }
            } else {
                Text(
                    "14-day free trial, then Pro. Play displays the current local price before purchase.",
                    color = Color.Gray,
                    fontSize = 12.sp,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
                )
                billing.products.forEach { product ->
                    Button(
                        onClick = {
                            (context as? Activity)?.let { activity ->
                                PlayBillingManager.purchase(activity, product.id)
                            }
                        },
                        enabled = !billing.isLoading,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 4.dp),
                    ) {
                        Text("${product.label} · ${product.formattedPrice}")
                    }
                }
            }
            if (billing.isLoading) {
                LinearProgressIndicator(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                )
            }
            billing.message?.let { message ->
                Text(
                    message,
                    color = Color.Gray,
                    fontSize = 12.sp,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
                )
            }
            billing.error?.let { error ->
                Text(
                    error,
                    color = MaterialTheme.colorScheme.error,
                    fontSize = 12.sp,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
                )
            }
            Row(Modifier.padding(horizontal = 8.dp)) {
                TextButton(onClick = PlayBillingManager::restore, enabled = !billing.isLoading) {
                    Text("Restore purchases")
                }
                TextButton(onClick = PlayBillingManager::refresh, enabled = !billing.isLoading) {
                    Text("Retry")
                }
            }
        }

        // Privacy section
        SettingsSection(title = "Privacy") {
            Text(
                // Build 114: the old sentence described plumbing — a proxy, an
                // LLM, a bearer, a preferences file. What a person can act on is
                // what happens to their draft and where their sign-in lives.
                "Your draft is sent for coaching only when you ask, and it isn't kept. Your sign-in " +
                    "is stored encrypted on this device, and your password is never stored at all.",
                color    = Color.Gray,
                fontSize = 12.sp,
                modifier = Modifier.padding(16.dp),
            )
        }

        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun SettingsSection(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxWidth()) {
        Text(
            title.uppercase(),
            color    = Color.Gray,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
        )
        Surface(
            Modifier.fillMaxWidth(),
            color  = MaterialTheme.colorScheme.surface,
            tonalElevation = 1.dp,
        ) {
            Column(content = content)
        }
        Spacer(Modifier.height(16.dp))
    }
}

@Composable
private fun SettingsRow(label: String, value: String) {
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(label)
        Text(value, color = Color.Gray)
    }
}

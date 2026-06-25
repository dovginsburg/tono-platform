package com.tono.app.ui

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
import com.tono.app.notifications.DigestScheduler
import com.tono.shared.flags.FeatureFlag
import com.tono.shared.flags.FeatureFlags
import com.tono.shared.network.TonoBackend
import com.tono.shared.network.TonoMe
import com.tono.shared.storage.RecipientMemory
import com.tono.shared.storage.SharedKeys
import com.tono.shared.storage.SharedStore
import com.tono.shared.storage.UserMemory
import kotlinx.coroutines.launch

// Mirrors ios/App/SettingsView.swift
// Voice, memory, feature toggles, plan status — no Stripe on Android (Play Billing).

@Composable
fun SettingsScreen(
    onNavigateToMemory: () -> Unit = {},
    onNavigateToRecipients: () -> Unit = {},
) {
    val scope   = rememberCoroutineScope()
    var me      by remember { mutableStateOf<TonoMe?>(null) }
    var meError by remember { mutableStateOf<String?>(null) }

    var voiceField  by remember { mutableStateOf(SharedStore.getString(SharedKeys.PREFERRED_VOICE) ?: "") }
    var memoryCount by remember { mutableIntStateOf(UserMemory.all().size) }

    var featureToggles by remember {
        mutableStateOf(
            FeatureFlag.entries.filter { it.isUserControllable }
                .associateWith { FeatureFlags.isEnabled(it) }
        )
    }

    LaunchedEffect(Unit) {
        runCatching { me = TonoBackend.me() }
            .onFailure { meError = "Could not reach the Tono backend." }
    }

    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
    ) {
        // Account section
        SettingsSection(title = "Account") {
            SettingsRow("Status", if (me != null) "Connected" else "Not connected")
            me?.let { u ->
                SettingsRow("Plan", if (u.isPro) "Pro" else "Free")
                if (!u.isPro) {
                    SettingsRow("Today", "${u.usedToday} / ${u.dailyLimit} rewrites")
                }
            }
            meError?.let {
                Text(it, color = MaterialTheme.colorScheme.error, fontSize = 12.sp,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
            }
            Text(
                "Rewrites run on the Tono backend — your API key never leaves the server.",
                color = Color.Gray,
                fontSize = 12.sp,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            )
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
        val isPro = me?.isPro ?: SharedStore.getBoolean(SharedKeys.PRO_UNLOCKED)
        SettingsSection(title = "Plan") {
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(if (isPro) "Pro ✓" else "Free", fontWeight = FontWeight.SemiBold)
                if (!isPro) {
                    Text("Upgrade in Google Play", color = Color.Gray, fontSize = 14.sp)
                }
            }
            Text(
                if (isPro)
                    "Your Pro subscription is managed in Google Play → Subscriptions."
                else
                    "Free: 10 coaching sessions/day. Pro (\$5.99/mo or \$39.99/yr): unlimited rewrites, style memory, weekly digest.",
                color    = Color.Gray,
                fontSize = 12.sp,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            )
        }

        // Privacy section
        SettingsSection(title = "Privacy") {
            Text(
                "Tono sends your draft to our backend, which calls the LLM. Drafts are not stored. Your bearer token is kept in EncryptedSharedPreferences backed by Android Keystore — never in plain SharedPreferences.",
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

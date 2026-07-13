package com.tono.app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.Chat
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.core.content.ContextCompat
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.tono.app.theme.TonoTheme
import com.tono.app.ui.*
import com.tono.shared.flags.FeatureFlag
import com.tono.shared.flags.FeatureFlags
import com.tono.shared.storage.SharedKeys
import com.tono.shared.storage.SharedStore

class MainActivity : ComponentActivity() {

    // Android 13+ requires explicit POST_NOTIFICATIONS permission
    private val requestNotificationPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { /* no-op: user decided */ }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestNotificationPermissionIfNeeded()
        setContent {
            TonoTheme {
                val showOnboarding = remember {
                    val done = SharedStore.getBoolean(SharedKeys.ONBOARDING_DONE)
                    val flagOn = FeatureFlags.isEnabled(FeatureFlag.ONBOARDING_CALIBRATION)
                    mutableStateOf(!done && flagOn)
                }

                if (showOnboarding.value) {
                    OnboardingScreen(onDone = { showOnboarding.value = false })
                } else {
                    RootNav(
                        onOpenKeyboardSettings = { openKeyboardSettings() },
                    )
                }
            }
        }
    }

    private fun openKeyboardSettings() {
        startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
            == PackageManager.PERMISSION_GRANTED) return
        // Only prompt if the weekly digest feature is on — no surprise permission dialogs
        if (FeatureFlags.isEnabled(FeatureFlag.WEEKLY_DIGEST)) {
            requestNotificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun RootNav(onOpenKeyboardSettings: () -> Unit) {
    val navController = rememberNavController()
    val current = navController.currentBackStackEntryAsState().value?.destination?.route
    val isSubScreen = current == "memory" || current == "recipients"

    Scaffold(
        topBar = {
            if (isSubScreen) {
                TopAppBar(
                    title = { Text(when (current) { "memory" -> "Memory"; "recipients" -> "Recipients"; else -> "" }) },
                    navigationIcon = {
                        IconButton(onClick = { navController.popBackStack() }) {
                            Icon(Icons.Default.ArrowBack, contentDescription = "Back")
                        }
                    },
                )
            }
        },
        bottomBar = {
            if (!isSubScreen) {
                NavigationBar {
                    NavigationBarItem(
                        selected = current == "coach",
                        onClick  = { navController.navigate("coach") },
                        icon     = { Icon(Icons.Default.Chat, "Coach") },
                        label    = { Text("Coach") },
                    )
                    NavigationBarItem(
                        selected = current == "digest",
                        onClick  = { navController.navigate("digest") },
                        icon     = { Icon(Icons.Default.BarChart, "This Week") },
                        label    = { Text("This Week") },
                    )
                    NavigationBarItem(
                        selected = current == "settings",
                        onClick  = { navController.navigate("settings") },
                        icon     = { Icon(Icons.Default.Settings, "Settings") },
                        label    = { Text("Settings") },
                    )
                }
            }
        },
    ) { padding ->
        NavHost(navController, startDestination = "coach", modifier = Modifier.padding(padding)) {
            composable("coach")    { HomeScreen(onOpenKeyboardSettings = onOpenKeyboardSettings) }
            composable("digest")   { DigestScreen() }
            composable("settings") {
                SettingsScreen(
                    onNavigateToMemory     = { navController.navigate("memory") },
                    onNavigateToRecipients = { navController.navigate("recipients") },
                )
            }
            composable("memory")     { MemoryScreen() }
            composable("recipients") { RecipientsScreen() }
        }
    }
}

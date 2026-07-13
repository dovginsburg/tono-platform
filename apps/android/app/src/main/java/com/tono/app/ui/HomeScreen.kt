package com.tono.app.ui

import android.content.Intent
import android.provider.Settings
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.tono.app.billing.BillingProducts
import com.tono.app.billing.PlayBillingManager
import com.tono.shared.storage.SharedKeys
import com.tono.shared.storage.SharedStore

// Mirrors ios/App/HomeView.swift
// Guides user through: enable keyboard → allow full access → use coach

private val Purple = Color(0xFF9B59B6)

@Composable
fun HomeScreen(onOpenKeyboardSettings: () -> Unit) {
    var keyboardLoaded by remember { mutableStateOf(false) }
    var isRegistered by remember { mutableStateOf(false) }
    val billing by PlayBillingManager.state.collectAsState()

    fun checkStatus() {
        keyboardLoaded = SharedStore.getBoolean(SharedKeys.KEYBOARD_LOADED)
        isRegistered   = SharedStore.getString(SharedKeys.REGISTERED_AT) != null
    }

    // Re-check whenever the app resumes (user may have been to Settings)
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) checkStatus()
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }

    LaunchedEffect(Unit) { checkStatus() }

    Column(
        Modifier
            .fillMaxSize()
            .background(Color.Black)
            .verticalScroll(rememberScrollState())
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(24.dp),
    ) {
        Spacer(Modifier.height(8.dp))

        // Hero
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                "Say what you mean.\nLand how you intend.",
                color = Color.White,
                fontSize = 26.sp,
                fontWeight = FontWeight.Bold,
                lineHeight = 32.sp,
            )
            Text(
                "Pre-send rewrites for any text field — warmer, clearer, funnier, or safer — with a risk badge before you hit send.",
                color = Color.White.copy(alpha = 0.7f),
                fontSize = 15.sp,
            )
        }

        AnimatedContent(targetState = keyboardLoaded && isRegistered, label = "home_state") { ready ->
            if (ready) {
                ReadyCard()
            } else {
                SetupCard(
                    keyboardLoaded = keyboardLoaded,
                    onOpenSettings = onOpenKeyboardSettings,
                )
            }
        }

        // Footer — free / pro tiers
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("Free · 10 rewrites/day", color = Color.White.copy(alpha = 0.7f),
                fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            Text("All four rewrite axes on the Tono keyboard.",
                color = Color.White.copy(alpha = 0.5f), fontSize = 13.sp)
            Spacer(Modifier.height(4.dp))
            val monthly = billing.products.firstOrNull { it.id == BillingProducts.MONTHLY }
            val yearly = billing.products.firstOrNull { it.id == BillingProducts.YEARLY }
            val proPrice = if (monthly != null && yearly != null)
                "Pro · ${monthly.formattedPrice}/mo or ${yearly.formattedPrice}/yr"
            else
                "Pro · pricing shown in Google Play"
            Text(proPrice, color = Color.White.copy(alpha = 0.7f),
                fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            Text("Unlimited rewrites, style memory, per-recipient coaching, weekly digest.",
                color = Color.White.copy(alpha = 0.5f), fontSize = 13.sp)
        }

        Spacer(Modifier.height(8.dp))
    }
}

@Composable
private fun ReadyCard() {
    Column(
        Modifier
            .fillMaxWidth()
            .background(Color.Green.copy(alpha = 0.12f), RoundedCornerShape(14.dp))
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Icon(
            Icons.Default.Check,
            contentDescription = null,
            tint = Color.Green,
            modifier = Modifier.size(48.dp),
        )
        Text("You're all set!", color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold)
        Text(
            "Switch to the Tono keyboard in any text field and tap Coach on a draft.",
            color = Color.White.copy(alpha = 0.7f),
            fontSize = 15.sp,
        )
    }
}

@Composable
private fun SetupCard(keyboardLoaded: Boolean, onOpenSettings: () -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .background(Color.White.copy(alpha = 0.06f), RoundedCornerShape(14.dp))
            .padding(16.dp)
    ) {
        SetupRow(
            number      = 1,
            title       = "Enable the keyboard",
            detail      = "Settings → System → Languages → On-screen keyboard → Manage keyboards → Enable Tono",
            done        = false,
            buttonLabel = "Open Settings",
            onTap       = onOpenSettings,
        )
        HorizontalDivider(Modifier.padding(start = 52.dp), color = Color.White.copy(alpha = 0.08f))
        SetupRow(
            number = 2,
            title  = "Select Tono as your keyboard",
            detail = "Long-press the space bar or globe icon in any text field and pick Tono.",
            done   = false,
        )
        HorizontalDivider(Modifier.padding(start = 52.dp), color = Color.White.copy(alpha = 0.08f))
        SetupRow(
            number = 3,
            title  = "Switch to Tono and type",
            detail = "Tap Coach on your draft to get risk analysis and rewrites.",
            done   = keyboardLoaded,
        )
    }
}

@Composable
private fun SetupRow(
    number:      Int,
    title:       String,
    detail:      String,
    done:        Boolean,
    buttonLabel: String? = null,
    onTap:       (() -> Unit)? = null,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .padding(vertical = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            Modifier
                .size(28.dp)
                .background(if (done) Color.Green else Purple, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            if (done) {
                Icon(Icons.Default.Check, null, tint = Color.White, modifier = Modifier.size(14.dp))
            } else {
                Text("$number", color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.Bold)
            }
        }

        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(
                title,
                color = if (done) Color.Green else Color.White,
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Text(detail, color = Color.White.copy(alpha = 0.6f), fontSize = 13.sp)
            if (buttonLabel != null && onTap != null && !done) {
                OutlinedButton(
                    onClick = onTap,
                    modifier = Modifier.padding(top = 2.dp),
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = Color.White),
                    shape = RoundedCornerShape(50),
                ) {
                    Text(buttonLabel, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}

package com.tono.app.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.tono.shared.network.PaymentHistoryItem
import com.tono.shared.network.TonoBackend
import kotlinx.coroutines.launch

/**
 * The account's billing timeline on Android. Reads the owner-scoped backend
 * endpoint (server-scoped by the bearer's account — this device can only see
 * its own account's billing) and renders each subscription/purchase as a
 * human-readable row. Never shows a raw provider or transaction id.
 *
 * Loaded on demand inside Settings so it costs nothing until a person opens it.
 */
@Composable
fun PaymentHistorySection() {
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    var items by remember { mutableStateOf<List<PaymentHistoryItem>>(emptyList()) }
    val scope = rememberCoroutineScope()

    fun load() {
        loading = true
        error = null
        scope.launch {
            runCatching { TonoBackend.paymentHistory() }
                .onSuccess { items = it.items; loading = false }
                .onFailure { error = "Couldn't load payment history."; loading = false }
        }
    }

    LaunchedEffect(Unit) { load() }

    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
        when {
            loading -> {
                Row(Modifier.padding(vertical = 8.dp)) {
                    CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.height(18.dp))
                }
            }
            error != null -> {
                Text(error!!, color = MaterialTheme.colorScheme.error, fontSize = 13.sp)
                TextButton(onClick = { load() }) { Text("Retry") }
            }
            items.isEmpty() -> {
                Text(
                    "No purchases yet. When you subscribe — here, on the web, or on an iPhone — " +
                        "every payment shows up here, tied to this account.",
                    color = Color.Gray,
                    fontSize = 13.sp,
                )
            }
            else -> {
                items.forEach { item ->
                    PaymentHistoryRow(item)
                    Spacer(Modifier.height(10.dp))
                }
            }
        }
    }
}

@Composable
private fun PaymentHistoryRow(item: PaymentHistoryItem) {
    Column(Modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth()) {
            Text(
                productLabel(item.productId),
                fontWeight = FontWeight.SemiBold,
                fontSize = 15.sp,
                modifier = Modifier.weight(1f),
            )
            Text(
                statusLabel(item),
                color = if (item.isCurrent) MaterialTheme.colorScheme.primary else Color.Gray,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
            )
        }
        Text(
            buildString {
                append("via ").append(providerLabel(item.provider))
                if (item.grantKind == "family") append(" · family sharing")
                if (item.environment == "Sandbox") append(" · sandbox")
            },
            color = Color.Gray,
            fontSize = 12.sp,
        )
        priceLabel(item)?.let { price ->
            Text(
                "plan price $price",
                color = Color.Gray,
                fontSize = 12.sp,
            )
        }
        item.expiresAt?.let { exp ->
            Text(
                (if (item.isCurrent) "renews / ends " else "ended ") + shortDate(exp),
                color = Color.Gray,
                fontSize = 12.sp,
            )
        }
    }
}

/** A verified price string, present ONLY when both the normalized minor-unit
 *  amount and an ISO currency arrived from the backend. Never fabricated. */
private fun priceLabel(item: PaymentHistoryItem): String? {
    val minor = item.amountMinor ?: return null
    val code = item.currency ?: return null
    return try {
        val fmt = java.text.NumberFormat.getCurrencyInstance()
        fmt.currency = java.util.Currency.getInstance(code.uppercase())
        fmt.format(minor / 100.0)
    } catch (_: Exception) {
        null
    }
}

private fun providerLabel(p: String): String = when (p) {
    "stripe" -> "web (card / wallet)"
    "apple" -> "Apple"
    "google_play" -> "Google Play"
    else -> p
}

private fun productLabel(id: String): String = when (id) {
    "com.tonoit.pro.monthly" -> "Tono Pro — monthly"
    "com.tonoit.pro.yearly" -> "Tono Pro — yearly"
    else -> id
}

private fun statusLabel(item: PaymentHistoryItem): String = when {
    item.isCurrent -> "active"
    item.entitlementState == "revoked" -> "revoked"
    item.purchaseState == "refunded" -> "refunded"
    item.purchaseState == "expired" -> "expired"
    else -> item.purchaseState
}

/** ISO-8601 → YYYY-MM-DD without pulling in a date library. */
private fun shortDate(iso: String): String = iso.substringBefore('T')

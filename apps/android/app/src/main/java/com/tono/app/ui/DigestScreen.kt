package com.tono.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.tono.shared.network.TonoBackend
import com.tono.shared.network.WeeklyDigestResponse
import com.tono.shared.storage.SharedKeys
import com.tono.shared.storage.SharedStore
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.roundToInt

// Mirrors ios/App/DigestView.swift
// Free users: top-line stats. Pro: axis bars + trends + streak card.

private val Purple = Color(0xFF9B59B6)
private val Orange = Color(0xFFE67E22)

@Composable
fun DigestScreen() {
    var digest  by remember { mutableStateOf<WeeklyDigestResponse?>(null) }
    var loading by remember { mutableStateOf(true) }
    var error   by remember { mutableStateOf<String?>(null) }
    val scope   = rememberCoroutineScope()

    val isPro = SharedStore.getBoolean(SharedKeys.PRO_UNLOCKED)

    fun load() {
        loading = true
        error   = null
        scope.launch {
            runCatching { TonoBackend.weeklyDigest() }
                .onSuccess { digest = it; loading = false }
                .onFailure { error = it.message ?: "Could not load digest."; loading = false }
        }
    }

    LaunchedEffect(Unit) { load() }

    when {
        loading -> {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = Purple)
            }
        }
        error != null -> {
            Column(
                Modifier.fillMaxSize(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Icon(Icons.Default.Warning, null, tint = Color(0xFFF1C40F), modifier = Modifier.size(40.dp))
                Spacer(Modifier.height(12.dp))
                Text(error!!, color = Color.Gray, modifier = Modifier.padding(horizontal = 24.dp))
                Spacer(Modifier.height(12.dp))
                OutlinedButton(onClick = ::load) { Text("Try again") }
            }
        }
        digest != null -> {
            DigestContent(digest = digest!!, isPro = isPro)
        }
    }
}

@Composable
private fun DigestContent(digest: WeeklyDigestResponse, isPro: Boolean) {
    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        // Top-line stats — all users
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            StatTile(value = "${digest.rewrites}", label = "Rewrites", modifier = Modifier.weight(1f))
            StatTile(value = "${digest.daysActive}", label = "Active days", modifier = Modifier.weight(1f))
        }

        digest.topAxis?.let { top ->
            Column(
                Modifier
                    .fillMaxWidth()
                    .background(MaterialTheme.colorScheme.surface, RoundedCornerShape(14.dp))
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text("Your go-to this week", color = Color.Gray, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                Text(top.replaceFirstChar { it.uppercase() }, color = Purple, fontSize = 28.sp, fontWeight = FontWeight.Bold)
            }
        }

        if (digest.rewrites == 0) {
            Text(
                "No rewrites this week yet — switch to Tono and tap Coach on any draft to get started.",
                color = Color.Gray,
                fontSize = 14.sp,
                modifier = Modifier.padding(horizontal = 8.dp),
            )
        }

        // Pro-gated depth
        if (isPro) {
            if (digest.axisBreakdown.isNotEmpty()) {
                AxisBars(breakdown = digest.axisBreakdown, prevBreakdown = digest.prevAxisBreakdown)
            }
            if (digest.daysActive >= 5) {
                StreakCard(days = digest.daysActive)
            }
        } else {
            DigestDepthTeaser()
        }

        Spacer(Modifier.height(8.dp))
    }
}

@Composable
private fun AxisBars(breakdown: Map<String, Int>, prevBreakdown: Map<String, Int>) {
    val sorted    = breakdown.entries.sortedByDescending { it.value }
    val maxCount  = sorted.firstOrNull()?.value?.coerceAtLeast(1) ?: 1
    val prevTotal = prevBreakdown.values.sum()
    val currTotal = breakdown.values.sum()

    Column(
        Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface, RoundedCornerShape(14.dp))
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("Axis breakdown", color = Color.Gray, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)

        sorted.forEach { (axis, count) ->
            val trend = weekOverWeekTrend(axis, count, currTotal, prevBreakdown, prevTotal)
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Text(
                        axis.replaceFirstChar { it.uppercase() },
                        fontSize = 14.sp,
                        modifier = Modifier.width(72.dp),
                    )
                    LinearProgressIndicator(
                        progress  = { count.toFloat() / maxCount },
                        modifier  = Modifier.weight(1f).height(12.dp).clip(RoundedCornerShape(6.dp)),
                        color     = Purple.copy(alpha = 0.6f),
                        trackColor = Color.Transparent,
                    )
                    Text("$count", color = Color.Gray, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.width(28.dp))
                }
                if (trend != null) {
                    Text(trend, color = Color.Gray, fontSize = 11.sp,
                        modifier = Modifier.padding(start = 82.dp))
                }
            }
        }
    }
}

private fun weekOverWeekTrend(
    axis: String, currCount: Int, currTotal: Int,
    prevBreakdown: Map<String, Int>, prevTotal: Int,
): String? {
    if (currTotal == 0 || prevTotal == 0) return null
    val currPct = currCount.toDouble() / currTotal
    val prevPct = (prevBreakdown[axis] ?: 0).toDouble() / prevTotal
    val delta   = currPct - prevPct
    if (abs(delta) < 0.05) return null
    val pct = (abs(delta) * 100).roundToInt()
    return if (delta > 0) "$pct% more often than last week" else "$pct% less than last week"
}

@Composable
private fun StreakCard(days: Int) {
    Row(
        Modifier
            .fillMaxWidth()
            .background(Orange.copy(alpha = 0.12f), RoundedCornerShape(14.dp))
            .padding(16.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("🔥", fontSize = 28.sp)
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text("$days-day coaching streak", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
            Text("Consistent practice is where the improvement compounds.",
                color = Color.Gray, fontSize = 12.sp)
        }
    }
}

@Composable
private fun DigestDepthTeaser() {
    val exampleRows = listOf(
        "Warmer"  to "↑ 18% vs last week",
        "Clearer" to "—",
        "Safer"   to "↓ 7% vs last week",
        "Funnier" to "—",
    )

    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        // Blurred preview
        Column(
            Modifier
                .fillMaxWidth()
                .background(MaterialTheme.colorScheme.surface, RoundedCornerShape(14.dp))
                .padding(14.dp)
                .blur(3.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text("Axis breakdown & trends", color = Color.Gray,
                fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            exampleRows.forEach { (axis, trend) ->
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(axis, fontSize = 14.sp, modifier = Modifier.width(72.dp))
                    Spacer(Modifier.weight(1f))
                    Text(
                        trend,
                        color = when {
                            trend.startsWith("↑") -> Color.Green
                            trend.startsWith("↓") -> Orange
                            else -> Color.Gray
                        },
                        fontSize = 12.sp,
                    )
                }
            }
        }

        Text(
            "Upgrade to Pro to unlock axis trends, streak tracking, and weekly coaching reports.",
            color    = Color.Gray,
            fontSize = 14.sp,
        )
    }
}

@Composable
private fun StatTile(value: String, label: String, modifier: Modifier = Modifier) {
    Column(
        modifier
            .background(MaterialTheme.colorScheme.surface, RoundedCornerShape(14.dp))
            .padding(vertical = 20.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(value, fontSize = 36.sp, fontWeight = FontWeight.Bold, color = Color.White)
        Text(label, color = Color.Gray, fontSize = 13.sp)
    }
}

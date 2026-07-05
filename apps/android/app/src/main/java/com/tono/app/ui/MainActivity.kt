package com.tono.app.ui

import android.net.Uri
import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.viewmodel.compose.viewModel
import com.tono.app.R
import com.tono.app.ui.theme.RiskHigh
import com.tono.app.ui.theme.RiskLow
import com.tono.app.ui.theme.RiskMedium
import com.tono.app.ui.theme.TonoAccent
import com.tono.app.ui.theme.TonoTheme
import com.tono.app.viewmodel.AccountViewModel
import com.tono.app.viewmodel.CoachViewModel
import com.tono.app.viewmodel.UiState

// FragmentActivity (not plain ComponentActivity) because androidx.biometric's
// BiometricPrompt needs one to host its confirmation dialog fragment.
class MainActivity : FragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            TonoTheme {
                Surface {
                    BiometricGate {
                        CoachScreen()
                    }
                }
            }
        }
    }
}

private val riskColor = mapOf(
    "low" to RiskLow,
    "medium" to RiskMedium,
    "high" to RiskHigh,
)

@Composable
fun CoachScreen(viewModel: CoachViewModel = viewModel()) {
    val state by viewModel.state.collectAsState()
    var draft by remember { mutableStateOf("") }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(20.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(
                modifier = Modifier
                    .size(10.dp)
                    .background(color = TonoAccent, shape = CircleShape)
            )
            Text(stringResource(R.string.app_name), style = MaterialTheme.typography.headlineMedium)
        }
        Text(stringResource(R.string.tagline), style = MaterialTheme.typography.bodyMedium)

        Spacer(Modifier.height(16.dp))

        OutlinedTextField(
            value = draft,
            onValueChange = { draft = it },
            modifier = Modifier.fillMaxWidth().height(120.dp),
            placeholder = { Text(stringResource(R.string.draft_placeholder)) },
            keyboardOptions = KeyboardOptions.Default,
        )

        Spacer(Modifier.height(12.dp))

        Button(onClick = { viewModel.coach(draft) }, enabled = state !is UiState.Loading) {
            Text(if (state is UiState.Loading) stringResource(R.string.analyzing) else stringResource(R.string.coach_button))
        }

        Spacer(Modifier.height(16.dp))

        when (val s = state) {
            is UiState.Error -> Text(s.message, color = MaterialTheme.colorScheme.error)
            is UiState.Result -> ResultCard(s.analysis.riskLevel, s.analysis.perception, s.analysis.subtext, s.analysis.riskReason, s.analysis.suggestions.map { it.axis to it.text })
            else -> Text(stringResource(R.string.empty_state), style = MaterialTheme.typography.bodySmall)
        }

        Spacer(Modifier.height(20.dp))
        Divider()
        Spacer(Modifier.height(12.dp))
        AccountSection()
    }
}

@Composable
fun AccountSection(viewModel: AccountViewModel = viewModel()) {
    val state by viewModel.state.collectAsState()
    val context = LocalContext.current
    var couponCode by remember { mutableStateOf("") }

    LaunchedEffect(Unit) {
        viewModel.openUrl.collect { url ->
            CustomTabsIntent.Builder().build().launchUrl(context, Uri.parse(url))
        }
    }

    Text(
        text = if (state.isPro) {
            stringResource(R.string.account_plan_pro, state.plan)
        } else {
            stringResource(R.string.account_plan_free, state.plan)
        },
        style = MaterialTheme.typography.bodyMedium,
    )
    Spacer(Modifier.height(8.dp))
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (state.isPro) {
            OutlinedButton(onClick = { viewModel.manageSubscription() }) {
                Text(stringResource(R.string.manage_button))
            }
        } else {
            OutlinedButton(onClick = { viewModel.upgrade() }) {
                Text(stringResource(R.string.upgrade_button))
            }
        }
    }
    state.billingStatus?.let {
        Spacer(Modifier.height(6.dp))
        Text(it, style = MaterialTheme.typography.bodySmall)
    }

    Spacer(Modifier.height(16.dp))
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(
            value = couponCode,
            onValueChange = { couponCode = it },
            modifier = Modifier.weight(1f),
            placeholder = { Text(stringResource(R.string.coupon_placeholder)) },
            singleLine = true,
        )
        OutlinedButton(onClick = {
            viewModel.redeemCoupon(couponCode.trim())
            couponCode = ""
        }) {
            Text(stringResource(R.string.redeem_button))
        }
    }
    state.couponStatus?.let {
        Spacer(Modifier.height(6.dp))
        Text(it, style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
private fun ResultCard(
    riskLevel: String,
    perception: String,
    subtext: String,
    riskReason: String,
    suggestions: List<Pair<String, String>>,
) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            Surface(color = riskColor[riskLevel] ?: Color.Gray, shape = MaterialTheme.shapes.small) {
                Text(
                    text = riskLabel(riskLevel).uppercase(),
                    color = Color.White,
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
                    style = MaterialTheme.typography.labelMedium,
                )
            }
            Spacer(Modifier.height(8.dp))
            Text(perception, style = MaterialTheme.typography.bodyLarge)
            if (subtext.isNotBlank()) Text(subtext, style = MaterialTheme.typography.bodySmall)
            if (riskReason.isNotBlank()) Text(riskReason, style = MaterialTheme.typography.bodySmall)

            Spacer(Modifier.height(12.dp))
            suggestions.forEach { (axis, text) ->
                Column(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
                    Text(axisLabel(axis), fontWeight = FontWeight.Bold)
                    Text(text)
                }
            }
        }
    }
}

@Composable
private fun riskLabel(level: String): String = when (level) {
    "low" -> stringResource(R.string.risk_low)
    "high" -> stringResource(R.string.risk_high)
    else -> stringResource(R.string.risk_medium)
}

@Composable
private fun axisLabel(axis: String): String = when (axis) {
    "warmer" -> stringResource(R.string.axis_warmer)
    "clearer" -> stringResource(R.string.axis_clearer)
    "funnier" -> stringResource(R.string.axis_funnier)
    "safer" -> stringResource(R.string.axis_safer)
    else -> axis
}

package com.tono.ime.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.tono.ime.CoachViewModel
import com.tono.ime.KeyboardMode
import com.tono.shared.models.AnalysisMode
import com.tono.shared.models.RewriteAxis
import com.tono.shared.models.RewriteSuggestion
import com.tono.shared.models.RiskLevel
import com.tono.shared.models.ToneAnalysis
import com.tono.shared.storage.Recipient

// Mirrors ios/KeyboardExtension/KeyboardRootView.swift

private val Purple       = Color(0xFF9B59B6)
private val PurpleDark   = Color(0xFF7D3C98)
private val AmberWarn    = Color(0xFFF39C12)
private val RedError     = Color(0xFFE74C3C)
private val GreenOk      = Color(0xFF27AE60)
private val Surface      = Color(0xFF1C1C1E)
private val SurfaceVariant = Color(0xFF2C2C2E)

@Composable
fun KeyboardScreen(
    viewModel: CoachViewModel,
    draft: String,
    onInsertText: (String) -> Unit,
    onDeleteBackward: () -> Unit,
    onInsertSpace: () -> Unit,
    onSwitchIme: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val mode              by viewModel.mode.collectAsState()
    val recipients        by viewModel.recipients.collectAsState()
    val selectedRecipient by viewModel.selectedRecipient.collectAsState()

    Box(
        modifier = modifier
            .fillMaxWidth()
            .background(Surface)
            .heightIn(min = 260.dp),
    ) {
        when (val m = mode) {
            is KeyboardMode.Keyboard -> KeyboardLayout(
                draft             = draft,
                recipients        = recipients,
                selectedRecipient = selectedRecipient,
                onSelectRecipient = { viewModel.selectRecipient(it) },
                onCoach           = { viewModel.runCoach() },
                onRead            = { viewModel.runRead() },
                onDeleteBackward  = onDeleteBackward,
                onInsertSpace     = onInsertSpace,
                onSwitchIme       = onSwitchIme,
            )
            is KeyboardMode.Loading -> LoadingView()
            is KeyboardMode.Results -> ResultsView(
                analysis = m.analysis,
                mode     = m.mode,
                onInsert = { suggestion ->
                    val text = viewModel.onRewriteChosen(suggestion, m.analysis)
                    onInsertText(text)
                },
                onBack = { viewModel.goBack() },
            )
            is KeyboardMode.Error -> ErrorView(
                message = m.message,
                onBack  = { viewModel.goBack() },
            )
        }
    }
}

// ─── Keyboard layout ──────────────────────────────────────────────────────────

@Composable
private fun KeyboardLayout(
    draft: String,
    recipients: List<Recipient>,
    selectedRecipient: Recipient?,
    onSelectRecipient: (Recipient) -> Unit,
    onCoach: () -> Unit,
    onRead: () -> Unit,
    onDeleteBackward: () -> Unit,
    onInsertSpace: () -> Unit,
    onSwitchIme: () -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp)) {

        // Draft preview
        if (draft.isNotEmpty()) {
            Text(
                text     = draft.takeLast(120),
                color    = Color.White.copy(alpha = 0.5f),
                fontSize = 13.sp,
                maxLines = 2,
                modifier = Modifier.padding(bottom = 4.dp, start = 4.dp),
            )
        }

        // Recipient chip row — only shown when the user has added recipients
        if (recipients.isNotEmpty()) {
            RecipientChipRow(
                recipients        = recipients,
                selectedRecipient = selectedRecipient,
                onSelect          = onSelectRecipient,
            )
            Spacer(Modifier.height(4.dp))
        }

        // Action row
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment     = Alignment.CenterVertically,
        ) {
            // Globe — switch IME
            KeyButton(
                icon     = "⌨",
                label    = "Switch keyboard",
                onClick  = onSwitchIme,
                modifier = Modifier.semantics { contentDescription = "Switch keyboard" },
            )

            // Space
            KeyButton(
                label   = "space",
                onClick = onInsertSpace,
                modifier = Modifier
                    .weight(1f)
                    .padding(horizontal = 4.dp)
                    .semantics { contentDescription = "Space" },
            )

            // Backspace
            KeyButton(
                icon     = "⌫",
                label    = "Delete",
                onClick  = onDeleteBackward,
                modifier = Modifier.semantics { contentDescription = "Delete" },
            )

            Spacer(Modifier.width(8.dp))

            // Read button
            ActionButton(
                label    = "Read",
                onClick  = onRead,
                modifier = Modifier.semantics {
                    contentDescription = "Read — interpret a message you received"
                },
            )

            Spacer(Modifier.width(6.dp))

            // Coach button
            ActionButton(
                label    = "Coach",
                onClick  = onCoach,
                primary  = true,
                modifier = Modifier.semantics {
                    contentDescription = "Coach — analyze your draft"
                },
            )
        }
    }
}

// Horizontally scrollable row of recipient chips.
// Selected chip turns purple; all others are muted.
@Composable
private fun RecipientChipRow(
    recipients: List<Recipient>,
    selectedRecipient: Recipient?,
    onSelect: (Recipient) -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(start = 4.dp, bottom = 2.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment     = Alignment.CenterVertically,
    ) {
        Text("To:", color = Color.White.copy(alpha = 0.4f), fontSize = 12.sp,
            modifier = Modifier.padding(end = 2.dp))
        recipients.forEach { recipient ->
            val selected = selectedRecipient?.id == recipient.id
            Box(
                Modifier
                    .background(
                        if (selected) Purple else SurfaceVariant,
                        RoundedCornerShape(16.dp),
                    )
                    .clickable { onSelect(recipient) }
                    .padding(horizontal = 10.dp, vertical = 5.dp)
                    .semantics {
                        contentDescription = if (selected)
                            "${recipient.label} selected as recipient. Tap to deselect."
                        else
                            "Select ${recipient.label} as recipient."
                    },
            ) {
                Text(
                    text     = recipient.label,
                    color    = if (selected) Color.White else Color.White.copy(alpha = 0.65f),
                    fontSize = 12.sp,
                    fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                )
            }
        }
    }
}

@Composable
private fun KeyButton(
    icon: String? = null,
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .background(SurfaceVariant, RoundedCornerShape(8.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(icon ?: label, color = Color.White, fontSize = 15.sp)
    }
}

@Composable
private fun ActionButton(
    label: String,
    onClick: () -> Unit,
    primary: Boolean = false,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .background(if (primary) Purple else SurfaceVariant, RoundedCornerShape(10.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 10.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(label, color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
    }
}

// ─── Loading ─────────────────────────────────────────────────────────────────

@Composable
private fun LoadingView() {
    Box(Modifier.fillMaxWidth().height(200.dp), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(color = Purple, modifier = Modifier.size(32.dp))
    }
}

// ─── Results ─────────────────────────────────────────────────────────────────

@Composable
private fun ResultsView(
    analysis: ToneAnalysis,
    mode: AnalysisMode,
    onInsert: (RewriteSuggestion) -> Unit,
    onBack: () -> Unit,
) {
    Column(
        Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        // Back + risk badge row
        Row(
            verticalAlignment     = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            TextButton(onClick = onBack) {
                Text("← Back", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp)
            }
            RiskBadge(level = analysis.riskLevel, reason = analysis.reason)
        }

        // Perception
        Text(
            text     = analysis.perception,
            color    = Color.White,
            fontSize = 15.sp,
            modifier = Modifier.semantics {
                contentDescription = "Analysis: ${analysis.perception}"
            },
        )

        // Rewrites (Coach mode only)
        if (mode == AnalysisMode.COACH) {
            analysis.suggestions.forEach { suggestion ->
                RewriteChip(suggestion = suggestion, onInsert = { onInsert(suggestion) })
            }
        }
    }
}

@Composable
private fun RiskBadge(level: RiskLevel, reason: String?) {
    val (color, icon) = when (level) {
        RiskLevel.LOW    -> GreenOk   to "✓"
        RiskLevel.MEDIUM -> AmberWarn to "!"
        RiskLevel.HIGH   -> RedError  to "⚠"
    }
    val description = "${level.displayName}${if (reason != null) ". $reason" else ""}"
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .background(color.copy(alpha = 0.15f), RoundedCornerShape(20.dp))
            .padding(horizontal = 10.dp, vertical = 4.dp)
            .semantics(mergeDescendants = true) { contentDescription = description },
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        // A5: icon + color — two signals for color-blind users
        Text(icon, color = color, fontSize = 13.sp, fontWeight = FontWeight.Bold)
        Text(level.displayName, color = color, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun RewriteChip(suggestion: RewriteSuggestion, onInsert: () -> Unit) {
    val axisColor = when (suggestion.axis) {
        RewriteAxis.WARMER  -> Color(0xFFE67E22)
        RewriteAxis.CLEARER -> Color(0xFF3498DB)
        RewriteAxis.FUNNIER -> Color(0xFF27AE60)
        RewriteAxis.SAFER   -> Color(0xFF9B59B6)
    }
    val a11yLabel = "${suggestion.axis.displayName} rewrite. ${suggestion.text}. " +
            "Tap to insert. ${suggestion.axis.bestWhen}."

    Column(
        Modifier
            .fillMaxWidth()
            .background(SurfaceVariant, RoundedCornerShape(12.dp))
            .clickable(onClick = onInsert)
            .padding(12.dp)
            .semantics { contentDescription = a11yLabel },
    ) {
        Row(
            verticalAlignment     = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Box(
                Modifier
                    .background(axisColor, RoundedCornerShape(6.dp))
                    .padding(horizontal = 8.dp, vertical = 3.dp),
            ) {
                Text(suggestion.axis.displayName, color = Color.White,
                    fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
            }
        }
        Spacer(Modifier.height(6.dp))
        // C3: rewrite text
        Text(suggestion.text, color = Color.White, fontSize = 15.sp, lineHeight = 21.sp)
        Spacer(Modifier.height(4.dp))
        // C3: bestWhen usage condition
        Text(suggestion.axis.bestWhen, color = Color.White.copy(alpha = 0.45f), fontSize = 12.sp)
    }
}

// ─── Error ────────────────────────────────────────────────────────────────────

@Composable
private fun ErrorView(message: String, onBack: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().padding(16.dp),
        verticalArrangement  = Arrangement.spacedBy(12.dp),
        horizontalAlignment  = Alignment.CenterHorizontally,
    ) {
        Text(message, color = Color.White.copy(alpha = 0.7f), fontSize = 14.sp)
        TextButton(onClick = onBack) {
            Text("← Back", color = Purple)
        }
    }
}

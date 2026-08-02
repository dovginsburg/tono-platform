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
import com.tono.ime.keyboard.KeyLayer
import com.tono.ime.keyboard.KeyboardLayout
import com.tono.ime.keyboard.ShiftState
import com.tono.ime.keyboard.displayLabel
import com.tono.ime.keyboard.shiftAccessibilityLabel
import com.tono.ime.keyboard.shiftGlyph
import com.tono.shared.models.AnalysisMode
import com.tono.shared.models.RewriteAxis
import com.tono.shared.models.RewriteSuggestion
import com.tono.shared.models.RiskLevel
import com.tono.shared.models.ToneAnalysis
import com.tono.shared.storage.Recipient

// Mirrors ios/KeyboardExtension/KeyboardViewController.swift — a full QWERTY
// keyboard with Tono's Coach/Read layered on top as explicit, tap-only actions.

private val Purple         = Color(0xFF9B59B6)
private val AmberWarn      = Color(0xFFF39C12)
private val RedError       = Color(0xFFE74C3C)
private val GreenOk        = Color(0xFF27AE60)
private val Surface        = Color(0xFF1C1C1E)
private val KeyFill        = Color(0xFF3A3A3C)
private val SpecialKeyFill = Color(0xFF2C2C2E)

// Every key clears the 44dp accessibility minimum touch target.
private val KeyHeight = 46.dp

@Composable
fun KeyboardScreen(
    viewModel: CoachViewModel,
    draft: String,
    onKey: (String) -> Unit,
    onShift: () -> Unit,
    onSwitchLayer: () -> Unit,
    onDeleteBackward: () -> Unit,
    onReturn: () -> Unit,
    onInsertText: (String) -> Unit,
    onSwitchIme: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val mode              by viewModel.mode.collectAsState()
    val recipients        by viewModel.recipients.collectAsState()
    val selectedRecipient by viewModel.selectedRecipient.collectAsState()
    val layer             by viewModel.layer.collectAsState()
    val shift             by viewModel.shift.collectAsState()
    val secureField       by viewModel.secureField.collectAsState()
    val returnLabel       by viewModel.returnLabel.collectAsState()

    Box(
        modifier = modifier
            .fillMaxWidth()
            .background(Surface)
            .heightIn(min = 300.dp),
    ) {
        when (val m = mode) {
            is KeyboardMode.Keyboard -> TypingKeyboard(
                draft             = draft,
                recipients        = recipients,
                selectedRecipient = selectedRecipient,
                layer             = layer,
                shift             = shift,
                secureField       = secureField,
                returnLabel       = returnLabel,
                onSelectRecipient = { viewModel.selectRecipient(it) },
                onCoach           = { viewModel.runCoach() },
                onRead            = { viewModel.runRead() },
                onKey             = onKey,
                onShift           = onShift,
                onSwitchLayer     = onSwitchLayer,
                onDeleteBackward  = onDeleteBackward,
                onReturn          = onReturn,
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
private fun TypingKeyboard(
    draft: String,
    recipients: List<Recipient>,
    selectedRecipient: Recipient?,
    layer: KeyLayer,
    shift: ShiftState,
    secureField: Boolean,
    returnLabel: String,
    onSelectRecipient: (Recipient) -> Unit,
    onCoach: () -> Unit,
    onRead: () -> Unit,
    onKey: (String) -> Unit,
    onShift: () -> Unit,
    onSwitchLayer: () -> Unit,
    onDeleteBackward: () -> Unit,
    onReturn: () -> Unit,
    onSwitchIme: () -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 6.dp)) {

        // Coach/Read read the field, so they only appear where reading is
        // allowed. In secure fields the keyboard still types; the analysis
        // strip is replaced by a plain, honest note.
        if (secureField) {
            Text(
                text     = "Password field — Tono types on your device. Coach and Read are off here.",
                color    = Color.White.copy(alpha = 0.55f),
                fontSize = 12.sp,
                modifier = Modifier
                    .padding(horizontal = 6.dp, vertical = 6.dp)
                    .semantics {
                        contentDescription =
                            "Password field. Tono types on your device. " +
                            "Coach and Read are turned off here."
                    },
            )
        } else {
            CoachStrip(
                draft             = draft,
                recipients        = recipients,
                selectedRecipient = selectedRecipient,
                onSelectRecipient = onSelectRecipient,
                onCoach           = onCoach,
                onRead            = onRead,
            )
        }

        Spacer(Modifier.height(6.dp))

        // ─── Character rows ───────────────────────────────────────────────
        val rows = KeyboardLayout.rows(layer)
        rows.forEachIndexed { index, row ->
            val isLastRow = index == rows.lastIndex
            Row(
                Modifier.fillMaxWidth().padding(vertical = 3.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                if (isLastRow) {
                    if (layer == KeyLayer.LETTERS) {
                        SpecialKey(
                            label       = shiftGlyph(shift),
                            description = shiftAccessibilityLabel(shift),
                            highlighted = shift != ShiftState.NONE,
                            onClick     = onShift,
                            modifier    = Modifier.weight(1.5f),
                        )
                    } else {
                        Spacer(Modifier.weight(1.5f))
                    }
                }

                // Row 2 of letters is inset by half a key on each side to
                // reproduce the QWERTY stagger, exactly like iOS makeIndentedRow.
                val indent = layer == KeyLayer.LETTERS && index == 1
                if (indent) Spacer(Modifier.weight(0.5f))

                row.forEach { key ->
                    CharKey(
                        label   = displayLabel(key, layer, shift),
                        raw     = key,
                        onKey   = onKey,
                        modifier = Modifier.weight(1f),
                    )
                }

                if (indent) Spacer(Modifier.weight(0.5f))

                if (isLastRow) {
                    SpecialKey(
                        label       = "⌫",
                        description = "Delete",
                        onClick     = onDeleteBackward,
                        modifier    = Modifier.weight(1.5f),
                    )
                }
            }
        }

        // ─── Bottom action row ────────────────────────────────────────────
        Row(
            Modifier.fillMaxWidth().padding(vertical = 3.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            SpecialKey(
                label       = if (layer == KeyLayer.LETTERS) "123" else "ABC",
                description = if (layer == KeyLayer.LETTERS) "Numbers and symbols" else "Letters",
                onClick     = onSwitchLayer,
                modifier    = Modifier.weight(1.6f),
            )
            SpecialKey(
                label       = "⌨",
                description = "Switch keyboard",
                onClick     = onSwitchIme,
                modifier    = Modifier.weight(1.2f),
            )
            SpecialKey(
                label       = "space",
                description = "Space",
                onClick     = { onKey(" ") },
                modifier    = Modifier.weight(4f),
            )
            SpecialKey(
                label       = returnLabel,
                description = returnLabel,
                highlighted = true,
                onClick     = onReturn,
                modifier    = Modifier.weight(2f),
            )
        }
    }
}

// Draft preview + the explicit Coach/Read actions. Coach/Read never fire on
// typing — only when the user taps these buttons.
@Composable
private fun CoachStrip(
    draft: String,
    recipients: List<Recipient>,
    selectedRecipient: Recipient?,
    onSelectRecipient: (Recipient) -> Unit,
    onCoach: () -> Unit,
    onRead: () -> Unit,
) {
    Column {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text     = if (draft.isEmpty()) "Type a message, then tap Coach" else draft.takeLast(120),
                color    = if (draft.isEmpty()) Color.White.copy(alpha = 0.4f) else Color.White.copy(alpha = 0.75f),
                fontSize = 13.sp,
                maxLines = 1,
                modifier = Modifier.weight(1f),
            )
            Spacer(Modifier.width(6.dp))
            ActionButton(
                label   = "Read",
                onClick = onRead,
                modifier = Modifier.semantics {
                    contentDescription = "Read — interpret a message you received"
                },
            )
            Spacer(Modifier.width(6.dp))
            ActionButton(
                label   = "Coach",
                onClick = onCoach,
                primary = true,
                modifier = Modifier.semantics {
                    contentDescription = "Coach — analyze your draft and suggest rewrites"
                },
            )
        }

        if (recipients.isNotEmpty()) {
            Spacer(Modifier.height(4.dp))
            RecipientChipRow(
                recipients        = recipients,
                selectedRecipient = selectedRecipient,
                onSelect          = onSelectRecipient,
            )
        }
    }
}

// ─── Keys ───────────────────────────────────────────────────────────────────

@Composable
private fun CharKey(
    label: String,
    raw: String,
    onKey: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .height(KeyHeight)
            .background(KeyFill, RoundedCornerShape(6.dp))
            .clickable { onKey(raw) }
            // The typed letter is the label; TalkBack reads it in its display case.
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Text(label, color = Color.White, fontSize = 18.sp)
    }
}

@Composable
private fun SpecialKey(
    label: String,
    description: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    highlighted: Boolean = false,
) {
    Box(
        modifier = modifier
            .height(KeyHeight)
            .background(if (highlighted) Purple else SpecialKeyFill, RoundedCornerShape(6.dp))
            .clickable(onClick = onClick)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        Text(label, color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.Medium)
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
                        if (selected) Purple else SpecialKeyFill,
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
private fun ActionButton(
    label: String,
    onClick: () -> Unit,
    primary: Boolean = false,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .heightIn(min = 44.dp)
            .background(if (primary) Purple else SpecialKeyFill, RoundedCornerShape(10.dp))
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
            .background(SpecialKeyFill, RoundedCornerShape(12.dp))
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

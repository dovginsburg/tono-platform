package com.tono.app.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.tono.shared.storage.SharedKeys
import com.tono.shared.storage.SharedStore
import com.tono.shared.storage.UserMemory

// Mirrors ios/App/OnboardingCalibrationView.swift
// 5 steps: role + writing-style + recipient + privacy + how-it-works (D3/D4)

private val Purple = Color(0xFF9B59B6)

@Composable
fun OnboardingScreen(onDone: () -> Unit) {
    var step by remember { mutableIntStateOf(0) }
    var roleAnswer by remember { mutableStateOf("") }
    var tendencyAnswer by remember { mutableStateOf("") }
    var recipientAnswer by remember { mutableStateOf("") }
    val totalSteps = 5

    Column(
        Modifier.fillMaxSize().background(Color.Black).padding(24.dp),
        verticalArrangement = Arrangement.SpaceBetween,
    ) {
        Column {
            // Header
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text("Quick setup", color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
                TextButton(onClick = { finish(roleAnswer, tendencyAnswer, recipientAnswer); onDone() }) {
                    Text("Skip", color = Color.White.copy(alpha = 0.5f))
                }
            }
            Spacer(Modifier.height(16.dp))

            // Progress dots
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                repeat(totalSteps) { i ->
                    Box(
                        Modifier
                            .weight(1f)
                            .height(4.dp)
                            .background(
                                if (i <= step) Purple else Color.White.copy(alpha = 0.2f),
                                RoundedCornerShape(2.dp),
                            )
                    )
                }
            }
            Spacer(Modifier.height(40.dp))

            AnimatedContent(targetState = step, label = "onboarding_step") { s ->
                when (s) {
                    0 -> StepCard(
                        icon        = "👤",
                        question    = "What best describes you?",
                        placeholder = "e.g. manager, founder, individual contributor",
                        answer      = roleAnswer,
                        onAnswer    = { roleAnswer = it },
                    )
                    1 -> StepCard(
                        icon        = "✏️",
                        question    = "How would others describe your writing?",
                        placeholder = "e.g. direct and brief, overly formal, occasionally passive-aggressive",
                        answer      = tendencyAnswer,
                        onAnswer    = { tendencyAnswer = it },
                    )
                    2 -> StepCard(
                        icon        = "👥",
                        question    = "Who do you message most often?",
                        placeholder = "e.g. my manager, teammates, clients",
                        answer      = recipientAnswer,
                        onAnswer    = { recipientAnswer = it },
                    )
                    3 -> InfoCard(
                        icon     = "🔒",
                        headline = "Your memory, your control",
                        bullets  = listOf(
                            "Everything Tono learns stays on your device",
                            "You can see and delete every fact in the Memory tab",
                            "Tono only gets smarter during sessions you choose",
                            "API keys never leave our server — your device never sees them",
                        ),
                    )
                    4 -> InfoCard(
                        icon     = "⌨️",
                        headline = "How to use Tono",
                        bullets  = listOf(
                            "Draft in any app, then switch to the Tono keyboard when you're ready to send",
                            "Tono can't read anything unless you tap Coach or Read",
                            "Secure fields (passwords, banking) block all keyboards — that's Android, not us",
                            "Tap Coach to analyze your draft · Tap Read to interpret a message you received",
                        ),
                    )
                }
            }
        }

        Button(
            onClick = {
                if (step < totalSteps - 1) step++ else {
                    finish(roleAnswer, tendencyAnswer, recipientAnswer)
                    onDone()
                }
            },
            modifier = Modifier.fillMaxWidth().height(52.dp),
            colors = ButtonDefaults.buttonColors(containerColor = Purple),
            shape  = RoundedCornerShape(14.dp),
        ) {
            Text(
                if (step == totalSteps - 1) "Get started" else "Next",
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
            )
        }
    }
}

@Composable
private fun StepCard(icon: String, question: String, placeholder: String, answer: String, onAnswer: (String) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {
        Text(icon, fontSize = 40.sp, modifier = Modifier.fillMaxWidth(), textAlign = TextAlign.Center)
        Text(question, color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(
            value         = answer,
            onValueChange = onAnswer,
            placeholder   = { Text(placeholder, color = Color.White.copy(alpha = 0.35f)) },
            modifier      = Modifier.fillMaxWidth(),
            colors        = OutlinedTextFieldDefaults.colors(
                focusedBorderColor   = Color(0xFF9B59B6),
                unfocusedBorderColor = Color.White.copy(alpha = 0.2f),
                focusedTextColor     = Color.White,
                unfocusedTextColor   = Color.White,
            ),
            minLines = 2, maxLines = 4,
        )
    }
}

@Composable
private fun InfoCard(icon: String, headline: String, bullets: List<String>) {
    Column(verticalArrangement = Arrangement.spacedBy(24.dp)) {
        Text(icon, fontSize = 44.sp, modifier = Modifier.fillMaxWidth(), textAlign = TextAlign.Center)
        Text(headline, color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            bullets.forEach { bullet ->
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text("✓", color = Color(0xFF9B59B6), fontSize = 14.sp, fontWeight = FontWeight.Bold)
                    Text(bullet, color = Color.White.copy(alpha = 0.85f), fontSize = 15.sp)
                }
            }
        }
    }
}

private fun finish(role: String, tendency: String, recipient: String) {
    role.trim().takeIf { it.isNotEmpty() }?.let { UserMemory.addManual(it, "profile") }
    tendency.trim().takeIf { it.isNotEmpty() }?.let { UserMemory.addManual(it, "tendency") }
    recipient.trim().takeIf { it.isNotEmpty() }?.let { UserMemory.addManual("Often messages $it", "communication") }
    SharedStore.putBoolean(SharedKeys.ONBOARDING_DONE, true)
}

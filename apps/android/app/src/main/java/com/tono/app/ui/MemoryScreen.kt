package com.tono.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.tono.shared.storage.MemoryFact
import com.tono.shared.storage.SharedKeys
import com.tono.shared.storage.SharedStore
import com.tono.shared.storage.UserMemory

// Mirrors ios/App/MemoryView.swift
// Pro users: browse + add + delete facts grouped by category.
// Free users: teaser with blurred examples.

private val Purple = Color(0xFF9B59B6)

private val CATEGORIES = listOf("profile", "tendency", "communication", "inferred")
private val CATEGORY_LABELS = mapOf(
    "profile"       to "Profile",
    "tendency"      to "Tendency",
    "communication" to "Communication",
    "inferred"      to "Learned",
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MemoryScreen() {
    val isPro = SharedStore.getBoolean(SharedKeys.PRO_UNLOCKED)
    var facts by remember { mutableStateOf(UserMemory.all()) }
    var showAddSheet by remember { mutableStateOf(false) }
    var showClearConfirm by remember { mutableStateOf(false) }

    fun reload() { facts = UserMemory.all() }

    Scaffold(
        floatingActionButton = {
            if (isPro) {
                FloatingActionButton(
                    onClick = { showAddSheet = true },
                    containerColor = Purple,
                ) {
                    Icon(Icons.Default.Add, contentDescription = "Add memory", tint = Color.White)
                }
            }
        },
    ) { padding ->
        if (isPro) {
            Column(
                Modifier
                    .padding(padding)
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState()),
            ) {
                if (facts.isNotEmpty()) {
                    // Clear-all button
                    TextButton(
                        onClick = { showClearConfirm = true },
                        modifier = Modifier.padding(horizontal = 8.dp),
                    ) {
                        Text("Clear all", color = MaterialTheme.colorScheme.error, fontSize = 14.sp)
                    }

                    // How-it-works note
                    Text(
                        "These facts are sent as short hints with each rewrite request so Tono personalizes suggestions without you having to repeat yourself.",
                        color    = Color.Gray,
                        fontSize = 12.sp,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
                    )

                    Spacer(Modifier.height(8.dp))

                    CATEGORIES.forEach { category ->
                        val catFacts = facts.filter { it.category == category }
                        if (catFacts.isNotEmpty()) {
                            CategorySection(
                                label = CATEGORY_LABELS[category] ?: category,
                                facts = catFacts,
                                onDelete = { id ->
                                    UserMemory.delete(id)
                                    reload()
                                },
                            )
                        }
                    }
                } else {
                    EmptyState(onAdd = { showAddSheet = true })
                }
            }
        } else {
            MemoryProTeaser(modifier = Modifier.padding(padding))
        }
    }

    if (showAddSheet) {
        AddMemorySheet(
            onDismiss = { showAddSheet = false },
            onSave    = { content, category ->
                UserMemory.addManual(content, category)
                reload()
                showAddSheet = false
            },
        )
    }

    if (showClearConfirm) {
        AlertDialog(
            onDismissRequest = { showClearConfirm = false },
            title   = { Text("Clear all memories?") },
            text    = { Text("Tono will start learning again from your next session.") },
            confirmButton = {
                TextButton(onClick = {
                    UserMemory.deleteAll()
                    reload()
                    showClearConfirm = false
                }) {
                    Text("Clear all", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { showClearConfirm = false }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun CategorySection(label: String, facts: List<MemoryFact>, onDelete: (String) -> Unit) {
    Column(Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) {
        Text(
            label.uppercase(),
            color      = Color.Gray,
            fontSize   = 11.sp,
            fontWeight = FontWeight.SemiBold,
            modifier   = Modifier.padding(vertical = 6.dp),
        )
        Surface(
            shape         = RoundedCornerShape(12.dp),
            tonalElevation = 1.dp,
        ) {
            Column {
                facts.forEachIndexed { index, fact ->
                    FactRow(fact = fact, onDelete = { onDelete(fact.id) })
                    if (index < facts.lastIndex) {
                        HorizontalDivider(Modifier.padding(start = 16.dp))
                    }
                }
            }
        }
        Spacer(Modifier.height(12.dp))
    }
}

@Composable
private fun FactRow(fact: MemoryFact, onDelete: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment     = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(fact.content, fontSize = 14.sp)
            Text(
                if (fact.category == "inferred") "✦ Learned by Tono" else "Added by you",
                color    = if (fact.category == "inferred") Purple else Color.Gray,
                fontSize = 11.sp,
            )
        }
        IconButton(onClick = onDelete) {
            Icon(Icons.Default.Delete, contentDescription = "Delete",
                tint = Color.Gray, modifier = Modifier.size(18.dp))
        }
    }
}

@Composable
private fun EmptyState(onAdd: () -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("🧠", fontSize = 40.sp)
        Text("No memories yet", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
        Text(
            "Tono learns from your rewrite choices. After a few sessions, it will recognize patterns here and use them to personalize future rewrites automatically.",
            color = Color.Gray,
            fontSize = 14.sp,
        )
        TextButton(onClick = onAdd) {
            Text("Add something manually", color = Purple)
        }
    }
}

@Composable
private fun MemoryProTeaser(modifier: Modifier = Modifier) {
    val exampleFacts = listOf(
        "Goes warmer with close colleagues",
        "Direct tone with managers",
        "Clients prefer formal language",
        "Tends to soften risk before sending",
    )

    Column(
        modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(24.dp),
    ) {
        Column(
            Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text("🧠", fontSize = 40.sp)
            Text(
                "Tono learns how you communicate",
                fontSize = 20.sp, fontWeight = FontWeight.Bold, color = Color.White,
            )
            Text(
                "After a few sessions, Tono builds a picture of how you write — and quietly adjusts rewrites to sound like you at your best.",
                color = Color.Gray, fontSize = 14.sp,
            )
        }

        // Blurred example list
        Column(
            Modifier
                .fillMaxWidth()
                .background(MaterialTheme.colorScheme.surface, RoundedCornerShape(14.dp))
                .padding(16.dp)
                .blur(3.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text("Example — what Pro subscribers see",
                color = Color.Gray, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
            exampleFacts.forEach { text ->
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text("✦", color = Purple, fontSize = 12.sp)
                    Text(text, fontSize = 14.sp)
                }
            }
        }

        Text(
            "Upgrade to Pro to unlock memory, per-recipient coaching, and weekly digest.",
            color = Color.Gray, fontSize = 14.sp,
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AddMemorySheet(onDismiss: () -> Unit, onSave: (String, String) -> Unit) {
    var content  by remember { mutableStateOf("") }
    var category by remember { mutableStateOf("profile") }

    val examples = listOf("I'm a manager", "I tend to be too direct", "I work in finance", "I prefer no-fluff replies")

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 24.dp)
                .padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text("Add memory", fontSize = 18.sp, fontWeight = FontWeight.SemiBold, color = Color.White)

            OutlinedTextField(
                value         = content,
                onValueChange = { content = it },
                label         = { Text("What should Tono remember?") },
                placeholder   = { Text(examples.random(), color = Color.Gray) },
                modifier      = Modifier.fillMaxWidth(),
                minLines      = 2,
                maxLines      = 4,
            )

            // Category tabs
            Text("Category", color = Color.Gray, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                listOf("profile" to "Profile", "tendency" to "Tendency", "communication" to "Comms").forEachIndexed { i, (key, label) ->
                    SegmentedButton(
                        selected = category == key,
                        onClick  = { category = key },
                        shape    = SegmentedButtonDefaults.itemShape(i, 3),
                    ) {
                        Text(label, fontSize = 12.sp)
                    }
                }
            }

            Text(
                "Stored only on your device. Sent as a short hint alongside your draft — never stored on the server.",
                color = Color.Gray, fontSize = 11.sp,
            )

            Button(
                onClick  = { onSave(content.trim(), category) },
                enabled  = content.isNotBlank(),
                modifier = Modifier.fillMaxWidth(),
                colors   = ButtonDefaults.buttonColors(containerColor = Purple),
                shape    = RoundedCornerShape(12.dp),
            ) {
                Text("Save", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

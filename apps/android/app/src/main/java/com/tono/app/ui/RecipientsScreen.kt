package com.tono.app.ui

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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.tono.shared.storage.Recipient
import com.tono.shared.storage.RecipientMemory

// Mirrors the Recipients section of ios/App/SettingsView.swift (AddRecipientView).
// Lets users add, view, and delete named recipients with optional voice hints.
// The hint is sent alongside each rewrite request to tailor tone for that person.

private val Purple = Color(0xFF9B59B6)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RecipientsScreen() {
    var recipients    by remember { mutableStateOf(RecipientMemory.all()) }
    var showAddSheet  by remember { mutableStateOf(false) }
    var deleteTarget  by remember { mutableStateOf<Recipient?>(null) }

    fun reload() { recipients = RecipientMemory.all() }

    Scaffold(
        floatingActionButton = {
            FloatingActionButton(
                onClick        = { showAddSheet = true },
                containerColor = Purple,
            ) {
                Icon(Icons.Default.Add, contentDescription = "Add recipient", tint = Color.White)
            }
        },
    ) { padding ->
        Column(
            Modifier
                .padding(padding)
                .fillMaxSize()
                .verticalScroll(rememberScrollState()),
        ) {
            Text(
                "When you pick a recipient, their voice hint is sent to the model alongside your draft so the tone is calibrated for that specific person.",
                color    = Color.Gray,
                fontSize = 13.sp,
                modifier = Modifier.padding(16.dp),
            )

            if (recipients.isEmpty()) {
                EmptyRecipients(onAdd = { showAddSheet = true })
            } else {
                Surface(
                    Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp),
                    shape          = RoundedCornerShape(12.dp),
                    tonalElevation = 1.dp,
                ) {
                    Column {
                        recipients.forEachIndexed { index, r ->
                            RecipientRow(
                                recipient = r,
                                onDelete  = { deleteTarget = r },
                            )
                            if (index < recipients.lastIndex) {
                                HorizontalDivider(Modifier.padding(start = 16.dp))
                            }
                        }
                    }
                }
            }

            Spacer(Modifier.height(80.dp)) // clear FAB
        }
    }

    if (showAddSheet) {
        AddRecipientSheet(
            onDismiss = { showAddSheet = false },
            onSave    = { label, hint, safer ->
                RecipientMemory.addNew(label, hint.takeIf { it.isNotBlank() }, safer)
                reload()
                showAddSheet = false
            },
        )
    }

    deleteTarget?.let { r ->
        AlertDialog(
            onDismissRequest = { deleteTarget = null },
            title   = { Text("Remove ${r.label}?") },
            text    = { Text("Their voice hint will no longer be sent with rewrites.") },
            confirmButton = {
                TextButton(onClick = {
                    RecipientMemory.delete(r.id)
                    reload()
                    deleteTarget = null
                }) {
                    Text("Remove", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { deleteTarget = null }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun RecipientRow(recipient: Recipient, onDelete: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment     = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(recipient.label, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                if (recipient.preferSafer) {
                    Text(
                        "safer",
                        color    = Purple,
                        fontSize = 10.sp,
                        modifier = Modifier
                            .padding(horizontal = 6.dp, vertical = 2.dp)
                            .let { it },  // badge styling via Surface below
                    )
                }
            }
            recipient.voiceHint?.let {
                Text(it, color = Color.Gray, fontSize = 13.sp)
            }
        }
        IconButton(onClick = onDelete) {
            Icon(Icons.Default.Delete, contentDescription = "Remove",
                tint = Color.Gray, modifier = Modifier.size(18.dp))
        }
    }
}

@Composable
private fun EmptyRecipients(onAdd: () -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("👥", fontSize = 40.sp)
        Text("No recipients yet", fontSize = 17.sp,
            fontWeight = FontWeight.SemiBold, color = Color.White)
        Text(
            "Add the people you message most. Their voice hint will be used to tailor rewrites — \"prefers formal\", \"dislikes exclamation marks\", etc.",
            color = Color.Gray, fontSize = 14.sp,
        )
        TextButton(onClick = onAdd) {
            Text("Add someone", color = Purple)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AddRecipientSheet(
    onDismiss: () -> Unit,
    onSave:    (label: String, voiceHint: String, preferSafer: Boolean) -> Unit,
) {
    var label       by remember { mutableStateOf("") }
    var voiceHint   by remember { mutableStateOf("") }
    var preferSafer by remember { mutableStateOf(false) }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 24.dp)
                .padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text("Add recipient", fontSize = 18.sp,
                fontWeight = FontWeight.SemiBold, color = Color.White)

            OutlinedTextField(
                value         = label,
                onValueChange = { label = it },
                label         = { Text("Name or relationship") },
                placeholder   = { Text("e.g. Mom, Boss, Alex", color = Color.Gray) },
                modifier      = Modifier.fillMaxWidth(),
                singleLine    = true,
            )

            OutlinedTextField(
                value         = voiceHint,
                onValueChange = { voiceHint = it },
                label         = { Text("Tone hint (optional)") },
                placeholder   = { Text("e.g. prefers formal tone; no humor", color = Color.Gray) },
                modifier      = Modifier.fillMaxWidth(),
                minLines      = 2,
                maxLines      = 3,
            )

            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment     = Alignment.CenterVertically,
            ) {
                Column {
                    Text("Always include safer rewrite", fontSize = 15.sp)
                    Text("Puts the lower-risk option in every result",
                        color = Color.Gray, fontSize = 12.sp)
                }
                Switch(checked = preferSafer, onCheckedChange = { preferSafer = it })
            }

            Text(
                "Stored only on your device. Sent as a short hint alongside your draft.",
                color = Color.Gray, fontSize = 11.sp,
            )

            Button(
                onClick  = { onSave(label.trim(), voiceHint.trim(), preferSafer) },
                enabled  = label.isNotBlank(),
                modifier = Modifier.fillMaxWidth(),
                colors   = ButtonDefaults.buttonColors(containerColor = Purple),
                shape    = RoundedCornerShape(12.dp),
            ) {
                Text("Save", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

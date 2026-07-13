package com.tono.shared.storage

import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.util.UUID

// Mirrors ios/Shared/RecipientMemory.swift
// Stores named recipients with optional voice hints. The hint is passed to
// the backend alongside each rewrite request so the LLM adjusts tone for
// the specific person being addressed.

@Serializable
data class Recipient(
    val id: String,
    val label: String,           // "Mom", "Boss", "Alex"
    val voiceHint: String? = null, // "prefers formal; no humor"
    val preferSafer: Boolean = false,
)

object RecipientMemory {

    fun all(): List<Recipient> {
        val raw = SharedStore.getString(SharedKeys.RECIPIENTS) ?: return emptyList()
        return runCatching { Json.decodeFromString<List<Recipient>>(raw) }.getOrDefault(emptyList())
    }

    fun add(recipient: Recipient) {
        save(all() + recipient)
    }

    fun addNew(label: String, voiceHint: String? = null, preferSafer: Boolean = false) {
        add(Recipient(id = UUID.randomUUID().toString(), label = label,
            voiceHint = voiceHint, preferSafer = preferSafer))
    }

    fun delete(id: String) {
        save(all().filterNot { it.id == id })
    }

    fun hintFor(label: String): String? =
        all().firstOrNull { it.label.equals(label, ignoreCase = true) }?.voiceHint

    private fun save(list: List<Recipient>) {
        SharedStore.putString(SharedKeys.RECIPIENTS, Json.encodeToString(list))
    }
}

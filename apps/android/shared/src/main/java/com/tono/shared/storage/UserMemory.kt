package com.tono.shared.storage

import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

// Mirrors ios/Shared/UserMemory.swift

@Serializable
data class MemoryFact(
    val id: String,
    val content: String,
    val category: String,    // "profile" | "tendency" | "communication" | "inferred"
    val createdAt: Long = System.currentTimeMillis(),
)

object UserMemory {

    private const val MAX_FACTS = 50

    fun all(): List<MemoryFact> {
        val raw = SharedStore.getString(SharedKeys.MEMORY_FACTS) ?: return emptyList()
        return runCatching { Json.decodeFromString<List<MemoryFact>>(raw) }.getOrDefault(emptyList())
    }

    fun addManual(content: String, category: String) {
        val fact = MemoryFact(
            id = java.util.UUID.randomUUID().toString(),
            content = content,
            category = category,
        )
        save((all() + fact).takeLast(MAX_FACTS))
    }

    fun delete(id: String) {
        save(all().filterNot { it.id == id })
    }

    fun deleteAll() = SharedStore.remove(SharedKeys.MEMORY_FACTS)

    fun contextHints(): List<String> = all().map { it.content }.take(10)

    fun recordSession(flags: List<String>, chosenAxis: String) {
        if (flags.isEmpty()) return
        flags.forEach { flag ->
            addManual("Tendency: $flag (resolved via $chosenAxis rewrite)", "inferred")
        }
    }

    private fun save(facts: List<MemoryFact>) {
        SharedStore.putString(SharedKeys.MEMORY_FACTS, Json.encodeToString(facts))
    }
}

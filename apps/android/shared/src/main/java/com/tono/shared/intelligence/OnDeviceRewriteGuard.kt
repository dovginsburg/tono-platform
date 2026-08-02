package com.tono.shared.intelligence

// The load-bearing output guard for the on-device route. Pure Kotlin, so the
// "never return the source draft as a success" and "reject an empty/blocked
// result" rules are unit-testable without ML Kit or a device.
//
// Mirror of iOS `ShortcutRewrite.normalizedForNoOp` / `resolve`. The ML Kit
// boundary calls [resolve] on whatever Gemini Nano returns; it never invents a
// success on its own.
object OnDeviceRewriteGuard {

    /**
     * Case/whitespace/punctuation-insensitive normalization for the no-op
     * comparison — a byte-for-byte mirror of the iOS normalizer so a rewrite
     * that only churns casing or punctuation is still caught as a no-op.
     */
    fun normalizedForNoOp(text: String): String =
        text.lowercase()
            .split(Regex("[^\\p{Alnum}]+"))
            .filter { it.isNotEmpty() }
            .joinToString(" ")

    /**
     * Resolve a raw on-device result into either a distinct rewrite or an honest
     * failure. Returns [OnDeviceRewriteOutcome.Success] ONLY for a non-empty
     * rewrite that is distinct from [source]. An empty result or a near-identical
     * no-op fails — the source draft is NEVER returned as a success.
     *
     * A `null` [rawResult] means the engine produced nothing (guarded here as an
     * empty result) so callers can pass through the model's first suggestion
     * without a separate null check.
     */
    fun resolve(rawResult: String?, source: String): OnDeviceRewriteOutcome {
        val rewrite = (rawResult ?: "").trim()
        if (rewrite.isEmpty()) {
            return OnDeviceRewriteOutcome.Failure(GeminiRewriteUnavailableReason.NO_VALID_REWRITE)
        }
        if (normalizedForNoOp(rewrite) == normalizedForNoOp(source)) {
            return OnDeviceRewriteOutcome.Failure(GeminiRewriteUnavailableReason.NO_VALID_REWRITE)
        }
        return OnDeviceRewriteOutcome.Success(rewrite)
    }
}

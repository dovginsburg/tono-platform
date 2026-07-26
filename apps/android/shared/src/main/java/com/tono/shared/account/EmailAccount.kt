package com.tono.shared.account

import java.text.Normalizer

/**
 * Build 114 — the Android half of the email account contract.
 *
 * This file is deliberately pure Kotlin with no Android imports, so every
 * property below is provable by an ordinary JVM unit test rather than only by
 * running the app. What lives here:
 *
 *   * [EmailAuthOutcome] — the closed set of consumer-visible SHAPES an account
 *     request can produce. The UI switches on these and never on a message, so
 *     no text from the network can reach a screen.
 *   * [EmailAccountCopy] — the ONE place an outcome becomes a sentence a person
 *     reads. Exhaustive, with no `else` branch, so adding an outcome is a
 *     compile error rather than a silently generic screen.
 *   * [EmailAddress] — the same normalization rule the server applies, so the
 *     client and the account ledger agree about what "the same address" means.
 *
 * Mirrors `ios/Shared/TonoBackend.swift` (`EmailAuthOutcome`),
 * `ios/App/OnboardingEntryPointsView.swift` (`emailOutcomeMessage`) and
 * `backend/email_identity.py` (`normalize_email`).
 */

/**
 * What happened, as a shape.
 *
 * [CHECK_YOUR_EMAIL] is deliberately the answer for creating an account,
 * resending a confirmation, and starting a password reset — for a registered
 * AND an unregistered address alike. That identity is the anti-enumeration
 * property: the app must not be usable as an oracle for whether someone has a
 * Tono account, and the server already refuses to be one.
 */
enum class EmailAuthOutcome {
    /** The request was accepted. Identical for a known and an unknown address. */
    CHECK_YOUR_EMAIL,

    /** The address exists but ownership has not been proven yet. */
    VERIFICATION_REQUIRED,

    /** Credentials were rejected. Says nothing about whether the address exists. */
    INVALID_CREDENTIALS,

    /** Throttled. Wait and retry — never a paywall, never a bad password. */
    RATE_LIMITED,

    /** The address is not a usable mailbox, or the password is too short. */
    INVALID_INPUT,

    /** No usable connection. */
    OFFLINE,

    /** Email sign-in is unavailable. Never "we sent you an email". */
    SERVICE_UNAVAILABLE,

    /** Anything else. */
    UNKNOWN_FAILURE,
    ;

    /** True for the accepted answer, so the UI can style a notice rather than an error. */
    val isAccepted: Boolean get() = this == CHECK_YOUR_EMAIL
}

/**
 * What the person was trying to do. Kept separate from the outcome so ONE
 * accepted answer can still name which link is waiting for them — a
 * confirmation link and a password-reset link lead to different next steps,
 * and neither reveals account state.
 */
enum class EmailAccountAction {
    CREATE_ACCOUNT,
    SIGN_IN,
    RESEND_CONFIRMATION,
    RESET_PASSWORD,
}

/** A non-accepted outcome, carrying no message. The absence of a text field is the point. */
class EmailAuthException(val outcome: EmailAuthOutcome) : Exception(outcome.name)

object EmailAccountPolicy {
    /**
     * The server's own floor, mirrored so a person is told the rule while typing
     * rather than after a round trip. The server still enforces it; this only
     * decides whether the button is tappable.
     */
    const val MINIMUM_PASSWORD_LENGTH = 8

    /** Bounded above for the same reason the server bounds it: no multi-megabyte body. */
    const val MAXIMUM_PASSWORD_LENGTH = 512

    fun passwordIsUsable(password: String): Boolean =
        password.length in MINIMUM_PASSWORD_LENGTH..MAXIMUM_PASSWORD_LENGTH
}

/**
 * Normalization, matching `backend/email_identity.normalize_email` rule for
 * rule. Two rules matter enough to restate:
 *
 *   1. Case is folded on BOTH halves. The auth authority lowercases addresses,
 *      so treating `A@x.com` and `a@x.com` as different here would produce two
 *      client identities the server can only back with one.
 *   2. Dots and `+` tags are PRESERVED. Stripping them is a silent-merge
 *      vector: `victim+anything@example.com` would collapse onto
 *      `victim@example.com` and hand someone else's account away.
 */
object EmailAddress {
    private const val MAX_LENGTH = 254
    private const val MAX_LOCAL_LENGTH = 64

    private val LOCAL = Regex("""^[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+)*$""")
    private val DOMAIN_LABEL = Regex("""^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$""")

    /** The canonical comparison form, or null when the input is not a mailbox. */
    fun normalize(raw: String?): String? {
        if (raw == null) return null
        // NFKC first, so a full-width or compatibility look-alike cannot present
        // itself as a different mailbox than the one it folds to.
        val value = Normalizer.normalize(raw, Normalizer.Form.NFKC).trim()
        if (value.isEmpty() || value.length > MAX_LENGTH) return null
        if (value.any { it.isWhitespace() || it.code < 0x20 || it.code == 0x7F }) return null

        val at = value.lastIndexOf('@')
        if (at <= 0 || at == value.length - 1) return null
        val local = value.substring(0, at)
        val domain = value.substring(at + 1)
        if (local.contains('@')) return null
        if (local.length > MAX_LOCAL_LENGTH) return null
        if (!LOCAL.matches(local)) return null
        val labels = domain.split('.')
        if (labels.size < 2 || labels.any { !DOMAIN_LABEL.matches(it) }) return null
        return "${local.lowercase()}@${domain.lowercase()}"
    }

    /** True when [raw] is a usable mailbox. */
    fun isUsable(raw: String?): Boolean = normalize(raw) != null
}

/**
 * The only place in the Android client that turns an outcome into words.
 *
 * Takes an outcome and an action — never an exception, a status code, or a
 * message — so there is no parameter through which implementation detail could
 * arrive. `EmailAccountCopyTest` pins the vocabulary these sentences may use.
 */
object EmailAccountCopy {

    fun message(outcome: EmailAuthOutcome, action: EmailAccountAction): String = when (outcome) {
        EmailAuthOutcome.CHECK_YOUR_EMAIL -> when (action) {
            EmailAccountAction.CREATE_ACCOUNT,
            EmailAccountAction.RESEND_CONFIRMATION ->
                "Check your email. Open the link we sent to confirm your address, then sign in."
            EmailAccountAction.RESET_PASSWORD ->
                "Check your email. Open the link we sent to choose a new password."
            EmailAccountAction.SIGN_IN ->
                "Check your email for the link we sent you."
        }
        EmailAuthOutcome.VERIFICATION_REQUIRED ->
            "Confirm your email address first. Open the link we sent you, or ask for a new one."
        EmailAuthOutcome.INVALID_CREDENTIALS ->
            // Anti-enumerating on purpose: identical whether the address is
            // unknown or the password is wrong.
            "That email and password don't match. Check them and try again."
        EmailAuthOutcome.RATE_LIMITED ->
            // A rate limit is not a paywall and not a bad password. Keeping this
            // sentence free of "subscription" is the same correction Build 113
            // made on the Coach path.
            "Too many tries just now. Wait a minute and try again."
        EmailAuthOutcome.INVALID_INPUT ->
            // Covers BOTH input-shaped refusals the server can answer with: an
            // address it will not accept, and a password the auth provider
            // considers too weak on its own rules. Naming only the length floor
            // was a dead end for the second one — someone who typed twenty
            // characters and was refused for lack of a digit would read "use at
            // least 8 characters", change nothing, and be refused again. The
            // client cannot tell the two apart (both arrive as 400, carrying no
            // provider text by design), so the sentence must be true of either.
            "That email address or password can't be used. Try a different address, " +
                "or a longer, less predictable password."
        EmailAuthOutcome.OFFLINE ->
            "You're offline. Check your connection and try again."
        EmailAuthOutcome.SERVICE_UNAVAILABLE ->
            // Never "we sent you an email". Dressing an operational failure up
            // as delivery leaves a person waiting for mail that never arrives.
            "Email sign-in isn't available right now. Try again in a few minutes."
        EmailAuthOutcome.UNKNOWN_FAILURE ->
            "That didn't work. Try again."
    }

    /** Every sentence this object can produce — the surface a copy test judges. */
    fun allSentences(): List<String> =
        EmailAuthOutcome.entries.flatMap { outcome ->
            EmailAccountAction.entries.map { action -> message(outcome, action) }
        }
}

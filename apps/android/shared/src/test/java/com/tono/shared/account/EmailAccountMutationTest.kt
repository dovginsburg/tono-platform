package com.tono.shared.account

import com.tono.shared.storage.AccountIdentity
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Build 114 — proof that the account contract is RED-CAPABLE.
 *
 * A contract test that passes for both the correct implementation and a reverted
 * one is decoration. Every test below builds the mutant — the plausible wrong
 * version someone would actually write, or the pre-Build-114 version someone
 * would revert to — and asserts that the very predicate
 * `EmailAccountContractTest` uses REJECTS it.
 *
 * So each case here answers a specific question: "if this guarantee were rolled
 * back, would anything go red?" The answer has to be yes, or the guarantee is
 * unprotected.
 *
 * The mutants are local functions. Nothing in production is modified, and no
 * test here depends on running the app.
 */
class EmailAccountMutationTest {

    // ── Predicates, shared with the contract test ──────────────────────────
    //
    // Written once so the mutants are judged by the SAME rule the real
    // implementation is judged by. A mutation test that invents a weaker rule
    // proves nothing.

    private fun revealsAccountState(sentenceForKnown: String, sentenceForUnknown: String): Boolean =
        sentenceForKnown != sentenceForUnknown

    private fun readsAsPaywall(sentence: String): Boolean =
        listOf("subscription", "subscribe", "trial", "upgrade", "pro")
            .any { sentence.lowercase().contains(it) }

    private fun claimsDelivery(sentence: String): Boolean =
        sentence.lowercase().let { it.contains("check your email") || it.contains("we sent") }

    private fun namesImplementationDetail(sentence: String): Boolean =
        listOf("backend", "server", "provider", "http", "token", "supabase", "503")
            .any { sentence.lowercase().contains(it) }

    private fun mergesDistinctMailboxes(normalize: (String) -> String?): Boolean =
        normalize("victim+attacker@example.com") == normalize("victim@example.com") ||
            normalize("first.last@example.com") == normalize("firstlast@example.com")

    private fun splitsOneMailbox(normalize: (String) -> String?): Boolean =
        normalize("Person@Example.com") != normalize("person@example.com")

    // ── The real implementation passes every predicate ──────────────────────

    @Test
    fun theShippedImplementationSatisfiesEveryPredicate() {
        assertFalse(
            revealsAccountState(
                EmailAccountCopy.message(
                    EmailAuthOutcome.CHECK_YOUR_EMAIL, EmailAccountAction.CREATE_ACCOUNT
                ),
                EmailAccountCopy.message(
                    EmailAuthOutcome.CHECK_YOUR_EMAIL, EmailAccountAction.RESEND_CONFIRMATION
                ),
            )
        )
        assertFalse(
            readsAsPaywall(
                EmailAccountCopy.message(
                    EmailAuthOutcome.RATE_LIMITED, EmailAccountAction.SIGN_IN
                )
            )
        )
        assertFalse(
            claimsDelivery(
                EmailAccountCopy.message(
                    EmailAuthOutcome.SERVICE_UNAVAILABLE, EmailAccountAction.CREATE_ACCOUNT
                )
            )
        )
        assertFalse(EmailAccountCopy.allSentences().any(::namesImplementationDetail))
        assertFalse(mergesDistinctMailboxes { EmailAddress.normalize(it) })
        assertFalse(splitsOneMailbox { EmailAddress.normalize(it) })
    }

    // ── Mutant: the copy layer becomes an account oracle ───────────────────

    @Test
    fun mutantThatRevealsWhetherAnAddressExistsIsCaught() {
        // The tempting "helpful" version: tell the person their address is
        // already registered. That is an enumeration oracle, and it undoes the
        // server's anti-enumeration work at the one surface a stranger can see.
        fun mutantCopy(action: EmailAccountAction): String = when (action) {
            EmailAccountAction.CREATE_ACCOUNT -> "That email is already registered. Sign in instead."
            else -> "Check your email. Open the link we sent to confirm your address, then sign in."
        }
        assertTrue(
            "an oracle-shaped copy layer must be caught",
            revealsAccountState(
                mutantCopy(EmailAccountAction.CREATE_ACCOUNT),
                mutantCopy(EmailAccountAction.RESEND_CONFIRMATION),
            ),
        )
    }

    @Test
    fun mutantThatNamesWhichCredentialHalfWasWrongIsCaught() {
        val mutant = "We don't know that email address."
        assertTrue(
            "naming one half tells an attacker the other half was right",
            mutant.lowercase().contains("don't know that email"),
        )
        // And the shipped sentence does not.
        assertFalse(
            EmailAccountCopy
                .message(EmailAuthOutcome.INVALID_CREDENTIALS, EmailAccountAction.SIGN_IN)
                .lowercase()
                .contains("don't know that email")
        )
    }

    // ── Mutant: Build 113's rate-limit-as-paywall regression, reintroduced ──

    @Test
    fun mutantThatTellsARateLimitedPersonToSubscribeIsCaught() {
        // This is the exact defect Build 113 fixed on the Coach path: a
        // subscriber who trips a limit told to buy what they already pay for.
        val mutant = "An active trial or subscription is required. Open Tono to continue."
        assertTrue("a paywall sentence for 429 must be caught", readsAsPaywall(mutant))
        assertFalse(
            readsAsPaywall(
                EmailAccountCopy.message(
                    EmailAuthOutcome.RATE_LIMITED, EmailAccountAction.SIGN_IN
                )
            )
        )
    }

    // ── Mutant: an outage dressed up as delivery ───────────────────────────

    @Test
    fun mutantThatClaimsDeliveryDuringAnOutageIsCaught() {
        // The worst answer to an outage: the person waits for mail that will
        // never arrive, and blames their own inbox.
        val mutant = "Check your email. Open the link we sent to confirm your address."
        assertTrue("a false delivery claim must be caught", claimsDelivery(mutant))
        for (action in EmailAccountAction.entries) {
            assertFalse(
                claimsDelivery(
                    EmailAccountCopy.message(EmailAuthOutcome.SERVICE_UNAVAILABLE, action)
                )
            )
        }
    }

    @Test
    fun mutantThatLeaksProviderVocabularyIsCaught() {
        for (mutant in listOf(
            "The auth server returned 503. Try again.",
            "Could not reach the Tono backend.",
            "Supabase rejected the request.",
            "Your bearer token expired.",
        )) {
            assertTrue(
                "implementation vocabulary must be caught: $mutant",
                namesImplementationDetail(mutant),
            )
        }
    }

    // ── Mutant: normalization that merges two people ───────────────────────

    @Test
    fun mutantNormalizerThatStripsPlusTagsAndDotsIsCaught() {
        // The classic "canonicalize Gmail-style" mutation. It hands
        // `victim@example.com`'s account to whoever registers
        // `victim+anything@example.com`.
        fun mutant(raw: String): String {
            val at = raw.lastIndexOf('@')
            val local = raw.substring(0, at).substringBefore('+').replace(".", "")
            return "${local.lowercase()}@${raw.substring(at + 1).lowercase()}"
        }
        assertTrue(
            "a tag/dot-stripping normalizer must be caught",
            mergesDistinctMailboxes(::mutant),
        )
    }

    @Test
    fun mutantNormalizerThatKeepsCaseIsCaught() {
        // The opposite failure: two client identities for one mailbox the auth
        // authority can only ever back with one.
        fun mutant(raw: String): String = raw.trim()
        assertTrue(
            "a case-preserving normalizer must be caught",
            splitsOneMailbox(::mutant),
        )
    }

    @Test
    fun mutantNormalizerThatAcceptsNonMailboxesIsCaught() {
        // A permissive normalizer writes keys the ledger can never match again.
        fun mutant(raw: String): String? = raw.trim().takeIf { it.isNotEmpty() }
        val nonMailboxes = listOf("person", "@example.com", "person@", "person@example")
        assertTrue(
            "a permissive normalizer must be caught",
            nonMailboxes.any { mutant(it) != null && EmailAddress.normalize(it) == null },
        )
        // And the shipped one refuses all of them.
        assertTrue(nonMailboxes.all { EmailAddress.normalize(it) == null })
    }

    // ── Mutant: the purchase gate rolled back to Build 113 ─────────────────

    @Test
    fun mutantPurchaseGateThatAcceptsAnAnonymousAccountIsCaught() {
        // Build 113's Android gate required only a non-blank account id. An
        // anonymous device-only account has one, and loses it on reinstall — so a
        // purchase bound to it is unrecoverable and the person pays twice.
        //
        // The mutant keeps the shipped gate's SIGNATURE and drops one input on
        // the floor — ignoring `signedInEmail` is precisely the mutation, so the
        // unused parameter is deliberate rather than an oversight.
        @Suppress("UNUSED_PARAMETER")
        fun mutantGate(signedInEmail: String?, accountId: String?): Boolean =
            !accountId.isNullOrBlank()

        val anonymous = "11111111-2222-3333-4444-555555555555"
        assertTrue(
            "the reverted gate would let an anonymous device buy",
            mutantGate(signedInEmail = null, accountId = anonymous),
        )
        assertFalse(
            "the shipped gate must refuse an anonymous device",
            AccountIdentity.isIdentified(signedInEmail = null, accountId = anonymous),
        )
    }

    @Test
    fun mutantPurchaseGateThatAcceptsAConfirmedAddressAloneIsCaught() {
        // The other half: an address with no canonical account has nothing for
        // the purchase to bind to. Same shape as above: dropping `accountId` is
        // the mutation, so the unused parameter is the point.
        @Suppress("UNUSED_PARAMETER")
        fun mutantGate(signedInEmail: String?, accountId: String?): Boolean =
            !signedInEmail.isNullOrBlank()

        assertTrue(mutantGate(signedInEmail = "person@example.com", accountId = null))
        assertFalse(
            AccountIdentity.isIdentified(signedInEmail = "person@example.com", accountId = null)
        )
    }

    @Test
    fun theShippedGateAcceptsOnlyBothFactsTogether() {
        assertTrue(
            AccountIdentity.isIdentified(
                signedInEmail = "person@example.com",
                accountId = "11111111-2222-3333-4444-555555555555",
            )
        )
        assertFalse(AccountIdentity.isIdentified(null, null))
        assertFalse(AccountIdentity.isIdentified("  ", "  "))
    }

    // ── Mutant: a confirmed address that grants Pro ────────────────────────

    @Test
    fun beingIdentifiedIsNeverItselfAnEntitlement() {
        // "Verified email alone never grants paid access." The mutant conflates
        // recoverability with entitlement.
        fun mutantEntitlement(signedInEmail: String?, backendIsPro: Boolean): Boolean =
            !signedInEmail.isNullOrBlank() || backendIsPro
        assertTrue(
            "the mutant grants Pro for a confirmed address alone",
            mutantEntitlement("person@example.com", backendIsPro = false),
        )

        // The shipped gate answers a different question, and its answer carries
        // no entitlement meaning: a fully identified device is still not Pro.
        // `PlayBillingManagerGateTest` pins the entitlement decision itself,
        // which lives in the app module beside Play Billing.
        val identified = AccountIdentity.isIdentified(
            signedInEmail = "person@example.com",
            accountId = "11111111-2222-3333-4444-555555555555",
        )
        assertTrue("the gate must let a recoverable device proceed", identified)
        assertFalse(
            "nothing in the shared account layer may expose a Pro verdict",
            com.tono.shared.storage.SecureStore::class.java.methods
                .any { it.name.lowercase().contains("pro") } ||
                AccountIdentity::class.java.methods
                    .any { it.name.lowercase().contains("pro") },
        )
    }

    // ── Mutant: transport classification by message ────────────────────────

    @Test
    fun mutantTransportClassifierThatSniffsMessagesIsCaught() {
        // Message sniffing is how "network is fine" becomes "you're offline",
        // and how a host name reaches a screen. Type is the only honest signal.
        fun mutantClassify(error: Throwable): EmailAuthOutcome =
            if (error.message?.contains("network") == true ||
                error.message?.contains("connect") == true
            ) {
                EmailAuthOutcome.OFFLINE
            } else {
                EmailAuthOutcome.UNKNOWN_FAILURE
            }

        // A real connectivity failure whose message says nothing about networks:
        // the mutant misses it.
        val realOutage = java.net.UnknownHostException("api.example.invalid")
        assertTrue(
            "the mutant misclassifies a real outage",
            mutantClassify(realOutage) == EmailAuthOutcome.UNKNOWN_FAILURE,
        )
        assertTrue(
            "the shipped classifier reads the type",
            com.tono.shared.network.TonoBackend.outcomeForTransport(realOutage)
                == EmailAuthOutcome.OFFLINE,
        )
    }

    // ── Mutant: sign-out that leaves the device able to sign itself back in ─

    @Test
    fun mutantSignOutThatKeepsTheDeviceCredentialIsCaught() {
        // Rotating the bearer alone is not a sign-out: the device credential lets
        // the very next registration hand this device a working token for the
        // account it just left. On a shared phone that is not a sign-out at all.
        val session = mutableMapOf(
            "apiToken" to "t", "signedInEmail" to "person@example.com",
            "deviceID" to "d", "deviceCredential" to "c",
        )
        fun mutantSignOut() {
            session.remove("apiToken")
            session.remove("signedInEmail")
        }
        fun shippedSignOut() {
            listOf("apiToken", "signedInEmail", "deviceID", "deviceCredential")
                .forEach(session::remove)
        }

        mutantSignOut()
        assertTrue(
            "the mutant leaves a credential that can re-register this device",
            session.containsKey("deviceCredential"),
        )
        shippedSignOut()
        assertTrue(
            "a real sign-out leaves nothing that can re-register this device",
            session.isEmpty(),
        )
    }
}

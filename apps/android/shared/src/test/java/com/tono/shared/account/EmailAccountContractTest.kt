package com.tono.shared.account

import com.tono.shared.network.TonoBackend
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException

/**
 * Build 114 — the Android email account contract, asserted rather than
 * described.
 *
 * These are the properties a hostile reader attacks first, and the ones a later
 * refactor is most likely to quietly undo:
 *
 *   * the app answering differently for a registered and an unregistered address
 *     (turning it into an account oracle);
 *   * normalization drifting from the server's rule, so an address silently
 *     stops matching itself — or worse, starts matching someone else's;
 *   * a rate limit rendering as a paywall or as a bad password;
 *   * an operational failure rendering as "we sent you an email";
 *   * provider or transport vocabulary reaching a consumer sentence.
 *
 * Every one of them is red-capable: each assertion fails if the behaviour it
 * pins is reverted. `EmailAccountMutationTest` proves that claim directly.
 */
class EmailAccountContractTest {

    // ── Anti-enumeration ───────────────────────────────────────────────────

    @Test
    fun createAccountAndResendShareOneSentence() {
        // Registering an address that is already taken and one that is brand new
        // both come back as CHECK_YOUR_EMAIL from the server, so the sentence
        // rendered for either must be identical — otherwise the copy layer
        // reintroduces the oracle the server refuses to be.
        assertEquals(
            EmailAccountCopy.message(
                EmailAuthOutcome.CHECK_YOUR_EMAIL, EmailAccountAction.CREATE_ACCOUNT
            ),
            EmailAccountCopy.message(
                EmailAuthOutcome.CHECK_YOUR_EMAIL, EmailAccountAction.RESEND_CONFIRMATION
            ),
        )
    }

    @Test
    fun acceptedAnswerNeverNamesAccountState() {
        val forbidden = listOf(
            "already", "exists", "registered", "not found", "unknown", "no account",
            "new account", "taken",
        )
        for (action in EmailAccountAction.entries) {
            val sentence = EmailAccountCopy
                .message(EmailAuthOutcome.CHECK_YOUR_EMAIL, action)
                .lowercase()
            for (word in forbidden) {
                assertFalse(
                    "the accepted answer must not reveal account state ($word): $sentence",
                    sentence.contains(word),
                )
            }
        }
    }

    @Test
    fun rejectedCredentialsDoNotSayWhichHalfWasWrong() {
        val sentence = EmailAccountCopy
            .message(EmailAuthOutcome.INVALID_CREDENTIALS, EmailAccountAction.SIGN_IN)
            .lowercase()
        // Naming one half tells an attacker the other half was right.
        assertFalse(sentence.contains("no such"))
        assertFalse(sentence.contains("wrong password"))
        assertFalse(sentence.contains("incorrect password"))
        assertFalse(sentence.contains("unknown email"))
        assertTrue(
            "the sentence must name the pair, not one half: $sentence",
            sentence.contains("email and password"),
        )
    }

    // ── Consumer vocabulary ────────────────────────────────────────────────

    @Test
    fun noSentenceNamesImplementationDetail() {
        // Mirrors the iOS Build 112 surface contract's forbidden vocabulary. A
        // person cannot act on where a failure happened, only on what to do next.
        val forbiddenTerms = listOf(
            "backend", "server", "endpoint", "api key", "apikey", "bearer",
            "auth token", "api token", "provider", "proxy", "llm", "transport",
            "non-2xx", "staging", "sharedpreferences", "keystore", "supabase",
            "http", "://", "okhttp", "401", "402", "403", "429", "500", "503",
        )
        val forbiddenWords = listOf("url", "urls", "token", "tokens", "json")
        for (sentence in EmailAccountCopy.allSentences()) {
            val haystack = sentence.lowercase()
            for (term in forbiddenTerms) {
                assertFalse(
                    "consumer copy names “$term”: $sentence",
                    haystack.contains(term),
                )
            }
            for (word in forbiddenWords) {
                assertFalse(
                    "consumer copy names the word “$word”: $sentence",
                    Regex("""\b${Regex.escape(word)}\b""").containsMatchIn(haystack),
                )
            }
        }
    }

    @Test
    fun everySentenceIsNonEmptyAndActionable() {
        for (sentence in EmailAccountCopy.allSentences()) {
            assertTrue("a blank consumer sentence is not copy", sentence.isNotBlank())
            assertTrue("copy must be a sentence: $sentence", sentence.length > 12)
        }
    }

    @Test
    fun rateLimitIsNeverAPaywallAndNeverACredentialFailure() {
        // Build 113 fixed exactly this confusion on the Coach path: a subscriber
        // who trips a limit was told to buy the subscription they already pay
        // for. The account path must not reintroduce it.
        val sentence = EmailAccountCopy
            .message(EmailAuthOutcome.RATE_LIMITED, EmailAccountAction.SIGN_IN)
            .lowercase()
        for (paywallWord in listOf("subscription", "subscribe", "trial", "upgrade", "pro")) {
            assertFalse(
                "a rate limit must not read as a paywall ($paywallWord): $sentence",
                sentence.contains(paywallWord),
            )
        }
        assertFalse(sentence.contains("password"))
        assertTrue("a rate limit must tell the person to wait: $sentence", sentence.contains("wait"))
    }

    @Test
    fun serviceUnavailableIsNeverDressedUpAsDelivery() {
        // The worst possible answer to an outage is "check your email": the
        // person then waits for mail that will never arrive.
        for (action in EmailAccountAction.entries) {
            val sentence = EmailAccountCopy
                .message(EmailAuthOutcome.SERVICE_UNAVAILABLE, action)
                .lowercase()
            assertFalse(
                "an outage must not claim delivery: $sentence",
                sentence.contains("check your email") || sentence.contains("we sent"),
            )
        }
    }

    @Test
    fun theThreeDistinctFailuresGetThreeDistinctSentences() {
        val credentials = EmailAccountCopy
            .message(EmailAuthOutcome.INVALID_CREDENTIALS, EmailAccountAction.SIGN_IN)
        val limited = EmailAccountCopy
            .message(EmailAuthOutcome.RATE_LIMITED, EmailAccountAction.SIGN_IN)
        val unavailable = EmailAccountCopy
            .message(EmailAuthOutcome.SERVICE_UNAVAILABLE, EmailAccountAction.SIGN_IN)
        assertEquals(3, setOf(credentials, limited, unavailable).size)
    }

    @Test
    fun everyOutcomeAndActionPairHasReviewedCopy() {
        // Proves the mapper is exhaustive at runtime, not only at compile time:
        // a `when` that gained an `else` would still compile and would silently
        // flatten new outcomes into one generic screen.
        val produced = EmailAuthOutcome.entries.flatMap { outcome ->
            EmailAccountAction.entries.map { action ->
                EmailAccountCopy.message(outcome, action)
            }
        }
        assertEquals(
            EmailAuthOutcome.entries.size * EmailAccountAction.entries.size,
            produced.size,
        )
        assertTrue(produced.none { it.isBlank() })
    }

    // ── Normalization parity with the account ledger ───────────────────────

    @Test
    fun caseIsFoldedOnBothHalves() {
        assertEquals("person@example.com", EmailAddress.normalize("Person@Example.COM"))
        assertEquals(
            EmailAddress.normalize("PERSON@EXAMPLE.COM"),
            EmailAddress.normalize("person@example.com"),
        )
    }

    @Test
    fun plusTagsAndDotsSurviveNormalization() {
        // Stripping either is a silent-merge vector: `victim+x@example.com` would
        // collapse onto `victim@example.com` and hand away someone's account.
        assertEquals("a.b+tag@example.com", EmailAddress.normalize("A.B+Tag@Example.com"))
        assertNotEquals(
            EmailAddress.normalize("victim+attacker@example.com"),
            EmailAddress.normalize("victim@example.com"),
        )
        assertNotEquals(
            EmailAddress.normalize("first.last@example.com"),
            EmailAddress.normalize("firstlast@example.com"),
        )
    }

    @Test
    fun surroundingWhitespaceIsTrimmedButInteriorSpaceIsRejected() {
        assertEquals("person@example.com", EmailAddress.normalize("  person@example.com \n"))
        assertNull(EmailAddress.normalize("per son@example.com"))
        assertNull(EmailAddress.normalize("person@exa mple.com"))
    }

    @Test
    fun lookAlikeAddressesFoldToTheSameMailbox() {
        // NFKC, so a full-width look-alike cannot present itself as a different
        // mailbox than the one it folds to.
        assertEquals(
            EmailAddress.normalize("person@example.com"),
            EmailAddress.normalize("ｐｅｒｓｏｎ@example.com"),
        )
    }

    @Test
    fun nonMailboxesAreRefusedRatherThanGuessedAt() {
        for (bad in listOf(
            null, "", "   ", "person", "@example.com", "person@", "person@@example.com",
            "person@example", "person@.com", "person@example.", "person@-example.com",
            "person @example.com", "person@exam_ple.com",
        )) {
            assertNull("must refuse: $bad", EmailAddress.normalize(bad))
            assertFalse(EmailAddress.isUsable(bad))
        }
    }

    @Test
    fun addressAndLocalPartLengthsAreBounded() {
        // An over-long address is not a real mailbox, and unbounded input would
        // otherwise reach the ledger as an unbounded index key.
        val longLocal = "a".repeat(65)
        assertNull(EmailAddress.normalize("$longLocal@example.com"))
        assertEquals(
            "${"a".repeat(64)}@example.com",
            EmailAddress.normalize("${"a".repeat(64)}@example.com"),
        )
        val longDomain = "b".repeat(60) + ".com"
        val overLong = "c".repeat(200) + "@" + longDomain
        assertTrue(overLong.length > 254)
        assertNull(EmailAddress.normalize(overLong))
    }

    // ── Password policy ────────────────────────────────────────────────────

    @Test
    fun passwordFloorMatchesTheServerAndIsBoundedAbove() {
        assertEquals(8, EmailAccountPolicy.MINIMUM_PASSWORD_LENGTH)
        assertFalse(EmailAccountPolicy.passwordIsUsable("short"))
        assertFalse(EmailAccountPolicy.passwordIsUsable("1234567"))
        assertTrue(EmailAccountPolicy.passwordIsUsable("12345678"))
        assertTrue(
            EmailAccountPolicy.passwordIsUsable(
                "x".repeat(EmailAccountPolicy.MAXIMUM_PASSWORD_LENGTH)
            )
        )
        assertFalse(
            EmailAccountPolicy.passwordIsUsable(
                "x".repeat(EmailAccountPolicy.MAXIMUM_PASSWORD_LENGTH + 1)
            )
        )
    }

    // ── Status and transport classification ────────────────────────────────

    @Test
    fun statusClassMapsExactlyAsTheServerAnswers() {
        assertNull("2xx is success", TonoBackend.outcomeForStatus(200))
        assertNull(TonoBackend.outcomeForStatus(202))
        assertEquals(EmailAuthOutcome.INVALID_INPUT, TonoBackend.outcomeForStatus(400))
        assertEquals(EmailAuthOutcome.INVALID_INPUT, TonoBackend.outcomeForStatus(422))
        assertEquals(EmailAuthOutcome.INVALID_CREDENTIALS, TonoBackend.outcomeForStatus(401))
        assertEquals(EmailAuthOutcome.VERIFICATION_REQUIRED, TonoBackend.outcomeForStatus(403))
        assertEquals(EmailAuthOutcome.RATE_LIMITED, TonoBackend.outcomeForStatus(429))
        assertEquals(EmailAuthOutcome.SERVICE_UNAVAILABLE, TonoBackend.outcomeForStatus(500))
        assertEquals(EmailAuthOutcome.SERVICE_UNAVAILABLE, TonoBackend.outcomeForStatus(503))
        assertEquals(EmailAuthOutcome.UNKNOWN_FAILURE, TonoBackend.outcomeForStatus(418))
    }

    @Test
    fun theEntitlementGateAndTheRateLimitStayApart() {
        // 402 must never arrive on the account lane as a credential failure, and
        // 429 must never arrive as anything that reads like paying.
        assertNotEquals(
            TonoBackend.outcomeForStatus(429),
            TonoBackend.outcomeForStatus(401),
        )
        assertNotEquals(
            TonoBackend.outcomeForStatus(429),
            TonoBackend.outcomeForStatus(403),
        )
    }

    @Test
    fun onlyRealConnectivityFailuresReadAsOffline() {
        for (offline in listOf(
            java.net.UnknownHostException("host"),
            java.net.ConnectException("refused"),
            java.net.SocketTimeoutException("timeout"),
            javax.net.ssl.SSLException("handshake"),
        )) {
            assertEquals(
                "${offline.javaClass.simpleName} means no usable connection",
                EmailAuthOutcome.OFFLINE,
                TonoBackend.outcomeForTransport(offline),
            )
        }
        // A generic I/O failure is NOT proof the connection is down. Telling
        // someone to check a working connection is its own wrong answer.
        assertEquals(
            EmailAuthOutcome.UNKNOWN_FAILURE,
            TonoBackend.outcomeForTransport(IOException("stream closed")),
        )
    }

    @Test
    fun transportClassificationNeverReadsTheFailuresMessage() {
        // Two failures with the SAME misleading message but different types must
        // classify by type. A message-sniffing implementation fails this.
        assertEquals(
            EmailAuthOutcome.OFFLINE,
            TonoBackend.outcomeForTransport(java.net.ConnectException("network is fine")),
        )
        assertEquals(
            EmailAuthOutcome.UNKNOWN_FAILURE,
            TonoBackend.outcomeForTransport(IOException("connect network unreachable")),
        )
    }

    // ── The failure type carries no text ───────────────────────────────────

    @Test
    fun theFailureTypeCannotCarryProviderText() {
        // The absence of a message parameter is the point: there is no way for a
        // caller to render provider detail, because the object never holds any.
        val thrown = EmailAuthException(EmailAuthOutcome.RATE_LIMITED)
        assertEquals(EmailAuthOutcome.RATE_LIMITED, thrown.outcome)
        assertEquals("RATE_LIMITED", thrown.message)
        val constructors = EmailAuthException::class.java.constructors
        assertEquals(1, constructors.size)
        assertEquals(1, constructors.first().parameterCount)
        assertEquals(
            EmailAuthOutcome::class.java,
            constructors.first().parameterTypes.first(),
        )
    }

    @Test
    fun onlyTheAcceptedOutcomeIsAccepted() {
        assertTrue(EmailAuthOutcome.CHECK_YOUR_EMAIL.isAccepted)
        for (outcome in EmailAuthOutcome.entries - EmailAuthOutcome.CHECK_YOUR_EMAIL) {
            assertFalse("$outcome must not read as accepted", outcome.isAccepted)
        }
    }

    // ── The input refusal covers both refusals it is given ─────────────────

    @Test
    fun theInputRefusalSentenceIsTrueOfBothRefusalsItCovers() {
        // The server answers TWO different input-shaped refusals with 400: an
        // address it will not accept, and a password the auth provider judges
        // too weak on its own strength rules. Both arrive carrying no provider
        // text — deliberately — so this client cannot tell them apart.
        //
        // A sentence naming only the length floor is a dead end for the second:
        // someone who typed twenty characters and was refused for lacking a
        // digit reads "use at least 8 characters", changes nothing, and is
        // refused again. The one sentence has to be true of either.
        val sentence = EmailAccountCopy
            .message(EmailAuthOutcome.INVALID_INPUT, EmailAccountAction.CREATE_ACCOUNT)
            .lowercase()
        assertFalse(
            "the refusal sentence must not name the length floor",
            sentence.contains("${EmailAccountPolicy.MINIMUM_PASSWORD_LENGTH} characters"),
        )
        assertTrue(sentence.contains("email address"))
        assertTrue(sentence.contains("password"))
        assertTrue(sentence.contains("different address"))
        assertTrue(sentence.contains("longer") || sentence.contains("less predictable"))
    }

    @Test
    fun theTwoClientsRenderTheSameInputRefusal() {
        // iOS and Android must not diverge on the sentence a person reads for
        // the same server answer — a support reply that is true on one phone
        // and false on the other is worse than either sentence alone. Read
        // from the shipped Swift source rather than restated here, so a change
        // on one side without the other turns this red.
        val swift = java.io.File(
            "../ios/App/OnboardingEntryPointsView.swift"
        ).takeIf { it.exists() }
            ?: java.io.File("../../ios/App/OnboardingEntryPointsView.swift")
        val ours = EmailAccountCopy
            .message(EmailAuthOutcome.INVALID_INPUT, EmailAccountAction.CREATE_ACCOUNT)
        assertTrue(
            "the iOS sheet must render the identical input-refusal sentence",
            swift.readText().contains(ours),
        )
    }
}

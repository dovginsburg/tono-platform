package com.tono.shared.intelligence

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class OnDeviceRewriteGuardTest {

    @Test fun emptyOrBlankResultIsNoValidRewrite() {
        listOf(null, "", "   ", "\n\t").forEach {
            val outcome = OnDeviceRewriteGuard.resolve(it, "hello there")
            assertTrue(outcome is OnDeviceRewriteOutcome.Failure)
            assertEquals(
                GeminiRewriteUnavailableReason.NO_VALID_REWRITE,
                (outcome as OnDeviceRewriteOutcome.Failure).reason,
            )
        }
    }

    @Test fun caseAndPunctuationOnlyChangesAreNoOps() {
        val source = "Can you send that over?"
        listOf(
            "can you send that over",
            "CAN YOU SEND THAT OVER?!",
            "  can you, send that over?  ",
        ).forEach {
            val outcome = OnDeviceRewriteGuard.resolve(it, source)
            assertTrue("'$it' should be a no-op", outcome is OnDeviceRewriteOutcome.Failure)
        }
    }

    @Test fun aGenuinelyDifferentRewriteSucceeds() {
        val outcome = OnDeviceRewriteGuard.resolve(
            "Mind firing that over when you get a sec? 😄",
            "Can you send that over?",
        )
        assertTrue(outcome is OnDeviceRewriteOutcome.Success)
        assertEquals("Mind firing that over when you get a sec? 😄",
            (outcome as OnDeviceRewriteOutcome.Success).text)
    }

    @Test fun successTextIsTrimmed() {
        val outcome = OnDeviceRewriteGuard.resolve("  Fresh wording here  ", "Old wording")
        assertEquals("Fresh wording here", (outcome as OnDeviceRewriteOutcome.Success).text)
    }

    @Test fun normalizerMatchesTheCrossPlatformRule() {
        assertEquals("hello world", OnDeviceRewriteGuard.normalizedForNoOp("  Hello,   World!! "))
        assertEquals("", OnDeviceRewriteGuard.normalizedForNoOp("  ??!! "))
    }
}

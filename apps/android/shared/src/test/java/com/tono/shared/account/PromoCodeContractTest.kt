package com.tono.shared.account

import com.tono.shared.network.TonoBackend
import kotlinx.coroutines.runBlocking
import okhttp3.Request
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PromoCodeContractTest {

    @Test
    fun normalizationTrimsAndUppercasesWithoutChangingInteriorCharacters() {
        assertEquals("SAVE-TEST_42", PromoCode.normalize(" \n save-test_42 \t"))
        assertEquals("", PromoCode.normalize("   "))
    }

    @Test
    fun emptyAndLoadingStatesCannotSubmit() {
        assertFalse(PromoCodeUiState(input = "  ").canApply)
        val loading = PromoCodeUiState(input = "sample-code").applying()
        assertEquals("SAMPLE-CODE", loading.input)
        assertTrue(loading.isApplying)
        assertFalse(loading.canApply)
    }

    @Test
    fun successClearsInputAndUsesBoundedCopy() {
        val success = PromoCodeUiState(input = "sample-code").applying().succeeded()
        assertEquals("", success.input)
        assertFalse(success.isApplying)
        assertEquals(CouponRedemptionCopy.SUCCESS, success.notice)
    }

    @Test
    fun rejectedExpiredAndUsedCodesHaveReviewedDistinctCopy() {
        val rejected = PromoCodeUiState().failed(CouponRedemptionOutcome.REJECTED)
        val expired = PromoCodeUiState().failed(CouponRedemptionOutcome.EXPIRED)
        val used = PromoCodeUiState().failed(CouponRedemptionOutcome.ALREADY_USED)
        assertEquals(3, setOf(rejected.notice, expired.notice, used.notice).size)
        assertTrue(listOf(rejected, expired, used).all { !it.isApplying })
    }

    @Test
    fun consumerCopyNeverNamesBackendInternals() {
        val forbidden = listOf(
            "backend", "server", "endpoint", "bearer", "token", "json",
            "http", "401", "403", "409", "410", "422", "500",
        )
        CouponRedemptionCopy.allSentences().forEach { sentence ->
            forbidden.forEach { term ->
                assertFalse("$sentence contains $term", sentence.lowercase().contains(term))
            }
        }
    }

    @Test
    fun requestIsAuthorizedJsonPostThenEntitlementRefreshIsCached() = runBlocking {
        val requests = mutableListOf<Request>()
        val responses = ArrayDeque(
            listOf(
                """{"coupon_pro_expires_at":"2099-01-02T03:04:05Z","message":"accepted"}""",
                """{"device_id":"device-test","account_id":"account-test","plan":"pro","is_pro":true,"used_today":0,"daily_limit":5}""",
            )
        )
        var cachedPro: Boolean? = null

        val result = TonoBackend.redeemCouponAuthorized(
            code = "SAMPLE-CODE",
            bearerToken = "test-bearer",
            serverBaseUrl = "https://example.invalid",
            cacheAccount = { cachedPro = it.isPro },
            requestExecutor = {
                requests += it
                responses.removeFirst()
            },
        )

        val redeem = requests[0]
        assertEquals("POST", redeem.method)
        assertEquals("/v1/coupon/redeem", redeem.url.encodedPath)
        assertEquals("application/json", redeem.header("Content-Type"))
        assertEquals("Bearer test-bearer", redeem.header("Authorization"))
        assertEquals("""{"code":"SAMPLE-CODE"}""", redeem.body!!.let {
            okio.Buffer().also(it::writeTo).readUtf8()
        })

        val refresh = requests[1]
        assertEquals("GET", refresh.method)
        assertEquals("/v1/me", refresh.url.encodedPath)
        assertEquals("Bearer test-bearer", refresh.header("Authorization"))
        assertEquals("2099-01-02T03:04:05Z", result.couponProExpiresAt)
        assertEquals("accepted", result.message)
        assertEquals(true, cachedPro)
    }

    @Test
    fun rejectedExpiredAndUsedStatusesAreClassifiedWithoutReadingBodies() {
        val cases = listOf(
            400 to CouponRedemptionOutcome.REJECTED,
            410 to CouponRedemptionOutcome.EXPIRED,
            409 to CouponRedemptionOutcome.ALREADY_USED,
        )
        cases.forEach { (status, expected) ->
            assertEquals(expected, TonoBackend.couponOutcomeForStatus(status))
        }
    }
}

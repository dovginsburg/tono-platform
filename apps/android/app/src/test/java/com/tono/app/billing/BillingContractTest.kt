package com.tono.app.billing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BillingContractTest {
    @Test
    fun productIds_matchCanonicalTonoSubscriptions() {
        assertEquals("com.tonoit.pro.monthly", BillingProducts.MONTHLY)
        assertEquals("com.tonoit.pro.yearly", BillingProducts.YEARLY)
        assertEquals(setOf(BillingProducts.MONTHLY, BillingProducts.YEARLY), BillingProducts.all)
    }

    @Test
    fun providerOwnershipId_matchesBackendDigestContract() {
        assertEquals(
            "873a6971b5a69ec99f5bca7c9329fbf68b047fef4e6b5daca2b660d817769e49",
            BillingOwnership.obfuscatedAccountId("00000000-0000-0000-0000-000000000001"),
        )
    }

    @Test
    fun trialOffer_requiresARealSevenDayZeroPricePhase() {
        assertTrue(TrialOfferContract.isRealSevenDayTrial(0L, "P7D"))
        assertTrue(TrialOfferContract.isRealSevenDayTrial(0L, "P1W"))
        assertFalse(TrialOfferContract.isRealSevenDayTrial(1L, "P7D"))
        assertFalse(TrialOfferContract.isRealSevenDayTrial(0L, "P14D"))
    }

    @Test
    fun entitlement_neverUnlocksFromAnUnverifiedPlayPurchase() {
        assertFalse(EntitlementDecision.isPro(hasActivePlayPurchase = true, backendIsPro = false))
    }

    @Test
    fun entitlement_unlocksOnlyAfterBackendVerification() {
        assertTrue(EntitlementDecision.isPro(hasActivePlayPurchase = true, backendIsPro = true))
    }

    @Test
    fun entitlementRemainsAvailableForCrossPlatformBackendSubscription() {
        assertTrue(EntitlementDecision.isPro(hasActivePlayPurchase = false, backendIsPro = true))
    }
}

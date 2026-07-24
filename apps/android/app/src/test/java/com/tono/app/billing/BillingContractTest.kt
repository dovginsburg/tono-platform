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
        assertEquals("pro-monthly", BillingProducts.MONTHLY_BASE_PLAN)
        assertEquals("pro-yearly", BillingProducts.YEARLY_BASE_PLAN)
        assertEquals("trial-14-days", BillingProducts.TRIAL_OFFER)
        assertEquals(setOf(BillingProducts.MONTHLY, BillingProducts.YEARLY), BillingProducts.all)
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

    @Test
    fun canonicalProductsRemainValidPlaySubscriptionIdentifiers() {
        BillingProducts.all.forEach { productId ->
            assertTrue(productId.startsWith("com.tonoit.pro."))
            assertFalse(productId.contains("base-plan"))
        }
    }
}

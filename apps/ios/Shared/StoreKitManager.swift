// StoreKitManager.swift
// StoreKit 2 purchase manager for Tono Pro.
//
// Product IDs must match exactly what you register in App Store Connect.
// CURRENT CODE values (used at runtime by ProductID enum below):
//   com.tonoit.pro.monthly  — auto-renewing subscription
//   com.tonoit.pro.yearly   — auto-renewing subscription
// App/Tono.storekit and the ProductID enum use the same `com.tonoit.pro.*`
// identifiers. Product IDs in App Store Connect are immutable once created;
// verify what's registered in ASC before changing either source.
//
// To test in the Simulator: File → New → StoreKit Configuration File in
// Xcode, add both product IDs, then select it under
// Product → Scheme → Edit Scheme → Run → StoreKit Configuration.

import StoreKit
import Foundation

@MainActor
public final class StoreKitManager: ObservableObject {
    public static let shared = StoreKitManager()

    public enum ProductID {
        public static let monthly = "com.tonoit.pro.monthly"
        public static let yearly  = "com.tonoit.pro.yearly"
        public static var all: [String] { [monthly, yearly] }
    }

    @Published public var products:     [Product] = []
    @Published public private(set) var isPro: Bool = false
    @Published public var isLoading:    Bool      = false
    @Published public var purchaseError: String?
    /// True when the user is in an active introductory free trial period
    /// (Apple's "real" 14-day trial configured in App Store Connect).
    @Published public private(set) var isInFreeTrial: Bool = false
    @Published public private(set) var eligibleFreeTrialProductIDs: Set<String> = []

    /// build 122: fail-closed Apple purchase capability resolved from the live
    /// backend readiness contract (`apple_configured` via `/health`). Defaults to
    /// `.unknown` so nothing can initiate a charge before a probe confirms
    /// `.ready`. Build 121 was quarantined because the app could reach
    /// `product.purchase(...)` while the live backend reported
    /// `apple_configured: false`; this is the state the initiation gate reads.
    @Published public private(set) var applePurchaseCapability: ApplePurchaseCapability = .unknown

    private var updatesTask: Task<Void, Never>?

    /// Seam for deterministic tests. Production resolves the live `/health`
    /// contract; a test injects a fixed verdict for the false / unavailable /
    /// malformed / verified-true states with no network and no secrets.
    public var applePurchaseCapabilityProvider: () async -> ApplePurchaseCapability = {
        await TonoBackend.shared.fetchApplePurchaseCapability()
    }

    private init() {}

    // MARK: - Account identity (build 101)

    /// True when this device has a verified email identity AND a server-issued
    /// canonical accountID. Anonymous devices (device-only registration with no
    /// email sign-in) have an accountID but no signedInEmail; their UUID is not
    /// recoverable after a reinstall, so binding a purchase to it risks silent
    /// entitlement loss. Purchase initiation is blocked until the user signs in.
    public var isIdentifiedAccount: Bool {
        guard let accountID = SharedKeychain.get(KeychainKeys.accountID),
              !accountID.isEmpty else { return false }
        if SharedKeychain.get(KeychainKeys.hasRecoveryIdentity) == "true" {
            return true
        }

        // Upgrade migration: before hasRecoveryIdentity existed, signedInEmail
        // was written only after the backend confirmed email_verified. Preserve
        // that verified state for existing installs, then persist the new flag.
        guard let legacyVerifiedEmail = SharedKeychain.get(KeychainKeys.signedInEmail),
              !legacyVerifiedEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        SharedKeychain.set("true", forKey: KeychainKeys.hasRecoveryIdentity)
        return true
    }

    /// Resets all in-memory entitlement state to anonymous/non-Pro.
    /// Called after successful account deletion so extensions and the entitlement
    /// gate see the cleared state without waiting for a restart.
    public func resetToAnonymous() {
        isPro = false
        isInFreeTrial = false
        purchaseError = nil
        eligibleFreeTrialProductIDs = []
        TonePreferences.recordEntitlement(.notEntitled, isPro: false)
    }

    public var statusLabel: String {
        if isInFreeTrial { return "Pro trial" }
        return isPro ? "Pro" : "Subscription required"
    }

    // Call once from the app entry point.
    public func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { await listenForTransactionUpdates() }
        Task { await loadProductsAndEntitlements() }
    }

    // MARK: - Purchase-capability gate (build 122)

    /// Passively resolves the live Apple purchase capability and publishes it to
    /// `applePurchaseCapability`, WITHOUT setting `purchaseError`. The paywall
    /// calls this on appear so it can disable the buy button before any tap.
    public func refreshApplePurchaseCapability() async {
        applePurchaseCapability = await applePurchaseCapabilityProvider()
    }

    /// The fail-closed initiation gate. Resolves the live capability, publishes
    /// it, and — on any non-`.ready` verdict — sets `purchaseError` with honest,
    /// action-appropriate copy and returns the verdict so the caller aborts
    /// BEFORE `product.purchase(...)`. This is the single authority that stops a
    /// charge when the backend cannot honor it; the UI disable is only
    /// defense-in-depth. A later `/v1/me` reconciliation cannot undo a charge,
    /// so it is deliberately NOT relied on here.
    @discardableResult
    public func preflightApplePurchaseCapability() async -> ApplePurchaseCapability {
        let verdict = await applePurchaseCapabilityProvider()
        applePurchaseCapability = verdict
        switch verdict {
        case .ready:
            break
        case .notConfigured, .malformed:
            purchaseError = ConsumerErrorCopy.message(
                for: StoreError.appleNotConfigured, action: .purchase
            )
        case .unavailable, .unknown:
            purchaseError = ConsumerErrorCopy.message(
                for: StoreError.purchaseCapabilityUnavailable, action: .purchase
            )
        }
        return verdict
    }

    // MARK: - Public API

    public func purchase(_ product: Product) async {
        // build 101: an anonymous (device-only) account cannot safely bind a
        // purchase token because the UUID is lost on reinstall. The caller
        // (PaywallView) must gate the buy tap on isIdentifiedAccount and route
        // to sign-in first; this guard is a belt-and-suspenders fail-loud check.
        guard isIdentifiedAccount else {
            purchaseError = ConsumerErrorCopy.message(
                for: StoreError.needsIdentifiedAccount, action: .purchase
            )
            return
        }
        // build 122: fail-closed purchase-INITIATION gate. Build 121 was
        // quarantined because the app could reach `product.purchase(...)` while
        // the LIVE backend reported `apple_configured: false` — Apple took the
        // money and the backend could not honor it. Capability is confirmed at
        // initiation: the charge never starts unless the readiness contract is a
        // well-formed, explicit `true`. Every other verdict (false / unreachable
        // / malformed / not-yet-known) refuses here, with no charge. Post-payment
        // entitlement reconciliation cannot refund a charge and is not a
        // substitute for this guard.
        guard await preflightApplePurchaseCapability().allowsPurchaseInitiation else {
            return  // purchaseError set by the preflight; no charge initiated.
        }
        isLoading = true
        purchaseError = nil
        do {
            _ = try await TonoBackend.shared.registerIfNeeded(
                platform: "ios",
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
            )
            let ownershipOption = Product.PurchaseOption.appAccountToken(
                try purchaseAccountToken()
            )
            let result = try await product.purchase(options: [ownershipOption])
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                let me = try await TonoBackend.shared.syncAppStoreSubscription(
                    signedTransactionInfo: verification.jwsRepresentation
                )
                applyBackendState(
                    me,
                    inTrial: transaction.offer?.paymentMode == .freeTrial
                )
                await transaction.finish()
            case .userCancelled:
                purchaseError = "Purchase canceled."
            case .pending:
                purchaseError = "Purchase is pending approval."
            @unknown default:
                purchaseError = "Purchase did not complete. Please try again."
            }
        } catch {
            // Build 112: a purchase failure carried the transport's own text
            // straight onto the paywall. The user gets the action instead.
            purchaseError = ConsumerErrorCopy.message(for: error, action: .purchase)
        }
        isLoading = false
    }

    public func restorePurchases() async {
        isLoading = true
        purchaseError = nil
        do {
            try await AppStore.sync()
            await updateProState()
        } catch {
            purchaseError = ConsumerErrorCopy.message(for: error, action: .restore)
        }
        isLoading = false
    }

    public func refreshEntitlements() async {
        await updateProState()
    }

    // MARK: - Private helpers

    private func loadProductsAndEntitlements() async {
        do {
            products = try await Product.products(for: ProductID.all)
            products.sort { $0.price > $1.price }  // yearly first
            var eligible: Set<String> = []
            for product in products {
                guard let subscription = product.subscription,
                      subscription.introductoryOffer?.paymentMode == .freeTrial,
                      await subscription.isEligibleForIntroOffer else { continue }
                eligible.insert(product.id)
            }
            eligibleFreeTrialProductIDs = eligible
        } catch {
            // Products unavailable in Simulator without a StoreKit config file.
        }
        // App startup and the first screen's registration task run concurrently.
        // Ensure reconciliation has credentials instead of silently leaving a
        // returning subscriber non-Pro until Settings opens.
        _ = try? await TonoBackend.shared.registerIfNeeded(
            platform: "ios",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        )
        await updateProState()
    }

    private func updateProState() async {
        var inTrial = false
        var backendState: TonoMe?
        var sawVerifiedEntitlement = false
        var serverSyncFailed = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let tx) = result else { continue }
            guard ProductID.all.contains(tx.productID) else { continue }
            guard tx.revocationDate == nil else { continue }
            sawVerifiedEntitlement = true
            do {
                backendState = try await TonoBackend.shared.syncAppStoreSubscription(
                    signedTransactionInfo: result.jwsRepresentation
                )
            } catch {
                serverSyncFailed = true
            }
            if tx.offer?.paymentMode == .freeTrial { inTrial = true }
        }
        if backendState == nil {
            backendState = try? await TonoBackend.shared.me()
        }
        guard let backendState else {
            // Backend reconciliation is unavailable/invalid: transition to the
            // explicit `unknown` state and FAIL CLOSED (build 91 §7). We must
            // not leave a stale cached Pro Bool standing as authority — there is
            // no 72-hour offline allowance. `recordEntitlement(.unknown)` keeps
            // the last-known mirror but flips `isProAuthoritative` false so the
            // keyboard/extensions and the entitlement gate stop presenting Pro.
            isPro = false
            isInFreeTrial = false
            TonePreferences.recordEntitlement(.unknown, isPro: false)
            if sawVerifiedEntitlement {
                purchaseError = "Couldn't reach Tono to confirm your subscription. Pro resumes once you're back online."
            }
            return
        }
        applyBackendState(backendState, inTrial: inTrial)
        // build 101: Apple has a verified transaction for this device but the
        // backend does not grant Pro. Most likely the transaction's appAccountToken
        // is bound to a different email account (reinstall/device-switch conflict).
        // Surface a clear sign-in path so the user can recover without silent loss.
        if sawVerifiedEntitlement && !backendState.isPro {
            if serverSyncFailed {
                purchaseError = "Apple confirmed your subscription, but Tono couldn't verify it right now. Try again when you're back online."
            } else {
                purchaseError = "Your subscription is linked to a different account. Sign in with that email to restore access, or contact support@tonoit.com."
            }
        }
    }

    private func applyBackendState(_ me: TonoMe, inTrial: Bool) {
        isPro = me.isPro
        isInFreeTrial = me.isPro && inTrial
        // A successful backend response is authoritative (build 91 §7): record
        // the verdict as tri-state so extensions and the entitlement gate read a
        // freshness-aware value rather than a stale Bool. `.notEntitled` clears
        // the shared Pro mirror immediately; `.entitled` sets it. This replaces
        // the bare `proUnlocked` write below.
        TonePreferences.recordEntitlement(me.isPro ? .entitled : .notEntitled, isPro: me.isPro)
        // recordEntitlement owns `proUnlocked`; here we only persist the
        // StoreKit-derived trial flag for the entitled+trial case.
        var prefs = TonePreferences()
        prefs.inFreeTrial = isInFreeTrial
        prefs.save()
    }

    /// Applies `/v1/me` to the same authority used by purchase and restore.
    public func acceptBackendState(_ me: TonoMe) {
        applyBackendState(me, inTrial: me.isPro && isInFreeTrial)
    }

    public func isEligibleForFreeTrial(_ product: Product) -> Bool {
        eligibleFreeTrialProductIDs.contains(product.id)
    }

    private func listenForTransactionUpdates() async {
        for await result in Transaction.updates {
            if case .verified(let tx) = result {
                do {
                    _ = try await TonoBackend.shared.syncAppStoreSubscription(
                        signedTransactionInfo: result.jwsRepresentation
                    )
                    await updateProState()
                    await tx.finish()
                } catch {
                    purchaseError = "Purchase received, but we couldn't confirm it yet. Try Restore purchases."
                }
            }
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let value):
            return value
        }
    }

    private func purchaseAccountToken() throws -> UUID {
        // The canonical server-issued account UUID is the ONLY entitlement
        // principal, and the only value bound as `appAccountToken` on a new
        // purchase (build 91 §1/§4). Never the device id, and there is no
        // fallback: if the canonical account UUID isn't persisted yet, the
        // purchase is disabled so a paid transaction can't bind to a
        // non-principal. `registerIfNeeded` (called before purchase) persists it.
        guard let accountID = SharedKeychain.get(KeychainKeys.accountID),
              let token = UUID(uuidString: accountID) else {
            throw StoreError.missingAccountToken
        }
        return token
    }

    public enum StoreError: LocalizedError {
        case failedVerification
        case missingAccountToken
        /// build 101: purchase blocked because the device has no verified email
        /// identity. The purchase token (appAccountToken) must bind a canonical
        /// server account UUID that is recoverable after reinstall, which requires
        /// a prior email sign-in. Route the user to sign in before retrying.
        case needsIdentifiedAccount
        /// build 122: purchase blocked at INITIATION because the live backend is
        /// not configured to verify/honor Apple StoreKit transactions
        /// (`apple_configured` is false, or the readiness contract was malformed).
        /// Starting the charge anyway is exactly what quarantined Build 121: Apple
        /// takes the money and the backend cannot grant Pro. Fail closed.
        case appleNotConfigured
        /// build 122: purchase blocked at INITIATION because the backend readiness
        /// contract could not be reached, so Apple-configuration could not be
        /// confirmed. Fail closed rather than charging on an unknown.
        case purchaseCapabilityUnavailable
        public var errorDescription: String? {
            switch self {
            case .failedVerification:
                return "Purchase verification failed. Contact support if this persists."
            case .missingAccountToken:
                return "Tono must finish account setup before purchasing. Please reopen the app and try again."
            case .needsIdentifiedAccount:
                return "Sign in with your email before subscribing so your account is recoverable if you reinstall or switch devices."
            case .appleNotConfigured:
                return "Subscriptions aren't available right now. No charge was made. Please try again later."
            case .purchaseCapabilityUnavailable:
                return "Couldn't confirm subscriptions are available right now. No charge was made. Check your connection and try again."
            }
        }
    }
}

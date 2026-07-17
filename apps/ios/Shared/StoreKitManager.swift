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
    /// (Apple's "real" 7-day trial configured in App Store Connect).
    @Published public private(set) var isInFreeTrial: Bool = false
    @Published public private(set) var eligibleFreeTrialProductIDs: Set<String> = []

    private var updatesTask: Task<Void, Never>?

    private init() {}

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

    // MARK: - Public API

    public func purchase(_ product: Product) async {
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
            purchaseError = error.localizedDescription
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
            purchaseError = "Restore failed: \(error.localizedDescription)"
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
            // keyboard/extensions and free-tier gate stop presenting Pro.
            isPro = false
            isInFreeTrial = false
            TonePreferences.recordEntitlement(.unknown, isPro: false)
            if sawVerifiedEntitlement {
                purchaseError = "Couldn't reach Tono to confirm your subscription. Pro resumes once you're back online."
            }
            return
        }
        applyBackendState(backendState, inTrial: inTrial)
        if sawVerifiedEntitlement, serverSyncFailed, !backendState.isPro {
            purchaseError = "Apple confirmed the purchase, but server verification failed. Try Restore purchases."
        }
    }

    private func applyBackendState(_ me: TonoMe, inTrial: Bool) {
        isPro = me.isPro
        isInFreeTrial = me.isPro && inTrial
        // A successful backend response is authoritative (build 91 §7): record
        // the verdict as tri-state so extensions and the free-tier gate read a
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
                    purchaseError = "Purchase received, but server verification failed. Try Restore purchases."
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
        public var errorDescription: String? {
            switch self {
            case .failedVerification:
                return "Purchase verification failed. Contact support if this persists."
            case .missingAccountToken:
                return "Tono must finish account setup before purchasing. Please reopen the app and try again."
            }
        }
    }
}


// StoreKitManager.swift
// StoreKit 2 purchase manager for Tono Pro.
//
// Product IDs must match exactly what you register in App Store Connect.
// CURRENT CODE values (used at runtime by ProductID enum below):
//   com.tonoit.pro.monthly  — auto-renewing subscription
//   com.tonoit.pro.yearly   — auto-renewing subscription
// NOTE: App/Tono.storekit still references `com.tono.pro.*` (no `it`),
// and the header docs in this file historically used `com.tonocoach.pro.*`.
// Product IDs in App Store Connect are immutable once created — verify
// what's registered in ASC before changing the .storekit or this enum,
// or StoreKit will throw "product not available" at loadProducts time.
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
    @Published public var isPro:        Bool      = false
    @Published public var isLoading:    Bool      = false
    @Published public var purchaseError: String?
    /// True when the user is in an active introductory free trial period
    /// (Apple's "real" 7-day trial configured in App Store Connect).
    @Published public var isInFreeTrial: Bool     = false
    @Published public private(set) var eligibleFreeTrialProductIDs: Set<String> = []

    private var updatesTask: Task<Void, Never>?

    private init() {}

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
            let result = try await product.purchase()
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
        await updateProState()
    }

    private func updateProState() async {
        var inTrial = false
        var backendState: TonoMe?
        var sawVerifiedEntitlement = false
        var serverSyncFailed = false
        for await result in Transaction.currentEntitlements {
            // Verified by StoreKit; unverified transactions are silently
            // skipped (StoreError.failedVerification would be thrown for
            // any caller that needed to handle them explicitly).
            guard case .verified(let tx) = result else { continue }
            guard ProductID.all.contains(tx.productID) else { continue }
            guard tx.revocationDate == nil else { continue }
            sawVerifiedEntitlement = true
            do {
                let me = try await TonoBackend.shared.syncAppStoreSubscription(
                    signedTransactionInfo: result.jwsRepresentation
                )
                backendState = me
            } catch {
                serverSyncFailed = true
            }
            // Only Apple's explicit free-trial payment mode counts as a trial;
            // paid introductory offers must remain ordinary Pro subscriptions.
            if tx.offer?.paymentMode == .freeTrial {
                inTrial = true
            }
        }
        if backendState == nil {
            backendState = try? await TonoBackend.shared.me()
        }
        guard let backendState else { return }
        applyBackendState(backendState, inTrial: inTrial)
        if sawVerifiedEntitlement, serverSyncFailed, !backendState.isPro {
            purchaseError = "Apple confirmed the purchase, but server verification failed. Try Restore purchases."
        }
    }

    private func applyBackendState(_ me: TonoMe, inTrial: Bool) {
        isPro = me.isPro
        isInFreeTrial = me.isPro && inTrial
        // Mirror into shared prefs so the keyboard extension can read it
        // without importing StoreKit (extensions can't use @MainActor across
        // process boundary; the flag is the safe IPC channel).
        var prefs = TonePreferences()
        prefs.proUnlocked = me.isPro
        prefs.inFreeTrial = me.isPro && inTrial
        prefs.save()
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

    public enum StoreError: LocalizedError {
        case failedVerification
        public var errorDescription: String? {
            "Purchase verification failed. Contact support if this persists."
        }
    }
}


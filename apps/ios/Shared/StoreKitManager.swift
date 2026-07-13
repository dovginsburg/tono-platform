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

    private var updatesTask: Task<Void, Never>?

    private init() {}

    // Call once from the app entry point.
    public func start() {
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
                await updateProState()
                await transaction.finish()
            case .userCancelled:
                break
            case .pending:
                purchaseError = "Purchase is pending approval."
            @unknown default:
                break
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

    // MARK: - Private helpers

    private func loadProductsAndEntitlements() async {
        do {
            products = try await Product.products(for: ProductID.all)
            products.sort { $0.price > $1.price }  // yearly first
        } catch {
            // Products unavailable in Simulator without a StoreKit config file.
        }
        await updateProState()
    }

    private func updateProState() async {
        var active = false
        var inTrial = false
        for await result in Transaction.currentEntitlements {
            // Verified by StoreKit; unverified transactions are silently
            // skipped (StoreError.failedVerification would be thrown for
            // any caller that needed to handle them explicitly).
            guard case .verified(let tx) = result else { continue }
            guard ProductID.all.contains(tx.productID) else { continue }
            guard tx.revocationDate == nil else { continue }
            active = true
            // Detect Apple's real 7-day free trial: tx.offerType == .introductory
            // and offer is a free-trial-period offer. This is the ONLY way to
            // know the user is in a trial — there's no separate "isOnTrial" flag.
            // tx.offer is only available on iOS 17.2+. We fall back to
            // offerType alone on older OS versions (still correctly identifies
            // an intro offer, just doesn't distinguish free-trial from pay-up-front).
            if tx.offerType == .introductory {
                // Transaction.Offer.PaymentMode values:
                //   .freeTrial, .payAsYouGo, .payUpFront, .oneTime (iOS 26+)
                if let offer = tx.offer, offer.paymentMode == .freeTrial {
                    inTrial = true
                }
            }
        }
        isPro = active
        isInFreeTrial = inTrial
        // Mirror into shared prefs so the keyboard extension can read it
        // without importing StoreKit (extensions can't use @MainActor across
        // process boundary; the flag is the safe IPC channel).
        var prefs = TonePreferences()
        prefs.proUnlocked = active
        prefs.inFreeTrial = inTrial
        prefs.save()
    }

    private func listenForTransactionUpdates() async {
        for await result in Transaction.updates {
            if case .verified(let tx) = result {
                await updateProState()
                await tx.finish()
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


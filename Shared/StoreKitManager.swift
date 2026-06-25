// StoreKitManager.swift
// StoreKit 2 purchase manager for Tono Pro.
//
// Product IDs must match exactly what you register in App Store Connect:
//   com.tonocoach.pro.monthly  — $3 / month auto-renewing subscription
//   com.tonocoach.pro.yearly   — $29 / year auto-renewing subscription
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
        public static let monthly = "com.tono.pro.monthly"
        public static let yearly  = "com.tono.pro.yearly"
        public static var all: [String] { [monthly, yearly] }
    }

    @Published public var products:     [Product] = []
    @Published public var isPro:        Bool      = false
    @Published public var isLoading:    Bool      = false
    @Published public var purchaseError: String?

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
        for await result in Transaction.currentEntitlements {
            if case .verified(let tx) = result,
               ProductID.all.contains(tx.productID),
               tx.revocationDate == nil {
                active = true
            }
        }
        isPro = active
        // Mirror into shared prefs so the keyboard extension can read it
        // without importing StoreKit (extensions can't use @MainActor across
        // process boundary; the flag is the safe IPC channel).
        var prefs = TonePreferences()
        prefs.proUnlocked = active
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

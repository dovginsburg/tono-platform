// RevenueCatManager.swift
// RevenueCat canary integration (build 123) — APP TARGET ONLY.
//
// RevenueCat is the first Tono canary for a unified subscription lifecycle. This
// manager owns the RevenueCat iOS SDK lifecycle: authenticated identity
// (logIn/appUserID = the canonical Tono account UUID), safe logout/reset,
// CustomerInfo refresh, purchase, restore, pending/cancel/error handling, and
// localized provider prices — all behind a kill switch.
//
// TWO invariants keep this safe as an additive canary:
//
//  1. The Tono BACKEND stays the sole entitlement authority. RevenueCat's
//     CustomerInfo is treated as telemetry/observation ONLY; it never sets Pro.
//     The Pro gate remains `/v1/me`.is_pro projected by the server (see
//     TonePreferences.isProAuthoritative / StoreKitManager). No anonymous user
//     owns durable paid access: we only ever logIn the server-issued account UUID.
//
//  2. This file is compiled into the APP TARGET ONLY and is guarded by
//     `#if canImport(RevenueCat)`. The RevenueCat SPM package
//     (https://github.com/RevenueCat/purchases-ios) is the first SPM dependency
//     in this project; adding it is an Xcode/provider step. Until it is linked,
//     `canImport(RevenueCat)` is false and every method is a safe no-op, so the
//     existing build stays green. The public API is SDK-agnostic so callers
//     (TonoApp) compile unchanged either way.
//
// Kill switch: RevenueCat is configured ONLY when the Info.plist key
// REVENUECAT_PUBLIC_SDK_KEY holds a real publishable key (an `appl_...` value).
// An empty/placeholder key leaves RevenueCat entirely dormant — the default
// canary posture. There is never a duplicate checkout: the existing StoreKit
// paywall path is unchanged; this manager provides the identity/observation layer
// now and the purchase/restore capability for a later, deliberate cutover.

import Foundation

#if canImport(RevenueCat)
import RevenueCat
#endif

@MainActor
public final class RevenueCatManager: ObservableObject {
    public static let shared = RevenueCatManager()

    // The RevenueCat entitlement identifier that maps to the canonical Tono `pro`
    // entitlement. Overridable via Info.plist for a per-environment project.
    private static let defaultEntitlementID = "pro"

    /// RevenueCat's default package identifiers for the monthly / annual offering.
    public enum PackageID {
        public static let monthly = "$rc_monthly"
        public static let annual  = "$rc_annual"
    }

    /// True once RevenueCat has been configured with a real key (kill switch on).
    @Published public private(set) var isConfigured: Bool = false
    /// RevenueCat's view of entitlement — OBSERVATION ONLY. The backend `/v1/me`
    /// projection remains the sole Pro authority; nothing here gates access.
    @Published public private(set) var customerInfoIsPro: Bool = false
    /// User-facing error copy for the current purchase/restore attempt.
    @Published public var purchaseError: String?
    /// True while a purchase or restore is in flight.
    @Published public private(set) var isPurchasing: Bool = false
    /// Localized display price per package id, from the provider's StoreProduct —
    /// never a hard-coded literal (pricing always comes from the store).
    @Published public private(set) var localizedPrices: [String: String] = [:]

    private init() {}

    // MARK: - Configuration (kill switch)

    private var entitlementID: String {
        (Bundle.main.object(forInfoDictionaryKey: "REVENUECAT_ENTITLEMENT_ID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? Self.defaultEntitlementID
    }

    /// The publishable RevenueCat key from Info.plist, or nil when unset/placeholder.
    /// Publishable (`appl_`) keys are safe to ship in the client; secrets never are.
    private var publicSDKKey: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "REVENUECAT_PUBLIC_SDK_KEY") as? String
        else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Treat empty / obvious placeholders as "not configured" (fail closed).
        guard !key.isEmpty, !key.hasPrefix("$("), key.uppercased() != "REPLACE_ME" else { return nil }
        return key
    }

    /// True when a real publishable key is present. Callers can branch UI on this
    /// without importing the SDK.
    public var isEnabled: Bool { publicSDKKey != nil }

    /// Configure RevenueCat once, at app launch, behind the kill switch. A no-op
    /// when no real key is present or the SDK is not linked. If the canonical
    /// account UUID already exists we configure with it directly so no anonymous
    /// RevenueCat identity is ever created; otherwise we identify later via
    /// `identifyFromKeychain()` once registration completes.
    public func configureIfEnabled() {
        guard let key = publicSDKKey else { return }  // kill switch: dormant by default
        #if canImport(RevenueCat)
        guard !isConfigured else { return }
        let appUserID = Self.canonicalAccountID
        let builder = Configuration.Builder(withAPIKey: key)
        if let appUserID { _ = builder.with(appUserID: appUserID) }
        Purchases.configure(with: builder.build())
        isConfigured = true
        Task { await refreshCustomerInfo() }
        #else
        // SDK not linked yet — remain dormant. Adding the SPM package activates this.
        _ = key
        #endif
    }

    // MARK: - Identity (never anonymous, always the canonical account UUID)

    /// The immutable, server-issued Tono account UUID — the ONLY RevenueCat App
    /// User ID we ever use. Never the device id, email, or an anonymous RC id.
    private static var canonicalAccountID: String? {
        guard let id = SharedKeychain.get(KeychainKeys.accountID),
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return id
    }

    /// Log the current canonical account UUID into RevenueCat. Call after the
    /// Tono account is established (post-register / post-sign-in). No-op if there
    /// is no account UUID yet (we never create an anonymous durable identity).
    public func identifyFromKeychain() {
        guard isConfigured, let appUserID = Self.canonicalAccountID else { return }
        #if canImport(RevenueCat)
        Purchases.shared.logIn(appUserID) { [weak self] _, _, _ in
            Task { await self?.refreshCustomerInfo() }
        }
        #endif
    }

    /// Reset RevenueCat identity on sign-out / account deletion so the next person
    /// on this device never inherits the previous account's RevenueCat customer.
    public func signOut() {
        customerInfoIsPro = false
        localizedPrices = [:]
        purchaseError = nil
        guard isConfigured else { return }
        #if canImport(RevenueCat)
        Purchases.shared.logOut { _, _ in }
        #endif
    }

    // MARK: - CustomerInfo (observation only)

    /// Refresh RevenueCat's CustomerInfo for OBSERVATION. This never changes the
    /// Pro gate — the backend projection is authoritative. It only updates the
    /// telemetry mirror so a future authoritative cutover has a live signal.
    public func refreshCustomerInfo() async {
        guard isConfigured else { return }
        #if canImport(RevenueCat)
        do {
            let info = try await Purchases.shared.customerInfo()
            customerInfoIsPro = info.entitlements[entitlementID]?.isActive == true
        } catch {
            // Never fail closed here in a way that touches entitlement — this is
            // telemetry. Leave the last known value untouched.
        }
        #endif
    }

    // MARK: - Localized offerings / prices

    /// Load the current offering and cache localized display prices per package.
    public func refreshOfferings() async {
        guard isConfigured else { return }
        #if canImport(RevenueCat)
        do {
            let offerings = try await Purchases.shared.offerings()
            guard let current = offerings.current else { return }
            var prices: [String: String] = [:]
            for package in current.availablePackages {
                prices[package.identifier] = package.storeProduct.localizedPriceString
            }
            localizedPrices = prices
        } catch {
            // Non-fatal: the paywall can fall back to its existing StoreKit prices.
        }
        #endif
    }

    // MARK: - Purchase / restore (with pending / cancel / error handling)

    public enum PurchaseOutcome: Equatable {
        case purchased
        case pending          // e.g. Ask-to-Buy / SCA — access is not granted yet
        case cancelled
        case notConfigured
        case unavailable      // offering/package missing
        case failed(String)
    }

    /// Purchase the package for the given identifier ($rc_monthly / $rc_annual).
    /// Requires the canonical account UUID (never an anonymous purchase). The
    /// backend remains the entitlement authority — a successful purchase here
    /// surfaces via the RevenueCat webhook, which the server projects.
    @discardableResult
    public func purchase(packageID: String) async -> PurchaseOutcome {
        guard isConfigured else { return .notConfigured }
        // No anonymous durable paid access: refuse to buy without the account UUID.
        guard Self.canonicalAccountID != nil else {
            let msg = "Finish account setup before purchasing."
            purchaseError = msg
            return .failed(msg)
        }
        isPurchasing = true
        defer { isPurchasing = false }
        purchaseError = nil
        #if canImport(RevenueCat)
        do {
            // Ensure RevenueCat is identified with the canonical UUID before buying.
            identifyFromKeychain()
            let offerings = try await Purchases.shared.offerings()
            guard let package = offerings.current?.package(identifier: packageID)
                    ?? offerings.current?.availablePackages.first(where: { $0.identifier == packageID })
            else { return .unavailable }
            let result = try await Purchases.shared.purchase(package: package)
            if result.userCancelled { return .cancelled }
            // A transaction with no active entitlement yet is a PENDING purchase
            // (Ask-to-Buy / deferred). Do not present it as granted.
            let active = result.customerInfo.entitlements[entitlementID]?.isActive == true
            customerInfoIsPro = active
            await refreshCustomerInfo()
            return active ? .purchased : .pending
        } catch {
            let msg = Self.userFacingError(error)
            purchaseError = msg
            return .failed(msg)
        }
        #else
        return .notConfigured
        #endif
    }

    /// Restore purchases (reinstall / second device). Re-identifies the canonical
    /// account first so a restore attaches to the right RevenueCat customer.
    @discardableResult
    public func restore() async -> PurchaseOutcome {
        guard isConfigured else { return .notConfigured }
        isPurchasing = true
        defer { isPurchasing = false }
        purchaseError = nil
        #if canImport(RevenueCat)
        do {
            identifyFromKeychain()
            let info = try await Purchases.shared.restorePurchases()
            let active = info.entitlements[entitlementID]?.isActive == true
            customerInfoIsPro = active
            return active ? .purchased : .failed("No active subscription found to restore.")
        } catch {
            let msg = Self.userFacingError(error)
            purchaseError = msg
            return .failed(msg)
        }
        #else
        return .notConfigured
        #endif
    }

    // MARK: - Error mapping

    private static func userFacingError(_ error: Error) -> String {
        #if canImport(RevenueCat)
        if let rcError = error as? RevenueCat.ErrorCode {
            switch rcError {
            case .purchaseCancelledError:
                return "Purchase cancelled."
            case .paymentPendingError:
                return "Your purchase is pending approval."
            case .networkError:
                return "Network problem — check your connection and try again."
            case .storeProblemError:
                return "The App Store is having a problem. Please try again later."
            default:
                break
            }
        }
        #endif
        return "Purchase could not be completed. Please try again."
    }
}

private extension String {
    /// nil when the string is empty after trimming, else self — for config reads.
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Canary routing mode (off / shadow / authoritative)

/// The three-state client routing mode for the RevenueCat canary, mirroring the
/// backend `TONO_REVENUECAT_MODE` and the web `NEXT_PUBLIC_REVENUECAT_MODE`. It is
/// read from the Info.plist key `REVENUECAT_MODE` and fails closed to `.off`.
///
///  - `off`:           the existing StoreKit paywall path conducts purchase and
///                     restore; RevenueCat is dormant. Current behavior, unchanged.
///  - `shadow`:        the existing StoreKit path still conducts the purchase — it
///                     stays the sole deterministic writer — and RevenueCat only
///                     observes (CustomerInfo/offerings), never granting access.
///  - `authoritative`: RevenueCat conducts the purchase/restore lifecycle. The Tono
///                     backend remains the sole durable entitlement projector (the
///                     Pro gate is still `/v1/me`.is_pro, driven by the webhook).
public enum RevenueCatMode: String, CaseIterable, Equatable {
    case off
    case shadow
    case authoritative

    /// Parse a raw Info.plist / environment string, failing closed to `.off` for
    /// anything unknown, empty, placeholder, or nil.
    public static func parse(_ raw: String?) -> RevenueCatMode {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "shadow":        return .shadow
        case "authoritative": return .authoritative
        default:              return .off   // fail closed: unknown/empty/nil ⇒ off
        }
    }

    /// The mode configured for this build via the Info.plist key `REVENUECAT_MODE`.
    public static var current: RevenueCatMode {
        parse(Bundle.main.object(forInfoDictionaryKey: "REVENUECAT_MODE") as? String)
    }
}

/// Which engine should conduct a paywall purchase, given the mode and whether
/// RevenueCat is actually usable right now (real publishable key + linked SDK +
/// successful configuration). Pure and SDK-agnostic so it is fully unit-testable
/// without the provider or a live key.
public enum RevenueCatPurchaseRoute: Equatable {
    /// The legacy StoreKit path (off / shadow, and the fail-closed authoritative
    /// fallback for restore).
    case storeKit
    /// RevenueCat conducts the purchase/restore (authoritative + usable).
    case revenueCat
    /// Authoritative was requested but RevenueCat is not usable (missing key or
    /// unlinked SDK). A *purchase* fails closed here — we never silently charge
    /// through the wrong engine.
    case blockedNotConfigured
}

public enum RevenueCatPurchaseRouter {
    /// Decide which engine conducts a **purchase**.
    ///
    /// `revenueCatUsable` must be true only when a real key is present, the SDK is
    /// linked, and configuration succeeded (`RevenueCatManager.isConfigured`).
    public static func route(mode: RevenueCatMode, revenueCatUsable: Bool) -> RevenueCatPurchaseRoute {
        switch mode {
        case .off, .shadow:
            // The legacy StoreKit path is the deterministic writer; shadow only
            // adds RevenueCat observation on top, it never conducts the purchase.
            return .storeKit
        case .authoritative:
            // Fail closed: authoritative without a usable RevenueCat is blocked,
            // not silently downgraded to a StoreKit charge.
            return revenueCatUsable ? .revenueCat : .blockedNotConfigured
        }
    }

    /// Decide which engine conducts a **restore**. Restore never charges, so an
    /// authoritative-but-unusable state safely falls back to StoreKit restore
    /// instead of blocking the user out of recovering an existing subscription.
    public static func restoreRoute(mode: RevenueCatMode, revenueCatUsable: Bool) -> RevenueCatPurchaseRoute {
        switch route(mode: mode, revenueCatUsable: revenueCatUsable) {
        case .revenueCat:          return .revenueCat
        case .storeKit,
             .blockedNotConfigured: return .storeKit
        }
    }
}

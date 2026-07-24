import Foundation

/// Optional rewrite variants exposed by build 94. Declaration order is the
/// persisted, settings, request, and render order; never sort these labels.
public enum CoachOptionalVariant: String, Codable, CaseIterable, Hashable {
    case clearer
    case funnier
    case affectionate
    case professional
    case concise
    case custom

    public var displayName: String { rawValue.capitalized }
}

/// Shared source contract for the keyboard and iMessage tone chips. Keeping
/// labels and semantic accents here prevents the two extension surfaces from
/// drifting while still allowing the user's two configured optional tones.
public enum CoachToneChipContract {
    public static func label(for axis: String) -> String {
        axis.lowercased().capitalized
    }

    public static func accentHex(for axis: String) -> String? {
        switch axis.lowercased() {
        case "safer": return "34D399"
        case "clearer": return "38BDF8"
        case "funnier": return "FBBF24"
        case "affectionate": return "F472B6"
        case "professional": return "A78BFA"
        case "concise": return "22D3EE"
        case "custom": return "38BDF8"
        default: return nil
        }
    }
}

/// Device-local build-97 selection. Safer is intentionally absent: it is
/// a mandatory pipeline stage, not a user preference. The user picks
/// exactly two optional tones; the keyboard renders them under the
/// fixed Safer chip. Legacy builds that persisted three optional tones
/// are deterministically migrated to the first two on next load — the
/// pick order in the legacy array IS preserved (never reordered).
public struct CoachVariantSettings: Codable, Equatable {
    /// Build-97 contract: exactly two user-selected optional tones, no
    /// more. Legacy build-94/95 installs that persisted up to three are
    /// deterministically truncated to the first two by `normalize()` and
    /// `load()`; the user never sees a fourth choice.
    public static let maximumOptionalCount = 2
    /// Per Ezra's canonical packet: one free-text instruction, max 120 chars.
    /// Matches backend `BUILD94_MAX_CUSTOM_LENGTH`.
    public static let maximumCustomLength = 120

    /// Persisted settings.
    public var enabled: [CoachOptionalVariant]
    public var customInstruction: String

    /// Transient UI state — NOT serialized. Cleared on every load so a
    /// "Turn one off first (3 max)" hint does not survive an app relaunch.
    public var pendingFourthBlocked: Bool = false

    /// Coding keys exclude `pendingFourthBlocked` from the persisted JSON;
    /// it's transient in-memory UI state, never a device preference.
    private enum CodingKeys: String, CodingKey {
        case enabled, customInstruction
    }

    public init(
        enabled: [CoachOptionalVariant] = [.clearer, .funnier],
        customInstruction: String = ""
    ) {
        self.enabled = Self.legacyPreservingCanonical(enabled)
        self.customInstruction = customInstruction
        self.pendingFourthBlocked = false
        normalize()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let enabledRaw = try container.decode([CoachOptionalVariant].self, forKey: .enabled)
        let customInstruction = try container.decode(String.self, forKey: .customInstruction)
        self.init(enabled: enabledRaw, customInstruction: customInstruction)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(customInstruction, forKey: .customInstruction)
    }

    public var selectedCount: Int { enabled.count }

    /// Build-97 chip count includes Safer plus the user's selection:
    /// Safer (mandatory) + up to `maximumOptionalCount` optional tones.
    /// The keyboard renders exactly `1 + selectedCount` chips.
    public var totalShippedChipCount: Int { 1 + selectedCount }

    /// `true` while the user has fewer than the maximum allowed
    /// optional tones selected. Used by the Settings UI to gate the
    /// "Add tone" affordance — there is no fourth chip, ever.
    public var canSelectAnother: Bool { selectedCount < Self.maximumOptionalCount }

    public func canEnable(_ variant: CoachOptionalVariant) -> Bool {
        if enabled.contains(variant) { return true }
        guard canSelectAnother else { return false }
        return variant != .custom || isCustomInstructionValid
    }

    public var isCustomInstructionValid: Bool {
        let trimmed = customInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= Self.maximumCustomLength
    }

    /// Returns false without mutating when the cap is reached. Existing
    /// selections are never silently replaced. When a beyond-cap toggle
    /// attempt is blocked, `pendingFourthBlocked` is set so the UI can
    /// surface the spec-exact "Two tones max" hint.
    @discardableResult
    public mutating func set(_ variant: CoachOptionalVariant, enabled shouldEnable: Bool) -> Bool {
        if shouldEnable {
            guard canEnable(variant) else {
                if !enabled.contains(variant) && !canSelectAnother {
                    pendingFourthBlocked = true
                }
                return false
            }
            if !enabled.contains(variant) {
                enabled.append(variant)
                pendingFourthBlocked = false
            }
        } else {
            enabled.removeAll { $0 == variant }
            pendingFourthBlocked = false
        }
        enabled = Self.legacyPreservingCanonical(enabled)
        return true
    }

    public mutating func normalize() {
        enabled = Array(Self.legacyPreservingCanonical(enabled).prefix(Self.maximumOptionalCount))
        if enabled.contains(.custom), !isCustomInstructionValid {
            enabled.removeAll { $0 == .custom }
        }
    }

    /// Build-97 canonical: dedupe but preserve the FIRST occurrence
    /// order of each variant. This is the deterministic migration
    /// contract — a legacy user with `[funnier, clearer, professional]`
    /// lands on `[funnier, clearer]`, NOT the alphabetical reorder
    /// `[clearer, funnier, professional]`. New users always see the
    /// declared order, which is already preserved by this rule.
    private static func legacyPreservingCanonical(
        _ variants: [CoachOptionalVariant]
    ) -> [CoachOptionalVariant] {
        var seen = Set<CoachOptionalVariant>()
        var result: [CoachOptionalVariant] = []
        for variant in variants {
            if seen.insert(variant).inserted {
                result.append(variant)
            }
        }
        return result
    }
}

/// App Group persistence shared by the host app and keyboard extension. Raw
/// Custom text is held only in this device-local JSON blob and is never logged.
public struct CoachVariantSettingsStore {
    public static let settingsKey = "tc.coachVariantSettings.v1"
    public static let versionKey = "tc.coachVariantSettingsVersion"
    /// Build 97 — bump when the persisted schema changes again. The
    /// load() migration step relies on this constant to know whether a
    /// legacy payload needs deterministic 3→2 migration.
    public static let currentVersion = 2
    /// Legacy build-94/95 schema version. If a payload is read under
    /// this version (or any version < current), the load() path
    /// deterministically migrates the legacy 3-selection list down to
    /// exactly two via the FIRST-OCCURRENCE order-preserving canonical.
    public static let legacyBuild94Version = 1

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = UserDefaults(suiteName: "group.com.tonoit.shared") ?? .standard) {
        self.defaults = defaults
    }

    public func load() -> CoachVariantSettings {
        let storedVersion = defaults.integer(forKey: Self.versionKey)

        if storedVersion == Self.currentVersion,
           let data = defaults.data(forKey: Self.settingsKey),
           var decoded = try? JSONDecoder().decode(CoachVariantSettings.self, from: data) {
            decoded.normalize()
            return decoded
        }

        // Migration path — handle legacy payload from before the
        // build-97 schema change. The legacy JSON may carry up to three
        // optional tones; we deterministically truncate to the first
        // two in the legacy pick order and re-save under the new
        // version key so subsequent loads are fast-path.
        if storedVersion == Self.legacyBuild94Version,
           let data = defaults.data(forKey: Self.settingsKey),
           var decoded = try? JSONDecoder().decode(CoachVariantSettings.self, from: data) {
            decoded.normalize()
            save(decoded)
            return decoded
        }

        // Every pre-build-94 install (no schema key at all) migrates to
        // the build-97 reviewed defaults. The defaults are already
        // order-preserving ([.clearer, .funnier]) so this is also the
        // "fresh install" path.
        let migrated = CoachVariantSettings()
        save(migrated)
        return migrated
    }

    public func save(_ settings: CoachVariantSettings) {
        var normalized = settings
        normalized.normalize()
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        defaults.set(data, forKey: Self.settingsKey)
        defaults.set(Self.currentVersion, forKey: Self.versionKey)
    }
}

// MARK: - Apple Shortcut / App Intent rewrite-style contract
//
// The Apple Shortcut ("Rewrite with Tono") exposes the SAME tone chips the
// keyboard and iMessage surfaces render: the mandatory Safer chip plus the six
// fixed optional tones (Clearer, Funnier, Affectionate, Professional, Concise,
// Custom). Keeping the label→axis map, the 120-char Custom cap, and the no-op
// guard *here* — beside the shared tone-chip contract and reusing
// `CoachOptionalVariant` / `CoachVariantSettings.maximumCustomLength` — means
// the Shortcut cannot drift from the keyboard chips or the backend variant
// axis allowlist. Pure (Foundation only): no AppIntents, no UIKit, no network,
// so it is directly unit-testable.

/// One selectable Rewrite Style for the Apple Shortcut. Raw value == the exact
/// axis string sent to `POST /api/analyze/variant` and == the keyboard chip
/// axis (`CoachToneChipContract`), so the three stay in lock-step.
public enum ShortcutRewriteStyle: String, CaseIterable, Hashable {
    case safer
    case clearer
    case funnier
    case affectionate
    case professional
    case concise
    case custom

    /// Backend selected-variant axis (a member of the server VARIANT_ALLOWLIST).
    public var axis: String { rawValue }

    /// Keyboard-source display label (identical to `CoachToneChipContract.label`).
    public var label: String { CoachToneChipContract.label(for: rawValue) }

    /// Only the Custom tone consumes a free-text directive.
    public var requiresCustomText: Bool { self == .custom }

    /// Canonical selectable order: the mandatory Safer chip first, then the six
    /// optional tones in their persisted `CoachOptionalVariant` declaration
    /// order. This is the exact chip order the keyboard/iMessage strips render.
    public static var selectableOrder: [ShortcutRewriteStyle] {
        [.safer] + CoachOptionalVariant.allCases.map(Self.init(optional:))
    }

    private init(optional: CoachOptionalVariant) {
        switch optional {
        case .clearer: self = .clearer
        case .funnier: self = .funnier
        case .affectionate: self = .affectionate
        case .professional: self = .professional
        case .concise: self = .concise
        case .custom: self = .custom
        }
    }
}

/// Pure resolver + validator for the Shortcut rewrite lane. Encapsulates the
/// Custom 120-char rule and the "never return the source draft as a successful
/// rewrite" no-op guard so the App Intent stays a thin wrapper and the behavior
/// is unit-testable without AppIntents/URLSession.
public enum ShortcutRewrite {
    /// Matches `CoachVariantSettings.maximumCustomLength` and the backend
    /// `BUILD94_MAX_CUSTOM_LENGTH` (both 120).
    public static let maxCustomLength = CoachVariantSettings.maximumCustomLength

    /// Honest, user-facing failure reasons. Every path that is NOT a genuine,
    /// distinct rewrite lands here — the resolver never falls back to the
    /// source draft.
    public enum Failure: Error, Equatable {
        case notRegistered
        case emptyDraft
        case customRequired
        case customTooLong(max: Int)
        case noDistinctRewrite
        case entitlementRequired
        case blocked(reason: String?)
        case emptyResult

        public var message: String {
            switch self {
            case .notRegistered:
                return "Open Tono once to create your account, then try again."
            case .emptyDraft:
                return "Type a message to rewrite first."
            case .customRequired:
                return "Enter a Custom style instruction (1–\(ShortcutRewrite.maxCustomLength) characters)."
            case .customTooLong(let max):
                return "Custom style must be \(max) characters or fewer."
            case .noDistinctRewrite:
                return "Tono couldn't produce a distinct rewrite. Try again or pick another style."
            case .entitlementRequired:
                return "An active trial or subscription is required. Open Tono to continue."
            case .blocked(let reason):
                if let reason, !reason.isEmpty {
                    return "Tono couldn't rewrite that (\(reason))."
                }
                return "Tono couldn't rewrite that. Try again or pick another style."
            case .emptyResult:
                return "Tono returned an empty rewrite. Try again."
            }
        }
    }

    /// Validate + bound the Custom directive. Trims; rejects empty; rejects any
    /// directive longer than 120 characters (never silently truncates a
    /// too-long instruction into a "success", which could change its meaning).
    public static func validatedCustomText(_ raw: String?) -> Result<String, Failure> {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .failure(.customRequired) }
        if trimmed.count > maxCustomLength { return .failure(.customTooLong(max: maxCustomLength)) }
        return .success(trimmed)
    }

    /// Case/whitespace/punctuation-insensitive normalization used for the no-op
    /// comparison — a byte-for-byte mirror of the iMessage extension's
    /// `normalized(_:)` so a rewrite that only churns casing or punctuation is
    /// still caught as a no-op.
    public static func normalizedForNoOp(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Resolve a `/api/analyze/variant` envelope into either the rewritten
    /// String or an honest failure. This is the load-bearing guard: it returns
    /// `.success` ONLY for a non-empty rewrite that is distinct from the source
    /// draft. A blocked envelope, an empty rewrite, or a near-identical no-op
    /// all fail — the source draft is NEVER returned as a success.
    ///
    /// `status`/`axis`/`text`/`reason` come straight from `TonoVariantResult`.
    public static func resolve(
        status: String,
        text: String?,
        reason: String?,
        source: String
    ) -> Result<String, Failure> {
        let rewrite = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == "ok" else {
            return .failure(reason == "no_distinct_rewrite" ? .noDistinctRewrite : .blocked(reason: reason))
        }
        guard !rewrite.isEmpty else { return .failure(.emptyResult) }
        guard normalizedForNoOp(rewrite) != normalizedForNoOp(source) else {
            return .failure(.noDistinctRewrite)
        }
        return .success(rewrite)
    }
}

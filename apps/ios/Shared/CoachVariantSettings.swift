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

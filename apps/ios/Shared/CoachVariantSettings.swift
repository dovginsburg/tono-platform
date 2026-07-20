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

/// Device-local build-94 selection. Safer is intentionally absent: it is a
/// mandatory pipeline stage, not a user preference.
public struct CoachVariantSettings: Codable, Equatable {
    public static let maximumOptionalCount = 3
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
        self.enabled = Self.canonical(enabled)
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

    public func canEnable(_ variant: CoachOptionalVariant) -> Bool {
        if enabled.contains(variant) { return true }
        guard enabled.count < Self.maximumOptionalCount else { return false }
        return variant != .custom || isCustomInstructionValid
    }

    public var isCustomInstructionValid: Bool {
        let trimmed = customInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= Self.maximumCustomLength
    }

    /// Returns false without mutating when a fourth option or invalid Custom is
    /// requested. Existing selections are never silently replaced. When a
    /// fourth-toggle attempt is blocked, `pendingFourthBlocked` is set so the
    /// UI can surface the spec-exact "Turn one off first (3 max)" hint.
    @discardableResult
    public mutating func set(_ variant: CoachOptionalVariant, enabled shouldEnable: Bool) -> Bool {
        if shouldEnable {
            guard canEnable(variant) else {
                // Record the blocked attempt if the user is at the cap AND
                // the variant they tried to enable is currently OFF (so they
                // were actually trying to enable, not re-enable something).
                if !enabled.contains(variant) && selectedCount >= Self.maximumOptionalCount {
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
        enabled = Self.canonical(enabled)
        return true
    }

    public mutating func normalize() {
        enabled = Array(Self.canonical(enabled).prefix(Self.maximumOptionalCount))
        if enabled.contains(.custom), !isCustomInstructionValid {
            enabled.removeAll { $0 == .custom }
        }
    }

    private static func canonical(_ variants: [CoachOptionalVariant]) -> [CoachOptionalVariant] {
        let selected = Set(variants)
        return CoachOptionalVariant.allCases.filter(selected.contains)
    }
}

/// App Group persistence shared by the host app and keyboard extension. Raw
/// Custom text is held only in this device-local JSON blob and is never logged.
public struct CoachVariantSettingsStore {
    public static let settingsKey = "tc.coachVariantSettings.v1"
    public static let versionKey = "tc.coachVariantSettingsVersion"
    public static let currentVersion = 1

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = UserDefaults(suiteName: "group.com.tonoit.shared") ?? .standard) {
        self.defaults = defaults
    }

    public func load() -> CoachVariantSettings {
        if defaults.integer(forKey: Self.versionKey) == Self.currentVersion,
           let data = defaults.data(forKey: Self.settingsKey),
           var decoded = try? JSONDecoder().decode(CoachVariantSettings.self, from: data) {
            decoded.normalize()
            return decoded
        }

        // Every pre-build-94 install migrates to the reviewed defaults. Legacy
        // axes cannot represent the new variants and Safer is no longer optional.
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

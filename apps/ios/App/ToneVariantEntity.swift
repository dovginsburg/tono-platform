// ToneVariantEntity.swift
// Apple Intelligence readiness — the entities-first App Intents model.
//
// A `ToneVariantEntity` is a first-class, privacy-safe App Intents entity for
// one of Tono's tone variants (Safer, Clearer, Funnier, Affectionate,
// Professional, Concise, Custom). Making the variants ENTITIES — rather than
// only an in-intent enum — is what lets Shortcuts and Spotlight discover and
// suggest them, and what lets other intents take "a tone variant" as a typed
// parameter with a picker.
//
// THE PRIVACY CONTRACT OF THE ENTITY. Its identifier is the axis string and
// NOTHING else — never a draft, never clipboard, never typed text. The entity
// names a TONE, not a message. It carries a display label and whether the tone
// needs a Custom directive, both derived from the pure `ShortcutRewriteStyle`
// contract (Shared/CoachVariantSettings.swift), so the entity, the keyboard
// chips, the iMessage chips and the backend variant allowlist cannot drift.

import AppIntents
import Foundation

/// One selectable tone variant, as an App Intents entity.
@available(iOS 16.0, *)
struct ToneVariantEntity: AppEntity, Identifiable {

    /// The axis string — e.g. "safer", "funnier". This is the ONLY identity the
    /// entity has, and it is deliberately not derived from anything the user
    /// typed. A tone is not a message.
    var id: String

    /// The keyboard-source display label ("Safer", "Funnier", …).
    var label: String

    /// Whether this variant consumes a free-text Custom directive.
    var requiresCustomText: Bool

    init(style: ShortcutRewriteStyle) {
        self.id = style.rawValue
        self.label = style.label
        self.requiresCustomText = style.requiresCustomText
    }

    /// The pure contract this entity mirrors, recovered from an id. Nil for an
    /// id that is not a known tone.
    var style: ShortcutRewriteStyle? { ShortcutRewriteStyle(rawValue: id) }

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Tone Variant"

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(label)")
    }

    static var defaultQuery = ToneVariantQuery()

    /// Every selectable variant, in the canonical Safer-first chip order.
    static var all: [ToneVariantEntity] {
        ShortcutRewriteStyle.selectableOrder.map(ToneVariantEntity.init(style:))
    }
}

/// The query that makes tone variants discoverable.
///
/// `suggestedEntities()` is what surfaces the variants in the Shortcuts editor
/// and in Spotlight suggestions on iOS 16+. It returns the full canonical set;
/// there is nothing user-specific or text-derived in it, so it is safe to
/// suggest anywhere.
@available(iOS 16.0, *)
struct ToneVariantQuery: EntityQuery {

    func entities(for identifiers: [String]) async throws -> [ToneVariantEntity] {
        ToneVariantEntity.all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ToneVariantEntity] {
        ToneVariantEntity.all
    }
}

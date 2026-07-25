// setup_doctor_verifier_shim.swift
// VERIFICATION ONLY — never compiled into any shipping target.
//
// `verify_setup_doctor.swift` compiles the REAL `Shared/SetupDoctor.swift`,
// `Shared/SharedUserDefaults.swift`, and `Shared/SharedKeychain.swift`, so
// every type the Setup Doctor actually consumes (`EntitlementState`,
// `SharedStore`, `SharedKeys`) is the shipping definition, not a copy.
//
// `SharedUserDefaults.swift` also references two enums that live in
// `ToneEngine.swift`, and pulling that file in would cascade into the whole
// analyzer graph (TonoBackend, the three provider clients, the Apple rewrite
// bridge) — none of which the Setup Doctor touches. These two stand-ins break
// that cascade.
//
// They are pinned: `verify_setup_doctor.swift` re-reads `ToneEngine.swift` and
// fails if either enum's real case list stops matching what is declared here,
// so this file cannot silently drift out of sync with the source it stands in
// for.

import Foundation

public enum LLMProvider: String, Codable, CaseIterable {
    case openai
    case anthropic
    case mock
}

public enum RewriteAxis: String, Codable, CaseIterable, Identifiable {
    case warmer
    case clearer
    case funnier
    case safer

    public var id: String { rawValue }
}

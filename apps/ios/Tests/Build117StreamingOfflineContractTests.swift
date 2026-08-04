// Build117StreamingOfflineContractTests.swift
// Tono build 117 — the streaming path must express OFFLINE as a shape.
//
// Build 113 stopped the streaming path from collapsing 401 / 402 / 429 into a
// generic "Try again." by carrying the HTTP status as `AnalysisEvent.failure`
// instead of a sentence. One member of that same family was left behind: a
// TRANSPORT failure. `analyzeStream`'s terminal catch stringified an offline
// `URLError` into `.error(localizedDescription)`, and every consumer then
// re-wrapped that string as a backend error — which `ConsumerErrorCopy` maps to
// `.retry`. So an offline coach on the streaming keyboard/Share path read
// "Try again." while the non-streaming path (which throws
// `TonoBackendError.offline`) correctly read "Check your connection…".
//
// The fix adds `AnalysisEvent.offline` — a payload-free SHAPE, like
// `.failure(status:)` — which the producer emits for an offline transport and
// every consumer maps to `TonoBackendError.offline`. These probes pin:
//   1. the producer's SHAPE classifier (`isOfflineTransport`) — by case, never
//      by the error's message, and matching the offline URLError set every
//      other Tono surface uses;
//   2. that an offline streamed failure resolves to the "check your connection"
//      recovery and is NOT the generic retry the old stringify collapsed to.

import XCTest
@testable import Tono

final class Build117StreamingOfflineContractTests: XCTestCase {

    // MARK: - The producer's offline SHAPE classifier

    /// Every URLError code that means "no usable connection" is offline. This
    /// is the same set `ConsumerErrorCopy.isOffline` and
    /// `EmailAuthOutcome.offlineCodes` use; the three must never drift.
    func testEveryOfflineURLErrorCodeIsClassifiedOffline() {
        let offlineCodes: [URLError.Code] = [
            .notConnectedToInternet,
            .networkConnectionLost,
            .cannotConnectToHost,
            .cannotFindHost,
            .dataNotAllowed,
            .internationalRoamingOff,
            .secureConnectionFailed,
        ]
        for code in offlineCodes {
            XCTAssertTrue(
                TonoBackend.isOfflineTransport(URLError(code)),
                "URLError \(code.rawValue) should be treated as offline"
            )
        }
    }

    /// The backend's own offline error is offline too, so the streaming and
    /// non-streaming producers agree.
    func testBackendOfflineErrorIsClassifiedOffline() {
        XCTAssertTrue(TonoBackend.isOfflineTransport(TonoBackendError.offline))
    }

    /// A request that was ANSWERED — badly or otherwise — is not offline. These
    /// must stay "try again" / status-specific, never "check your connection".
    func testAnsweredAndUnknownFailuresAreNotOffline() {
        let notOffline: [Error] = [
            URLError(.badServerResponse),
            URLError(.cannotParseResponse),
            URLError(.userAuthenticationRequired),
            TonoBackendError.http(500, "db-primary.tono.internal SELECT * FROM users"),
            TonoBackendError.http(402, "Bearer eyJhbGciOiJIUzI1NiJ9"),
            TonoBackendError.decoding("password=hunter2"),
            TonoBackendError.network("api.tonoit.com refused"),
            ToneEngineError.backend("status 500 | /var/app/server.py"),
        ]
        for error in notOffline {
            XCTAssertFalse(
                TonoBackend.isOfflineTransport(error),
                "\(error) must not be classified offline"
            )
        }
    }

    /// The classifier reads the error's CASE, never its payload — a URLError
    /// whose userInfo is stuffed with an offline-sounding sentence but whose
    /// code is a server answer stays "answered", and vice-versa.
    func testClassifierIgnoresThePayload() {
        let answeredWithOfflineText = URLError(
            .badServerResponse,
            userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."]
        )
        XCTAssertFalse(
            TonoBackend.isOfflineTransport(answeredWithOfflineText),
            "a server answer must not become offline just because its text says so"
        )

        let offlineWithServerText = URLError(
            .notConnectedToInternet,
            userInfo: [NSLocalizedDescriptionKey: "HTTP 500 Internal Server Error"]
        )
        XCTAssertTrue(
            TonoBackend.isOfflineTransport(offlineWithServerText),
            "a genuine offline code stays offline whatever its text claims"
        )
    }

    // MARK: - The user-visible consequence

    /// A streamed offline failure resolves to the offline recovery — the same
    /// sentence the non-streaming `TonoBackendError.offline` produces — and is
    /// DISTINCT from the generic retry the old stringified `.error` collapsed
    /// to. This is the whole point of the shape: it changes what the user reads.
    func testStreamedOfflineIsCheckConnectionNotRetry() {
        // Every consumer maps `AnalysisEvent.offline` to this thrown error.
        let offlineRecovery = ConsumerErrorCopy.message(
            for: TonoBackendError.offline, action: .coachDraft
        )
        // What the pre-fix path produced: an offline URLError stringified into
        // `.error(msg)`, re-wrapped by a consumer as a backend error.
        let oldCollapse = ConsumerErrorCopy.message(
            for: ToneEngineError.backend("The Internet connection appears to be offline."),
            action: .coachDraft
        )

        XCTAssertTrue(
            offlineRecovery.contains("Check your connection"),
            "offline must guide the user to their connection: \(offlineRecovery)"
        )
        XCTAssertNotEqual(
            offlineRecovery, oldCollapse,
            "the streamed-offline fix must change the sentence, not just its route"
        )
    }

    /// The offline recovery agrees with the transport-level URLError recovery,
    /// so the streaming and non-streaming surfaces say the same thing offline.
    func testStreamedOfflineAgreesWithTransportOffline() {
        for action in [ConsumerErrorCopy.Action.coachDraft, .readMessage] {
            let viaBackend = ConsumerErrorCopy.message(for: TonoBackendError.offline, action: action)
            let viaURLError = ConsumerErrorCopy.message(for: URLError(.notConnectedToInternet), action: action)
            XCTAssertEqual(
                viaBackend, viaURLError,
                "the streamed-offline and transport-offline sentences must match"
            )
        }
    }
}

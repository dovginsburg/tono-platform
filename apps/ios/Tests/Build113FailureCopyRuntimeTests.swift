// Build113FailureCopyRuntimeTests.swift
// Tono build 113 — the failure-copy contract, executed rather than read.
//
// The Build 112 contract is a source scanner. It proved that no shipped
// surface *writes* a raw failure onto a screen, and an independent QA pass
// then showed the obvious limit of that: a lexical rule can only ban the
// shapes someone thought of. Three probes walked straight through it
// (`(error as NSError).localizedFailureReason`, an aliased
// `let cause = error` interpolated into a literal, and a closure that read
// `ns.domain`), and — more fundamentally — nothing anywhere executed
// `ConsumerErrorCopy` at all. Every assertion about the mapper was an
// assertion about its *literals*, not its *output*.
//
// This file closes that. It calls the mapper for real, with errors built to
// be as hostile as a transport can make them: host names, bearer tokens,
// SQL, file paths and stack frames stuffed into every slot Foundation offers
// a error to carry text in — `localizedDescription`, `errorDescription`,
// `failureReason`, `recoverySuggestion`, and `userInfo`. Then it asserts on
// what a user would actually read.
//
// The property under test is not "the mapper is careful". It is that the
// mapper *cannot* leak, because it never consults the payload at all: an
// error type it has never seen, carrying nothing but hostile text, still
// produces one of the reviewed sentences.

import XCTest
@testable import Tono

final class Build113FailureCopyRuntimeTests: XCTestCase {

    // MARK: - Hostile inputs

    /// Every distinctive token below is something a transport could
    /// plausibly put in a failure and a user must never read.
    private static let payloadTokens = [
        "db-primary.tono.internal",
        "api.tonoit.com",
        "Bearer eyJhbGciOiJIUzI1NiJ9",
        "password=hunter2",
        "/var/app/server.py",
        "SELECT * FROM users",
        "NSURLErrorDomain",
        "com.tono.secret",
        "Server error",
        "status 500",
        "0x00007ff8",
    ]

    private static var hostilePayload: String {
        payloadTokens.joined(separator: " | ")
    }

    /// An error the mapper has never heard of, which answers every Foundation
    /// question with the payload. If the mapper consults any of these, this
    /// file fails.
    private struct HostileError: LocalizedError, CustomStringConvertible, CustomDebugStringConvertible {
        var errorDescription: String? { Build113FailureCopyRuntimeTests.hostilePayload }
        var failureReason: String? { Build113FailureCopyRuntimeTests.hostilePayload }
        var recoverySuggestion: String? { Build113FailureCopyRuntimeTests.hostilePayload }
        var helpAnchor: String? { Build113FailureCopyRuntimeTests.hostilePayload }
        var description: String { Build113FailureCopyRuntimeTests.hostilePayload }
        var debugDescription: String { Build113FailureCopyRuntimeTests.hostilePayload }
    }

    private static var hostileNSError: NSError {
        NSError(
            domain: "com.tono.secret",
            code: 500,
            userInfo: [
                NSLocalizedDescriptionKey: hostilePayload,
                NSLocalizedFailureReasonErrorKey: hostilePayload,
                NSLocalizedRecoverySuggestionErrorKey: hostilePayload,
            ]
        )
    }

    /// The full cross-product the mapper has to survive.
    private static var hostileErrors: [(label: String, error: Error)] {
        [
            ("HostileError", HostileError()),
            ("NSError", hostileNSError),
            ("backend.http(500)", TonoBackendError.http(500, hostilePayload)),
            ("backend.http(401)", TonoBackendError.http(401, hostilePayload)),
            ("backend.http(402)", TonoBackendError.http(402, hostilePayload)),
            ("backend.http(429)", TonoBackendError.http(429, hostilePayload)),
            ("backend.http(-1)", TonoBackendError.http(-1, hostilePayload)),
            ("backend.network", TonoBackendError.network(hostilePayload)),
            ("backend.decoding", TonoBackendError.decoding(hostilePayload)),
            ("backend.offline", TonoBackendError.offline),
            ("backend.notRegistered", TonoBackendError.notRegistered),
            ("backend.tooManyDevices", TonoBackendError.tooManyDevices(current: 3, max: 2)),
            ("engine.backend", ToneEngineError.backend(hostilePayload)),
            ("engine.network", ToneEngineError.network(hostilePayload)),
            ("engine.decoding", ToneEngineError.decoding(hostilePayload)),
            ("engine.noAPIKey", ToneEngineError.noAPIKey),
            ("streamed.http(401)", StreamedFailure.http(status: 401)),
            ("streamed.http(402)", StreamedFailure.http(status: 402)),
            ("streamed.http(429)", StreamedFailure.http(status: 429)),
            ("streamed.http(500)", StreamedFailure.http(status: 500)),
            ("store.failedVerification", StoreKitManager.StoreError.failedVerification),
            ("store.missingAccountToken", StoreKitManager.StoreError.missingAccountToken),
            ("store.needsIdentifiedAccount", StoreKitManager.StoreError.needsIdentifiedAccount),
            ("urlError.offline", URLError(.notConnectedToInternet)),
            ("urlError.badServerResponse", URLError(.badServerResponse)),
        ]
    }

    private static let actions: [(label: String, action: ConsumerErrorCopy.Action)] = [
        ("coachDraft", .coachDraft),
        ("readMessage", .readMessage),
        ("weeklySummary", .weeklySummary),
        ("purchase", .purchase),
        ("restore", .restore),
        ("insertRewrite", .insertRewrite),
    ]

    // MARK: - The output contract

    /// Not one token of a hostile payload survives into rendered copy — for
    /// any error, under any action.
    ///
    /// This is the assertion the source scanner structurally could not make.
    /// `HostileError` and the raw `NSError` matter most: the mapper has no
    /// case for either, so they exercise the fall-through, and both answer
    /// every Foundation text accessor with the payload. A mapper that
    /// consulted `localizedDescription` even once — in a `default:`, in a log
    /// line that got interpolated, in a future edit — fails here.
    func testNoHostilePayloadTokenSurvivesIntoRenderedCopy() {
        for (errorLabel, error) in Self.hostileErrors {
            for (actionLabel, action) in Self.actions {
                let rendered = ConsumerErrorCopy.message(for: error, action: action)
                for token in Self.payloadTokens {
                    XCTAssertFalse(
                        rendered.localizedCaseInsensitiveContains(token),
                        "\(errorLabel) + \(actionLabel) leaked “\(token)”: \(rendered)"
                    )
                }
                XCTAssertFalse(
                    rendered.isEmpty,
                    "\(errorLabel) + \(actionLabel) rendered nothing at all"
                )
            }
        }
    }

    /// Every sentence the mapper can produce is one somebody reviewed.
    ///
    /// The source contract pins the mapper's *literals*. This pins its
    /// *compositions* — the thing a user actually reads — so a new branch
    /// that assembles reviewed fragments into an unreviewed sentence is
    /// caught too.
    func testEveryProducedSentenceIsReviewed() {
        let headlines = [
            "Couldn't coach this draft.",
            "Couldn't read this message.",
            "Couldn't load your weekly summary.",
            "Purchase couldn't be completed.",
            "Restore couldn't be completed.",
            "Couldn't add the rewrite to your message.",
        ]
        let nextSteps = [
            "Try again.",
            "Check your connection and try again.",
            "Open Tono and sign in again.",
            "Open Tono once to finish setting up, then try again.",
            "An active trial or subscription is required. Open Tono to continue.",
            "Wait a minute and try again.",
            "Sign in with your email first so your subscription follows you if you reinstall.",
            "Try again, and contact support@tonoit.com if it keeps happening.",
        ]
        var reviewed = Set<String>()
        for headline in headlines {
            for nextStep in nextSteps {
                reviewed.insert(headline + " " + nextStep)
            }
        }
        // The one composition that deliberately replaces the pair, because
        // the count is the whole point of the message.
        reviewed.insert(
            "This email is already on 3 devices (max 2). Contact support if you need more."
        )

        for (errorLabel, error) in Self.hostileErrors {
            for (actionLabel, action) in Self.actions {
                let rendered = ConsumerErrorCopy.message(for: error, action: action)
                XCTAssertTrue(
                    reviewed.contains(rendered),
                    "\(errorLabel) + \(actionLabel) produced an unreviewed sentence: \(rendered)"
                )
            }
        }
    }

    /// No produced sentence names an implementation detail, whatever the
    /// transport put in the failure.
    func testNoProducedSentenceNamesImplementationDetail() {
        let forbiddenTerms = [
            "backend", "server", "endpoint", "api key", "bearer", "auth token",
            "provider", "proxy", "llm", "transport", "non-2xx", "staging",
            "userdefaults", "app group", "://", "http",
        ]
        let forbiddenWords = ["url", "urls", "token", "tokens", "endpoint", "endpoints"]

        for (errorLabel, error) in Self.hostileErrors {
            for (actionLabel, action) in Self.actions {
                let rendered = ConsumerErrorCopy.message(for: error, action: action).lowercased()
                for term in forbiddenTerms {
                    XCTAssertFalse(
                        rendered.contains(term),
                        "\(errorLabel) + \(actionLabel) says “\(term)”: \(rendered)"
                    )
                }
                for word in forbiddenWords {
                    let hit = rendered
                        .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                        .contains(Substring(word))
                    XCTAssertFalse(
                        hit,
                        "\(errorLabel) + \(actionLabel) says “\(word)”: \(rendered)"
                    )
                }
                // No digits at all except the device-count message, which is
                // about numbers by design. A status code reaching copy would
                // show up here even if it were phrased in words we did not ban.
                if !rendered.contains("devices") {
                    XCTAssertFalse(
                        rendered.contains(where: \.isNumber),
                        "\(errorLabel) + \(actionLabel) put a number in copy: \(rendered)"
                    )
                }
            }
        }
    }

    // MARK: - The distinctions that must survive

    /// 401, 402 and 429 lead to three different next steps, and 429 never
    /// says a subscription is required.
    ///
    /// This is the runtime half of the Build 113 truthfulness repair: the
    /// source contract pins the two Coach surfaces that map a status by hand,
    /// and this pins the mapper every other surface routes through.
    func testStatusClassesKeepTheirDistinctNextSteps() {
        for action in Self.actions.map(\.action) {
            let signIn = ConsumerErrorCopy.message(
                for: TonoBackendError.http(401, Self.hostilePayload), action: action
            )
            let gated = ConsumerErrorCopy.message(
                for: TonoBackendError.http(402, Self.hostilePayload), action: action
            )
            let limited = ConsumerErrorCopy.message(
                for: TonoBackendError.http(429, Self.hostilePayload), action: action
            )
            let generic = ConsumerErrorCopy.message(
                for: TonoBackendError.http(500, Self.hostilePayload), action: action
            )

            XCTAssertEqual(Set([signIn, gated, limited, generic]).count, 4,
                           "401, 402, 429 and 500 must not collapse into one another")

            XCTAssertTrue(signIn.contains("sign in again"), signIn)
            XCTAssertTrue(gated.contains("subscription is required"), gated)
            XCTAssertTrue(limited.contains("Wait a minute"), limited)

            for word in ["subscription", "subscribe", "trial"] {
                XCTAssertFalse(
                    limited.localizedCaseInsensitiveContains(word),
                    "a rate-limited user was told to \(word): \(limited)"
                )
            }
        }
    }

    /// The streaming path and the non-streaming path answer the same status
    /// with the same sentence.
    ///
    /// This is the behavioural proof of the Build 113 streaming repair. Before
    /// it, `analyzeStream` stringified the code into `"Server error (402)"`,
    /// the consumers wrapped that into `ToneEngineError.backend`, and the
    /// mapper could only say "Try again." — so the keyboard strip and the
    /// Share sheet lost every distinction the host app kept. Equality here is
    /// exactly the property that was missing.
    func testStreamedStatusRendersIdenticallyToTheThrownStatus() {
        for status in [401, 402, 429, 500, 503, -1] {
            for (actionLabel, action) in Self.actions {
                let streamed = ConsumerErrorCopy.message(
                    for: StreamedFailure.http(status: status), action: action
                )
                let thrown = ConsumerErrorCopy.message(
                    for: TonoBackendError.http(status, Self.hostilePayload), action: action
                )
                XCTAssertEqual(
                    streamed, thrown,
                    "status \(status) + \(actionLabel): streaming and non-streaming disagree"
                )
            }
        }
    }

    /// A streamed 401 / 402 / 429 does not render as the generic retry — the
    /// exact symptom the independent QA pass named.
    func testStreamedActionableStatusesAreNotCollapsedIntoRetry() {
        for action in Self.actions.map(\.action) {
            let generic = ConsumerErrorCopy.message(
                for: StreamedFailure.http(status: 500), action: action
            )
            for status in [401, 402, 429] {
                let actionable = ConsumerErrorCopy.message(
                    for: StreamedFailure.http(status: status), action: action
                )
                XCTAssertNotEqual(
                    actionable, generic,
                    "streamed \(status) collapsed into the generic retry: \(actionable)"
                )
            }
        }
    }

    /// What the user was doing stays distinct from what they can do next.
    func testTheActionHeadlineIsAlwaysTheUsersOwnAction() {
        let expected: [(ConsumerErrorCopy.Action, String)] = [
            (.coachDraft, "Couldn't coach this draft."),
            (.readMessage, "Couldn't read this message."),
            (.weeklySummary, "Couldn't load your weekly summary."),
            (.purchase, "Purchase couldn't be completed."),
            (.restore, "Restore couldn't be completed."),
            (.insertRewrite, "Couldn't add the rewrite to your message."),
        ]
        for (action, headline) in expected {
            for (errorLabel, error) in Self.hostileErrors {
                // The device-count message deliberately replaces the pair.
                if case TonoBackendError.tooManyDevices = error { continue }
                let rendered = ConsumerErrorCopy.message(for: error, action: action)
                XCTAssertTrue(
                    rendered.hasPrefix(headline),
                    "\(errorLabel) lost the user's own action: \(rendered)"
                )
            }
        }
    }

    /// The device-count message keeps its two integers and nothing else.
    func testDeviceCountKeepsItsNumbersAndNoPayload() {
        for (_, action) in Self.actions {
            let rendered = ConsumerErrorCopy.message(
                for: TonoBackendError.tooManyDevices(current: 7, max: 4), action: action
            )
            XCTAssertEqual(
                rendered,
                "This email is already on 7 devices (max 4). Contact support if you need more."
            )
        }
    }

    /// Offline is distinguishable from a server that answered badly, on both
    /// error families that can express it.
    func testOfflineStaysDistinctFromAFailedRequest() {
        for action in Self.actions.map(\.action) {
            let offline = ConsumerErrorCopy.message(for: URLError(.notConnectedToInternet), action: action)
            let answered = ConsumerErrorCopy.message(for: URLError(.badServerResponse), action: action)
            XCTAssertTrue(offline.contains("Check your connection"), offline)
            XCTAssertNotEqual(offline, answered)

            let backendOffline = ConsumerErrorCopy.message(for: TonoBackendError.offline, action: action)
            XCTAssertEqual(backendOffline, offline, "the two offline families must agree")
        }
    }

    /// An error type the mapper has never seen falls through to the safe
    /// generic sentence rather than to anything derived from the error.
    func testUnknownErrorTypesFallThroughToTheGenericRetry() {
        for (label, action) in Self.actions {
            let hostile = ConsumerErrorCopy.message(for: HostileError(), action: action)
            let ns = ConsumerErrorCopy.message(for: Self.hostileNSError, action: action)
            let known = ConsumerErrorCopy.message(
                for: TonoBackendError.decoding(Self.hostilePayload), action: action
            )
            XCTAssertEqual(hostile, known, "\(label): unknown errors must use the reviewed retry")
            XCTAssertEqual(ns, known, "\(label): a raw NSError must use the reviewed retry")
        }
    }
}

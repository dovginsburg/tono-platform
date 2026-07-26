import XCTest

/// Block A — released-build-number guard.
///
/// The shipped build number is a reviewed release input, not mutable build
/// output. Every shipped bundle — App, KeyboardExtension, ShareExtension and
/// TonoMessagesExtension — must declare exactly the same `CFBundleVersion`
/// that `Scripts/bump-build.sh` pins as `EXPECTED_BUILD`. Past regressions
/// came from one of two drift patterns: shipping the four plists at the new
/// build while the archive guard stayed on the previous one, or vice versa.
/// Either way the Release build/full test run then aborted in the "Verify
/// Build Number" phase (xcodebuild exit 65, zero executed tests).
///
/// This contract reads the reviewed source of truth (the four `Info.plist`
/// files and the guard script) exactly as the build phase does. It is
/// compile-safe — pure Foundation, no keyboard/UIKit symbols — so on a base
/// where build numbers disagree it fails on the version values, never on a
/// syntax/type error.
final class BuildNumberGuardTests: XCTestCase {
    /// Read from `Scripts/bump-build.sh`, the SINGLE reviewed authority for the
    /// shipped build number, rather than hardcoding a fifth copy. Every release
    /// bump previously had to edit this constant too, and forgetting it turned
    /// the whole iOS suite red on an unrelated change. Deriving here keeps the
    /// real invariant — every shipped bundle agrees with the archive guard —
    /// while removing the drift.
    private static func expectedBuild(root: URL) throws -> String {
        let script = try String(
            contentsOf: root.appendingPathComponent("Scripts/bump-build.sh"),
            encoding: .utf8
        )
        let value = Self.value(ofAssignment: "EXPECTED_BUILD", in: script)
        let unwrapped = try XCTUnwrap(
            value, "Scripts/bump-build.sh must pin EXPECTED_BUILD — it is the release authority"
        )
        XCTAssertFalse(unwrapped.isEmpty, "EXPECTED_BUILD must not be empty")
        return unwrapped
    }

    private static let shippedPlists = [
        "App/Info.plist",
        "KeyboardExtension/Info.plist",
        "ShareExtension/Info.plist",
        "TonoMessagesExtension/Info.plist",
    ]

    /// `#filePath` is `<srcroot>/Tests/BuildNumberGuardTests.swift`; the SRCROOT
    /// the build phase uses is two directories up.
    private func sourceRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // <srcroot>/Tests
            .deletingLastPathComponent()   // <srcroot>
    }

    func testEveryShippedBundleDeclaresTheReviewedBuildNumber() throws {
        let root = sourceRoot()
        let expected = try Self.expectedBuild(root: root)
        for relative in Self.shippedPlists {
            let url = root.appendingPathComponent(relative)
            let data = try Data(contentsOf: url)
            let plist = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) as? [String: Any]
            let actual = plist?["CFBundleVersion"] as? String
            XCTAssertEqual(
                actual, expected,
                "\(relative) declares CFBundleVersion \(actual ?? "nil"); every shipped bundle must declare \(expected), the number Scripts/bump-build.sh pins"
            )
        }
    }

    /// The shipped `CFBundleVersion` must also be a STRING. App Store Connect
    /// rejects a numeric `CFBundleVersion`, and the failure only surfaces at
    /// upload — long after the archive is built.
    func testEveryShippedBundleDeclaresBuildNumberAsAString() throws {
        let root = sourceRoot()
        for relative in Self.shippedPlists {
            let data = try Data(contentsOf: root.appendingPathComponent(relative))
            let plist = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) as? [String: Any]
            XCTAssertTrue(
                plist?["CFBundleVersion"] is String,
                "\(relative) must declare CFBundleVersion as <string>; App Store Connect rejects a numeric build number"
            )
        }
    }

    func testArchiveGuardCoversEveryShippedBundle() throws {
        let root = sourceRoot()
        let script = try String(
            contentsOf: root.appendingPathComponent("Scripts/bump-build.sh"),
            encoding: .utf8
        )

        // The guard must still cover all four shipped bundles, so none can
        // silently drift off the reviewed build. (The number itself is no
        // longer duplicated here — it is read from this same script.)
        for relative in Self.shippedPlists {
            XCTAssertTrue(
                script.contains(relative),
                "Scripts/bump-build.sh must verify \(relative) so no shipped bundle drifts off the reviewed build"
            )
        }
    }

    private static func value(ofAssignment name: String, in script: String) -> String? {
        for rawLine in script.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("\(name)=") else { continue }
            let value = line.dropFirst(name.count + 1)
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        return nil
    }
}

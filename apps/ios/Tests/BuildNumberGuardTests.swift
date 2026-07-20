import XCTest

/// Blocker A — build-92 release-number guard.
///
/// The shipped build number is a reviewed release input, not mutable build
/// output. Every shipped bundle — App, KeyboardExtension, ShareExtension and
/// TonoMessagesExtension — must declare exactly `CFBundleVersion` 93, and the
/// `Scripts/bump-build.sh` archive guard must require the *same* number. The
/// rejected build-92 candidate moved all four plists to 92 but left the guard
/// pinned at 91; the Release build/full test run then aborted in the "Verify
/// Build Number" phase (xcodebuild exit 65, zero executed tests).
///
/// This contract reads the reviewed source of truth (the four `Info.plist`
/// files and the guard script) exactly as the build phase does. It is
/// compile-safe — pure Foundation, no keyboard/UIKit symbols — so on the
/// build-91 base it fails on the version values (91 ≠ 93), never on a
/// syntax/type error.
final class BuildNumberGuardTests: XCTestCase {
    private static let expectedBuild = "94"

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

    func testEveryShippedBundleDeclaresBuild92() throws {
        let root = sourceRoot()
        for relative in Self.shippedPlists {
            let url = root.appendingPathComponent(relative)
            let data = try Data(contentsOf: url)
            let plist = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) as? [String: Any]
            let actual = plist?["CFBundleVersion"] as? String
            XCTAssertEqual(
                actual, Self.expectedBuild,
                "\(relative) declares CFBundleVersion \(actual ?? "nil"); build 94 requires \(Self.expectedBuild) across every shipped bundle"
            )
        }
    }

    func testArchiveGuardRequiresTheSameBuild92AcrossEveryBundle() throws {
        let root = sourceRoot()
        let script = try String(
            contentsOf: root.appendingPathComponent("Scripts/bump-build.sh"),
            encoding: .utf8
        )

        // The guard's own expected number must be 93 so it agrees with the
        // shipped plists. This is the exact mismatch that failed the rejected
        // candidate (plists 92, guard 91 → exit 65, zero executed tests).
        let guardValue = Self.value(ofAssignment: "EXPECTED_BUILD", in: script)
        XCTAssertEqual(
            guardValue, Self.expectedBuild,
            "Scripts/bump-build.sh pins EXPECTED_BUILD=\(guardValue ?? "nil"); it must require \(Self.expectedBuild) so the archive guard agrees with the shipped plists"
        )

        // …and the guard must still cover all four shipped bundles so none can
        // silently drift off build 94.
        for relative in Self.shippedPlists {
            XCTAssertTrue(
                script.contains(relative),
                "Scripts/bump-build.sh must verify \(relative) so no shipped bundle can drift off build \(Self.expectedBuild)"
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

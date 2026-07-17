#!/usr/bin/env python3
"""Regression gate for Tono's embedded iMessage extension and release artifacts."""
from __future__ import annotations

import argparse
import json
import plistlib
import struct
import sys
import zipfile
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "Tono.xcodeproj/project.pbxproj"
ICONSET = ROOT / "TonoMessagesExtension/Assets.xcassets/iMessage App Icon.stickersiconset"
EXPECTED_MARKETING_VERSION = "1.1"
EXPECTED_BUILD_VERSION = "91"
EXPECTED_BUNDLE_ID = "com.tonoit.app.messages"
EXPECTED_TEAM = "4938S9TTBM"
EXPECTED_APP_GROUP = "group.com.tonoit.shared"
EXPECTED_KEYCHAIN_GROUP = f"{EXPECTED_TEAM}.{EXPECTED_APP_GROUP}"
BUNDLES = (
    "App/Info.plist",
    "KeyboardExtension/Info.plist",
    "ShareExtension/Info.plist",
    "TonoMessagesExtension/Info.plist",
)
EXPECTED_ICONS = {
    ("iphone", "29x29", "2x", None): (58, 58),
    ("iphone", "29x29", "3x", None): (87, 87),
    ("iphone", "60x45", "2x", None): (120, 90),
    ("iphone", "60x45", "3x", None): (180, 135),
    ("ipad", "29x29", "2x", None): (58, 58),
    ("ipad", "67x50", "2x", None): (134, 100),
    ("ipad", "74x55", "2x", None): (148, 110),
    ("universal", "27x20", "2x", "ios"): (54, 40),
    ("universal", "27x20", "3x", "ios"): (81, 60),
    ("universal", "32x24", "2x", "ios"): (64, 48),
    ("universal", "32x24", "3x", "ios"): (96, 72),
    ("ios-marketing", "1024x768", "1x", "ios"): (1024, 768),
}


def load_plist(path: Path) -> dict:
    with path.open("rb") as handle:
        return plistlib.load(handle)


def png_size(path: Path) -> tuple[int, int]:
    data = path.read_bytes()[:24]
    if len(data) != 24 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise ValueError(f"{path} is not a PNG")
    return struct.unpack(">II", data[16:24])


def check_source(errors: list[str]) -> None:
    project = PROJECT.read_text()
    required_project_markers = (
        "TonoMessagesExtension.appex in Embed Foundation Extensions",
        "TonoShare.appex in Embed Foundation Extensions */ = {isa = PBXBuildFile; fileRef = 1AEE8A1C65E51602F4AD7330 /* TonoShare.appex */; settings = {ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, )",
        "remoteGlobalIDString = E55677B30636D321CFE4401C;\n\t\t\tremoteInfo = TonoShare;",
        "ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, )",
        "target = 5E7AA4C8F391BA513B44CF06 /* TonoMessagesExtension */",
        'ASSETCATALOG_COMPILER_APPICON_NAME = "iMessage App Icon"',
        "Assets.xcassets in Resources",
        f"PRODUCT_BUNDLE_IDENTIFIER = {EXPECTED_BUNDLE_ID}",
        f"DEVELOPMENT_TEAM = {EXPECTED_TEAM}",
        'PROVISIONING_PROFILE_SPECIFIER = "ASC AppStore com.tonoit.app.messages"',
    )
    for marker in required_project_markers:
        if marker not in project:
            errors.append(f"project missing: {marker}")
    embed_start = project.find("2683EAB09F60A8B296EAAE4A /* Embed Foundation Extensions */")
    embed_end = project.find("/* End PBXCopyFilesBuildPhase section */", embed_start)
    embed = project[embed_start:embed_end]
    for product in ("TonoKeyboard.appex", "TonoShare.appex", "TonoMessagesExtension.appex"):
        if product not in embed:
            errors.append(f"embed phase missing {product}")
    share_embed = "TonoShare.appex in Embed Foundation Extensions"
    if share_embed in embed and "E6440EC45FF7489495E84BC6" not in embed:
        errors.append("embed phase does not reference the TonoShare build file")

    host_start = project.find("EBE86B011C11AB11A09CEBA7 /* Tono */ = {")
    host_end = project.find("/* End PBXNativeTarget section */", host_start)
    host = project[host_start:host_end]
    if "E620E36CE284444D862FF350 /* PBXTargetDependency */" not in host:
        errors.append("Tono host target is missing the TonoShare dependency")
    share_dependency = project.find("E620E36CE284444D862FF350 /* PBXTargetDependency */ = {")
    share_dependency_end = project.find("};", share_dependency)
    dependency = project[share_dependency:share_dependency_end]
    if "target = E55677B30636D321CFE4401C /* TonoShare */" not in dependency:
        errors.append("TonoShare target dependency is invalid")
    if "targetProxy = 9C48D8BAF5FA4A5490685907 /* PBXContainerItemProxy */" not in dependency:
        errors.append("TonoShare target dependency proxy is invalid")

    versions: set[tuple[type, object, type, object]] = set()
    for relative in BUNDLES:
        plist = load_plist(ROOT / relative)
        versions.add(
            (
                type(plist.get("CFBundleShortVersionString")),
                plist.get("CFBundleShortVersionString"),
                type(plist.get("CFBundleVersion")),
                plist.get("CFBundleVersion"),
            )
        )
    expected_versions = {(str, EXPECTED_MARKETING_VERSION, str, EXPECTED_BUILD_VERSION)}
    if versions != expected_versions:
        errors.append(f"source bundle version drift: {versions!r}")

    info = load_plist(ROOT / "TonoMessagesExtension/Info.plist")
    extension = info.get("NSExtension", {})
    if extension.get("NSExtensionPointIdentifier") != "com.apple.message-payload-provider":
        errors.append("Messages extension point identifier is invalid")
    if extension.get("NSExtensionPrincipalClass") != "$(PRODUCT_MODULE_NAME).MessagesViewController":
        errors.append("Messages principal class is invalid")
    if extension.get("NSExtensionAttributes", {}).get("MSMessagesAppPresentationContextMessages") is not True:
        errors.append("Messages presentation context metadata is missing")
    if info.get("MSMessagesExtensionStoreIconName") != "iMessage App Icon":
        errors.append("MSMessagesExtensionStoreIconName does not name the compiled icon set")
    if info.get("CFBundleIconName") != "iMessage App Icon":
        errors.append("CFBundleIconName does not name the compiled icon set")

    entitlements = load_plist(ROOT / "TonoMessagesExtension/TonoMessagesExtension.entitlements")
    if entitlements.get("application-identifier") != f"{EXPECTED_TEAM}.{EXPECTED_BUNDLE_ID}":
        errors.append("Messages application-identifier/team is invalid")
    if entitlements.get("com.apple.security.application-groups") != [EXPECTED_APP_GROUP]:
        errors.append("Messages App Group entitlement is invalid")
    if entitlements.get("keychain-access-groups") != [EXPECTED_KEYCHAIN_GROUP]:
        errors.append("Messages keychain group entitlement is invalid")

    catalog = json.loads((ICONSET / "Contents.json").read_text())
    actual: dict[tuple[str, str, str, str | None], tuple[int, int]] = {}
    for image in catalog.get("images", []):
        slot = (image.get("idiom"), image.get("size"), image.get("scale"), image.get("platform"))
        filename = image.get("filename")
        if not filename:
            errors.append(f"icon slot has no filename: {slot}")
            continue
        path = ICONSET / filename
        if not path.is_file():
            errors.append(f"icon file missing: {filename}")
            continue
        try:
            actual[slot] = png_size(path)
        except ValueError as exc:
            errors.append(str(exc))
    if set(actual) != set(EXPECTED_ICONS):
        errors.append(f"iMessage icon slots differ: missing={set(EXPECTED_ICONS) - set(actual)}, extra={set(actual) - set(EXPECTED_ICONS)}")
    for slot, expected_size in EXPECTED_ICONS.items():
        if slot in actual and actual[slot] != expected_size:
            errors.append(f"icon {slot} is {actual[slot]}, expected {expected_size}")

    bump = (ROOT / "Scripts/bump-build.sh").read_text()
    if f"EXPECTED_BUILD={EXPECTED_BUILD_VERSION}" not in bump:
        errors.append("build-number gate is not pinned to the corrective build")
    if "PlistBuddy -c \"Set" in bump or "PlistBuddy -c \"Add" in bump:
        errors.append("build-number gate mutates bundle metadata")


def check_built_bundle(app: Path, label: str, errors: list[str]) -> None:
    plugins = app / "PlugIns"
    expected = ("TonoKeyboard.appex", "TonoShare.appex", "TonoMessagesExtension.appex")
    for name in expected:
        if not (plugins / name).is_dir():
            errors.append(f"{label} missing PlugIns/{name}")
    plists = [app / "Info.plist"] + [plugins / name / "Info.plist" for name in expected]
    versions = set()
    for path in plists:
        if not path.is_file():
            continue
        plist = load_plist(path)
        versions.add((type(plist.get("CFBundleShortVersionString")), plist.get("CFBundleShortVersionString"), type(plist.get("CFBundleVersion")), plist.get("CFBundleVersion")))
    if versions != {(str, EXPECTED_MARKETING_VERSION, str, EXPECTED_BUILD_VERSION)}:
        errors.append(f"{label} built bundle version drift: {versions!r}")
    messages_info = plugins / "TonoMessagesExtension.appex/Info.plist"
    if messages_info.is_file() and load_plist(messages_info).get("CFBundleIdentifier") != EXPECTED_BUNDLE_ID:
        errors.append(f"{label} Messages bundle identifier is invalid")


def check_archive(path: Path, errors: list[str]) -> None:
    apps = list((path / "Products/Applications").glob("*.app"))
    if len(apps) != 1:
        errors.append(f"archive must contain exactly one host app, found {len(apps)}")
        return
    check_built_bundle(apps[0], "archive", errors)


def check_ipa(path: Path, errors: list[str]) -> None:
    with zipfile.ZipFile(path) as archive:
        app_roots = sorted({PurePosixPath(name).parts[:2] for name in archive.namelist() if name.startswith("Payload/") and name.endswith(".app/Info.plist")})
        if len(app_roots) != 1:
            errors.append(f"IPA must contain exactly one host app, found {len(app_roots)}")
            return
        root = PurePosixPath(*app_roots[0])
        expected = ("TonoKeyboard.appex", "TonoShare.appex", "TonoMessagesExtension.appex")
        versions = set()
        for relative in ("Info.plist", *(f"PlugIns/{name}/Info.plist" for name in expected)):
            member = str(root / relative)
            try:
                plist = plistlib.loads(archive.read(member))
            except KeyError:
                errors.append(f"IPA missing {relative}")
                continue
            versions.add((type(plist.get("CFBundleShortVersionString")), plist.get("CFBundleShortVersionString"), type(plist.get("CFBundleVersion")), plist.get("CFBundleVersion")))
            if relative.endswith("TonoMessagesExtension.appex/Info.plist") and plist.get("CFBundleIdentifier") != EXPECTED_BUNDLE_ID:
                errors.append("IPA Messages bundle identifier is invalid")
        if versions != {(str, EXPECTED_MARKETING_VERSION, str, EXPECTED_BUILD_VERSION)}:
            errors.append(f"IPA built bundle version drift: {versions!r}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--ipa", type=Path)
    args = parser.parse_args()
    errors: list[str] = []
    check_source(errors)
    if args.archive:
        check_archive(args.archive, errors)
    if args.ipa:
        check_ipa(args.ipa, errors)
    if errors:
        print("\n".join(f"FAIL: {error}" for error in errors))
        return 1
    scopes = ["source"] + (["archive"] if args.archive else []) + (["ipa"] if args.ipa else [])
    print(f"PASS: Messages extension verification ({', '.join(scopes)}; build {EXPECTED_BUILD_VERSION})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

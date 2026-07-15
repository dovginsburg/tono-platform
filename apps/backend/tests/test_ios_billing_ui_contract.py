"""Source-level regressions for shipping billing configuration and UI copy."""

import hashlib
import importlib.util
import json
import re
from pathlib import Path


IOS = Path(__file__).resolve().parents[2] / "ios"
ANDROID = Path(__file__).resolve().parents[2] / "android"
WEB = Path(__file__).resolve().parents[2] / "web"
BACKEND = Path(__file__).resolve().parents[1]

detector_spec = importlib.util.spec_from_file_location(
    "retired_quota_detector",
    BACKEND / "retired_quota_detector.py",
)
assert detector_spec and detector_spec.loader
detector_module = importlib.util.module_from_spec(detector_spec)
detector_spec.loader.exec_module(detector_module)
_retired_quota_claims = detector_module.retired_quota_claims

APPROVED_BINARY_METADATA_SHA256 = {
    "apps/android/fastlane/metadata/android/en-US/featureGraphic.png":
        "6e0aea6fca31341240ec3387702b4bf2bb809173e932e8e3880e805ba3e46a99",
    "apps/android/fastlane/metadata/android/en-US/phoneScreenshots/1.png":
        "7c8a901da2be60a6b806e1e2e65131142528170dfab1ae25251855ba6b22ede4",
}


def _source(relative: str) -> str:
    return (IOS / relative).read_text(encoding="utf-8")


def _shipping_sources() -> dict[str, str]:
    paths = [
        *(
            path
            for path in IOS.rglob("*.swift")
            if "Tests" not in path.parts
            and not path.name.endswith("Tests.swift")
            and not path.name.startswith("verify_build")
        ),
        *(
            path
            for path in ANDROID.rglob("*.kt")
            if "src" in path.parts
            and "main" in path.parts
            and "build" not in path.parts
        ),
        *(
            path
            for path in BACKEND.glob("*.py")
            if not path.name.startswith("test_")
            and path.name != "retired_quota_detector.py"
        ),
        *(
            path
            for extension in ("*.ts", "*.tsx")
            for path in WEB.glob(f"src/**/*{extension[1:]}")
            if not path.name.endswith((".test.ts", ".test.tsx", ".d.ts"))
        ),
        *(path for path in IOS.glob("fastlane/metadata/**/*") if path.is_file()),
        *(path for path in ANDROID.glob("fastlane/metadata/**/*") if path.is_file()),
    ]
    repo = BACKEND.parents[1]
    return {
        str(path.relative_to(repo)): path.read_text(encoding="utf-8", errors="ignore")
        for path in sorted(paths)
    }


def test_active_ios_surfaces_do_not_expose_retired_free_plan_copy():
    sources = "\n".join(
        _source(path)
        for path in (
            "App/SettingsView.swift",
            "App/HomeView.swift",
            "App/CoachView.swift",
            "KeyboardExtension/KeyboardRootView.swift",
            "KeyboardExtension/TonoCoachClient.swift",
            "Shared/TonoBackend.swift",
        )
    )

    for retired_copy in (
        'Text(u.isPro ? "Pro" : "Free")',
        '"Pro ✓" : "Free"',
        "Free ·",
        "Free: 3",
        "Unlimited rewrites (Free is 3/day)",
        "no card required",
        "No credit card, no trial",
        "Daily free limit",
    ):
        assert retired_copy not in sources


def test_shipping_surfaces_do_not_expose_retired_quota_claims():
    shipping_sources = _shipping_sources()
    claims = {
        path: found
        for path, source in shipping_sources.items()
        if (found := _retired_quota_claims(source))
    }
    assert not claims, claims
    assert not {
        path: "open tono to upgrade"
        for path, source in shipping_sources.items()
        if "open tono to upgrade" in source.lower()
    }


def test_shipping_source_discovery_covers_active_platform_trees():
    paths = set(_shipping_sources())
    assert {
        "apps/backend/server.py",
        "apps/backend/store.py",
        "apps/web/src/app/app/editor-client.tsx",
        "apps/web/src/app/layout.tsx",
        "apps/ios/fastlane/metadata/en-US/description.txt",
        "apps/ios/fastlane/metadata/en-US/release_notes.txt",
        "apps/ios/App/HomeView.swift",
        "apps/ios/App/SettingsView.swift",
        "apps/ios/KeyboardExtension/KeyboardRootView.swift",
        "apps/android/fastlane/metadata/android/en-US/full_description.txt",
        "apps/android/fastlane/metadata/android/en-US/featureGraphic.png",
        "apps/android/fastlane/metadata/android/en-US/phoneScreenshots/1.png",
        "apps/android/app/src/main/java/com/tono/app/ui/HomeScreen.kt",
        "apps/android/ime/src/main/java/com/tono/ime/CoachViewModel.kt",
        "apps/android/shared/src/main/java/com/tono/shared/network/TonoBackend.kt",
    } <= paths


def test_production_binary_metadata_matches_independently_reviewed_copy():
    repo = BACKEND.parents[1]
    actual = {
        path: hashlib.sha256((repo / path).read_bytes()).hexdigest()
        for path in APPROVED_BINARY_METADATA_SHA256
    }

    assert actual == APPROVED_BINARY_METADATA_SHA256


def test_retired_quota_claim_detector_rejects_semantic_equivalents():
    hostile_copy = (
        "Every day, free users get ten rewrites.",
        "Each day includes 10 complimentary coaching requests.",
        "Your ten free rewrites reset at midnight.",
        "Get ten included rewrites every 24 hours.",
        "Free members can coach ten messages each morning.",
        "Ten rewrites are available per day on the free tier.",
        "Free users get ten rewrites. The allowance resets every day.",
        "The free allowance is ten rewrites; it refreshes each morning.",
        "Free members can rewrite ten messages before access renews tomorrow.",
        "Free users get ten rewrites. Your allowance renews. This happens every day.",
        "Each free account includes ten rewrites\nThe allowance refreshes\nEvery morning",
        "Ten complimentary coaching requests; the allowance renews; every 24 hours.",
        "A free account receives ten rewrites. Those credits replenish. That cycle repeats. Once per day.",
        "Ten coaching requests come included; after they are used, the allowance returns; the next morning.",
        "Free members can rewrite 10 messages; their quota comes back; on a 24-hour cadence.",
        "A free user's allowance is 10/day for coaching requests.",
    )

    for copy in hostile_copy:
        assert _retired_quota_claims(copy), copy


def test_retired_quota_claim_detector_handles_fresh_adversarial_copy():
    hostile_copy = (
        "No-cost members receive 10 rewrites. Their balance is restored. Each day.",
        "People who pay nothing may revise ten messages\nTheir allotment reloads\nEvery day",
        "Ten coaching turns; the no-charge plan; every 24 hours.",
        "At no cost, ten rewrites / day are available.",
        "The free plan provides 10 rewrites/24h.",
        "At midnight. Their balance reappears. Members receive ten rewrites. They pay nothing.",
        "Gratis members may rephrase ten drafts; their allowance reloads at dawn.",
        "Zero-price accounts receive ten edits, replenished at sunrise.",
        "On-the-house members get ten tune-ups day-by-day.",
        "Nonpaying members get a decuple of rewrites nightly.",
        "Without paying, members may polish ten drafts; access renews at 00:00.",
        "Complimentary accounts receive ten text improvements every twenty-four-hour cycle.",
    )

    for copy in hostile_copy:
        assert _retired_quota_claims(copy), copy


def test_retired_quota_claim_detector_handles_ordinary_allocation_copy():
    hostile_copy = (
        "Every calendar day comes with ten complimentary edits.",
        "Each UTC day, no-cost accounts receive ten rewrites.",
        "Unpaid members receive 10 revisions every day.",
        "The complimentary plan permits ten rewrite requests per calendar day.",
        "Ten gratis edits are restored on each new calendar day.",
        "Each unpaid user is granted ten edits per calendar day.",
        "Every day, ten complimentary revisions are allotted to each account.",
        "A daily bundle of ten gratis edits is assigned to users.",
        "Each calendar day, the system grants users ten complimentary coaching turns.",
        "The service allocates ten complimentary rewrites to members each day.",
    )

    for copy in hostile_copy:
        assert _retired_quota_claims(copy), copy


def test_retired_quota_claim_detector_binds_allocation_semantics():
    hostile_copy = (
        "Every day, complimentary members are allotted ten coaching requests.",
        "Complimentary members, every day, are granted ten edits.",
        "Each morning, unpaid users get assigned ten revisions.",
        "No-cost users have ten rewrites allocated to them each day.",
        "The service grants, to unpaid users, ten rewrites every day.",
        "The service assigns ten edits each day to complimentary accounts.",
        "Ten rewrites per day are allocated among complimentary members.",
        "Complimentary members are allotted, on each day, ten rewrites.",
        "Complimentary members receive, per day, ten rewrites.",
        "Ten daily rewrites go to unpaid users.",
        "Ten complimentary edits\nare assigned to unpaid users\nevery morning.",
        "For complimentary users, the daily grant is ten coaching turns.",
    )
    benign_copy = (
        "Every day complimentary members are granted awards; ten edits describe the ceremony.",
        "The service grants users awards. Ten complimentary revisions document the ceremony each day.",
        "Every day, ten complimentary edits mention users allocated to the beta cohort.",
        "Ten complimentary revisions are published daily. Awards are allotted to free members.",
        "The system assigns users badges each day; ten complimentary edits explain badge colors.",
        "The daily grant report names ten complimentary editors and unpaid users.",
        "Unpaid users receive awards each day; ten revisions remain in the style guide.",
        "Each morning, Pro users get assigned ten revisions.",
    )

    for copy in hostile_copy:
        assert _retired_quota_claims(copy), copy
    for copy in benign_copy:
        assert not _retired_quota_claims(copy), copy


def test_retired_quota_claim_detector_binds_fresh_allocation_relations():
    hostile_copy = (
        "Gratis accounts have, each morning, an allotment of ten revisions.",
        "Every morning, ten rewrites are set aside for no-cost members.",
        "Unpaid users are entitled to ten revisions each day.",
        "Ten revisions accrue to free members every day.",
        "At dawn, the gratis tier carries an allowance of ten rewrites.",
        "Complimentary members' allotment: ten rewrites per day.",
    )
    benign_copy = (
        "Each day, unpaid users review ten edits allocated to paid subscribers.",
        "Ten edits are allocated daily to Pro users; complimentary members read the report.",
        "Free users receive badges daily, and ten edits explain them.",
        "Ten daily coaching requests are allocated to paid members, while free users get documentation.",
        "Free members can read ten coaching articles every day.",
    )

    missing = [copy for copy in hostile_copy if not _retired_quota_claims(copy)]
    false_positives = [copy for copy in benign_copy if _retired_quota_claims(copy)]

    assert not missing, missing
    assert not false_positives, false_positives


def test_retired_quota_claim_detector_handles_nominal_and_reordered_allocations():
    hostile_copy = (
        "Allocated each dawn to unpaid members are ten revisions.",
        "A daily entitlement of ten rewrites belongs to complimentary accounts.",
        "The revision allotment for unpaid accounts is ten every morning.",
        "Every day brings the free tier an allowance of ten edits.",
        "Ten edits constitute complimentary members' allowance each day.",
        "To gratis users accrue ten edits at every sunrise.",
        "Ten rewrites are reserved for no-cost members every morning.",
        "Each day, ten revisions are earmarked for unpaid accounts.",
        "Ten daily edits are set apart for complimentary users.",
        "At sunrise, ten rewrites are credited to gratis members.",
    )

    for copy in hostile_copy:
        assert _retired_quota_claims(copy), copy


def test_retired_quota_claim_detector_handles_reviewed_nominal_relations():
    hostile_copy = (
        "Subscribers get unlimited polish requests; whereas unpaid users are allocated ten each night.",
        "Ten rewrites form the nightly allowance belonging to nonpaying accounts.",
        "For unpaid members, an allocation comprising ten revisions comes back each dawn.",
        "A grant of ten text improvements is owned by complimentary accounts and replenishes nightly.",
        "No-cost accounts are the beneficiaries of ten rewrites; that allowance resets each day.",
        "Each day restores the ten-revision allocation held by gratis members.",
        "The ten-edit grant accruing to unpaid people renews every morning.",
        "No-cost people hold ten coaching turns. Their balance returns at sunrise.",
        "Zero-price users' daily allowance consists of ten text improvements; a neighboring blog updates each morning.",
    )

    for copy in hostile_copy:
        assert _retired_quota_claims(copy), copy


def test_retired_quota_claim_detector_closes_ownership_and_ellipsis_gaps():
    hostile_copy = (
        "The nightly ration owned by no-charge accounts consists of ten rewrites.",
        "Owned by unpaid members is an allowance of ten coaching requests, restored each sunrise.",
        "Ten tune-ups compose the daily entitlement of people paying nothing.",
        "An allotment held for gratis users contains ten text improvements and renews every morning.",
        "Every midnight reinstates an entitlement of ten edits whose owners are complimentary members.",
        "The beneficiaries of the ten-revision allowance are zero-price accounts; it returns nightly.",
        "The free members' allowance contains ten rewrites and is replenished each dawn.",
        "Ten edits make up the daily grant of nonpaying users.",
        "The allowance of accounts without paying is ten coaching turns, renewed every day.",
        "A ten-rewrite entitlement is the property of no-cost members and resets nightly.",
        "Complimentary users are owners of a ten-edit allotment that returns at sunrise.",
        "Paid members have uncapped text improvements. While no-cost users receive ten at dawn.",
        "Premium customers get unrestricted rewrites. Unlike them, complimentary users are credited ten daily.",
        "Complimentary accounts own ten revisions. Those credits return. The next cycle begins each morning.",
        "Nonpaying users get ten text improvements. That balance replenishes. It does so once per day.",
        "For unpaid members, ten coaching turns accrue nightly; premium members have no cap.",
        "Each sunrise restores an allotment of ten edits owned by nonpaying users.",
    )
    benign_copy = (
        "Assistants to free users receive ten rewrites daily.",
        "Neighbors of nonpaying members get ten coaching turns each sunrise.",
        "Supervisors of gratis accounts are allotted ten edits nightly.",
        "Guests of no-cost users receive ten revisions every morning.",
        "Partners of complimentary members hold ten text improvements per day.",
        "Advisers for unpaid people are granted ten tune-ups at dawn.",
    )

    missing = [copy for copy in hostile_copy if not _retired_quota_claims(copy)]
    false_positives = [copy for copy in benign_copy if _retired_quota_claims(copy)]

    assert not missing, missing
    assert not false_positives, false_positives


def test_retired_quota_claim_detector_rejects_relationship_scope_controls():
    benign_copy = (
        "Friends of free users receive ten edits daily.",
        "Managers of unpaid accounts get ten coaching turns each night.",
        "The children of complimentary users get ten text improvements nightly.",
    )

    for copy in benign_copy:
        assert not _retired_quota_claims(copy), copy


def test_retired_quota_claim_detector_rejects_service_modifiers_and_crossed_owners():
    benign_copy = (
        "Unpaid users are entitled to ten revision examples each day, all belonging to Pro customers.",
        "Free members receive ten coach badges daily.",
        "Free members get ten revision guides each day.",
        "Complimentary accounts receive ten edit receipts daily for purchases by Pro users.",
        "Every morning, no-cost users are entitled to ten polish samples from premium authors.",
    )

    for copy in benign_copy:
        assert not _retired_quota_claims(copy), copy


def test_retired_quota_claim_detector_binds_ownership_and_cadence_clause_locally():
    hostile_copy = (
        "Free users receive ten edits daily, while Pro users receive unlimited edits.",
        "Ten daily rewrites are earmarked for unpaid accounts, while premium members have no cap.",
        "Each dawn credits gratis members with ten revisions, unlike paid members.",
        "For no cost users, ten revisions are reserved. The allocation refreshes every morning.",
        "Ten rewrites belong to complimentary members. The balance resets at dawn.",
    )
    benign_copy = (
        "Ten rewrites are reserved for free users. The unrelated status dashboard refreshes daily.",
        "Free members receive ten revisions. The office opens at dawn.",
        "Ten edits are credited to Pro users daily, while the free tier is mentioned in the footer.",
    )

    missing = [copy for copy in hostile_copy if not _retired_quota_claims(copy)]
    false_positives = [copy for copy in benign_copy if _retired_quota_claims(copy)]

    assert not missing, missing
    assert not false_positives, false_positives


def test_retired_quota_claim_detector_closes_beyond_suite_grammar():
    hostile_copy = (
        "A ration consisting of ten rewrites is owned by complimentary accounts and renews every night.",
        "The allowance belonging to unpaid members contains ten edits and resets at dawn.",
        "Ten coaching turns are held by no-cost users; the allotment is restored daily.",
        "An entitlement containing ten revisions is possessed by gratis accounts and returns each sunrise.",
        "Nonpaying members' grant consists of ten rewrites; it renews every morning.",
        "The ten-edit ration is those complimentary users' property and replenishes nightly.",
        "Paid users receive limitless rewrites. By contrast, free users get ten each morning.",
        "Pro accounts have unlimited edits. Conversely, no-cost accounts are allotted ten nightly.",
        "The entitlement whose beneficiaries are unpaid accounts comprises ten coaching turns and resets daily.",
        "Ten rewrites form an allowance for gratis members; the balance returns at sunrise.",
        "Complimentary members own ten edits. This ration comes back. Its next issuance is at dawn.",
        "Unpaid users hold ten revisions. The entitlement renews. Afterward the cycle repeats every morning.",
        "Each night replenishes the ration of ten rewrites belonging to free accounts.",
        "Ten revisions owned by gratis users return at dawn, while Pro remains unlimited.",
        "At sunrise, the allowance of no-cost accounts is restored with its ten coaching turns.",
    )
    benign_copy = (
        "Colleagues of free users receive ten rewrites every morning.",
        "Counselors for unpaid members are granted ten coaching turns daily.",
        "Employers of gratis accounts hold ten edits nightly.",
        "Relatives of no-cost users get ten revisions at dawn.",
        "Representatives for complimentary users receive ten text improvements per day.",
        "Customers of unpaid advisers are allotted ten tune-ups each sunrise.",
        "Free users receive ten rewrite tutorials daily.",
        "Complimentary members get ten editing certificates every morning.",
        "Unpaid accounts hold ten coaching vouchers nightly.",
        "Free users own ten rewrites. The weather report updates every morning.",
        "Ten edits belong to no-cost accounts. Separately, payroll runs nightly.",
        "Gratis members hold ten coaching turns. The cafeteria opens at dawn.",
        "The dashboard refreshes nightly, while free accounts own ten rewrites.",
        "No-cost members hold ten coaching turns, while the unrelated office opens each dawn.",
        "Gratis users own ten edits; the documentation site updates every day.",
        "Ten daily rewrites belong to paid users; free members read the announcement.",
        "Premium accounts own ten edits renewed nightly, while unpaid users receive badges.",
        "Complimentary members receive ten badges. Those badges return to storage every morning.",
    )

    missing = [copy for copy in hostile_copy if not _retired_quota_claims(copy)]
    false_positives = [copy for copy in benign_copy if _retired_quota_claims(copy)]

    assert not missing, missing
    assert not false_positives, false_positives


def test_retired_quota_claim_detector_closes_fresh_grammar_and_discourse_gaps():
    hostile_copy = (
        "Complimentary accounts are the proprietors of an allowance comprising ten rewrites; replenishment occurs every morning.",
        "There belong to unpaid users ten coaching turns, restored at the beginning of each day.",
        "A balance of ten revisions rests in gratis accounts' possession and is renewed nightly.",
        "Ownership of the ten-edit allotment lies with no-cost members; each dawn restores it.",
        "Ten coaching turns make up an entitlement under nonpaying members' ownership; renewal is nightly.",
        "The designated recipients of an allotment containing ten edits are unpaid accounts; every morning replenishes it.",
        "An allowance comprising ten rewrites is for the benefit of free users and is renewed nightly.",
        "Ten revisions sit in a grant payable to gratis members; it resets each day.",
        "The party entitled to ten coaching turns is each no-cost account; restoration happens at dawn.",
        "Subscribers edit without restriction. Free accounts, however, receive ten when each day begins.",
        "Premium customers have boundless coaching turns; free users, by comparison, ten every morning.",
        "Paid members can rewrite indefinitely. The complimentary tier gets ten per day instead.",
        "Pro has no editing ceiling. As for unpaid accounts, ten are supplied nightly.",
        "Ten rewrites belong to free users, with the balance reconstituted when a new day opens.",
        "Every morning is when gratis accounts' ten-edit allotment becomes available again.",
        "Upon each day's commencement, no-cost members regain their ten coaching turns.",
        "Free accounts control a ten-rewrite balance. Exhaustion lasts only until dawn. Then the balance is refilled.",
        "Gratis users hold an allotment of ten edits. Once spent, it is dormant. The following morning restores the allotment.",
        "Ten coaching turns are assigned to unpaid users. Their consumption empties the grant. A new day supplies it again.",
        "No-cost members own ten revisions. That stock is consumed. At midnight the stock is recreated.",
    )
    benign_copy = (
        "Agents representing gratis members receive ten edits each day.",
        "Vendors serving complimentary accounts get ten text improvements daily.",
        "Researchers studying nonpaying people are allotted ten tune-ups each sunrise.",
    )

    missing = [copy for copy in hostile_copy if not _retired_quota_claims(copy)]
    false_positives = [copy for copy in benign_copy if _retired_quota_claims(copy)]

    assert not missing, missing
    assert not false_positives, false_positives


def test_retired_quota_claim_detector_binds_recurring_event_and_state_allocations():
    hostile_copy = (
        "For each unpaid account, dawn unlocks a package containing ten rewrites.",
        "Each complimentary account starts the day able to request ten edits.",
        "Ten revisions become usable by nonpaying users anew every sunrise.",
        "Free members' capacity to perform ten rewrites is restored daily.",
        "At daily rollover, unpaid accounts once more may make ten revisions.",
        "Gratis users are limited to ten text improvements, with the allowance renewed each morning.",
        "Every sunrise activates ten edits for anyone without a paid plan.",
        "Complimentary users begin each calendar date with ten available rewrites.",
        "After midnight, each free member can make ten more revisions.",
        "Every new morning restores permission for gratis users to polish ten drafts.",
    )
    benign_copy = (
        "Free users can buy a pack of ten edits; purchases are available daily.",
        "Ten rewrites donated by free users are published every morning.",
        "Complimentary users may view ten revision examples daily.",
        "Unpaid members get ten editing tips each day.",
        "Ten rewrites are available to free users for the one-day launch event.",
        "Free users won ten edits in yesterday's contest; contest results refresh daily.",
        "Ten edits belong to free users' saved history; backups run nightly.",
        "No-cost accounts compare ten rewrites while the dashboard refreshes each morning.",
        "Gratis members receive ten edit invoices every day from paid contractors.",
        "Each morning, free users read a report about ten coaching requests made by Pro users.",
        "The free-user handbook has ten revision chapters and is republished daily.",
        "Unpaid users tag ten rewrites; the tag index rebuilds at midnight.",
    )

    missing = [copy for copy in hostile_copy if not _retired_quota_claims(copy)]
    false_positives = [copy for copy in benign_copy if _retired_quota_claims(copy)]

    assert not missing, missing
    assert not false_positives, false_positives


def test_retired_quota_claim_detector_binds_recurring_capacity_semantics():
    hostile_copy = (
        "Dawn makes ten rewrites possible for each unpaid user.",
        "Unpaid accounts wake up to ten rewrites every morning.",
        "Every new day sees ten edits placed at the disposal of free members.",
        "When the date changes, a no-cost member's ability to revise ten messages returns.",
        "Nonpaying users may rewrite up to ten messages between midnights.",
        "A complimentary account can submit ten coaching requests before the next sunrise.",
        "The clock striking midnight re-enables ten edits for gratis users.",
        "Ten rewrite slots open for free members with every new day.",
        "Each morning leaves unpaid people with room for ten revisions.",
        "Every dawn confers upon nonpaying accounts the ability to polish ten drafts.",
        "For free users, ten editing opportunities materialize anew each day.",
        "The day's first moment resets free accounts to ten remaining rewrites.",
    )
    benign_copy = (
        "The guide says dawn makes ten rewrite examples possible for each unpaid user.",
        "Unpaid accounts wake up to ten rewrite tips every morning.",
        "Every new day sees ten edit reports placed at the disposal of free members.",
        "When the date changes, a no-cost member's ability to revise ten survey responses returns.",
        "Nonpaying users may rewrite up to ten tutorial examples between midnights.",
        "A complimentary account can submit ten coaching request receipts before the next sunrise.",
        "The clock striking midnight re-enables ten edit guides for gratis users.",
        "Ten rewrite certificate slots open for free members with every new day.",
        "Each morning leaves unpaid people with room for ten revision tutorials.",
        "Every dawn confers upon nonpaying accounts the ability to polish ten survey drafts.",
        "For free users, ten editing certificate opportunities materialize anew each day.",
        "The day's first moment resets free accounts to ten remaining rewrite examples.",
    )

    missing = [copy for copy in hostile_copy if not _retired_quota_claims(copy)]
    false_positives = [copy for copy in benign_copy if _retired_quota_claims(copy)]

    assert not missing, missing
    assert not false_positives, false_positives


def test_retired_quota_claim_detector_rejects_benign_contexts():
    benign_copy = (
        "Pro users get ten rewrites daily during the pilot.",
        "A premium subscription includes ten coaching turns every day.",
        "Paid users get ten included rewrites daily.",
        "Free-tier analytics track 10 coaching requests/day as an aggregate metric.",
        "During the historical migration, the retired free plan provided ten rewrites each day.",
        "No-cost members receive coaching, with no recurring quantity allocation.",
        "The free plan renews daily and includes coaching, but this copy states no quantity.",
        "Ten editors review free-form coaching copy daily.",
        "Ten editors review complimentary coaching copy every day.",
        "Ten complimentary editors coach members every calendar day.",
        "Every day, ten complimentary edits mention users who receive awards.",
        "Ten complimentary edits profile users who get notifications every day.",
    )

    for copy in benign_copy:
        assert not _retired_quota_claims(copy), copy


def test_android_improvement_metadata_matches_runtime_default():
    flags = (
        ANDROID
        / "shared/src/main/java/com/tono/shared/flags/FeatureFlags.kt"
    ).read_text(encoding="utf-8")
    false_defaults = re.search(
        r"defaultValue:\s*Boolean.*?when\s*\(this\)\s*\{(.*?)else\s*->\s*true",
        flags,
        re.DOTALL,
    )
    assert false_defaults
    improve_tono_defaults_on = "IMPROVE_TONO" not in false_defaults.group(1)
    assert improve_tono_defaults_on

    metadata = {
        path.name: path.read_text(encoding="utf-8").lower()
        for path in (
            ANDROID / "fastlane/metadata/android/en-US/privacy_policy.txt",
            ANDROID / "fastlane/metadata/android/en-US/full_description.txt",
        )
    }
    for name, copy in metadata.items():
        assert "on by default" in copy, name
        assert "opt-out" in copy or "opt out" in copy, name
        assert "off by default" not in copy, name
        assert "opt-in only" not in copy, name


def test_active_backend_copy_does_not_describe_the_retired_free_quota():
    store = _shipping_sources()["apps/backend/store.py"].lower()

    assert "daily free-tier counter" not in store
    assert "free user's 10/day" not in store


def test_home_plan_copy_matches_bundled_storekit_prices():
    home = _source("App/HomeView.swift")

    assert 'Text("Pro · $3.99/month or $39.99/year")' in home
    assert "$5.99/mo" not in home


def test_bundled_storekit_configuration_matches_live_products():
    config = json.loads(_source("App/Tono.storekit"))
    products = {
        product["productID"]: product
        for group in config["subscriptionGroups"]
        for product in group["subscriptions"]
    }

    assert set(products) == {
        "com.tonoit.pro.monthly",
        "com.tonoit.pro.yearly",
    }
    assert products["com.tonoit.pro.monthly"]["displayPrice"] == "3.99"
    assert products["com.tonoit.pro.yearly"]["displayPrice"] == "39.99"
    for product in products.values():
        assert product["introductoryOffer"]["paymentMode"] == "FREE_TRIAL"
        assert product["introductoryOffer"]["subscriptionPeriod"] == "P1W"


def test_paywall_never_renders_introductory_zero_price_as_the_plan_price():
    settings = _source("App/SettingsView.swift")

    assert "intro.displayPrice" not in settings
    assert "product.displayPrice" in settings
    assert "intro.paymentMode == .freeTrial" in settings
    assert "then auto-renews at \\(product.displayPrice) unless canceled" in settings


def test_settings_visible_labels_use_tone_without_renaming_storage_symbols():
    settings = _source("App/SettingsView.swift")

    assert 'Section("Tone")' in settings
    assert 'TextField("Preferred tone (e.g. direct, warm, concise)"' in settings
    assert 'Section("Tone hint (optional)")' in settings
    assert "tone hint is sent with a coaching request" in settings
    assert "preferredVoice" in settings
    assert "voiceHint" in settings
    assert 'Section("Voice")' not in settings
    assert 'TextField("Preferred voice' not in settings
    assert 'Section("Voice hint (optional)")' not in settings


def test_storekit_purchase_outcomes_are_explicit_and_server_authoritative():
    manager = _source("Shared/StoreKitManager.swift")
    app = _source("App/TonoApp.swift")

    assert "syncAppStoreSubscription" in manager
    assert "applyBackendState(" in manager
    assert "inTrial: transaction.offer?.paymentMode == .freeTrial" in manager
    assert "subscription.isEligibleForIntroOffer" in manager
    assert 'purchaseError = "Purchase canceled."' in manager
    assert 'purchaseError = "Purchase is pending approval."' in manager
    assert "guard updatesTask == nil else { return }" in manager
    assert ".appAccountToken(" in manager
    assert "product.purchase(options:" in manager
    assert app.count("StoreKitManager.shared.start()") == 1
#!/bin/bash
#
# verify_space_cursor_lifetime.sh
# Release-level guard for the object-lifetime defect that made Build 104 inert.
#
# WHAT WENT WRONG
# `SpaceCursorSession` stored its `SpaceCursorTextProxy` in a `weak` property
# while `KeyboardViewController:427` passed the adapter as a TEMPORARY argument:
#
#     private lazy var spaceCursorSession =
#         SpaceCursorSession(proxy: SpaceCursorProxyAdapter(owner: self))
#
# Nothing else retained the adapter, so ARC freed it before the lazy initialiser
# returned. Every context read yielded nil, the engine captured an empty
# document, and the caret could never move — while the trackpad affordance still
# engaged, because `tick` transitions regardless of content.
#
# Swift DOES diagnose this, but only under `-O` (the SIL `DiagnoseLifetimeIssues`
# pass). Debug/incremental builds and `swiftc -typecheck` are silent, so the
# warning existed only in a Release build log and scrolled past unread. This
# script turns that warning into a deterministic, exit-code-bearing gate.
#
# The diagnostic has no Swift diagnostic-group name, so `-Werror <group>` cannot
# target it and a project-wide SWIFT_TREAT_WARNINGS_AS_ERRORS would couple this
# invariant to every unrelated warning in the tree. Hence a dedicated gate.
#
# FOUR CHECKS — all must pass:
#   1. OWNERSHIP INVARIANT   `SpaceCursorSession` stores its proxy strongly.
#   2. CYCLE INVARIANT       `SpaceCursorProxyAdapter` holds its owner weakly.
#   3. ARMED CONTROL         a deliberately-`weak` mutant MUST still produce the
#                            compiler diagnostic. Without this the gate could
#                            pass vacuously if a toolchain stopped emitting it.
#   4. PRODUCTION CLEAN      the real source, at Release settings (-O -wmo),
#                            emits ZERO lifetime diagnostics, and the production
#                            ownership shape actually reaches the host at run
#                            time.
#
# Usage (from apps/ios):  Scripts/verify_space_cursor_lifetime.sh
# Exits 0 on success, non-zero on any failure. No network, no simulator, no
# Xcode project, no signing — deterministic and safe to run anywhere.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENGINE="$IOS_ROOT/KeyboardExtension/AppleFidelity/SpaceCursorEngine.swift"
CONTROLLER="$IOS_ROOT/KeyboardExtension/KeyboardViewController.swift"

DIAGNOSTIC='weak reference will always be nil'
failures=0

pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; failures=$((failures + 1)); }

for f in "$ENGINE" "$CONTROLLER"; do
    if [ ! -f "$f" ]; then
        printf 'FATAL: missing source file: %s\n' "$f" >&2
        exit 2
    fi
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "=== Space cursor lifetime guard ==="
echo "engine     : $ENGINE"
echo "controller : $CONTROLLER"
echo

# ── 1. Ownership invariant ────────────────────────────────────────────────────
# The session must OWN its proxy. Callers construct the adapter as a temporary,
# so a weak/unowned store here deallocates it immediately.
SESSION_BODY="$(awk '/^public final class SpaceCursorSession/,/^}/' "$ENGINE")"
PROXY_DECL="$(printf '%s\n' "$SESSION_BODY" | grep -E '^[[:space:]]*(private|internal|public|fileprivate)?[[:space:]]*(weak|unowned)?[[:space:]]*(let|var)[[:space:]]+proxy[[:space:]]*:')"

if [ -z "$PROXY_DECL" ]; then
    fail "could not locate the 'proxy' storage declaration in SpaceCursorSession"
elif printf '%s' "$PROXY_DECL" | grep -qE '\b(weak|unowned)\b'; then
    fail "SpaceCursorSession stores its proxy weakly — the adapter will be deallocated as a temporary:
         $(printf '%s' "$PROXY_DECL" | sed 's/^[[:space:]]*//')"
else
    pass "SpaceCursorSession owns its proxy:$(printf '%s' "$PROXY_DECL" | sed 's/^[[:space:]]*/ /')"
fi

# ── 2. Cycle invariant ────────────────────────────────────────────────────────
# Owning the proxy is only safe because the adapter holds its controller weakly.
# If that ever becomes strong the chain closes: controller -> session -> adapter
# -> controller, and the keyboard leaks instead of going inert.
ADAPTER_BODY="$(awk '/^final class SpaceCursorProxyAdapter/,/^}/' "$CONTROLLER")"
OWNER_DECL="$(printf '%s\n' "$ADAPTER_BODY" | grep -E '^[[:space:]]*(private|internal|public|fileprivate)?[[:space:]]*(weak|unowned)?[[:space:]]*(let|var)[[:space:]]+owner[[:space:]]*:')"

if [ -z "$OWNER_DECL" ]; then
    fail "could not locate the 'owner' declaration in SpaceCursorProxyAdapter"
elif printf '%s' "$OWNER_DECL" | grep -qE '\b(weak|unowned)\b'; then
    pass "SpaceCursorProxyAdapter holds its owner weakly — no retain cycle"
else
    fail "SpaceCursorProxyAdapter holds its owner strongly — retain cycle with the session:
         $(printf '%s' "$OWNER_DECL" | sed 's/^[[:space:]]*//')"
fi

# ── Ownership mirror ──────────────────────────────────────────────────────────
# Reproduces the production construction shape: the adapter is built as a
# TEMPORARY argument and only the session is returned, so nothing in the caller
# can prop it up. Compiled against the REAL engine.
cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

final class HostField {
    private(set) var text: [Character]
    private(set) var caret: Int
    private(set) var adjustCalls = 0
    init(before: String, after: String) {
        text = Array(before + after); caret = Array(before).count
    }
    var contextBefore: String { String(text[0..<caret]) }
    var contextAfter: String { String(text[caret...]) }
    func adjustTextPosition(byCharacterOffset offset: Int) {
        adjustCalls += 1
        var idx = caret, remaining = abs(offset)
        let step = offset < 0 ? -1 : 1
        while remaining > 0 {
            let next = idx + step
            guard next >= 0, next <= text.count else { break }
            remaining -= (step > 0 ? text[idx] : text[next]).utf16.count
            idx = next
        }
        caret = max(0, min(idx, text.count))
    }
}

final class OwnerController {
    let field: HostField
    init(field: HostField) { self.field = field }
}

/// Mirror of SpaceCursorProxyAdapter — owner held weakly.
final class MirrorProxyAdapter: SpaceCursorTextProxy {
    private weak var owner: OwnerController?
    init(owner: OwnerController) { self.owner = owner }
    var documentContextBeforeInput: String? { owner?.field.contextBefore }
    var documentContextAfterInput: String? { owner?.field.contextAfter }
    func adjustTextPosition(byCharacterOffset offset: Int) {
        owner?.field.adjustTextPosition(byCharacterOffset: offset)
    }
}

/// Mirror of KeyboardViewController.swift:427 — adapter is a TEMPORARY argument.
func makeSessionTheWayTheControllerDoes(owner: OwnerController) -> SpaceCursorSession {
    SpaceCursorSession(proxy: MirrorProxyAdapter(owner: owner))
}

let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
func at(_ dt: TimeInterval) -> Date { base.addingTimeInterval(dt) }

let field = HostField(
    before: "The quick brown fox jumps over the lazy dog while the river runs on.",
    after: " And there is still more text after the caret."
)
// The owner must be held, mirroring production where it is the live
// UIInputViewController (`self`). Only the ADAPTER is a temporary.
let owner = OwnerController(field: field)
let session = makeSessionTheWayTheControllerDoes(owner: owner)
session.press(at: at(0))
_ = session.tick(at: at(0.30))
for dx in stride(from: 20.0, through: 300.0, by: 20.0) {
    _ = session.drag(translationX: dx, translationY: 0, at: at(0.4))
}
print("host_adjust_calls=\(field.adjustCalls) did_move=\(session.didMoveCaret) captured=\(session.engine.document?.count ?? 0)")
exit(field.adjustCalls > 0 && session.didMoveCaret ? 0 : 1)
SWIFT

# ── 3. Armed control ──────────────────────────────────────────────────────────
# Mutate the engine back to a weak proxy and require the compiler to complain.
# This proves the diagnostic is live in THIS toolchain, so check 4 cannot pass
# for the wrong reason.
sed -E 's/^([[:space:]]*)private let proxy: SpaceCursorTextProxy\?$/\1private weak var proxy: SpaceCursorTextProxy?/' \
    "$ENGINE" > "$WORK/EngineWeak.swift"

if ! grep -qE '^[[:space:]]*private weak var proxy: SpaceCursorTextProxy\?$' "$WORK/EngineWeak.swift"; then
    fail "armed control could not construct the weak mutant — the proxy declaration was reformatted; update this script"
else
    CONTROL_OUT="$(swiftc -O -wmo -o "$WORK/control" "$WORK/EngineWeak.swift" "$WORK/main.swift" 2>&1)"
    if printf '%s' "$CONTROL_OUT" | grep -q "$DIAGNOSTIC"; then
        pass "armed control: compiler still diagnoses the weak-temporary lifetime bug"
    else
        fail "armed control: toolchain did NOT emit \"$DIAGNOSTIC\" for a known-bad build.
         The compile-time half of this guard is not protecting anything.
         swiftc: $(swiftc -version | head -1)"
    fi
fi

# ── 4. Production clean, at Release settings ──────────────────────────────────
PROD_OUT="$(swiftc -O -wmo -o "$WORK/prod" "$ENGINE" "$WORK/main.swift" 2>&1)"
PROD_STATUS=$?

if [ $PROD_STATUS -ne 0 ]; then
    fail "production sources failed to compile at -O -wmo:
$PROD_OUT"
elif printf '%s' "$PROD_OUT" | grep -q "$DIAGNOSTIC"; then
    fail "production sources emit a lifetime diagnostic at Release settings (-O -wmo):
$(printf '%s' "$PROD_OUT" | grep -A1 "$DIAGNOSTIC" | head -6)"
else
    pass "production sources emit no lifetime diagnostic at -O -wmo"

    RUN_OUT="$("$WORK/prod" 2>&1)"
    if [ $? -eq 0 ]; then
        pass "production ownership shape reaches the host at run time ($RUN_OUT)"
    else
        fail "production ownership shape is INERT at run time ($RUN_OUT)"
    fi
fi

echo
if [ "$failures" -eq 0 ]; then
    echo "PASS: space cursor lifetime guard — 5 checks"
    exit 0
fi
echo "FAILED: space cursor lifetime guard — $failures check(s) failed" >&2
exit 1

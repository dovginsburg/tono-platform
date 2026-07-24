#!/usr/bin/env bash
# run.sh — compile the Apple-differentiation benchmark harness against the REAL
# Tono shipping analyzer and run the product-contract gate + corpus scorecard.
#
# No Xcode, no simulator, no network: the harness links the minimal Foundation-
# only closure of the shipping Shared engine plus the keyboard Coach client, so
# it exercises production code rather than a re-implementation.
#
#   ./run.sh            # run gate + measurement, print summary
#   ./run.sh --emit     # additionally (re)generate report/ artifacts
#
# Exit code is the product-contract gate (non-zero if any contract fails).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios="$(cd "$here/../.." && pwd)"
shared="$ios/Shared"
kbd="$ios/KeyboardExtension"

# Minimal real-source closure required to instantiate MockToneAnalyzer, the
# ToneAnalysis/RewriteAxis/RiskLevel schema, FeatureFlag, and TonoCoachClient.
real_sources=(
  "$shared/ToneEngine.swift"
  "$shared/TonoBackend.swift"
  "$shared/OpenAIToneAnalyzer.swift"
  "$shared/AnthropicToneAnalyzer.swift"
  "$shared/MockToneAnalyzer.swift"
  "$shared/SharedUserDefaults.swift"
  "$shared/FeatureFlags.swift"
  "$shared/TonoAnalytics.swift"
  "$shared/SharedKeychain.swift"
  "$kbd/TonoCoachClient.swift"
)

harness_sources=(
  "$here/Sources/BenchmarkCorpus.swift"
  "$here/Sources/ProductContract.swift"
  "$here/Sources/Scorecard.swift"
  "$here/Sources/main.swift"
)

bin="$(mktemp -d)/apple-diff-bench"
swiftc -O "${real_sources[@]}" "${harness_sources[@]}" -o "$bin"

emit_args=()
if [[ "${1:-}" == "--emit" ]]; then
  emit_args=(--emit "$here/report")
fi

"$bin" "$here/corpus/social_risk_corpus.json" ${emit_args[@]+"${emit_args[@]}"}

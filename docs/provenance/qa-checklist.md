# Independent QA checklist

1. Confirm all `original_head` values in `history-map.json` against the read-only donor repositories.
2. Confirm protected iOS build-85 source SHA `dc7ea04bec4af57cc901b99ddc034574d6353c10` is unchanged and maps to canonical `f3acaa296c295e87098af4e12b47da89c869b6ab`.
3. Run `python3 scripts/ci/verify_source.py` and assert no gitlinks, nested Git roots, generated output, signing material, database files, or credential files are tracked.
4. Run `gitleaks git --redact --verbose` against all reachable history.
5. Run `python3 scripts/ci/prepare_provenance.py`; inspect `build/provenance.json` and each app copy.
6. Install backend dependencies, run backend tests, and run `python3 scripts/ci/export_openapi.py --check`.
7. Build web, Android debug, and iOS simulator artifacts from a clean clone with no production secrets.
8. Inspect the web public file, Android APK asset, iOS generated Swift constants, and backend JSON/Docker labels for canonical SHA and schema revision.
9. Confirm no deployment workflow or command targets production automatically.

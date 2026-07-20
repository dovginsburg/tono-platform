import pytest

from backend.analyze import (
    AnalyzeRequest,
    CoachContractError,
    enforce_coach_contract,
    intended_draft,
    mock_analyze,
)


AXES = ["warmer", "clearer", "funnier", "safer"]


def _result(suggestions):
    return {
        "risk_level": "low",
        "perception": "Clear request.",
        "subtext": "asking for help",
        "risk_reason": "Direct request.",
        "suggestions": suggestions,
        "flags": [],
    }


def test_malformed_prefix_is_removed_from_valid_trailing_sentence():
    draft = "xqz 😵 hlp Hey, I need help with something!"
    assert intended_draft(draft) == "Hey, I need help with something!"


@pytest.mark.parametrize("draft", [
    "Context: Hey, I need help with something!",
    "❤️ Hey, I need help with something!",
])
def test_legitimate_prefix_is_preserved(draft):
    assert intended_draft(draft) == draft


def test_default_coach_contract_is_complete_and_canonical():
    req = AnalyzeRequest(draft="Hey, I need help with something!")
    scrambled = _result([
        {"axis": "safer", "text": "Could you help me with something?"},
        {"axis": "funnier", "text": "Plot twist: I could use help with something."},
        {"axis": "warmer", "text": "Hey, I’d appreciate your help with something!"},
        {"axis": "clearer", "text": "Hey, I need your help with something."},
    ])

    normalized = enforce_coach_contract(scrambled, req)

    assert [item["axis"] for item in normalized["suggestions"]] == AXES


def test_missing_axis_is_rejected_instead_of_silently_hidden():
    req = AnalyzeRequest(draft="Hey, I need help with something!")
    incomplete = _result([
        {"axis": "warmer", "text": "Hey, I’d appreciate your help."},
        {"axis": "clearer", "text": "Hey, I need your help."},
        {"axis": "safer", "text": "Could you help me?"},
    ])

    with pytest.raises(CoachContractError, match="missing.*funnier"):
        enforce_coach_contract(incomplete, req)


def test_subset_or_reordered_request_axes_are_accepted_and_canonicalized():
    """P0 t_a34717a8: subsets and reorders of canonical axes must NOT 502.

    Pre-fix the validator at apps/backend/analyze.py:213 rejected any
    req.axes value that wasn't exactly ('warmer','clearer','funnier','safer').
    Post-fix the validator accepts any subset of canonical axes in any
    order and canonicalizes the output order via CANONICAL_COACH_AXES.
    The provider is expected to emit only the requested axes (any extras
    are still rejected by the downstream loop) — this preserves the
    "fail closed" stance and only loosens the request shape contract.
    """

    # Single-axis subset: provider returns only that axis.
    req_single = AnalyzeRequest(
        draft="Please help with this request.",
        axes=["warmer"],
    )
    out_single = enforce_coach_contract(
        _result([{"axis": "warmer", "text": "Please help with this warmer request."}]),
        req_single,
    )
    assert [item["axis"] for item in out_single["suggestions"]] == ["warmer"]

    # Reverse order of all 4 canonical: provider returns all 4, validator
    # canonicalizes output to (warmer, clearer, funnier, safer).
    req_reversed = AnalyzeRequest(
        draft="Please help with this request.",
        axes=list(reversed(AXES)),
    )
    out_reversed = enforce_coach_contract(
        _result([
            {"axis": axis, "text": f"Please help with this {axis} request."}
            for axis in AXES
        ]),
        req_reversed,
    )
    assert [item["axis"] for item in out_reversed["suggestions"]] == AXES

    # Partial subset of three (out of order): provider returns only those 3,
    # validator canonicalizes output to (warmer, clearer, safer).
    requested = ["clearer", "safer", "warmer"]
    req_partial = AnalyzeRequest(
        draft="Please help with this request.",
        axes=requested,
    )
    out_partial = enforce_coach_contract(
        _result([
            {"axis": axis, "text": f"Please help with this {axis} request."}
            for axis in requested
        ]),
        req_partial,
    )
    assert [item["axis"] for item in out_partial["suggestions"]] == [
        "warmer", "clearer", "safer",
    ]


def test_subset_request_rejects_unrequested_axes_from_provider():
    """P0 t_a34717a8: when the user requests a subset, the provider is still
    held to that subset — extras are rejected (failed-closed preserved)."""
    req = AnalyzeRequest(
        draft="Please help with this request.",
        axes=["warmer"],
    )
    provider_payload = _result([
        {"axis": axis, "text": f"Please help with this {axis} request."}
        for axis in AXES
    ])
    with pytest.raises(CoachContractError, match="unexpected axis"):
        enforce_coach_contract(provider_payload, req)


def test_unknown_axis_is_rejected_at_contract_layer():
    """P0 t_a34717a8: unknown axes (e.g. 'warmth' / 'clarity' synonyms)
    must fail at the contract layer — the pre-fix path wasted a full
    Anthropic call before rejecting as 502. Post-fix they fail fast at
    the validate-input boundary (mapped by the server to 422)."""
    req = AnalyzeRequest(
        draft="hey can we grab lunch tomorrow?",
        axes=["warmth", "clarity"],
        mode="coach",
    )
    complete = _result([
        {"axis": axis, "text": f"please help with this {axis} request."}
        for axis in AXES
    ])
    with pytest.raises(CoachContractError, match="unknown axes:"):
        enforce_coach_contract(complete, req)


def test_exact_axis_label_prefix_is_removed_without_touching_legitimate_content():
    req = AnalyzeRequest(draft="Please help with this request.")
    result = _result([
        {"axis": axis, "text": f"{axis.title()}: Please help with this request."}
        for axis in AXES
    ])
    normalized = enforce_coach_contract(result, req)
    assert [item["text"] for item in normalized["suggestions"]] == [
        "Please help with this request."
    ] * 4


def test_semantic_scenario_hallucination_is_rejected():
    req = AnalyzeRequest(draft="xqz 😵 hlp Hey, I need help with something!")
    suggestions = [
        {"axis": "warmer", "text": "Hey, I’d appreciate your help with something!"},
        {"axis": "clearer", "text": "Hey, I need your help with something."},
        {"axis": "funnier", "text": "Plot twist: I could use help with something."},
        {"axis": "safer", "text": "Sorry, pocket text — ignore that!"},
    ]

    with pytest.raises(CoachContractError, match="semantic intent"):
        enforce_coach_contract(_result(suggestions), req)


@pytest.mark.parametrize("invented", [
    "Sorry, could you help me with something?",
    "Could you help me with something by Friday EOD?",
])
def test_apology_or_deadline_hallucination_is_rejected(invented):
    req = AnalyzeRequest(draft="Could you help me with something?")
    suggestions = [
        {"axis": axis, "text": invented if axis == "clearer" else req.draft}
        for axis in AXES
    ]
    with pytest.raises(CoachContractError, match="semantic intent"):
        enforce_coach_contract(_result(suggestions), req)


def test_mock_rewrites_clean_prefix_and_preserve_intended_message():
    result = mock_analyze(AnalyzeRequest(
        draft="xqz 😵 hlp Hey, I need help with something!"
    ))

    assert [item["axis"] for item in result["suggestions"]] == AXES
    assert all("xqz" not in item["text"] and "hlp" not in item["text"] for item in result["suggestions"])
    assert all("help" in item["text"].lower() for item in result["suggestions"])
    assert all("pocket text" not in item["text"].lower() for item in result["suggestions"])

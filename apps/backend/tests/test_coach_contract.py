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


def test_subset_or_reordered_request_axes_are_rejected():
    complete = _result([
        {"axis": axis, "text": f"Please help with this {axis} request."}
        for axis in AXES
    ])
    for axes in (["warmer"], list(reversed(AXES))):
        with pytest.raises(CoachContractError, match="requires"):
            enforce_coach_contract(complete, AnalyzeRequest(draft="Please help with this request.", axes=axes))


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

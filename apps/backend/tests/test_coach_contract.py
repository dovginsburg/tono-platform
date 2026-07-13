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


def test_mock_rewrites_clean_prefix_and_preserve_intended_message():
    result = mock_analyze(AnalyzeRequest(
        draft="xqz 😵 hlp Hey, I need help with something!"
    ))

    assert [item["axis"] for item in result["suggestions"]] == AXES
    assert all("xqz" not in item["text"] and "hlp" not in item["text"] for item in result["suggestions"])
    assert all("help" in item["text"].lower() for item in result["suggestions"])
    assert all("pocket text" not in item["text"].lower() for item in result["suggestions"])

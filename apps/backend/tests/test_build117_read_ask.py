"""Build 117 — Read the Ask, server side.

Read the Ask is a reading of a message the person RECEIVED. It stands beside
rewrite; it never replaces it, and Tono never works out which one was wanted.
Every request states its mode, and a request that does not state one — or
states one this route does not serve — is refused before anything is read,
billed or sent to a provider.

WHY THIS IS NOT THE EXISTING ``mode="read"``
--------------------------------------------
``READ_SYSTEM_PROMPT`` in ``analyze.py`` asks a model for "the sender's likely
intent and emotional state" and for "hidden asks, passive signals"; the mock
path answers "Sender sounds frustrated or passive-aggressive" with a subtext of
"annoyed, wants acknowledgment". Those are precisely the claims the Read the Ask
contract forbids — hidden intent, diagnosing the sender, saying what they
"really mean". So Read the Ask is its own mode with its own prompt and its own
narrow response, and the legacy mode is left alone, byte for byte.
``test_the_legacy_read_mode_is_untouched_and_is_not_read_ask`` pins both halves
of that: the legacy behaviour still exists unchanged, and it is not what the new
path returns.

BASELINE
--------
Every test in this file was run against the exact base object
(32ff2094 / tree 24ccdfcb) before a line of the feature existed. The verbatim
red output is recorded in the Build 117 handoff.
"""

from __future__ import annotations

import inspect

import pytest


# ── helpers ───────────────────────────────────────────────────────────────


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _register_entitled(client) -> dict:
    """A registered device holding an active subscription — the only principal
    that gets past the server-authoritative entitlement gate."""
    r = client.post("/v1/register", json={"platform": "ios", "app_version": "0.2.0"})
    assert r.status_code == 200, r.text
    reg = r.json()
    from backend.store import get_store

    get_store().update_subscription(
        device_id=reg["device_id"],
        customer_id=None,
        subscription_id=f"sub_{reg['device_id']}",
        status="active",
        renews_at=None,
    )
    return reg


#: A received message with one concrete ask and one deadline stated in the
#: sender's own words. Used wherever a test needs a message that HAS a deadline.
RECEIVED_WITH_DEADLINE = (
    "Hi — can you send me the Q3 deck by Friday? "
    "The board wants to read it over the weekend."
)

#: The same shape of message with NO deadline anywhere in it. Any deadline that
#: appears in a reading of this message was invented.
RECEIVED_WITHOUT_DEADLINE = (
    "Hi — can you send me the Q3 deck? The board wants to read it."
)


# ── the explicit mode boundary ────────────────────────────────────────────


def test_the_route_refuses_a_request_that_states_no_mode(client):
    """Missing mode fails closed. Tono must never decide for itself whether a
    piece of text is something the person received or something they are about
    to send, so the absence of a mode is a refusal, not a default."""
    reg = _register_entitled(client)
    r = client.post(
        "/api/read-ask",
        json={"text": RECEIVED_WITH_DEADLINE},
        headers=_auth(reg["api_token"]),
    )
    assert r.status_code == 422, r.text


@pytest.mark.parametrize(
    "mode",
    [
        "",              # empty
        " read_ask",     # padded — trimming is where inference starts
        "read_ask ",
        "READ_ASK",      # mis-cased
        "read-ask",      # near-miss spelling
        "read",          # the LEGACY mode, which this route does not serve
        "coach",         # the legacy rewrite mode
        "ask",
        "readAsk",
    ],
)
def test_the_route_refuses_every_mode_that_is_not_exactly_read_ask(client, mode):
    """Unknown, near-miss and legacy modes all fail closed. The check is exact:
    no trimming, no case folding, no "did you mean". Every one of these is a
    request whose intent is not certain, and an uncertain intent is refused."""
    reg = _register_entitled(client)
    r = client.post(
        "/api/read-ask",
        json={"text": RECEIVED_WITH_DEADLINE, "mode": mode},
        headers=_auth(reg["api_token"]),
    )
    assert r.status_code in (400, 422), (
        f"mode {mode!r} was accepted by the Read the Ask route"
    )


def test_the_route_refuses_the_rewrite_mode_with_a_stated_reason(client):
    """``rewrite`` is a REAL mode in the Build 117 vocabulary — it is simply not
    this route's. It is refused explicitly (400) rather than by schema accident,
    so the boundary is a decision the server states rather than one that falls
    out of a type."""
    reg = _register_entitled(client)
    r = client.post(
        "/api/read-ask",
        json={"text": RECEIVED_WITH_DEADLINE, "mode": "rewrite"},
        headers=_auth(reg["api_token"]),
    )
    assert r.status_code == 400, r.text
    assert "mode" in r.text.lower()


def test_the_route_accepts_exactly_read_ask(client):
    reg = _register_entitled(client)
    r = client.post(
        "/api/read-ask",
        json={"text": RECEIVED_WITH_DEADLINE, "mode": "read_ask"},
        headers=_auth(reg["api_token"]),
    )
    assert r.status_code == 200, r.text
    assert r.json()["mode"] == "read_ask"


def test_the_analyze_route_still_refuses_read_ask(client):
    """The rewrite endpoint does not grow a second personality. Its mode
    vocabulary is unchanged, so ``read_ask`` is not a thing it will answer."""
    reg = _register_entitled(client)
    r = client.post(
        "/api/analyze",
        json={"text": "hey can u send me the file tmrw thanks", "mode": "read_ask"},
        headers=_auth(reg["api_token"]),
    )
    assert r.status_code == 422, r.text


# ── the narrow first-release output ───────────────────────────────────────


def test_the_response_carries_only_the_approved_fields(client):
    """The first release returns The Ask, By when, Unclear and bounded possible
    readings. Nothing else — no risk score, no perception, no subtext, no
    suggestions, no flags. A field that does not exist cannot be rendered."""
    reg = _register_entitled(client)
    r = client.post(
        "/api/read-ask",
        json={"text": RECEIVED_WITH_DEADLINE, "mode": "read_ask"},
        headers=_auth(reg["api_token"]),
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert set(body) == {
        "mode",
        "status",
        "ask",
        "by_when",
        "unclear",
        "possible_readings",
        "plan",
    }, sorted(body)
    for banned in ("risk_level", "perception", "subtext", "suggestions", "flags"):
        assert banned not in body


def test_the_ask_is_the_concrete_request_the_text_supports(client):
    reg = _register_entitled(client)
    r = client.post(
        "/api/read-ask",
        json={"text": RECEIVED_WITH_DEADLINE, "mode": "read_ask"},
        headers=_auth(reg["api_token"]),
    )
    body = r.json()
    assert body["status"] == "ok"
    assert body["ask"], "an explicit request in the message produced no Ask"
    assert "deck" in body["ask"].lower()


# ── By when: stated or absent, never guessed ──────────────────────────────


def test_a_stated_deadline_is_returned_in_the_senders_own_words(client):
    reg = _register_entitled(client)
    r = client.post(
        "/api/read-ask",
        json={"text": RECEIVED_WITH_DEADLINE, "mode": "read_ask"},
        headers=_auth(reg["api_token"]),
    )
    by_when = r.json()["by_when"]
    assert by_when, "a deadline stated in the message was dropped"
    assert by_when.lower() in RECEIVED_WITH_DEADLINE.lower(), (
        f"by_when {by_when!r} is not a verbatim quotation from the message"
    )


def test_a_message_with_no_deadline_produces_no_deadline(client):
    """The single most damaging thing this feature could do is invent a time the
    sender never gave. Absent beats guessed, always."""
    reg = _register_entitled(client)
    r = client.post(
        "/api/read-ask",
        json={"text": RECEIVED_WITHOUT_DEADLINE, "mode": "read_ask"},
        headers=_auth(reg["api_token"]),
    )
    assert r.json()["by_when"] is None, (
        "a deadline appeared for a message that states none"
    )


def test_a_paraphrased_deadline_is_dropped_rather_than_rendered():
    """A model that paraphrases a deadline has stopped quoting and started
    interpreting. The field is dropped; the rest of the reading survives."""
    from backend.read_ask import enforce_read_ask_contract

    result = enforce_read_ask_contract(
        {
            "ask": "Send the Q3 deck.",
            "by_when": "end of the week",  # the message says "by Friday"
            "unclear": None,
            "possible_readings": [],
        },
        source_text=RECEIVED_WITH_DEADLINE,
    )
    assert result["by_when"] is None


def test_a_fabricated_deadline_is_dropped_rather_than_rendered():
    from backend.read_ask import enforce_read_ask_contract

    result = enforce_read_ask_contract(
        {
            "ask": "Send the Q3 deck.",
            "by_when": "by Tuesday at 9am",
            "unclear": None,
            "possible_readings": [],
        },
        source_text=RECEIVED_WITHOUT_DEADLINE,
    )
    assert result["by_when"] is None
    assert result["ask"], "dropping the deadline must not destroy the reading"


# ── never diagnose the sender ─────────────────────────────────────────────


SENDER_CLAIMS = [
    "The sender is frustrated and wants acknowledgment.",
    "They really mean that you have let them down.",
    "They seem annoyed about the delay.",
    "She sounds upset about the reschedule.",
    "He is being passive-aggressive about the deadline.",
    "Read between the lines: they want an apology.",
    "The hidden intent is to make you feel guilty.",
    "You seem to have missed their point.",
    "You sound defensive in this thread.",
    "Sentiment: negative.",
]


@pytest.mark.parametrize("claim", SENDER_CLAIMS)
def test_a_reading_that_diagnoses_the_sender_fails_closed(claim):
    """Tono is a communication coach, not a profiler. A reading that claims
    hidden intent, names the sender's feelings, scores sentiment or assigns a
    personality is refused whole — not sanitised into something quotable."""
    from backend.read_ask import ReadAskContractError, enforce_read_ask_contract

    with pytest.raises(ReadAskContractError):
        enforce_read_ask_contract(
            {
                "ask": claim,
                "by_when": None,
                "unclear": None,
                "possible_readings": [],
            },
            source_text=RECEIVED_WITH_DEADLINE,
        )


@pytest.mark.parametrize("claim", SENDER_CLAIMS)
def test_the_guard_covers_every_free_text_field(claim):
    """``unclear`` and the possible readings are rendered to the person exactly
    like the Ask is, so they are held to exactly the same rule."""
    from backend.read_ask import ReadAskContractError, enforce_read_ask_contract

    for field, payload in (
        ("unclear", {"ask": "Send the deck.", "unclear": claim, "possible_readings": []}),
        ("possible_readings", {"ask": "Send the deck.", "unclear": None, "possible_readings": [claim]}),
    ):
        with pytest.raises(ReadAskContractError):
            enforce_read_ask_contract(
                {"by_when": None, **payload}, source_text=RECEIVED_WITH_DEADLINE
            )


def test_an_ordinary_reading_is_not_over_blocked():
    """The guard has to survive contact with real asks. A question the SENDER
    asked about the reader is a legitimate ask, not a claim about the sender."""
    from backend.read_ask import enforce_read_ask_contract

    result = enforce_read_ask_contract(
        {
            "ask": "Confirm whether you are free on Tuesday.",
            "by_when": None,
            "unclear": "Which Tuesday is meant.",
            "possible_readings": [],
        },
        source_text="Are you free Tuesday?",
    )
    assert result["ask"] == "Confirm whether you are free on Tuesday."


def test_the_shipped_read_ask_prompt_forbids_the_claims_the_contract_forbids():
    from backend.read_ask import READ_ASK_SYSTEM_PROMPT

    lowered = READ_ASK_SYSTEM_PROMPT.lower()
    for required in ("really", "hidden intent", "feelings", "sentiment", "diagnos", "verbatim"):
        assert required in lowered, f"the prompt says nothing about {required!r}"


# ── possible readings are bounded and labelled as possibilities ───────────


def test_possible_readings_are_bounded():
    from backend.read_ask import MAX_POSSIBLE_READINGS, enforce_read_ask_contract

    result = enforce_read_ask_contract(
        {
            "ask": "Send the deck.",
            "by_when": None,
            "unclear": None,
            "possible_readings": [f"Reading {n}." for n in range(12)],
        },
        source_text=RECEIVED_WITH_DEADLINE,
    )
    assert len(result["possible_readings"]) <= MAX_POSSIBLE_READINGS


def test_exactly_one_unclear_detail_is_carried():
    """The contract asks for ONE material missing detail. A list is a different
    product — a checklist of everything that could be sharper — so a list fails
    closed rather than being silently reduced to its first element."""
    from backend.read_ask import ReadAskContractError, enforce_read_ask_contract

    with pytest.raises(ReadAskContractError):
        enforce_read_ask_contract(
            {
                "ask": "Send the deck.",
                "by_when": None,
                "unclear": ["Which deck.", "Which Friday."],
                "possible_readings": [],
            },
            source_text=RECEIVED_WITH_DEADLINE,
        )


def test_a_whitespace_only_ask_is_no_ask_and_never_rendered_as_one():
    """A blank Ask is never shown as an Ask. It became `no_ask` rather than a
    hard error once it was clear that "this message asks for nothing" is a real
    and common answer — see `test_a_message_with_no_request_says_so…`. What must
    never happen either way is a reading with an empty Ask reaching a screen."""
    from backend.read_ask import enforce_read_ask_contract

    result = enforce_read_ask_contract(
        {"ask": "   ", "by_when": "by Friday", "unclear": "something",
         "possible_readings": ["a", "b"]},
        source_text=RECEIVED_WITH_DEADLINE,
    )
    assert result["status"] == "no_ask"
    assert result["ask"] is None
    # And nothing else survives either — a reading with no Ask has no parts.
    assert result["by_when"] is None
    assert result["unclear"] is None
    assert result["possible_readings"] == []


# ── the safety boundary, without becoming a crisis product ────────────────


def test_self_directed_crisis_wording_is_declined_without_a_provider_call(client, monkeypatch):
    """Tono is a communication coach, not a crisis hotline. A received message
    carrying self-directed crisis wording is outside this feature's authority:
    it is declined before any provider call, with no resources, no helpline, no
    diagnosis and no interpretation — product-scope silence, not a clinical
    judgement about anyone."""
    reg = _register_entitled(client)

    import backend.read_ask as read_ask_module

    called = []

    async def _explode(*args, **kwargs):  # pragma: no cover - must never run
        called.append(True)
        raise AssertionError("a provider was called for crisis wording")

    monkeypatch.setattr(read_ask_module, "anthropic_read_ask", _explode)
    monkeypatch.setattr(read_ask_module, "openai_read_ask", _explode)

    r = client.post(
        "/api/read-ask",
        json={"text": "i want to kill myself, can you call me", "mode": "read_ask"},
        headers=_auth(reg["api_token"]),
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["status"] == "declined"
    assert body["ask"] is None
    assert body["by_when"] is None
    assert body["unclear"] is None
    assert body["possible_readings"] == []
    assert not called

    # No hotline, no resource, no clinical microcopy anywhere in the envelope.
    blob = r.text.lower()
    for banned in ("988", "911", "hotline", "helpline", "suicide", "crisis", "therapist", "counsel"):
        assert banned not in blob, f"the declined envelope mentions {banned!r}"


def test_the_crisis_preflight_uses_the_one_shared_lexicon():
    """One definition of the boundary, in one place. A second copy is a second
    thing to forget to update."""
    import backend.read_ask as read_ask_module
    from backend.analyze import _is_crisis

    assert read_ask_module.is_crisis is _is_crisis


# ── it reuses the canonical request path's protections ────────────────────


def test_the_route_is_authenticated(client):
    r = client.post(
        "/api/read-ask",
        json={"text": RECEIVED_WITH_DEADLINE, "mode": "read_ask"},
    )
    assert r.status_code in (401, 403), r.text


def test_the_route_fails_closed_without_an_entitlement(client):
    """No free tier here either. An unentitled caller gets the honest 402, and
    gets it BEFORE the per-IP window so it is never told to slow down when the
    real answer is that it needs a subscription."""
    r = client.post("/v1/register", json={"platform": "ios", "app_version": "0.2.0"})
    reg = r.json()
    r = client.post(
        "/api/read-ask",
        json={"text": RECEIVED_WITH_DEADLINE, "mode": "read_ask"},
        headers=_auth(reg["api_token"]),
    )
    assert r.status_code == 402, r.text


def test_the_route_calls_the_one_shared_entitlement_gate():
    """The same grep-enforced invariant every other provider-invoking consumer
    route is held to."""
    from backend import server

    src = inspect.getsource(server.api_read_ask)
    assert "_require_rewrite_entitlement(user)" in src
    assert "_check_ip_rate(" in src


def test_the_route_bounds_the_received_text(client):
    from backend.server import _DRAFT_MAX_CHARS

    reg = _register_entitled(client)
    r = client.post(
        "/api/read-ask",
        json={"text": "a" * (_DRAFT_MAX_CHARS + 1), "mode": "read_ask"},
        headers=_auth(reg["api_token"]),
    )
    assert r.status_code == 400, r.text


def test_empty_received_text_is_refused(client):
    reg = _register_entitled(client)
    r = client.post(
        "/api/read-ask",
        json={"text": "   ", "mode": "read_ask"},
        headers=_auth(reg["api_token"]),
    )
    assert r.status_code == 400, r.text


# ── the legacy rewrite path is untouched ──────────────────────────────────


def test_the_legacy_read_mode_is_untouched_and_is_not_read_ask(client):
    """Both halves matter. The legacy ``read`` mode still does exactly what it
    always did — including the sender diagnosis that made it unusable for this
    feature — and Read the Ask is demonstrably a different thing."""
    reg = _register_entitled(client)
    r = client.post(
        "/api/analyze",
        json={"text": "as per my last message", "mode": "read"},
        headers=_auth(reg["api_token"]),
    )
    assert r.status_code == 200, r.text
    legacy = r.json()
    # Unchanged legacy behaviour: it names the sender's state. This is the
    # evidence that it could not be reused, recorded as a fact rather than an
    # argument.
    assert "passive-aggressive" in legacy["flags"]
    assert "sender" in legacy["perception"].lower()
    assert "ask" not in legacy

    r = client.post(
        "/api/read-ask",
        json={"text": "as per my last message", "mode": "read_ask"},
        headers=_auth(reg["api_token"]),
    )
    assert r.status_code == 200, r.text
    read_ask = r.json()
    assert "perception" not in read_ask
    assert "flags" not in read_ask


def test_the_rewrite_request_shape_is_byte_for_byte_unchanged():
    """The wire schema established callers post to ``/api/analyze`` did not
    move. Its mode vocabulary, its default and its field set are exactly what
    they were on the base object."""
    from backend.server import ApiAnalyzeRequest

    fields = ApiAnalyzeRequest.model_fields
    assert set(fields) == {
        "text",
        "provider",
        "preferred_voice",
        "axes",
        "recipient_hint",
        "thread_context",
        "context_hints",
        "mode",
        "locale",
    }, sorted(fields)
    assert fields["mode"].default == "coach"


def test_the_legacy_analyze_prompt_selection_is_unchanged():
    from backend.analyze import (
        AnalyzeRequest,
        READ_SYSTEM_PROMPT,
        SYSTEM_PROMPT,
        build_system_prompt,
    )

    assert build_system_prompt(AnalyzeRequest(draft="x", mode="coach")) == SYSTEM_PROMPT
    assert build_system_prompt(AnalyzeRequest(draft="x", mode="read")) == READ_SYSTEM_PROMPT


# ── nothing is retained ───────────────────────────────────────────────────


def test_the_received_text_is_not_persisted(client):
    """The message a person shares for one reading is used for that reading.
    Nothing about it is written to the database — not the text, not a hash of
    it, not a summary."""
    reg = _register_entitled(client)
    needle = "zqxjkvbwpm"  # nothing else in the schema could produce this
    r = client.post(
        "/api/read-ask",
        json={
            "text": f"Can you send the {needle} report by Friday?",
            "mode": "read_ask",
        },
        headers=_auth(reg["api_token"]),
    )
    assert r.status_code == 200, r.text

    from backend.store import get_store

    conn = get_store()._conn
    tables = [
        row[0]
        for row in conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        ).fetchall()
    ]
    for table in tables:
        columns = [c[1] for c in conn.execute(f"PRAGMA table_info({table})").fetchall()]
        for column in columns:
            rows = conn.execute(
                f'SELECT COUNT(*) FROM "{table}" WHERE CAST("{column}" AS TEXT) LIKE ?',
                (f"%{needle}%",),
            ).fetchone()
            assert rows[0] == 0, f"{table}.{column} retained the received message"


def test_the_read_ask_response_is_not_cached_across_callers(client):
    """The rewrite path caches responses globally by request identity. A
    received message is one person's private context, so this path does not
    join that table at all."""
    from backend import server

    src = inspect.getsource(server.api_read_ask)
    assert "get_cached_response" not in src
    assert "set_cached_response" not in src


# ── a message that asks for nothing ───────────────────────────────────────


def test_a_message_with_no_request_says_so_rather_than_failing(client):
    """"Thanks for dinner last night" is an ordinary message. Read the Ask reads
    it fine; the answer is that there is no request in it.

    Before ``no_ask`` existed this came back as a 502 "Read the Ask response
    incomplete. Please retry." — a retry loop over a message that would never
    produce an Ask however many times it was sent."""
    reg = _register_entitled(client)
    r = client.post(
        "/api/read-ask",
        json={"text": "Thanks for dinner last night, it was lovely.", "mode": "read_ask"},
        headers=_auth(reg["api_token"]),
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["status"] == "no_ask"
    assert body["ask"] is None
    assert body["by_when"] is None
    assert body["unclear"] is None
    assert body["possible_readings"] == []


def test_an_empty_ask_from_a_provider_is_no_ask_not_an_error():
    from backend.read_ask import enforce_read_ask_contract

    for empty in ("", "   ", None):
        result = enforce_read_ask_contract(
            {"ask": empty, "by_when": None, "unclear": None, "possible_readings": []},
            source_text="Thanks for dinner.",
        )
        assert result["status"] == "no_ask", empty
        assert result["ask"] is None


def test_a_malformed_reading_is_still_an_error():
    """`no_ask` must not become a hiding place for a broken response. A missing
    key is malformed; a deliberately empty string is an answer."""
    from backend.read_ask import ReadAskContractError, enforce_read_ask_contract

    with pytest.raises(ReadAskContractError):
        enforce_read_ask_contract(
            {"by_when": None, "unclear": None, "possible_readings": []},
            source_text="Thanks for dinner.",
        )
    with pytest.raises(ReadAskContractError):
        enforce_read_ask_contract(
            {"ask": 42, "by_when": None, "unclear": None, "possible_readings": []},
            source_text="Thanks for dinner.",
        )


def test_the_mock_never_quotes_a_non_request_as_an_ask():
    """The mock used to fall back to the opening sentence when nothing looked
    like a request, which turned "thanks for dinner" into an Ask."""
    from backend.read_ask import mock_read_ask

    assert mock_read_ask("Thanks for dinner last night, it was lovely.")["ask"] == ""
    assert mock_read_ask("Can you send the deck by Friday?")["ask"]

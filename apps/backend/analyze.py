"""Shared tone-analysis logic for the Tono backend.

Extracted so that server.py (REST API) and slack.py (slash commands) can
both call the provider dispatch without a circular import.
"""

from __future__ import annotations

import json
import logging
import os
import re
from typing import Any, Literal, Optional

import httpx
from fastapi import HTTPException
from pydantic import BaseModel, Field

logger = logging.getLogger(__name__)


SYSTEM_PROMPT = """\
You are Social Tone Coach. You help a person say what they mean in a way
that actually lands. You are NOT an editor or a grammar checker. You are
NOT a therapist. You translate intent into impact.

Operate by these rules:

1. ONE-SENTENCE CEILING for any single rewrite. If a rewrite needs two
   sentences, rewrite it again until it doesn't.
2. PRESERVE the writer's voice. Do not over-polish into corporate or
   generic-LLM English.
3. FLAG passive aggression, ambiguous asks, unstated assumptions, and
   anything that could plausibly be misread as hostile, cold, or guilt-tripping.
4. Each rewrite must differ on exactly ONE axis. Do not bundle warmth
   with humor; the user picks the axis that fits the moment.
5. NEVER use "based on", "I checked", "looking at", "my read", or any
   tool-narration filler.
6. NO score predictions, NO analysis dumps. A perception is one short
   sentence plus, optionally, up to three emoji.
7. FUNNIER is risky. Only generate a funnier variant if the message has
   a clear light register. Otherwise return the same text for that axis
   with rationale "context doesn't call for humor".
8. SAFER removes anything that could be misread as guilt, sarcasm,
   cold-shoulder, or an unstated ask.
9. For each suggestion include "risk_after": your predicted risk level
   of that rewrite if sent ("low", "medium", or "high").
10. RISK_REASON: one short phrase ≤12 words naming the most likely
    misread or explaining the risk rating. State the rule, not just the
    verdict. Examples: "Reads as abrupt — opens with a demand."
    "Lands cleanly — direct ask with a deadline." Return in field
    risk_reason.
11. Preserve the user's semantic intent. Remove clearly accidental leading
    gibberish when a coherent trailing message is present, but never invent a
    new event or scenario (for example a pocket text, wrong recipient, apology,
    instruction to ignore the message, deadline, date, name, or commitment).
12. Return exactly one rewrite for every requested axis, in this order:
    warmer, clearer, funnier, safer. Never omit an axis.

Return JSON ONLY matching the ToneAnalysis schema. No prose, no markdown
fences, no commentary.

The JSON schema is:
{
  "risk_level": "low" | "medium" | "high",
  "perception": "one-line how this lands, optionally with up to 3 emoji",
  "subtext": "what the recipient will likely read between the lines",
  "risk_reason": "one short phrase ≤12 words explaining the risk rating",
  "suggestions": [
    {
      "axis": "warmer" | "clearer" | "funnier" | "safer",
      "text": "the rewrite (one sentence max)",
      "rationale": "why this helps",
      "risk_after": "low" | "medium" | "high" | null
    }
  ],
  "flags": ["passive aggression", "ambiguous ask", etc. — empty array if none]
}
"""


READ_SYSTEM_PROMPT = """\
You are a message interpreter. Someone received a message and wants to understand
how it was intended to land — the emotional tone, the subtext, and any subtle
signals the sender might be sending.

Operate by these rules:

1. Interpret the RECEIVED message from the perspective of the recipient, not
   the sender. What is the sender's likely intent and emotional state?
2. Identify the risk that this message will cause friction or confusion.
3. NAME any hidden asks, passive signals, or unclear intentions.
4. Do NOT suggest rewrites. The user is reading, not writing.
5. Keep the interpretation grounded: no armchair psychology, no overreach.
6. RISK_REASON: one short phrase ≤12 words naming what makes this message
   land the way it does (e.g. "Sender sounds detached — minimal effort reply."
   or "Warm close — genuine, no hidden ask."). Return in field risk_reason.

Return JSON ONLY matching the ToneAnalysis schema. No prose, no markdown
fences, no commentary. Set suggestions to an empty array.
"""


class AnalyzeRequest(BaseModel):
    draft: str
    recipient_hint: Optional[str] = None
    preferred_voice: Optional[str] = None
    axes: list[str] = Field(
        default_factory=lambda: ["warmer", "clearer", "funnier", "safer"]
    )
    context_hints: Optional[list[str]] = None
    thread_context: Optional[str] = None
    mode: Literal["coach", "read"] = "coach"


class RewriteSuggestion(BaseModel):
    axis: str
    text: str
    rationale: Optional[str] = None
    risk_after: Optional[str] = None


class ToneAnalysis(BaseModel):
    risk_level: str
    perception: str
    subtext: str
    risk_reason: str = ""
    suggestions: list[RewriteSuggestion]
    flags: list[str]


CANONICAL_COACH_AXES = ("warmer", "clearer", "funnier", "safer")


class CoachContractError(ValueError):
    """Provider output cannot be rendered without hiding or inventing content."""


def intended_draft(draft: str) -> str:
    """Conservatively remove an accidental malformed prefix before a coherent greeting."""
    stripped = draft.strip()
    matches = list(re.finditer(
        r"(?:^|\s)((?:hey|hi|hello)\b[\s\S]{3,}[.!?])\s*$",
        stripped,
        flags=re.IGNORECASE,
    ))
    if not matches:
        return stripped
    match = matches[-1]
    candidate = match.group(1).strip()
    prefix = stripped[:match.start(1)].strip()
    if not prefix:
        return candidate
    malformed_words = [
        word for word in re.findall(r"[A-Za-z]+", prefix)
        if len(word) >= 3 and not re.search(r"[aeiouy]", word, flags=re.IGNORECASE)
    ]
    # Symbols alone are not evidence of corruption: prefixes such as
    # "Context:" and "❤️" can carry legitimate meaning. Require multiple
    # word-like fragments that are mechanically malformed before dropping it.
    return candidate if len(malformed_words) >= 2 else stripped


def _semantic_terms(text: str) -> set[str]:
    stop = {
        "a", "an", "and", "are", "at", "be", "can", "could", "for", "hey",
        "hi", "i", "in", "is", "it", "me", "my", "of", "on", "please", "the",
        "this", "to", "we", "with", "would", "you", "your",
    }
    return {
        token for token in re.findall(r"[a-z0-9']+", text.lower())
        if len(token) >= 3 and token not in stop
    }


def _preserves_semantic_intent(source: str, rewrite: str) -> bool:
    lowered = rewrite.lower()
    invented_scenarios = (
        "pocket text", "wrong person", "wrong number", "sent by accident",
        "accidental text", "ignore that", "ignore this",
    )
    if any(phrase in lowered for phrase in invented_scenarios):
        return False
    factual_markers = (
        "sorry", "apologize", "apologies", "eod", "deadline", "today",
        "tomorrow", "monday", "tuesday", "wednesday", "thursday", "friday",
        "saturday", "sunday",
    )
    source_lowered = source.lower()
    if any(marker in lowered and marker not in source_lowered for marker in factual_markers):
        return False
    source_terms = _semantic_terms(source)
    if not source_terms:
        return True
    return bool(source_terms & _semantic_terms(rewrite))


def _clean_rewrite_prefix(text: str, axis: str) -> str:
    """Remove only an exact provider-added axis label, never user prose."""
    match = re.match(rf"^\s*{re.escape(axis)}\s*:\s*(\S[\s\S]*)$", text, re.IGNORECASE)
    return match.group(1).strip() if match else text.strip()


def enforce_coach_contract(result: dict[str, Any], req: AnalyzeRequest) -> dict[str, Any]:
    """Validate, canonicalize, and fail closed on incomplete or shifted rewrites."""
    if not isinstance(result, dict):
        raise CoachContractError("invalid response payload")
    if req.mode == "read":
        return result
    requested = [axis.strip().lower() for axis in req.axes]
    if not requested:
        requested = list(CANONICAL_COACH_AXES)
    if tuple(requested) != CANONICAL_COACH_AXES:
        raise CoachContractError("Coach requires warmer, clearer, funnier, safer in order")
    expected = list(CANONICAL_COACH_AXES)
    raw = result.get("suggestions")
    if not isinstance(raw, list):
        raise CoachContractError("missing suggestions")
    by_axis: dict[str, dict[str, Any]] = {}
    source = intended_draft(req.draft)
    for suggestion in raw:
        if not isinstance(suggestion, dict):
            raise CoachContractError("invalid suggestion")
        axis = str(suggestion.get("axis", "")).strip().lower()
        text = _clean_rewrite_prefix(str(suggestion.get("text", "")), axis)
        if axis not in expected:
            raise CoachContractError(f"unexpected axis: {axis}")
        if axis in by_axis:
            raise CoachContractError(f"duplicate axis: {axis}")
        if not text:
            raise CoachContractError(f"blank axis: {axis}")
        if not _preserves_semantic_intent(source, text):
            raise CoachContractError(f"{axis} rewrite does not preserve semantic intent")
        by_axis[axis] = {**suggestion, "axis": axis, "text": text}
    missing = [axis for axis in expected if axis not in by_axis]
    if missing:
        raise CoachContractError(f"missing axes: {', '.join(missing)}")
    return {**result, "suggestions": [by_axis[axis] for axis in expected]}


def build_system_prompt(req: AnalyzeRequest) -> str:
    """Pick prompt by mode, optionally extended with on-device user memory."""
    system = READ_SYSTEM_PROMPT if req.mode == "read" else SYSTEM_PROMPT
    if req.context_hints:
        hints = "\n".join(f"- {h}" for h in req.context_hints[:5])
        system += (
            "\n\nUSER PATTERNS (inferred from this person's history — use to "
            "personalize rewrites without mentioning or referencing these facts "
            "explicitly; just let them shape your choices):\n" + hints
        )
    return system


def build_user_prompt(req: AnalyzeRequest) -> str:
    lines: list[str] = []
    if req.thread_context:
        lines += ["THREAD (message you're replying to):", req.thread_context, ""]
    draft = intended_draft(req.draft) if req.mode == "coach" else req.draft.strip()
    lines += ["DRAFT (analyze and rewrite this):" if req.thread_context else "DRAFT:", draft]
    if req.recipient_hint:
        lines += ["", f"RECIPIENT CONTEXT: {req.recipient_hint}"]
    if req.preferred_voice:
        lines += ["", f"PREFERRED VOICE: {req.preferred_voice}"]
    lines += ["", f"GENERATE REWRITES FOR AXES: {', '.join(req.axes)}"]
    return "\n".join(lines)


def mock_analyze(req: AnalyzeRequest) -> dict[str, Any]:
    draft = intended_draft(req.draft) if req.mode == "coach" else req.draft.strip()
    lower = draft.lower()
    flags: list[str] = []

    if req.mode == "read":
        # Read mode: interpret received message, no rewrites.
        risk = "low"
        perception = "Seems straightforward. No obvious friction. ✅"
        subtext = "neutral, informational"
        risk_reason = "Reads as direct — nothing ambiguous or loaded."
        if (
            "as per my last" in lower
            or "per my last" in lower
            or "as previously discussed" in lower
        ):
            flags.append("passive-aggressive")
            risk = "high"
            perception = "Sender sounds frustrated or passive-aggressive. 📩"
            subtext = "annoyed, wants acknowledgment"
            risk_reason = "Sender is reminding you they were ignored."
        elif len(req.draft.strip()) < 6 or req.draft.strip().lower() in {"ok.", "fine.", "k."}:
            flags.append("terse reply")
            risk = "medium"
            perception = "Very short — hard to read intent. 🤔"
            subtext = "minimal engagement, possibly busy or cold"
            risk_reason = "Too brief to read — could be neutral or dismissive."
        return {
            "risk_level": risk,
            "perception": perception,
            "subtext": subtext,
            "risk_reason": risk_reason,
            "suggestions": [],
            "flags": flags,
        }

    risk = "low"
    perception = "Lands cleanly. ✅"
    subtext = "calm, neutral"

    risk_reason = "Lands cleanly — nothing stands out as risky."
    if (
        "as per my last" in lower
        or "per my last" in lower
        or "as previously discussed" in lower
    ):
        flags.append("passive-aggressive")
        risk = "high"
        perception = "Might land as a guilt-trip. 📩 😶"
        subtext = "frustrated, wants resolution"
        risk_reason = "Reads as a guilt-trip — implies they ignored you."
    elif (
        ("let me know" in lower and "by " not in lower)
        or "sometime" in lower
        or "when you can" in lower
    ):
        flags.append("ambiguous ask")
        risk = "medium"
        perception = "The ask is hard to act on without more detail. 🤔"
        subtext = "wants a reply but won't ask directly"
        risk_reason = "Ambiguous ask — no deadline or clear next step."
    elif len(draft) < 6 or draft.lower() in {"ok.", "fine.", "k."}:
        flags.append("terse — could read as cold")
        risk = "high"
        perception = "Reads as dismissive. 🥶"
        subtext = "upset or distracted"
        risk_reason = "Too terse — reads as cold or annoyed."

    suggestions: list[dict[str, Any]] = []
    if "warmer" in req.axes:
        warmer = (
            ("Hey — really appreciate it. " if lower.startswith(("thanks", "thank you")) else "Hey! ")
            + draft
        )
        suggestions.append(
            {"axis": "warmer", "text": warmer, "rationale": "Adds a one-line validation before the ask."}
        )
    if "clearer" in req.axes:
        clearer = draft.replace("let me know", "please tell me what you think")
        suggestions.append(
            {"axis": "clearer", "text": clearer, "rationale": "Names the ask and a specific deadline."}
        )
    if "funnier" in req.axes:
        suggestions.append(
            {"axis": "funnier", "text": draft, "rationale": "context doesn't call for humor"}
        )
    if "safer" in req.axes:
        safer = draft
        for bad, good in [
            (r"\bas per my last message\b", "following up on my last note"),
            (r"\bper my last\b", "following up on my last"),
            (r"\bas previously discussed\b", "to recap where we left off"),
        ]:
            safer = re.sub(bad, good, safer, flags=re.IGNORECASE)
        suggestions.append(
            {"axis": "safer", "text": safer, "rationale": "Removes anything that could be read as guilt or cold."}
        )

    return enforce_coach_contract({
        "risk_level": risk,
        "perception": perception,
        "subtext": subtext,
        "risk_reason": risk_reason,
        "suggestions": suggestions,
        "flags": flags,
    }, req)


async def openai_analyze(req: AnalyzeRequest) -> dict[str, Any]:
    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        raise HTTPException(500, "OPENAI_API_KEY not set")
    body = {
        "model": os.environ.get("OPENAI_MODEL", "gpt-4o-mini"),
        "temperature": 0.4,
        "messages": [
            {"role": "system", "content": build_system_prompt(req)},
            {"role": "user", "content": build_user_prompt(req)},
        ],
    }
    async with httpx.AsyncClient(timeout=30) as c:
        r = await c.post(
            "https://api.openai.com/v1/chat/completions",
            headers={"Authorization": f"Bearer {api_key}"},
            json=body,
        )
        r.raise_for_status()
        content = r.json()["choices"][0]["message"]["content"]
        return enforce_coach_contract(json.loads(content), req)


async def stream_openai_analyze(req: AnalyzeRequest):
    """Yields SSE events as the OpenAI response streams in."""
    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        yield f'data: {json.dumps({"type": "error", "message": "AI coach is not configured"})}\n\n'
        yield "data: [DONE]\n\n"
        return

    body = {
        "model": os.environ.get("OPENAI_MODEL", "gpt-4o-mini"),
        "temperature": 0.4,
        "stream": True,
        "messages": [
            {"role": "system", "content": build_system_prompt(req)},
            {"role": "user", "content": build_user_prompt(req)},
        ],
    }

    try:
        async with httpx.AsyncClient(timeout=30) as c:
            r = await c.post(
                "https://api.openai.com/v1/chat/completions",
                headers={"Authorization": f"Bearer {api_key}"},
                json=body,
            )
            if r.status_code != 200:
                err_text = (await r.aread()).decode()[:200]
                logger.error("OpenAI stream error %s: %s", r.status_code, err_text)
                yield f'data: {json.dumps({"type": "error", "message": f"AI service error ({r.status_code})"})}\n\n'
                yield "data: [DONE]\n\n"
                return

            # Read SSE stream from OpenAI
            sse_buffer = ""
            full_text = ""
            async for raw_chunk in r.aiter_text():
                sse_buffer += raw_chunk
                lines = sse_buffer.split("\n")
                sse_buffer = lines.pop() or ""
                for line in lines:
                    if not line.startswith("data: "):
                        continue
                    payload = line[6:].strip()
                    if payload == "[DONE]":
                        continue
                    try:
                        evt = json.loads(payload)
                    except json.JSONDecodeError:
                        continue
                    delta = evt.get("choices", [{}])[0].get("delta", {})
                    if "content" in delta:
                        full_text += delta["content"]

        # Parse the accumulated JSON
        text = full_text.strip()
        if text.startswith("```"):
            text = text.split("\n", 1)[1] if "\n" in text else text[3:]
        if text.endswith("```"):
            text = text[:-3]
        text = text.strip()

        result = enforce_coach_contract(json.loads(text), req)

        # Stream perception first
        if "perception" in result:
            yield f'data: {json.dumps({"type": "perception", "text": result["perception"]})}\n\n'

        # Stream each suggestion
        for s in result.get("suggestions", []):
            yield f'data: {json.dumps({"type": "suggestion", "axis": s.get("axis"), "text": s.get("text"), "rationale": s.get("rationale", ""), "risk_after": s.get("risk_after")})}\n\n'

        # Stream completion
        yield f'data: {json.dumps({"type": "complete", "risk_level": result.get("risk_level", "low"), "subtext": result.get("subtext", ""), "risk_reason": result.get("risk_reason", ""), "flags": result.get("flags", [])})}\n\n'

    except json.JSONDecodeError as e:
        logger.error("Failed to parse OpenAI stream as JSON: %s", e)
        yield f'data: {json.dumps({"type": "error", "message": "Could not parse AI response"})}\n\n'
    except Exception as e:
        logger.exception("stream_openai_analyze failed")
        yield f'data: {json.dumps({"type": "error", "message": str(e)})}\n\n'

    yield "data: [DONE]\n\n"


async def anthropic_analyze(req: AnalyzeRequest) -> dict[str, Any]:
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        raise HTTPException(500, "ANTHROPIC_API_KEY not set")
    body = {
        "model": get_model_for_user("anonymous"),
        "max_tokens": 800,
        "system": build_system_prompt(req),
        "messages": [{"role": "user", "content": build_user_prompt(req)}],
    }
    async with httpx.AsyncClient(timeout=30) as c:
        r = await c.post(
            "https://api.anthropic.com/v1/messages",
            headers={"x-api-key": api_key, "anthropic-version": "2023-06-01"},
            json=body,
        )
        if r.status_code != 200:
            logger.error("Anthropic API error %s: %s", r.status_code, r.text[:500])
            raise HTTPException(502, f"Anthropic API error: {r.status_code}")
        for block in r.json()["content"]:
            if block["type"] == "text":
                text = block["text"].strip()
                # Strip markdown code fences if present
                if text.startswith("```"):
                    text = text.split("\n", 1)[1] if "\n" in text else text[3:]
                if text.endswith("```"):
                    text = text[:-3]
                return enforce_coach_contract(json.loads(text.strip()), req)
        raise HTTPException(502, "no text block in anthropic response")


async def stream_anthropic_analyze(req: AnalyzeRequest):
    """Yields SSE events as the Anthropic response streams in.

    Event types:
      data: {"type":"perception","text":"..."}
      data: {"type":"suggestion","axis":"warmer","text":"...","rationale":"..."}
      data: {"type":"complete","risk_level":"low","flags":[],"used_today":N,"daily_limit":N,"plan":"free"}
      data: {"type":"error","message":"..."}
      data: [DONE]
    """
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        yield f'data: {json.dumps({"type": "error", "message": "AI coach is not configured"})}\n\n'
        yield "data: [DONE]\n\n"
        return

    body = {
        "model": get_model_for_user("anonymous"),
        "max_tokens": 800,
        "stream": True,
        "system": build_system_prompt(req),
        "messages": [{"role": "user", "content": build_user_prompt(req)}],
    }

    try:
        async with httpx.AsyncClient(timeout=30) as c:
            r = await c.post(
                "https://api.anthropic.com/v1/messages",
                headers={"x-api-key": api_key, "anthropic-version": "2023-06-01"},
                json=body,
            )
            if r.status_code != 200:
                err_text = (await r.aread()).decode()[:200]
                logger.error("Anthropic stream error %s: %s", r.status_code, err_text)
                yield f'data: {json.dumps({"type": "error", "message": f"AI service error ({r.status_code})"})}\n\n'
                yield "data: [DONE]\n\n"
                return

            # Read SSE stream from Anthropic, buffer into complete JSON
            sse_buffer = ""
            full_text = ""
            async for raw_chunk in r.aiter_text():
                sse_buffer += raw_chunk
                lines = sse_buffer.split("\n")
                sse_buffer = lines.pop() or ""
                for line in lines:
                    if not line.startswith("data: "):
                        continue
                    payload = line[6:].strip()
                    if payload == "[DONE]":
                        continue
                    try:
                        evt = json.loads(payload)
                    except json.JSONDecodeError:
                        continue
                    if evt.get("type") == "content_block_delta":
                        delta = evt.get("delta", {})
                        if delta.get("type") == "text_delta":
                            full_text += delta.get("text", "")

        # Parse the accumulated JSON
        text = full_text.strip()
        if text.startswith("```"):
            text = text.split("\n", 1)[1] if "\n" in text else text[3:]
        if text.endswith("```"):
            text = text[:-3]
        text = text.strip()

        result = enforce_coach_contract(json.loads(text), req)

        # Stream perception first (the user sees this immediately)
        if "perception" in result:
            yield f'data: {json.dumps({"type": "perception", "text": result["perception"]})}\n\n'

        # Stream each suggestion
        for s in result.get("suggestions", []):
            yield f'data: {json.dumps({"type": "suggestion", "axis": s.get("axis"), "text": s.get("text"), "rationale": s.get("rationale", ""), "risk_after": s.get("risk_after")})}\n\n'

        # Stream completion with metadata
        yield f'data: {json.dumps({"type": "complete", "risk_level": result.get("risk_level", "low"), "subtext": result.get("subtext", ""), "risk_reason": result.get("risk_reason", ""), "flags": result.get("flags", [])})}\n\n'

    except json.JSONDecodeError as e:
        logger.error("Failed to parse Anthropic stream as JSON: %s", e)
        yield f'data: {json.dumps({"type": "error", "message": "Could not parse AI response"})}\n\n'
    except Exception as e:
        logger.exception("stream_anthropic_analyze failed")
        yield f'data: {json.dumps({"type": "error", "message": str(e)})}\n\n'

    yield "data: [DONE]\n\n"

# Model tier logic: Sonnet for first week, then Haiku for free users
import datetime

def get_model_for_user(user_id: str) -> str:
    """Determine which model to use based on user status."""
    # Check if user is Pro
    if is_pro_user(user_id):
        return "claude-sonnet-4-5"
    
    # Free users: Sonnet for first 7 days, then Haiku
    signup_date = get_user_signup_date(user_id)
    if signup_date:
        days_since_signup = (datetime.datetime.now() - signup_date).days
        if days_since_signup <= 7:
            return "claude-sonnet-4-5"  # Free trial period
        else:
            return os.environ.get("TONO_MODEL", "claude-sonnet-4-5")  # Downgrade after 7 days
    
    # Default to Haiku for unknown users
    return os.environ.get("TONO_MODEL", "claude-sonnet-4-5")

def is_pro_user(user_id: str) -> bool:
    """Check if user has active subscription."""
    # TODO: Check Stripe subscription status
    return False

def get_user_signup_date(user_id: str) -> datetime.datetime:
    """Get user signup date from database."""
    # TODO: Query database for signup date
    return None

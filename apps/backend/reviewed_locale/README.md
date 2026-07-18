# reviewed_locale — inert reviewed-locale foundation

A **gate**, not a feature. It decides whether a proposed localized message
bundle is mechanically sound and carries *verifiable reviewer authority*, so a
human approver can then adjudicate it. It ships no translations, wires into no
server / dispatcher / config, does no I/O, and activates nothing. Importing it
has no side effects, and nothing in the running product imports it.

Pure standard library (Python 3.9+). Tests are stdlib `unittest`.

## What it can and cannot do

A technical gate can validate **evidence shape** and a **cryptographic
binding**. It cannot fabricate bilingual, legal, or product authority, and it
never declares a shipping GO. Accordingly, every result has
`go = shipping_approved = runtime_activated = False`, by construction
(`Decision.__post_init__` forces them false on every path).

## Terminal states (`evaluate_candidate`)

| status | meaning |
| --- | --- |
| `NOT_ELIGIBLE` | a mechanical gate failed, the tag is invalid, or an attestation is malformed / forged / out-of-scope / future-dated. Fail closed. |
| `PRE_REVIEW` | mechanically clean, but not eligible for review routing: a synthetic placeholder, an absent attestation, or an authentic-but-withholding / stale attestation. |
| `ELIGIBLE_FOR_REVIEW` | mechanically clean **and** carrying a verifiable authority attestation bound to exactly this content. Means only "a human with real authority MAY now adjudicate this." **Not** an approval, **not** a GO. |

## Mechanical gates (Sherlock t_80f35f58)

* **Exact pricing** — price/cadence tokens matched with boundaries, not
  substring containment: `$39.990` does **not** satisfy `$39.99`; a monthly
  message carrying an annual price/marker is rejected as cadence drift.
* **Interpolation** — required placeholders must appear in **every** plural /
  select form; unknown placeholders and unbalanced braces are rejected.
* **Forbidden safety tokens** — clinical / crisis tokens are rejected even under
  punctuation, zero-width, homoglyph, fullwidth, or leetspeak obfuscation
  (`textnorm` skeletonization). Tono is explicitly not a clinical product.
* **BCP-47 / RFC 5646** — extlang prefix validation (`en-yue` fails, `zh-yue`
  passes), plus rejection of malformed tags, duplicate variants / singletons,
  and private-use-only tags.
* **Control characters** — C0 (incl. tab/newline), DEL, and C1 rejected.
* **Blank reviewer** — blank reviewer identity / credentials rejected.

## Authority gates (Mira t_e64e4dfb)

Authority is never self-asserted. Enum role strings, arbitrary names, and
candidate booleans (`human_reviewed = True`, `go = True`, …) are **never read**
for the decision. `ELIGIBLE_FOR_REVIEW` requires an `attestation` that binds,
under one HMAC-SHA256 signature:

1. **reviewer authority** — verified against a caller-supplied
   `authority_registry` (held by the environment, never by the candidate);
2. the **locale / language pair**;
3. the **exact content hash** (recomputed here — one edit voids it);
4. the **scope** of keys covered;
5. the **decision** (only `APPROVE_FOR_REVIEW` is affirmative);
6. the **issue time** (rejected if future-dated or too old);
7. **revocation** status (checked against a caller-supplied list).

Synthetic placeholder fixtures are hard-capped at `PRE_REVIEW` regardless of
what they carry.

## Usage

```python
from backend.reviewed_locale import evaluate_candidate
decision = evaluate_candidate(
    candidate,
    authority_registry={"authority:...": b"<key held by the environment>"},
    revocation_list=[...],
    evaluation_time=...,   # tz-aware datetime; defaults to now(UTC)
)
```

## Tests

```
PYTHONPATH=apps python3 -m unittest discover -s apps/backend/reviewed_locale/tests -p 'test_*.py' -v
```

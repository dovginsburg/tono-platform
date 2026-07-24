# Apple-Differentiation Scorecard

Lane: `opus48/apple-differentiation` · Corpus schema `1.0`

> Regenerate with `./run.sh`. Output is deterministic (no timestamps), so a
> committed copy stays byte-identical unless the corpus or analyzer changes.

## Differentiated job under test

> Catch grammatically correct messages that are socially wrong before send, explain how they may land, and offer meaningfully distinct alternatives with measurable interpersonal-risk reduction.

## Apple baseline (capability fact, not synthetic output)

Apple Writing Tools (Apple Intelligence) provides free, systemwide Proofread, Rewrite (Friendly / Professional / Concise), Summarize, and Describe-your-change on supported devices. It corrects grammar/spelling and restyles register. It does NOT diagnose interpersonal/social risk of already-grammatical text, does not explain how a message may land to a specific relationship, and does not measure risk-after across distinct alternatives. These are capability facts used as the baseline, not synthetic Apple outputs.

## 1. Product-contract gate (shipping types)

**9/9 contracts pass.** These fail the build gate if Tono
regresses toward a generic, rewrite-only product.

| ID | Contract | Result |
|----|----------|--------|
| C1 | Diagnosis fields survive decode (risk+perception+subtext+reason+flags) | PASS |
| C2 | Coach = exactly four canonical distinct axes; partial sets rejected | PASS |
| C3 | Risk is 3-tier guidance with distinct labels + a11y icons | PASS |
| C4 | RewriteSuggestion carries risk-after (enables risk-reduction metric) | PASS |
| C5 | Rewrite axes are semantically distinct (help + bestWhen + name) | PASS |
| C6 | Keyboard client fails closed on missing/duplicate/unsupported axes | PASS |
| C7 | Read mode diagnoses received messages (perception, no rewrites) | PASS |
| C8 | Manual Coach stays available as diagnosis + four rewrites | PASS |
| C9 | Recipient memory dormant-by-default (not falsely claimed as live) | PASS |

## 2. Corpus composition

- Total cases: **46**
- Socially-risky (should nudge): **36**
- Benign controls (should NOT nudge): **10**, of which must-not-nudge adversarial: **10**
- All risky cases are grammatically valid by construction — the exact blind spot of a proofreader.

| Category | Cases |
|----------|-------|
| accusation | 3 |
| ambiguity | 4 |
| benign_control | 9 |
| coercive_urgency | 3 |
| contempt | 3 |
| cultural_idiomatic | 4 |
| defensiveness | 3 |
| dismissiveness | 3 |
| family_conflict | 3 |
| intimate_relationship | 4 |
| passive_aggression | 4 |
| workplace_hierarchy | 3 |

## 3. Offline analyzer measurement (MockToneAnalyzer)

This is the shipped **offline fallback**, not the LLM backend. It is measured here
honestly to establish the floor and to prove the gate runs end-to-end.

| Metric | Value |
|--------|-------|
| Detection recall on risky cases | **8%** (3/36) |
| Benign false-positive rate | **0%** (0/10) |
| Specificity | 100% |
| Precision | 100% |
| Risk-severity match (risky) | 3/36 |
| Cases with 4 distinct rewrite texts | 0/46 |

### Per-case detail

| id | category | expect nudge | offline risk | detected | sev-match | distinct rewrites |
|----|----------|:---:|:---:|:---:|:---:|:---:|
| pa-01 | passive_aggression | Y | high | Y | Y | · |
| pa-02 | passive_aggression | Y | low | · | · | · |
| pa-03 | passive_aggression | Y | low | · | · | · |
| pa-04 | passive_aggression | Y | low | · | · | · |
| contempt-01 | contempt | Y | low | · | · | · |
| contempt-02 | contempt | Y | low | · | · | · |
| contempt-03 | contempt | Y | low | · | · | · |
| accusation-01 | accusation | Y | low | · | · | · |
| accusation-02 | accusation | Y | low | · | · | · |
| accusation-03 | accusation | Y | low | · | · | · |
| defensiveness-01 | defensiveness | Y | low | · | · | · |
| defensiveness-02 | defensiveness | Y | low | · | · | · |
| defensiveness-03 | defensiveness | Y | low | · | · | · |
| urgency-01 | coercive_urgency | Y | low | · | · | · |
| urgency-02 | coercive_urgency | Y | low | · | · | · |
| urgency-03 | coercive_urgency | Y | low | · | · | · |
| dismissive-01 | dismissiveness | Y | low | · | · | · |
| dismissive-02 | dismissiveness | Y | low | · | · | · |
| dismissive-03 | dismissiveness | Y | low | · | · | · |
| ambiguity-01 | ambiguity | Y | medium | Y | Y | · |
| ambiguity-02 | ambiguity | Y | low | · | · | · |
| ambiguity-03 | ambiguity | Y | low | · | · | · |
| ambiguity-04 | ambiguity | Y | low | · | · | · |
| hierarchy-01 | workplace_hierarchy | Y | low | · | · | · |
| hierarchy-02 | workplace_hierarchy | Y | low | · | · | · |
| hierarchy-03 | workplace_hierarchy | Y | low | · | · | · |
| intimate-01 | intimate_relationship | Y | low | · | · | · |
| intimate-02 | intimate_relationship | Y | low | · | · | · |
| intimate-03 | intimate_relationship | Y | high | Y | Y | · |
| intimate-04 | intimate_relationship | Y | low | · | · | · |
| family-01 | family_conflict | Y | low | · | · | · |
| family-02 | family_conflict | Y | low | · | · | · |
| family-03 | family_conflict | Y | low | · | · | · |
| cultural-01 | cultural_idiomatic | n | low | · | · | · |
| cultural-02 | cultural_idiomatic | Y | low | · | · | · |
| cultural-03 | cultural_idiomatic | Y | low | · | · | · |
| cultural-04 | cultural_idiomatic | Y | low | · | · | · |
| benign-01 | benign_control | n | low | · | · | · |
| benign-02 | benign_control | n | low | · | · | · |
| benign-03 | benign_control | n | low | · | · | · |
| benign-04 | benign_control | n | low | · | · | · |
| benign-05 | benign_control | n | low | · | · | · |
| benign-06 | benign_control | n | low | · | · | · |
| benign-07 | benign_control | n | low | · | · | · |
| benign-08 | benign_control | n | low | · | · | · |
| benign-09 | benign_control | n | low | · | · | · |

## 4. Reading the result

The **contract gate** proves the schema can express the differentiated outcome
(risk + perception + subtext + reason + four distinct axes + risk-after). The
**offline recall** is deliberately low: the keyword MockToneAnalyzer catches only a
few overt patterns and cannot read contempt, coercion, or context. That is the gap
integration must close with the wired LLM backend — this harness is the gate that
will then measure it. No superiority to Apple is claimed here; a rewrite-only tool
would score 0% recall on this corpus by definition, because every case is already
grammatically correct.

The quality axes that decide the product — explanation usefulness, rewrite
diversity, intent preservation, and measurable risk reduction — are rated by humans
in `report/blind_rating_worksheet.csv` (labels held in `report/answer_key.csv`).

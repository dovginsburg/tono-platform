"""Detect retired free-tier quota claims in shipping product copy.

This production-owned policy is shared by release enforcement and regression tests.
"""

import re


def retired_quota_claims(source: str) -> list[str]:
    normalized = re.sub(r"\s*/\s*", " per ", source.lower())
    normalized = re.sub(r"-+", " ", normalized)
    chunks = [
        chunk
        for raw_chunk in re.split(r"[.!?;]+", normalized)
        if (chunk := re.sub(r"\s+", " ", raw_chunk).strip())
    ]
    free_pattern = (
        r"\b(?:complimentary|free(?!\s+form\b)|gratis|nonpaying|unpaid|"
        r"zero\s+price|on\s+the\s+house|no\s+(?:charge|cost)|"
        r"pay(?:s|ing)?\s+nothing|without\s+(?:paying|(?:a\s+)?paid\s+plan))\b"
    )
    recipient_pattern = r"\b(?:accounts?|members?|people|users?)\b"
    quantity_pattern = r"\b(?:10|ten|decuple)\b"
    service_pattern = (
        r"\b(?:coach(?:\s+(?:messages?|requests?|turns?))?|"
        r"coaching\s+(?:messages?|requests?|turns?)|edits?|editing|"
        r"polish(?:es|ing)?|rephras(?:e|es|ing)|revis(?:e|es|ing|ions?)|"
        r"rewrites?|text\s+improvements?|tune\s+ups?)\b"
        r"(?!\s+(?:(?:10|remaining|ten|to|up)\s+){0,4}"
        r"(?:articles?|badges?|certificates?|examples?|guides?|receipts?|reports?|"
        r"samples?|surveys?|tutorials?|vouchers?)\b)"
        r"(?!\s+(?!(?:access|after|allocated|allocation|allotted|allotment|allowance|"
        r"among|and|are|assigned|at|available|becomes?|before|belonging|belongs?|but|composes?|comprises?|"
        r"comes?|constitutes?|contains?|credited|daily|day|each|earmarked|entitlement|every|forms?|for|"
        r"from|go(?:es)?|grant|granted|in|is|nightly|of|on|or|per|provided|remain|"
        r"allotment|available|balance|benefit|control|decuple|held|it|its|make|our|owned|owners?|payable|"
        r"opportunities?|placed|possible|possession|property|ration|regain|replenished|requests?|"
        r"reset|reserved|rests?|restored|set|sits?|slots?|that|the|"
        r"their|them|they|this|those|ten|to|up|we|which|who|whose|you|your|"
        r"accrue(?:s)?)\b)[a-z]+\b)"
    )
    semantic_service_pattern = (
        r"\b(?:coach(?:\s+(?:messages?|requests?|turns?))?|"
        r"coaching\s+(?:messages?|requests?|turns?)|edits?|editing|"
        r"polish(?:es|ing)?|rephras(?:e|es|ing)|revis(?:e|es|ing|ions?)|"
        r"rewrites?|text\s+improvements?|tune\s+ups?)\b"
        r"(?!\s+(?:(?:10|remaining|ten|to|up)\s+){0,4}"
        r"(?:articles?|badges?|certificates?|examples?|guides?|receipts?|reports?|"
        r"samples?|surveys?|tips|tutorials?|vouchers?)\b)"
    )
    cadence_pattern = (
        r"(?:\b(?:daily|today|tomorrow|midnights?|morning|dawn|daybreaks?|sunrise|nightly|rollovers?|"
        r"24\s*(?:h|hours?)|twenty\s+four\s+hour(?:\s+cycle)?|day\s+by\s+day|"
        r"(?:a|each|every|per)\s+(?:(?:new\s+)?(?:calendar|utc)\s+)?(?:day|night|morning)|"
        r"once\s+per\s+day|the\s+following\s+morning|"
        r"(?:a|each|every|per)\s+(?:(?:new\s+)?(?:calendar|utc)\s+|new\s+)?date|"
        r"starts?\s+the\s+day|(?:the\s+)?date\s+changes?|"
        r"(?:the\s+)?day(?:'s)?\s+(?:first|opening)\s+moment|"
        r"(?:at|from|upon|when)\s+(?:the\s+)?(?:beginning|commencement)\s+of\s+each\s+day|"
        r"(?:once|when)\s+(?:a|each|the)\s+(?:fresh\s+|new\s+)?day\s+(?:begins|opens|starts|turns\s+over)|"
        r"when\s+(?:the\s+)?morning\s+arrives|"
        r"upon\s+each\s+day(?:'s)?\s+commencement|"
        r"(?:a|each|every|the)\s+(?:fresh\s+|new\s+)day(?:\s+(?:begins|opens|starts|supplies))?)\b|\b00:00\b)"
    )
    allocation_noun_pattern = (
        r"\b(?:allocations?|allowance|allotment|balance|credits?|plans?|quota|tiers?)\b"
    )
    free_entity_pattern = (
        r"(?:"
        + free_pattern
        + r"(?:\s+(?:plan|tier))?(?:,?\s+"
        + recipient_pattern
        + r")?|"
        + recipient_pattern
        + r"(?:\s+who)?\s+.{0,24}"
        + free_pattern
        + r")"
    )
    explicit_free_recipient_pattern = (
        r"(?:"
        + free_pattern
        + r"(?:\s+(?:plan|tier)|,?\s+"
        + recipient_pattern
        + r")|"
        + recipient_pattern
        + r"(?:\s+who)?\s+.{0,24}"
        + free_pattern
        + r")"
    )

    def has_quantity_and_service(text: str) -> bool:
        return bool(
            re.search(quantity_pattern, text)
            and re.search(semantic_service_pattern, text)
        )

    def has_bound_allocation(segment: str) -> bool:
        if not has_quantity_and_service(segment):
            return False

        if re.search(
            r"\b(?:beneficiary|beneficiaries)\s+of\s+(?:the\s+)?"
            + quantity_pattern
            + r".{0,50}\b(?:are|is)\s+"
            + free_entity_pattern,
            segment,
        ):
            return True

        association_subject_pattern = (
            r"\b(?!(?:allocation|allowance|allotment|balance|entitlement|grant|quota|ration)\b)"
            r"[a-z]+(?:\s+[a-z]+){0,2}\s+(?:of|to|for)\s+(?:the\s+)?"
            + free_entity_pattern
            + r"(?=\s+(?:(?:are|is)\s+(?:allocated|allotted|assigned|granted|provided)|"
            r"gets?|has|have|holds?|receives?))"
        )
        segment = re.sub(association_subject_pattern, "related people", segment)
        association_participle_subject_pattern = (
            r"\b[a-z]+(?:\s+[a-z]+){0,2}\s+"
            r"(?:representing|serving|studying)\s+(?:the\s+)?"
            + free_entity_pattern
            + r"(?=\s+(?:(?:are|is)\s+(?:allocated|allotted|assigned|granted|provided)|"
            r"gets?|has|have|holds?|receives?))"
        )
        segment = re.sub(association_participle_subject_pattern, "related people", segment)

        tight_quantity_service_pair = (
            r"(?:"
            + quantity_pattern
            + r".{0,40}"
            + service_pattern
            + r"|"
            + service_pattern
            + r".{0,40}"
            + quantity_pattern
            + r")"
        )
        semantic_quantity_service_pair = (
            r"(?:"
            + quantity_pattern
            + r".{0,40}"
            + semantic_service_pattern
            + r"|"
            + semantic_service_pattern
            + r".{0,40}"
            + quantity_pattern
            + r")"
        )
        allocation_noun = (
            r"(?:allocations?|allowances?|allotments?|balances?|credits?|entitlements?|"
            r"grants?|quotas?|rations?)"
        )
        subject_relation = (
            r"(?:can|may|gets?|has|have|holds?|receives?|includes?|permits?|provides?|"
            r"carries?|(?:are|is)\s+(?:credited(?:\s+with)?|entitled\s+to)|(?:are|is|get|gets)\s+"
            r"(?:allocated|allotted|assigned|granted|provided)|"
            r"(?:are|is)\s+(?:the\s+)?beneficiar(?:y|ies)\s+of)"
        )
        interposed_cadence = (
            r"(?:,?\s*(?:(?:at|on)\s+)?(?:each|every|per)\s+"
            r"(?:calendar\s+|utc\s+|new\s+)?(?:day|morning|night),?)?"
        )
        optional_allocation_noun = (
            r"(?:,?\s*(?:an?\s+)?(?:daily\s+)?"
            + allocation_noun
            + r"(?:\s+(?:is|of))?)?"
        )
        subject_beneficiary = re.search(
            free_entity_pattern
            + r"(?:'s|')?"
            + interposed_cadence
            + r",?\s+"
            + subject_relation
            + interposed_cadence
            + optional_allocation_noun
            + r"\s+(?:an?\s+)?"
            + tight_quantity_service_pair,
            segment,
        )
        possessive_allocation = re.search(
            free_entity_pattern
            + r"(?:'s|')\s+(?:daily\s+)?"
            + allocation_noun
            + r"\s*(?::|is|of|comprises?|consists\s+of|contains?)?\s*"
            + tight_quantity_service_pair,
            segment,
        )
        nominal_beneficiary = re.search(
            free_entity_pattern
            + interposed_cadence
            + r",?\s+(?:carries?|has|have)\s+(?:an?\s+)?"
            + allocation_noun
            + r"\s+(?:is\s+|of\s+)?"
            + tight_quantity_service_pair,
            segment,
        )
        allocation_to_beneficiary = re.search(
            tight_quantity_service_pair
            + r".{0,45}\b(?:accrue(?:s)?|go(?:es)?|(?:are\s+|is\s+)?"
            r"(?:allocated|allotted|assigned|credited|earmarked|granted|provided|"
            r"reserved|set\s+(?:apart|aside)))\b"
            r".{0,20}\b(?:among|for|to)\s+"
            + free_entity_pattern,
            segment,
        )
        relation_before_beneficiary = re.search(
            r"\b(?:allocated|allotted|assigned|credited|earmarked|granted|provided|"
            r"reserved|set\s+(?:apart|aside))\b.{0,45}\b(?:among|for|to)\s+"
            + free_entity_pattern
            + r".{0,45}"
            + tight_quantity_service_pair,
            segment,
        )
        nominal_pair_belongs_to_beneficiary = re.search(
            r"\b(?:allocation|allowance|allotment|entitlement|grant)\s+of\s+"
            + tight_quantity_service_pair
            + r".{0,25}\bbelongs?\s+to\s+"
            + free_entity_pattern,
            segment,
        )
        nominal_for_beneficiary_reordered = re.search(
            service_pattern
            + r"\s+(?:allocation|allowance|allotment|entitlement|grant)\s+for\s+"
            + free_entity_pattern
            + r".{0,25}\b(?:is|equals?)\s+"
            + quantity_pattern,
            segment,
        )
        brings_allowance_to_beneficiary = re.search(
            r"\bbrings?\s+(?:the\s+)?"
            + free_entity_pattern
            + r".{0,25}\b(?:allocation|allowance|allotment|entitlement|grant)\s+of\s+"
            + tight_quantity_service_pair,
            segment,
        )
        pair_constitutes_beneficiary_allowance = re.search(
            tight_quantity_service_pair
            + r".{0,15}\bconstitutes?\s+"
            + free_entity_pattern
            + r"(?:'s|')\s+(?:allocation|allowance|allotment|entitlement|grant)\b",
            segment,
        )
        beneficiary_precedes_accrual = re.search(
            r"\bto\s+"
            + free_entity_pattern
            + r".{0,15}\baccrue(?:s)?\s+"
            + tight_quantity_service_pair,
            segment,
        )
        active_relation_pair_to_beneficiary = re.search(
            r"\b(?:allocates?|allots?|assigns?|credits?|earmarks?|grants?|provides?|"
            r"reserves?|sets?\s+(?:apart|aside))\b.{0,20}"
            + tight_quantity_service_pair
            + r".{0,20}\b(?:among|for|to)\s+"
            + free_entity_pattern,
            segment,
        )
        beneficiary_credited_with_pair = re.search(
            free_entity_pattern
            + r".{0,20}\b(?:are|is|were|was)\s+credited\s+with\s+"
            + tight_quantity_service_pair,
            segment,
        )
        active_beneficiary_with_pair = re.search(
            r"\b(?:allocates?|allots?|assigns?|credits?|earmarks?|grants?|provides?|"
            r"reserves?)\b.{0,20}"
            + free_entity_pattern
            + r"\s+(?:with\s+)?"
            + tight_quantity_service_pair,
            segment,
        )
        beneficiary_holds_nominal_pair = re.search(
            free_entity_pattern
            + r".{0,20}\b(?:holds?|has|have)\s+(?:an?\s+)?(?:daily\s+)?"
            r"(?:allocation|allowance|allotment|entitlement|grant)\s+of\s+"
            + tight_quantity_service_pair,
            segment,
        )
        nominal_belongs_to_beneficiary_comprises_pair = re.search(
            r"\b(?:daily\s+)?(?:allocation|allowance|allotment|entitlement|grant)\s+"
            r"belonging\s+to\s+"
            + free_entity_pattern
            + r".{0,20}\b(?:comprises?|contains?|equals?|is)\s+"
            + tight_quantity_service_pair,
            segment,
        )
        pair_forms_beneficiary_nominal = re.search(
            tight_quantity_service_pair
            + r".{0,15}\b(?:comprises?|constitutes?|forms?)\s+(?:the\s+)?"
            r"(?:(?:daily|nightly)\s+)?(?:allocation|allowance|allotment|entitlement|grant)\s+"
            r"(?:belonging\s+to|of)\s+"
            + free_entity_pattern,
            segment,
        )
        beneficiary_precedes_nominal_pair = re.search(
            r"\b(?:for\s+)?"
            + free_entity_pattern
            + r".{0,20}\b(?:an?\s+)?(?:allocation|allowance|allotment|entitlement|grant)\s+"
            r"(?:comprising|consisting\s+of|containing)\s+"
            + tight_quantity_service_pair,
            segment,
        )
        nominal_pair_owned_by_beneficiary = re.search(
            r"\b(?:allocation|allowance|allotment|entitlement|grant)\s+of\s+"
            + tight_quantity_service_pair
            + r".{0,12}\b(?:is\s+)?(?:held|owned)\s+by\s+"
            + free_entity_pattern,
            segment,
        )
        pair_nominal_relation_to_beneficiary = re.search(
            tight_quantity_service_pair
            + r"\s+(?:allocation|allowance|allotment|entitlement|grant)\s+"
            r"(?:accruing\s+to|held\s+by|owned\s+by)\s+"
            + free_entity_pattern,
            segment,
        )
        active_to_beneficiary = re.search(
            r"\b(?:allocates?|allots?|assigns?|grants?|provides?)\b.{0,25}"
            r"\b(?:among|for|to)\s+"
            + free_entity_pattern
            + r".{0,45}"
            + tight_quantity_service_pair,
            segment,
        )
        active_service_to_beneficiary = re.search(
            r"\b(?:allocates?|allots?|assigns?|grants?|provides?)\b.{0,15}"
            + tight_quantity_service_pair
            + r".{0,35}\b(?:among|for|to)\s+"
            + free_entity_pattern,
            segment,
        )
        available_on_beneficiary = re.search(
            tight_quantity_service_pair
            + r"\s+(?:are|is)\s+available.{0,30}\b(?:for|on|to)\s+(?:the\s+)?"
            + free_entity_pattern,
            segment,
        )
        nominal_for_beneficiary = re.search(
            r"\bfor\s+"
            + free_entity_pattern
            + r".{0,35}\b(?:daily\s+)?(?:allocation|allowance|allotment|grant)\s+is\s+"
            + tight_quantity_service_pair,
            segment,
        )
        pair_reserved_for_beneficiary = re.search(
            r"\bfor\s+"
            + free_entity_pattern
            + r".{0,25}"
            + tight_quantity_service_pair
            + r"\s+(?:(?:are|is)\s+)?(?:earmarked|reserved|set\s+(?:apart|aside))\b",
            segment,
        )
        pair_belongs_to_beneficiary = re.search(
            tight_quantity_service_pair
            + r"\s+belongs?\s+to\s+"
            + free_entity_pattern,
            segment,
        )
        owned_nominal_contains_pair = re.search(
            r"\b(?:allocation|allowance|allotment|entitlement|grant|ration)\s+"
            r"(?:held|owned)\s+(?:by|for)\s+"
            + free_entity_pattern
            + r".{0,30}\b(?:comprises?|contains?|consists\s+of|is)\s+"
            + tight_quantity_service_pair,
            segment,
        )
        reordered_owned_nominal = re.search(
            r"\b(?:held|owned)\s+(?:by|for)\s+"
            + free_entity_pattern
            + r"\s+is\s+(?:an?\s+)?(?:allocation|allowance|allotment|entitlement|grant|ration)"
            r"(?:\s+of)?\s+"
            + tight_quantity_service_pair,
            segment,
        )
        pair_composes_beneficiary_nominal = re.search(
            tight_quantity_service_pair
            + r".{0,12}\b(?:composes?|makes?\s+up)\s+(?:the\s+)?(?:(?:daily|nightly)\s+)?"
            r"(?:allocation|allowance|allotment|entitlement|grant|ration)\s+of\s+"
            + free_entity_pattern,
            segment,
        )
        beneficiary_nominal_contains_pair = re.search(
            r"\b(?:allocation|allowance|allotment|entitlement|grant|ration)\s+of\s+"
            + free_entity_pattern
            + r".{0,15}\b(?:comprises?|contains?|consists\s+of|is)\s+"
            + tight_quantity_service_pair,
            segment,
        )
        reinstated_owned_nominal = re.search(
            r"\b(?:reinstates?|restores?)\s+(?:an?\s+)?"
            r"(?:allocation|allowance|allotment|entitlement|grant|ration)\s+of\s+"
            + tight_quantity_service_pair
            + r".{0,20}\b(?:owned\s+by|whose\s+owners?\s+are)\s+"
            + free_entity_pattern,
            segment,
        )
        nominal_beneficiaries_are_free = re.search(
            r"\bbeneficiar(?:y|ies)\s+of\s+(?:the\s+)?"
            + quantity_pattern
            + r".{0,40}"
            + service_pattern
            + r".{0,20}\b"
            r"(?:are|is)\s+"
            + free_entity_pattern,
            segment,
        )
        pair_nominal_is_property_of_beneficiary = re.search(
            tight_quantity_service_pair
            + r"\s+(?:allocation|allowance|allotment|entitlement|grant|ration)\s+"
            r"(?:are|is)\s+(?:the\s+)?property\s+of\s+"
            + free_entity_pattern,
            segment,
        )
        beneficiary_owns_pair = re.search(
            free_entity_pattern
            + r".{0,12}\b(?:owns?|(?:are|is)\s+owners?\s+of)\s+(?:an?\s+)?"
            + tight_quantity_service_pair,
            segment,
        )
        beneficiary_precedes_for_accrual = re.search(
            r"\bfor\s+"
            + free_entity_pattern
            + r".{0,15}\b"
            + tight_quantity_service_pair
            + r"\s+accrue(?:s)?\b",
            segment,
        )
        beneficiary_ownership_relation = re.search(
            r"(?:"
            + free_entity_pattern
            + r"(?:'s|')?.{0,24}\b(?:control(?:s)?|hold(?:s)?\s+title\s+to|"
            r"own(?:s)?|(?:are|is)\s+(?:the\s+)?proprietors?\s+of)\b.{0,35}"
            + tight_quantity_service_pair
            + r"|\bthere\s+belong(?:s)?\s+to\s+"
            + free_entity_pattern
            + r".{0,12}"
            + tight_quantity_service_pair
            + r"|"
            + tight_quantity_service_pair
            + r".{0,30}\b(?:belong(?:s)?\s+to|(?:rests?|lies?)\s+(?:in|with)|"
            r"(?:are|is)\s+assigned\s+to)\s+"
            + free_entity_pattern
            + r"|\bownership\s+of\s+(?:the\s+)?"
            + tight_quantity_service_pair
            + r".{0,18}\blies?\s+with\s+"
            + free_entity_pattern
            + r")",
            segment,
        )
        nominal_ownership_relation = re.search(
            r"(?:"
            + allocation_noun
            + r"(?:\s+of)?\s+"
            + tight_quantity_service_pair
            + r".{0,30}\b(?:rests?\s+in|lies?\s+with|is\s+for\s+the\s+benefit\s+of|"
            r"is\s+payable\s+to)\s+"
            + free_entity_pattern
            + r"|"
            + tight_quantity_service_pair
            + r".{0,20}\b(?:make(?:s)?\s+up|sit(?:s)?)\s+(?:an?\s+)?"
            + allocation_noun
            + r".{0,18}\b(?:under\s+)?"
            + free_entity_pattern
            + r"(?:'s|')?\s+(?:ownership|possession)\b"
            + r")",
            segment,
        )
        recipient_nominal_relation = re.search(
            r"(?:\b(?:designated\s+)?recipients?\s+of\s+(?:an?\s+)?"
            + allocation_noun
            + r".{0,18}"
            + tight_quantity_service_pair
            + r".{0,12}\b(?:are|is)\s+"
            + free_entity_pattern
            + r"|\b(?:the\s+)?party\s+entitled\s+to\s+"
            + tight_quantity_service_pair
            + r".{0,12}\b(?:are|is)\s+(?:each\s+)?"
            + free_entity_pattern
            + r")",
            segment,
        )
        compositional_role_binding = bool(
            re.search(free_entity_pattern, segment)
            and re.search(tight_quantity_service_pair, segment)
            and re.search(
                r"\b(?:assigned|available|belong(?:s)?|benefit|control(?:s)?|entitled|hold(?:s)?|"
                r"ownership|own(?:s)?|payable|possession|proprietors?|recipients?|"
                r"regain(?:ed|s)?|rests?|title)\b",
                segment,
            )
            and not re.search(
                r"\b(?:representing|serving|studying)\s+(?:the\s+)?"
                + free_entity_pattern,
                segment,
            )
        )
        nominal_pair_passive_owner = re.search(
            r"\b"
            + allocation_noun
            + r"\s+(?:comprising|consisting\s+of|containing)\s+"
            + tight_quantity_service_pair
            + r".{0,18}\b(?:is\s+)?(?:held|owned|possessed)\s+by\s+"
            + free_entity_pattern,
            segment,
        )
        pair_passive_owner = re.search(
            tight_quantity_service_pair
            + r".{0,18}\b(?:are|is)?\s*(?:held|owned|possessed)\s+by\s+"
            + free_entity_pattern,
            segment,
        )
        beneficiary_relative_nominal = re.search(
            r"\b"
            + allocation_noun
            + r"\s+whose\s+beneficiar(?:y|ies)\s+(?:are|is)\s+"
            + free_entity_pattern
            + r".{0,18}\b(?:comprises?|consists\s+of|contains?)\s+"
            + tight_quantity_service_pair,
            segment,
        )
        pair_forms_nominal_for_beneficiary = re.search(
            tight_quantity_service_pair
            + r".{0,12}\bforms?\s+(?:an?\s+)?"
            + allocation_noun
            + r"\s+for\s+"
            + free_entity_pattern,
            segment,
        )
        pair_nominal_is_beneficiary_property = re.search(
            tight_quantity_service_pair
            + r"\s+"
            + allocation_noun
            + r"\s+(?:are|is)\s+(?:those\s+)?"
            + free_entity_pattern
            + r"(?:'s|')\s+property\b",
            segment,
        )
        cadence_restores_owned_nominal = re.search(
            cadence_pattern
            + r".{0,18}\b(?:replenish(?:es)?|restore(?:s)?|return(?:s)?)\s+(?:the\s+)?"
            + allocation_noun
            + r"(?:\s+of)?\s+"
            + tight_quantity_service_pair
            + r".{0,18}\b(?:belonging\s+to|held\s+by|owned\s+by)\s+"
            + free_entity_pattern,
            segment,
        )
        cadence_restores_beneficiary_nominal_with_pair = re.search(
            cadence_pattern
            + r".{0,25}\b"
            + allocation_noun
            + r"\s+of\s+"
            + free_entity_pattern
            + r"\s+(?:are|is)\s+(?:replenished|restored)\s+with\s+(?:its\s+)?"
            + tight_quantity_service_pair,
            segment,
        )
        event_state_allocation = bool(
            re.search(free_entity_pattern, segment)
            and re.search(cadence_pattern, segment)
            and re.search(
                r"\b(?:"
                r"(?:unlock|activate)s?(?:\s+(?:an?\s+)?(?:package|bundle))?|"
                r"starts?\s+the\s+day\s+able\s+to|"
                r"becomes?\s+usable(?:\s+by)?|"
                r"capacity\s+to\b.{0,45}\b(?:are|is)\s+restored|"
                r"once\s+more\s+(?:can|may)|"
                r"(?:are|is)\s+limited\s+to|"
                r"begins?\s+each\s+(?:calendar\s+)?date\s+with|"
                r"can\s+make\b.{0,24}\bmore|"
                r"restores?\s+permission(?:\s+for)?"
                r")\b",
                segment,
            )
        )
        scope_artifact_modifier = re.search(
            r"(?:"
            + service_pattern
            + r"|"
            + quantity_pattern
            + r").{0,24}\b(?:articles?|badges?|certificates?|examples?|guides?|"
            r"receipts?|reports?|samples?|surveys?|tutorials?|vouchers?)\b",
            segment,
        )
        semantic_artifact_context = re.search(
            r"\b(?:articles?|badges?|certificates?|consultations?|documentation|examples?|guides?|"
            r"handbooks?|histories|invoices?|manuals?|newsletters?|receipts?|reports?|"
            r"samples?|seminars?|surveys?|templates?|tips|tutorials?|vouchers?|warranties)\b",
            segment,
        )
        non_beneficiary_role = re.search(
            r"(?:"
            r"^(?:the\s+)?[a-z]+(?:\s+[a-z]+){0,2}\s+(?:of|to|for)\s+(?:the\s+)?"
            + explicit_free_recipient_pattern
            + r"|"
            + semantic_quantity_service_pair
            + r".{0,24}\b(?:by|from)\s+(?:each\s+|every\s+)?"
            + explicit_free_recipient_pattern
            + r"|"
            + explicit_free_recipient_pattern
            + r".{0,24}\b(?:compare|compares|count|counts|discuss|discusses|download|downloads|"
            r"inspect|inspects|publish|publishes|read|reads|review|reviews|tag|tags|view|views)\b"
            r")",
            segment,
        )
        # Bind the policy's semantic roles instead of requiring an allowlisted
        # allocation verb: recipient + cadence + quantity + coaching service.
        recurring_semantic_benefit = bool(
            re.search(explicit_free_recipient_pattern, segment)
            and re.search(cadence_pattern, segment)
            and re.search(semantic_quantity_service_pair, segment)
            and not scope_artifact_modifier
            and not semantic_artifact_context
            and not non_beneficiary_role
        )
        directly_free_relation = (
            not re.search(r"\b(?:paid|premium|pro|subscribers?)\b", segment)
            and (
                re.search(
                    r"(?:"
                    + free_pattern
                    + r"\s*,?\s*"
                    + tight_quantity_service_pair
                    + r"|"
                    + quantity_pattern
                    + r".{0,15}"
                    + free_pattern
                    + r".{0,25}"
                    + service_pattern
                    + r")",
                    segment,
                )
                or re.search(r"\bincluded\b", segment)
            )
            and re.search(
                r"(?:\b(?:comes?\s+with|gets?|includes?|permits?|provides?|"
                r"allocates?|allots?|assigns?|grants?)\b.{0,40}"
                + tight_quantity_service_pair
                + r"|"
                + tight_quantity_service_pair
                + r"(?:\s+(?:per|each|every)\s+(?:calendar\s+|utc\s+|new\s+)?day)?"
                + r"\s+(?:(?:are|is)\s+)?(?:available|allocated|allotted|assigned|granted|provided|"
                r"reappears?|refresh(?:es)?|reloads?|renew(?:s)?|replenish(?:ed|es)?|"
                r"reset(?:s)?|restore(?:d|s)?|returns?)\b)",
                segment,
            )
        )
        return bool(
            subject_beneficiary
            or possessive_allocation
            or nominal_beneficiary
            or allocation_to_beneficiary
            or relation_before_beneficiary
            or nominal_pair_belongs_to_beneficiary
            or nominal_for_beneficiary_reordered
            or brings_allowance_to_beneficiary
            or pair_constitutes_beneficiary_allowance
            or beneficiary_precedes_accrual
            or active_relation_pair_to_beneficiary
            or beneficiary_credited_with_pair
            or active_beneficiary_with_pair
            or beneficiary_holds_nominal_pair
            or nominal_belongs_to_beneficiary_comprises_pair
            or pair_forms_beneficiary_nominal
            or beneficiary_precedes_nominal_pair
            or nominal_pair_owned_by_beneficiary
            or pair_nominal_relation_to_beneficiary
            or active_to_beneficiary
            or active_service_to_beneficiary
            or available_on_beneficiary
            or nominal_for_beneficiary
            or pair_reserved_for_beneficiary
            or pair_belongs_to_beneficiary
            or owned_nominal_contains_pair
            or reordered_owned_nominal
            or pair_composes_beneficiary_nominal
            or beneficiary_nominal_contains_pair
            or reinstated_owned_nominal
            or nominal_beneficiaries_are_free
            or pair_nominal_is_property_of_beneficiary
            or beneficiary_owns_pair
            or beneficiary_precedes_for_accrual
            or beneficiary_ownership_relation
            or nominal_ownership_relation
            or recipient_nominal_relation
            or compositional_role_binding
            or nominal_pair_passive_owner
            or pair_passive_owner
            or beneficiary_relative_nominal
            or pair_forms_nominal_for_beneficiary
            or pair_nominal_is_beneficiary_property
            or cadence_restores_owned_nominal
            or cadence_restores_beneficiary_nominal_with_pair
            or event_state_allocation
            or recurring_semantic_benefit
            or directly_free_relation
        )

    def allocation_clauses(segment: str) -> list[str]:
        """Separate contrasted plan propositions without splitting ordinary syntax."""
        return [
            clause.strip(" ,")
            for clause in re.split(
                r"\s*(?:,\s*)?\b(?:but|unlike|whereas|while)\b\s*",
                segment,
            )
            if clause.strip(" ,")
        ]

    continuation_reference_pattern = (
        r"\b(?:access|allocations?|allowances?|allotments?|balances?|credits?|"
        r"cycles?|entitlements?|grants?|issuances?|quotas?|rations?|stocks?|"
        r"renewals?|replenishments?|restorations?)\b"
    )
    continuation_action_pattern = (
        r"\b(?:becomes?\s+available\s+again|comes?\s+back|happens?|is|occurs?|reappears?|"
        r"refresh(?:es)?|reloads?|"
        r"reconstitut(?:ed|es?)|recreat(?:ed|es?)|refill(?:ed|s)?|regain(?:ed|s)?|"
        r"renew(?:s)?|repeats?|replenish(?:ed|es)?|reset(?:s)?|restore(?:d|s)?|"
        r"suppl(?:ied|ies)|returns?)\b"
    )
    depletion_bridge_pattern = (
        r"\b(?:consum(?:ed|ption)|dormant|empt(?:ied|ies)|exhaust(?:ed|ion)|spent)\b"
    )

    for chunk_index in range(1, len(chunks)):
        clause = chunks[chunk_index]
        prior_clause = chunks[chunk_index - 1]
        inherited_service = re.search(service_pattern, prior_clause)
        paid_service = inherited_service or re.search(
            r"\b(?:coach(?:ing)?\s+(?:turns?|requests?)|edits?|editing|revisions?|"
            r"rewrites?|text\s+improvements?|tune\s+ups?)\b",
            prior_clause,
        )
        if (
            paid_service
            and re.search(r"\b(?:paid|premium|pro|subscribers?)\b", prior_clause)
            and re.search(
                r"\b(?:boundless|ceiling|endless|indefinitely|limitless|restriction|"
                r"uncapped|unlimited|unrestricted)\b",
                prior_clause,
            )
            and re.search(free_entity_pattern, clause)
            and re.search(quantity_pattern, clause)
            and re.search(cadence_pattern, clause)
            and (
                re.search(
                    r"\b(?:allocated|allotted|assigned|credited|gets?|granted|provided|"
                    r"receives?|supplied)\b",
                    clause,
                )
                or re.search(
                    free_entity_pattern
                    + r"\s*,?\s*(?:(?:however|instead),?\s*|by\s+comparison,?\s*)?"
                    + quantity_pattern,
                    clause,
                )
            )
            and not re.search(service_pattern, clause)
        ):
            chunks[chunk_index] = f"{clause} rewrites"

    def has_bound_continuation(segments: list[str], allocation_index: int) -> bool:
        """Require a later cadence to belong to the detected allocation chain."""
        continuation_started = False
        cadence_seen = False
        for segment in segments[allocation_index + 1 :]:
            is_depletion_bridge = bool(re.search(depletion_bridge_pattern, segment))
            has_reference_action = bool(
                (
                    re.search(continuation_reference_pattern, segment)
                    or re.search(r"\b(?:it|that|this|those|they)\b", segment)
                )
                and re.search(continuation_action_pattern, segment)
            )
            is_chain_carrier = bool(
                re.match(
                    r"^(?:(?:after|at|each|every|on|once|the\s+next)\b|"
                    r"(?:it|its|that|this|those|their|they|your)\b)",
                    segment,
                )
                and (
                    re.search(continuation_action_pattern, segment)
                    or re.search(cadence_pattern, segment)
                )
            )
            cadence_seen = cadence_seen or bool(re.search(cadence_pattern, segment))
            if is_depletion_bridge:
                continuation_started = True
                continue
            if has_reference_action:
                continuation_started = True
            elif not (continuation_started and is_chain_carrier):
                return False
            if continuation_started and cadence_seen:
                return True
        return False

    claims = []
    for index in range(len(chunks)):
        max_width = min(4, len(chunks) - index)
        for width in range(1, max_width + 1):
            segments = chunks[index : index + width]
            chunk = " ".join(segments)
            excluded_context = re.search(
                r"\b(?:analytics?|historical|legacy|metrics?|migrat(?:e|ed|ing|ion)|previously|retired|telemetry|tracking|used to)\b",
                chunk,
            )
            clauses_by_segment = [allocation_clauses(segment) for segment in segments]
            bound_allocations = [
                (segment_index, clause)
                for segment_index, clauses in enumerate(clauses_by_segment)
                for clause in clauses
                if has_bound_allocation(clause)
                and (
                    re.search(free_pattern, clause)
                    or (
                        re.search(r"\bincluded\b", clause)
                        and not re.search(
                            r"\b(?:paid|premium|pro|subscription)\b",
                            clause,
                        )
                    )
                )
            ]
            reordered_free_subject = re.search(
                recipient_pattern
                + r".{0,30}\b(?:can|may|gets?|receives?)\b.{0,45}(?:"
                + quantity_pattern
                + r".{0,35}"
                + service_pattern
                + r"|"
                + service_pattern
                + r".{0,35}"
                + quantity_pattern
                + r").{0,100}\b(?:they|those\s+people)\b.{0,25}"
                + free_pattern,
                chunk,
            )
            direct_quota_claim = re.search(
                r"(?:"
                + quantity_pattern
                + r".{0,15}"
                + free_pattern
                + r".{0,25}"
                + service_pattern
                + r"|"
                + free_pattern
                + r"\s+(?:plan|tier|allocation|allowance|allotment|balance|credits?|quota)"
                + r".{0,45}(?:"
                + quantity_pattern
                + r".{0,35}"
                + service_pattern
                + r"|"
                + service_pattern
                + r".{0,35}"
                + quantity_pattern
                + r")|(?:"
                + quantity_pattern
                + r".{0,35}"
                + service_pattern
                + r"|"
                + service_pattern
                + r".{0,35}"
                + quantity_pattern
                + r").{0,45}"
                + free_pattern
                + r"\s+(?:plan|tier)|"
                + r"(?:"
                + quantity_pattern
                + r".{0,35}"
                + service_pattern
                + r"|"
                + service_pattern
                + r".{0,35}"
                + quantity_pattern
                + r").{0,25}\bincluded\b|"
                + r"\bincluded\b.{0,45}(?:"
                + quantity_pattern
                + r".{0,35}"
                + service_pattern
                + r"|"
                + service_pattern
                + r".{0,35}"
                + quantity_pattern
                + r"))",
                chunk,
            )
            quota_continuation = (
                has_quantity_and_service(chunk)
                and direct_quota_claim
                and re.search(allocation_noun_pattern, chunk)
                and (
                    re.search(
                        r"\b(?:is|reappears?|refresh(?:es)?|reloads?|renew(?:s)?|"
                        r"replenish(?:ed|es)?|reset(?:s)?|restore(?:d|s)?|returns?)\b",
                        chunk,
                    )
                    or re.search(r"\b(?:no\s+charge|complimentary|free|gratis)\s+plan\b", chunk)
                )
            )
            clause_local_claim = any(
                re.search(cadence_pattern, clause)
                or has_bound_continuation(segments, segment_index)
                for segment_index, clause in bound_allocations
            )
            reordered_continuation = bool(
                reordered_free_subject
                and re.search(cadence_pattern, chunk)
                and re.search(continuation_reference_pattern, chunk)
                and re.search(continuation_action_pattern, chunk)
            )
            legacy_included_continuation = bool(
                quota_continuation
                and re.search(cadence_pattern, chunk)
                and not re.search(
                    r"\b(?:paid|premium|pro|subscription)\b",
                    chunk,
                )
            )
            paid_to_free_ellipsis = any(
                re.search(r"\b(?:paid|premium|pro|subscribers?)\b", prior)
                and re.search(
                    r"\b(?:coach(?:ing)?\s+(?:turns?|requests?)|edits?|editing|revisions?|"
                    r"rewrites?|text\s+improvements?|tune\s+ups?)\b",
                    prior,
                )
                and re.search(
                    r"\b(?:boundless|ceiling|endless|indefinitely|limitless|restriction|"
                    r"uncapped|unlimited|unrestricted)\b",
                    prior,
                )
                and re.search(free_entity_pattern, current)
                and re.search(quantity_pattern, current)
                and re.search(cadence_pattern, current)
                and re.search(
                    r"\b(?:allocated|allotted|assigned|credited|gets?|granted|provided|"
                    r"receives?|supplied|however|instead|comparison)\b",
                    current,
                )
                for prior, current in zip(segments, segments[1:])
            )
            if (
                not excluded_context
                and (
                    clause_local_claim
                    or reordered_continuation
                    or legacy_included_continuation
                    or paid_to_free_ellipsis
                )
            ):
                claims.append(chunk)
                break
    return claims

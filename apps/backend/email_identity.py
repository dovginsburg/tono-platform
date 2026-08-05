"""Email registration identity — normalization, lifecycle, and the shared
anti-enumerating vocabulary every Tono client speaks (build 114).

Why this module exists at all
----------------------------
Before build 114 the iOS client called ``/v1/auth/request-link`` and
``/v1/auth/verify-otp``; neither endpoint existed on the server, and
``/v1/me`` never returned the ``email`` / ``email_verified_at`` fields the
client already decoded. The account path was a client-side fiction. Build
114 closes it against the authority that already exists — Supabase owns
``auth.users`` (passwords, verification links, reset links); this backend
owns the canonical person UUID, the product registration record, and the
audit trail.

The split matters: this process must never see a password, a verification
token, or a reset token. What it owns is the *product* fact — "which
canonical account is this, what lifecycle state is its email identity in,
when did that change, and from which surface".

Three invariants live here because they are the ones a mutation can quietly
break:

1. **Normalization is a comparison key, not a rewrite.** Case is folded
   (Supabase lowercases addresses, so if we did not fold we would create
   collisions the provider itself cannot represent), but dots and ``+`` tags
   are PRESERVED. Stripping them is a silent-merge vector:
   ``victim+anything@gmail.com`` would collapse onto ``victim@gmail.com``
   and hand an attacker someone else's account.

2. **Email is never a merge key.** The canonical principal is the immutable
   account UUID, resolved from the provider subject. A normalized email that
   already belongs to a *different* verified account is a CONFLICT, never a
   merge — see ``store.upsert_registration``.

3. **The consumer vocabulary is closed and generic.** Signup, resend and
   reset all answer from ``ENUMERATION_SAFE_OUTCOME`` regardless of whether
   the address exists, so no caller can use Tono as an account oracle.
"""

from __future__ import annotations

import re
import unicodedata
from typing import Optional

# ---------------------------------------------------------------------------
# Normalization
# ---------------------------------------------------------------------------

# RFC 5321 caps the whole address at 254 octets and the local part at 64.
# We enforce both: an over-long address is not a real mailbox, and unbounded
# input would otherwise reach the store as an unbounded index key.
_MAX_EMAIL_LENGTH = 254
_MAX_LOCAL_LENGTH = 64

# Deliberately strict rather than RFC-complete. Quoted local parts and
# bracketed IP-literal domains are legal RFC 5321 and are also things no
# consumer signup needs; accepting them would widen the normalization surface
# (and therefore the collision surface) for no user-visible gain.
_LOCAL_RE = re.compile(r"^[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+)*$")
_DOMAIN_LABEL_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$")


class EmailNormalizationError(ValueError):
    """The supplied string is not a usable mailbox. Callers must translate
    this into the generic consumer outcome — never echo the reason back."""


def normalize_email(raw: Optional[str]) -> str:
    """Return the canonical comparison form of ``raw``.

    Folds Unicode to NFKC and lowercases BOTH halves. Lowercasing the local
    part is a deliberate departure from RFC 5321's case-sensitivity: Supabase
    (the auth authority) lowercases addresses, so treating ``A@x.com`` and
    ``a@x.com`` as distinct here would produce two Tono registrations that the
    provider can only ever back with one ``auth.users`` row.

    Dots and ``+`` tags survive untouched — see invariant 1 in the module
    docstring.

    Raises ``EmailNormalizationError`` for anything that is not a mailbox.
    """
    if raw is None:
        raise EmailNormalizationError("empty")
    # NFKC first: it collapses full-width and compatibility characters, so a
    # look-alike address cannot present as a "different" mailbox.
    value = unicodedata.normalize("NFKC", raw).strip()
    if not value:
        raise EmailNormalizationError("empty")
    # Any interior whitespace (including the Unicode spaces NFKC leaves alone)
    # or control character means this was never a single address.
    if any(ch.isspace() or ord(ch) < 0x20 or ord(ch) == 0x7F for ch in value):
        raise EmailNormalizationError("whitespace or control character")
    if len(value) > _MAX_EMAIL_LENGTH:
        raise EmailNormalizationError("too long")
    # Split on the LAST '@': the local part may legally contain one in a
    # quoted form we reject below, but splitting on the first would silently
    # mis-parse it into a domain we then lowercase.
    local, sep, domain = value.rpartition("@")
    if not sep or not local or not domain:
        raise EmailNormalizationError("not an address")
    if "@" in local:
        raise EmailNormalizationError("multiple @")
    if len(local) > _MAX_LOCAL_LENGTH:
        raise EmailNormalizationError("local part too long")
    if not _LOCAL_RE.match(local):
        raise EmailNormalizationError("unsupported local part")
    labels = domain.split(".")
    if len(labels) < 2 or not all(_DOMAIN_LABEL_RE.match(lbl) for lbl in labels):
        raise EmailNormalizationError("unsupported domain")
    return f"{local.lower()}@{domain.lower()}"


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

# The only lifecycle states a product registration can hold. ``pending`` is a
# real, user-visible state ("check your email"), not a transient: a person can
# close the app, reinstall, and come back to it.
STATE_PENDING = "pending"
STATE_VERIFIED = "verified"
STATE_DISABLED = "disabled"

LIFECYCLE_STATES = frozenset({STATE_PENDING, STATE_VERIFIED, STATE_DISABLED})

# Event vocabulary. Closed on purpose, and enforced at the STORE
# (``Store._insert_registration_event`` raises on anything outside this set),
# so no request path can put free text — and therefore no token, address or
# payload — into the audit trail.
#
# Note what this vocabulary deliberately does NOT include: there is no
# client-submitted event endpoint at all. Every code below is written by the
# server, from something it either did itself or verified itself. A client can
# cause an event by making a request; it can never name one.
EVENT_SIGNUP_REQUESTED = "signup_requested"
EVENT_VERIFICATION_RESENT = "verification_resent"
EVENT_VERIFICATION_COMPLETED = "verification_completed"
EVENT_VERIFICATION_PENDING_BLOCKED = "verification_pending_blocked"
EVENT_SIGN_IN = "sign_in"
EVENT_SIGN_OUT = "sign_out"
EVENT_PASSWORD_RESET_REQUESTED = "password_reset_requested"
EVENT_MAGIC_LINK_REQUESTED = "magic_link_requested"
EVENT_IDENTITY_CONFLICT = "identity_conflict"
EVENT_PROVIDER_UNAVAILABLE = "provider_unavailable"

# Events recorded because a person ASKED for something (register, resend,
# reset) or because the attempt could not be served. They describe a request,
# never a proof, so none of them may move a registration toward `verified`.
REQUEST_EVENTS = frozenset(
    {
        EVENT_SIGNUP_REQUESTED,
        EVENT_VERIFICATION_RESENT,
        EVENT_PASSWORD_RESET_REQUESTED,
        EVENT_MAGIC_LINK_REQUESTED,
        EVENT_PROVIDER_UNAVAILABLE,
        EVENT_VERIFICATION_PENDING_BLOCKED,
    }
)

# Events recorded because the server OBSERVED a fact it verified itself: a
# provider-confirmed address, a completed sign-in, a sign-out it performed, or
# a collision it refused to merge.
OBSERVED_EVENTS = frozenset(
    {
        EVENT_VERIFICATION_COMPLETED,
        EVENT_SIGN_IN,
        EVENT_SIGN_OUT,
        EVENT_IDENTITY_CONFLICT,
    }
)

EVENT_TYPES = REQUEST_EVENTS | OBSERVED_EVENTS

# Which state an event moves a registration to. Absent = no state change (the
# event is audit-only). A verified registration is NEVER walked back to
# pending by a request event: only the server, on evidence, may disable one.
_STATE_TRANSITIONS = {
    EVENT_SIGNUP_REQUESTED: STATE_PENDING,
    EVENT_VERIFICATION_COMPLETED: STATE_VERIFIED,
}


def next_state(current: Optional[str], event: str) -> str:
    """Resolve the lifecycle state after ``event``.

    Monotonic in the direction that matters: once ``verified``, no event in
    ``REQUEST_EVENTS`` can return the registration to ``pending``. A caller
    replaying ``signup_requested`` against a verified account is an audit fact,
    not a downgrade — otherwise anyone holding a device bearer could un-verify
    the account they are signed into.
    """
    if current is not None and current not in LIFECYCLE_STATES:
        raise ValueError(f"unknown lifecycle state: {current}")
    if event not in EVENT_TYPES:
        raise ValueError(f"unknown registration event: {event}")
    target = _STATE_TRANSITIONS.get(event)
    if target is None:
        return current or STATE_PENDING
    if current == STATE_VERIFIED and target == STATE_PENDING:
        return STATE_VERIFIED
    if current == STATE_DISABLED:
        # A disabled registration is a deliberate administrative end-state.
        # Nothing a client reports reopens it.
        return STATE_DISABLED
    return target


# ---------------------------------------------------------------------------
# Surfaces / build tags
# ---------------------------------------------------------------------------

SURFACE_WEB = "web"
SURFACE_IOS = "ios"
SURFACE_ANDROID = "android"
SURFACE_UNKNOWN = "unknown"

SOURCE_SURFACES = frozenset({SURFACE_WEB, SURFACE_IOS, SURFACE_ANDROID, SURFACE_UNKNOWN})

_APP_BUILD_RE = re.compile(r"^[A-Za-z0-9._+-]{1,32}$")


def sanitize_source_surface(raw: Optional[str]) -> str:
    """Clamp to the known surface set. Unknown input becomes ``unknown``
    rather than 400-ing: an audit row with a vague surface is strictly better
    than losing the registration event because a future client sent a new
    string."""
    if raw is None:
        return SURFACE_UNKNOWN
    value = raw.strip().lower()
    return value if value in SOURCE_SURFACES else SURFACE_UNKNOWN


def sanitize_app_build(raw: Optional[str]) -> Optional[str]:
    """Accept a short build tag (``114``, ``1.1.0+114``) or nothing.

    Bounded charset AND length: this string is written to an audit row and
    read back by ``/admin/registrations``, so an unbounded client value would
    be a log-injection and storage-growth vector. Anything unexpected becomes
    ``None`` — an absent build tag is honest; a truncated arbitrary payload is
    not.
    """
    if raw is None:
        return None
    value = raw.strip()
    if not value or not _APP_BUILD_RE.match(value):
        return None
    return value


# ---------------------------------------------------------------------------
# Anti-enumeration
# ---------------------------------------------------------------------------

# The ONE answer signup / resend / reset give when the request was accepted,
# whether or not the address is registered. Clients render their own copy from
# this key; the key itself never varies with account existence.
ENUMERATION_SAFE_OUTCOME = "check_your_email"

# Distinct consumer outcomes that are NOT enumeration signals, because they
# describe the request rather than the account. Keeping them distinct is a
# requirement, not a nicety: collapsing "wait then retry" into "something went
# wrong" is how a rate limit starts reading as a dead account.
OUTCOME_INVALID_INPUT = "invalid_input"
OUTCOME_RATE_LIMITED = "rate_limited"
OUTCOME_OFFLINE = "offline"
OUTCOME_PROVIDER_UNAVAILABLE = "provider_unavailable"
OUTCOME_LINK_EXPIRED = "link_expired"
OUTCOME_VERIFICATION_PENDING = "verification_pending"
OUTCOME_ACCOUNT_CONFLICT = "account_conflict"
OUTCOME_UNKNOWN_FAILURE = "unknown_failure"

CONSUMER_OUTCOMES = frozenset(
    {
        ENUMERATION_SAFE_OUTCOME,
        OUTCOME_INVALID_INPUT,
        OUTCOME_RATE_LIMITED,
        OUTCOME_OFFLINE,
        OUTCOME_PROVIDER_UNAVAILABLE,
        OUTCOME_LINK_EXPIRED,
        OUTCOME_VERIFICATION_PENDING,
        OUTCOME_ACCOUNT_CONFLICT,
        OUTCOME_UNKNOWN_FAILURE,
    }
)

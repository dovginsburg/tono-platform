"""Immutable release-control models.

Each model is a ``tuple`` subclass with ``__slots__ = ()``. That gives the
strongest pure-Python immutability available: there is no instance ``__dict__``
and no writable slot, so direct assignment, ``object.__setattr__``, item
assignment, and slot-descriptor bypass all fail closed. There is no
``_replace``/``_set``/``_make``/``update`` helper. Fields are exposed through
read-only ``property`` descriptors backed by ``tuple.__getitem__``.

Construction is total for ordinary Exception-derived hostility: hostile inputs
are normalized to safe built-ins or drop the object to an inert ``valid=False``
state. Only the rules-iterable ingestion deliberately touches caller iteration
code, and it catches ``Exception`` (never ``BaseException``).
"""

from __future__ import annotations

from . import _normalize as N


class _Frozen(tuple):
    """Base for immutable tuple-backed records."""

    __slots__ = ()

    def __init__(self, *args, **kwargs):
        # __new__ already built the tuple; keep object.__init__ from rejecting
        # the constructor arguments across CPython versions.
        pass

    def __setattr__(self, name, value):
        raise AttributeError("release-control objects are immutable")

    def __delattr__(self, name):
        raise AttributeError("release-control objects are immutable")

    def __repr__(self):
        return "%s(...)" % type(self).__name__


def _get(obj, index):
    return tuple.__getitem__(obj, index)


# --- ReleaseRule ----------------------------------------------------------
# (valid, flag, cohort, allowlist, requires_authority, requires_ready,
#  min_build, required_schema, killed, has_ttl, ttl_valid, expires_at)

class ReleaseRule(_Frozen):
    __slots__ = ()

    def __new__(cls, flag=None, cohort=0, allowlist=(), requires_authority=False,
                requires_ready=False, min_build=0, required_schema=0,
                killed=False, expires_at=None):
        vflag = N.norm_flag(flag)
        vcohort = N.norm_cohort(cohort)
        vallow = N.norm_allowlist(allowlist)
        vauth = N.norm_bool(requires_authority)
        vready = N.norm_bool(requires_ready)
        vbuild = N.norm_build(min_build)
        vschema = N.norm_schema(required_schema)
        vkilled = N.norm_bool(killed)
        has_ttl, ttl_valid, vexp = N.norm_expires_at(expires_at)
        valid = vflag is not None
        return tuple.__new__(cls, (
            valid, vflag if vflag is not None else "", vcohort, vallow,
            vauth, vready, vbuild, vschema, vkilled, has_ttl, ttl_valid, vexp,
        ))

    @classmethod
    def from_mapping(cls, payload):
        """Build a rule from an exact dict, reading only genuine-str keys.

        Never probes/rehashes caller keys: it iterates ``.items()`` once and
        copies genuine-str-keyed entries into an internal dict, then reads that
        internal dict. A non-dict, or any non-genuine-str key, yields an inert
        (``valid=False``) rule. Never raises for Exception-derived hostility.
        """
        if type(payload) is not dict:
            return cls(flag=None)
        fields = {}
        try:
            for k, v in payload.items():
                if type(k) is not str:
                    return cls(flag=None)  # malformed mapping -> inert
                fields[k] = v
        except Exception:
            return cls(flag=None)
        return cls(
            flag=fields.get("flag"),
            cohort=fields.get("cohort", 0),
            allowlist=fields.get("allowlist", ()),
            requires_authority=fields.get("requires_authority", False),
            requires_ready=fields.get("requires_ready", False),
            min_build=fields.get("min_build", 0),
            required_schema=fields.get("required_schema", 0),
            killed=fields.get("killed", False),
            expires_at=fields.get("expires_at", None),
        )

    @property
    def valid(self):
        return _get(self, 0)

    @property
    def flag(self):
        return _get(self, 1)

    @property
    def cohort(self):
        return _get(self, 2)

    @property
    def allowlist(self):
        return _get(self, 3)

    @property
    def requires_authority(self):
        return _get(self, 4)

    @property
    def requires_ready(self):
        return _get(self, 5)

    @property
    def min_build(self):
        return _get(self, 6)

    @property
    def required_schema(self):
        return _get(self, 7)

    @property
    def killed(self):
        return _get(self, 8)

    @property
    def has_ttl(self):
        return _get(self, 9)

    @property
    def ttl_valid(self):
        return _get(self, 10)

    @property
    def expires_at(self):
        return _get(self, 11)


def _ingest_flags(flags):
    """Return a tuple of genuine str names to enable from a flags mapping.

    Whole-map strict validation: only an exact dict whose keys are ALL genuine
    ``str`` and whose values are ALL genuine ``bool`` is honored; any anomaly
    fails the whole mapping closed (enables nothing). Never rehashes caller
    keys and never raises for Exception-derived hostility.
    """
    if type(flags) is not dict:
        return ()
    enabled = []
    try:
        for k, v in flags.items():
            if type(k) is not str or type(v) is not bool:
                return ()
            if v is True:
                enabled.append(k)
    except Exception:
        return ()
    return tuple(enabled)


def _ingest_rules(rules_arg):
    """Collect valid ReleaseRule objects from an iterable.

    This is the one deliberate caller-code boundary: iterating an arbitrary
    iterable may run caller ``__iter__``/``__next__``. Ordinary Exception
    hostility fails closed to no rules; ``BaseException`` propagates.
    """
    if rules_arg is None:
        return ()
    collected = []
    try:
        for item in rules_arg:
            if type(item) is ReleaseRule and _get(item, 0) is True:
                collected.append(item)
    except Exception:
        return ()
    return tuple(collected)


# --- ReleaseConfig --------------------------------------------------------
# (valid, killed, ready, rules_tuple)

class ReleaseConfig(_Frozen):
    __slots__ = ()

    def __new__(cls, flags=None, rules=None, killed=False, ready=True):
        vkilled = N.norm_bool(killed)
        vready = N.norm_bool(ready, default=True)
        enabled = _ingest_flags(flags)
        collected = list(_ingest_rules(rules))
        have = set()
        for r in collected:
            have.add(_get(r, 1))
        # Simple enabled flags become full-cohort rules unless a rich rule for
        # the same flag was supplied.
        for name in enabled:
            if name not in have:
                collected.append(ReleaseRule(flag=name, cohort=N.MAX_COHORT))
                have.add(name)
        return tuple.__new__(cls, (True, vkilled, vready, tuple(collected)))

    @property
    def valid(self):
        return _get(self, 0)

    @property
    def killed(self):
        return _get(self, 1)

    @property
    def ready(self):
        return _get(self, 2)

    @property
    def rules(self):
        return _get(self, 3)


# --- EvaluationContext ----------------------------------------------------
# (valid, subject, build, schema, now, has_authority, ready)

class EvaluationContext(_Frozen):
    __slots__ = ()

    def __new__(cls, subject=None, build=0, schema=0, now=0.0,
                has_authority=False, ready=True):
        vsubject = N.norm_id(subject)
        vbuild = N.norm_context_build(build)
        vschema = N.norm_context_schema(schema)
        vnow = N.norm_epoch(now)
        vauth = N.norm_bool(has_authority)
        vready = N.norm_bool(ready, default=True)
        valid = vsubject is not None and vnow is not None
        return tuple.__new__(cls, (
            valid, vsubject if vsubject is not None else "", vbuild, vschema,
            vnow if vnow is not None else -1.0, vauth, vready,
        ))

    @property
    def valid(self):
        return _get(self, 0)

    @property
    def subject(self):
        return _get(self, 1)

    @property
    def build(self):
        return _get(self, 2)

    @property
    def schema(self):
        return _get(self, 3)

    @property
    def now(self):
        return _get(self, 4)

    @property
    def has_authority(self):
        return _get(self, 5)

    @property
    def ready(self):
        return _get(self, 6)


# --- Entitlement ----------------------------------------------------------
# (valid, name, granted)

class Entitlement(_Frozen):
    __slots__ = ()

    def __new__(cls, name=None, granted=False):
        vname = N.norm_id(name)
        vgranted = N.norm_bool(granted)
        return tuple.__new__(cls, (vname is not None, vname if vname else "", vgranted))

    @property
    def valid(self):
        return _get(self, 0)

    @property
    def name(self):
        return _get(self, 1)

    @property
    def granted(self):
        return _get(self, 2)


# --- Decision -------------------------------------------------------------
# (released, reason_code, gate, bucket)

class Decision(_Frozen):
    __slots__ = ()

    def __new__(cls, released, reason_code, gate, bucket=-1):
        r = released if type(released) is bool else bool(released is True)
        rc = reason_code if type(reason_code) is int else -1
        g = gate if type(gate) is int else -1
        b = bucket if type(bucket) is int else -1
        return tuple.__new__(cls, (r, rc, g, b))

    @property
    def released(self):
        return _get(self, 0)

    @property
    def reason_code(self):
        return _get(self, 1)

    @property
    def gate(self):
        return _get(self, 2)

    @property
    def bucket(self):
        return _get(self, 3)


# --- AuditReceipt ---------------------------------------------------------
# (released, reason_code, gate, schema_version)

class AuditReceipt(_Frozen):
    __slots__ = ()

    def __new__(cls, released, reason_code, gate, schema_version):
        r = released if type(released) is bool else bool(released is True)
        rc = reason_code if type(reason_code) is int else -1
        g = gate if type(gate) is int else -1
        sv = schema_version if type(schema_version) is int else -1
        return tuple.__new__(cls, (r, rc, g, sv))

    @property
    def released(self):
        return _get(self, 0)

    @property
    def reason_code(self):
        return _get(self, 1)

    @property
    def gate(self):
        return _get(self, 2)

    @property
    def schema_version(self):
        return _get(self, 3)

    def telemetry(self):
        return {
            "released": bool(_get(self, 0)),
            "reason_code": int(_get(self, 1)),
            "gate": int(_get(self, 2)),
            "schema_version": int(_get(self, 3)),
        }

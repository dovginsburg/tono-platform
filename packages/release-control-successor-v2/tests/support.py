"""Builders for well-formed engine inputs used across the gate tests."""

from release_control_successor_v2 import (
    Entitlement,
    EvaluationContext,
    ReleaseConfig,
)

BASE_RULE = {
    "percentage": 100,
    "issued_at": 1000,
    "ttl_seconds": 100000,
    "min_build": 100,
    "max_build": 200,
    "min_schema": 5,
    "max_schema": 9,
    "allowlist": ["vip"],
}


def make_config(rule=None, flag="feat"):
    return ReleaseConfig({flag: dict(BASE_RULE if rule is None else rule)})


def make_entitlement(caps=("feat",)):
    return Entitlement(list(caps))


def make_context(**overrides):
    base = dict(
        build=150,
        schema=7,
        now=1500,
        cohort="user1",
        ready=True,
        kill_switch=False,
    )
    base.update(overrides)
    return EvaluationContext(**base)

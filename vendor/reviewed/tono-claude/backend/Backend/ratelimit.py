"""Redis-backed sliding-window rate limiter.

Replaces the in-memory `collections.deque`-per-key limiters that used to
live directly in server.py (`_ip_windows`) and slack.py
(`_slack_user_windows`) — a plain Python dict is only correct with exactly
one worker process, which the Postgres/Redis migration is explicitly
moving away from.
"""

from __future__ import annotations

import time

from .redis_client import get_redis

# Prune-check-add has to happen atomically or two concurrent requests can
# both slip through between the ZCARD check and the ZADD — a Lua script is
# the standard way to get that atomicity from Redis without a distributed
# lock. This is a genuine correctness upgrade over the previous in-memory
# version: that one was only atomic because a single process holding a
# `threading.Lock()` serializes everything by definition.
_SLIDING_WINDOW_LUA = """
local key = KEYS[1]
local now = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local limit = tonumber(ARGV[3])
redis.call('ZREMRANGEBYSCORE', key, 0, now - window)
local count = redis.call('ZCARD', key)
if count >= limit then
    return 0
end
redis.call('ZADD', key, now, tostring(now) .. '-' .. tostring(math.random()))
redis.call('EXPIRE', key, window)
return 1
"""


async def check_sliding_window(key: str, limit: int, window_seconds: int = 60) -> bool:
    """Returns True if this call is within the limit (and records it),
    False if the caller is already at the limit for this window."""
    r = get_redis()
    now = time.time()
    allowed = await r.eval(_SLIDING_WINDOW_LUA, 1, f"ratelimit:{key}", now, window_seconds, limit)
    return bool(allowed)

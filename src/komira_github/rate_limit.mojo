# =============================================================================
# komira_github/rate_limit.mojo -- GitHub's rate limits, and the latch that
#   keeps a limited client from sending again before GitHub said it may.
# =============================================================================
#
# GitHub answers a request over a limit with 403 or 429 ("Rate limits for the
# REST API", "Best practices for using the REST API"):
#   * PRIMARY: `x-ratelimit-remaining: 0`; the quota returns at
#     `x-ratelimit-reset` (Unix seconds). Each installation and the App have
#     their own quota.
#   * SECONDARY: a `retry-after` header (wait that many seconds); or, with
#     neither header, a 429, or a 403 whose message names a secondary rate
#     limit (or the older "abuse detection" wording): wait at least a minute,
#     and exponentially longer while it keeps happening. GitHub warns that
#     continuing to send while limited can get the integration banned.
#   * Any other 403 is a permission answer, not a limit.
#
# This package NEVER retries a limited request, and never lets the next one
# out early. `classify_rate_limit` turns an answer into a verdict with the
# instant sending may resume; `RateLimitLatch.record` keeps it; and
# `RateLimitLatch.check` raises `GitHubError[RATE_LIMITED]` for any request
# before that instant without sending it. A secondary limit pauses the whole
# client (it is not tied to one quota); a primary limit pauses the
# credential that ran out. With no `retry-after`, a secondary limit waits
# 60 s, then 120, 240, ... up to 3600 s while consecutive answers keep being
# secondary limits; any answer that is not a limit resets that streak. A
# `retry-after` of 0 still waits 1 s and a reset in the past waits 1 s, so
# no answer can make the next send immediate.
# =============================================================================

from .error import KIND_RATE_LIMITED, github_error
from .header import GitHubHeader, header_value


comptime RATE_LIMIT_NONE: Int = 0
comptime RATE_LIMIT_PRIMARY: Int = 1
comptime RATE_LIMIT_SECONDARY: Int = 2

comptime SECONDARY_MIN_WAIT_S: Int64 = 60
comptime SECONDARY_MAX_WAIT_S: Int64 = 3600
comptime RATE_LIMIT_FLOOR_WAIT_S: Int64 = 1


@fieldwise_init
struct RateLimitVerdict(Copyable, Movable, Deinitable, ImplicitlyCopyable):
    """What an answer says about limits: `kind` (RATE_LIMIT_*) and, for a
    limit, the Unix second sending may resume (`resume_at`)."""

    var kind: Int
    var resume_at: Int64


def _parse_seconds(text: String) -> Int64:
    """A decimal of 1-12 digits, or -1."""
    var b = text.strip().as_bytes()
    if len(b) == 0 or len(b) > 12:
        return -1
    var v: Int64 = 0
    for i in range(len(b)):
        if b[i] < UInt8(ord("0")) or b[i] > UInt8(ord("9")):
            return -1
        v = v * 10 + Int64(Int(b[i] - UInt8(ord("0"))))
    return v


def secondary_backoff_s(streak: Int) -> Int64:
    """60 s after the first secondary limit with no `retry-after`, doubled
    for each one before it in the streak, at most 3600 s."""
    var wait = SECONDARY_MIN_WAIT_S
    for _ in range(streak):
        wait = wait * 2
        if wait >= SECONDARY_MAX_WAIT_S:
            return SECONDARY_MAX_WAIT_S
    return wait


def _lower_byte(c: UInt8) -> UInt8:
    if c >= UInt8(0x41) and c <= UInt8(0x5A):
        return c + 0x20
    return c


def _contains_ci(body: List[UInt8], needle: String) -> Bool:
    """Whether `body` holds the lower-case ASCII `needle`, ignoring ASCII
    case. Byte-wise: the body need not be UTF-8."""
    var nb = needle.as_bytes()
    var n = len(nb)
    if n == 0 or n > len(body):
        return n == 0
    for start in range(len(body) - n + 1):
        var hit = True
        for k in range(n):
            if _lower_byte(body[start + k]) != nb[k]:
                hit = False
                break
        if hit:
            return True
    return False


def _names_secondary_limit(body: List[UInt8]) -> Bool:
    """Whether a 403 body names a secondary limit (GitHub's message text;
    only the first 64 KiB is read)."""
    if len(body) > 65536:
        return False
    return _contains_ci(body, String("secondary rate limit")) or _contains_ci(
        body, String("abuse detection")
    )


def classify_rate_limit(
    status: Int,
    headers: List[GitHubHeader],
    body: List[UInt8],
    now_unix_s: Int64,
    secondary_streak: Int,
) -> RateLimitVerdict:
    """The verdict for one answer (module header). `secondary_streak` is the
    number of secondary limits in a row before this answer."""
    if status != 403 and status != 429:
        return RateLimitVerdict(RATE_LIMIT_NONE, 0)
    var ra = header_value(headers, String("retry-after"))
    if ra:
        var secs = _parse_seconds(ra.value())
        if secs >= 0:
            if secs < RATE_LIMIT_FLOOR_WAIT_S:
                secs = RATE_LIMIT_FLOOR_WAIT_S
            return RateLimitVerdict(RATE_LIMIT_SECONDARY, now_unix_s + secs)
    var remaining = header_value(headers, String("x-ratelimit-remaining"))
    if remaining and remaining.value().strip() == "0":
        var resume = now_unix_s + SECONDARY_MIN_WAIT_S
        var reset = header_value(headers, String("x-ratelimit-reset"))
        if reset:
            var at = _parse_seconds(reset.value())
            if at >= 0:
                resume = at
        if resume < now_unix_s + RATE_LIMIT_FLOOR_WAIT_S:
            resume = now_unix_s + RATE_LIMIT_FLOOR_WAIT_S
        return RateLimitVerdict(RATE_LIMIT_PRIMARY, resume)
    if status == 429 or _names_secondary_limit(body):
        return RateLimitVerdict(
            RATE_LIMIT_SECONDARY, now_unix_s + secondary_backoff_s(secondary_streak)
        )
    return RateLimitVerdict(RATE_LIMIT_NONE, 0)


struct RateLimitLatch(Movable, Deinitable):
    """When sending may resume: for the whole client (secondary limits) and
    per credential (primary limits, keyed by the caller's credential key)."""

    var global_resume_at: Int64
    var secondary_streak: Int
    var _keys: List[String]
    var _resume_at: List[Int64]

    def __init__(out self):
        self.global_resume_at = 0
        self.secondary_streak = 0
        self._keys = List[String]()
        self._resume_at = List[Int64]()

    def resume_at(self, key: String) -> Int64:
        """The later of the client's and `key`'s resume instants."""
        var at = self.global_resume_at
        for i in range(len(self._keys)):
            if self._keys[i] == key and self._resume_at[i] > at:
                at = self._resume_at[i]
        return at

    def check(self, key: String, now_unix_s: Int64) raises:
        """Raises `GitHubError[RATE_LIMITED]` when a request on `key` may
        not be sent at `now_unix_s`."""
        var at = self.resume_at(key)
        if now_unix_s < at:
            raise github_error(
                KIND_RATE_LIMITED,
                String("rate limited; nothing was sent; sending resumes at unix ")
                + String(at),
            )

    def record(mut self, key: String, verdict: RateLimitVerdict):
        """Keep what one answer on `key` said."""
        if verdict.kind == RATE_LIMIT_NONE:
            self.secondary_streak = 0
            return
        if verdict.kind == RATE_LIMIT_SECONDARY:
            self.secondary_streak += 1
            if verdict.resume_at > self.global_resume_at:
                self.global_resume_at = verdict.resume_at
            return
        for i in range(len(self._keys)):
            if self._keys[i] == key:
                if verdict.resume_at > self._resume_at[i]:
                    self._resume_at[i] = verdict.resume_at
                return
        self._keys.append(key)
        self._resume_at.append(verdict.resume_at)

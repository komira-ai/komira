"""A stub `komira_retry` for the mojo_aws_client fixtures.

The real package is komira//src/komira_retry. A library of this cell cannot
depend on it (a mojo_library of another cell carries another cell's
MojoPkgTSet type), so this file is kept by hand, in step with the names a
client-mode generated module imports from komira_retry (emit_aws/mod.rs
AWS_IMPORTS, the `komira_retry` row: MonotonicClock, RetryBudget,
RetryLoop, RetryRng, Sleeper) and with what the stub komira_aws_core's
`send_sigv4_signed_request_with` calls on them.

The four seam traits have the real ones' supertraits and methods, so a
struct that conforms to a real one conforms to the stub. `RetryLoop` has
the real one's parameters and the methods the stub send calls (`start`,
`attempts`, `after_success`), but no policy: the stub send never retries,
so there is nothing for one to decide, and its `__init__` takes the clock,
sleeper and random source only (the real one takes a `RetryPolicy` first).
"""


trait MonotonicClock(Movable, Deinitable):
    """Milliseconds from a clock that never goes back."""

    def now_ms(mut self) -> Int64:
        ...


trait Sleeper(Movable, Deinitable):
    """Blocks for a number of milliseconds."""

    def sleep_ms(mut self, ms: Int64) raises:
        ...


trait RetryRng(Movable, Deinitable):
    """The jitter source."""

    def next_u64(mut self) -> UInt64:
        ...


trait RetryBudget(Movable, Deinitable):
    """Retries cost tokens; a success refills."""

    def try_spend(mut self, cost: Int) -> Bool:
        ...

    def on_success(mut self, last_retry_cost: Int):
        ...


struct RetryLoop[K: MonotonicClock, S: Sleeper, R: RetryRng](Movable, Deinitable):
    """A loop that counts sends and never retries (module docstring)."""

    var _clock: Self.K
    var _sleeper: Self.S
    var _rng: Self.R
    var _attempts: Int

    def __init__(out self, var clock: Self.K, var sleeper: Self.S, var rng: Self.R):
        self._clock = clock^
        self._sleeper = sleeper^
        self._rng = rng^
        self._attempts = 0

    def start(mut self):
        """Call just before the first send."""
        _ = self._clock.now_ms()
        self._attempts = 1

    def attempts(self) -> Int:
        """Sends made or in flight in this call, the first included."""
        return self._attempts

    def after_success[B: RetryBudget](mut self, mut budget: B):
        """The last send succeeded: refill the budget (by nothing, since
        this loop never spends)."""
        budget.on_success(0)

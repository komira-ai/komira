"""Generic retry: when to retry and how long to wait, never which failures.

`RetryPolicy.decide` is a pure function of (attempts made, elapsed time,
`Verdict`, random source). `RetryLoop` runs it between sends and sleeps
through injected `MonotonicClock` / `Sleeper` / `RetryRng` seams. A
`Verdict` comes from a `RetryClassifier`, which lives in the client library
that knows the protocol (status codes, error names, `Retry-After`). An
optional `RetryBudget` (`TokenBucket`) limits retries across calls.

See README.md for the semantics and what does not belong here.
"""

from .seams import (
    MonotonicClock,
    Sleeper,
    RetryRng,
    SystemClock,
    SystemSleeper,
    SplitMix64Rng,
    ManualClock,
    RecordingSleeper,
)
from .policy import (
    Jitter,
    Backoff,
    Verdict,
    Decision,
    RetryPolicy,
    DEFAULT_RETRY_COST,
    MAX_WAIT_MS,
)
from .budget import RetryBudget, NoBudget, TokenBucket
from .loop import RetryClassifier, RetryLoop, system_retry_loop

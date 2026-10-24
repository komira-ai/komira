# =============================================================================
# komira_retry/budget.mojo -- an optional limit on retries across calls.
# =============================================================================
#
# Per-call limits (attempts, deadline) do not stop a client from tripling
# its load on a struggling server: every call retries. A budget shared by a
# client's calls does. `TokenBucket` follows the AWS SDKs' retry quota
# (botocore `RetryQuota`, standard mode): it starts full; each retry spends
# its cost and is refused, ending the call, when the bucket holds less; a
# call that succeeds puts back the cost of its LAST retry, or
# `success_refill` (1) when it succeeded first time, never above capacity.
#
# A budget is not thread-safe. A client that shares one between threads
# guards it; the loop takes it as a `mut` argument per call, so whoever owns
# it decides how.
# =============================================================================


trait RetryBudget(Movable, Deinitable):
    def try_spend(mut self, cost: Int) -> Bool:
        """Spend `cost` (>= 0) for one retry. False means do not retry."""
        ...

    def on_success(mut self, last_retry_cost: Int):
        """A call succeeded; `last_retry_cost` is what its last retry spent,
        0 if it made none."""
        ...


struct NoBudget(RetryBudget, Movable, Deinitable):
    """Every retry allowed; the per-call limits alone apply."""

    def __init__(out self):
        pass

    def try_spend(mut self, cost: Int) -> Bool:
        return True

    def on_success(mut self, last_retry_cost: Int):
        pass


struct TokenBucket(RetryBudget, Movable, Deinitable):
    var capacity: Int
    var success_refill: Int
    var _available: Int

    def __init__(out self, capacity: Int = 500, success_refill: Int = 1) raises:
        if capacity < 0:
            raise Error(String("TokenBucket: capacity must be >= 0, got ") + String(capacity))
        if success_refill < 0:
            raise Error(
                String("TokenBucket: success_refill must be >= 0, got ") + String(success_refill)
            )
        self.capacity = capacity
        self.success_refill = success_refill
        self._available = capacity

    def available(self) -> Int:
        return self._available

    def try_spend(mut self, cost: Int) -> Bool:
        if cost < 0 or cost > self._available:
            return False
        self._available -= cost
        return True

    def on_success(mut self, last_retry_cost: Int):
        var refill = last_retry_cost if last_retry_cost > 0 else self.success_refill
        self._available = min(self._available + refill, self.capacity)

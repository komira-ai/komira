# =============================================================================
# komira_kg_enrich/retry_scheduler.mojo -- the delayed retry seam and its fake.
# =============================================================================
#
# When a delivery fails, the drain worker arms a one-shot call back to its own
# drain endpoint at now + delay, so a transient outage heals without a poll
# loop: between events the worker holds no timer. The clock-holder (a task queue,
# a timer service, a cron) is the host's; this is the seam it plugs into.
#
# `schedule` is idempotent on `dedup_key`: arming again while the earlier call is
# still pending returns the earlier task id and records nothing new, so a burst
# of failures arms one retry per partition. A task is pending until it fires: once
# it has been handed to its callback or cancelled the key is free again, so a
# `schedule` made while the callback runs arms a new task.
#
# `FakeRetryScheduler` is the in-process conformer: it reads time from a counter
# the test advances (`advance`), never from a clock, and `take_due` returns the
# tasks whose time has come, so a test asserts a schedule by moving time and
# never by waiting.
# =============================================================================


trait RetryScheduler(Movable, Deinitable):
    """A delayed, one-shot, idempotent self-call."""

    def schedule(
        mut self,
        delay_seconds: Int64,
        callback_path: String,
        payload_json: String,
        dedup_key: String,
    ) raises -> String:
        """Arm one POST of `payload_json` to `callback_path` at now +
        `delay_seconds`. While a task with `dedup_key` is pending, return its id
        without arming another. A task counts as pending until it fires: once it
        has been handed to its callback (or cancelled) it no longer does, so a
        `schedule` made from inside that callback, or after it, arms a new task.
        Returns the task id."""
        ...

    def cancel(mut self, task_id: String) raises:
        """Cancel a pending task. An unknown, fired or cancelled task is not an
        error."""
        ...

    def ensure_ready(mut self) raises:
        """Create whatever the scheduler needs if it is absent; idempotent.
        Called once at boot before the first `schedule`."""
        ...


@fieldwise_init
struct DueRetry(Copyable, Movable):
    """One armed call whose time has come, as `take_due` returns it."""

    var task_id: String
    var due_at_seconds: Int64
    var callback_path: String
    var payload_json: String
    var dedup_key: String


struct _RetryCall(Copyable, Movable):
    var task_id: String
    var delay_seconds: Int64
    var due_at_seconds: Int64
    var callback_path: String
    var payload_json: String
    var dedup_key: String
    var pending: Bool

    def __init__(
        out self,
        var task_id: String,
        delay_seconds: Int64,
        due_at_seconds: Int64,
        var callback_path: String,
        var payload_json: String,
        var dedup_key: String,
    ):
        self.task_id = task_id^
        self.delay_seconds = delay_seconds
        self.due_at_seconds = due_at_seconds
        self.callback_path = callback_path^
        self.payload_json = payload_json^
        self.dedup_key = dedup_key^
        self.pending = True


struct FakeRetryScheduler(RetryScheduler):
    """Records every armed call and reads time from `now_seconds`, which only
    `advance` moves. A call is due when `due_at_seconds <= now_seconds`;
    `take_due` returns the due calls in the order they were armed and marks them
    fired, which frees their dedup keys."""

    var now_seconds: Int64
    var calls: List[_RetryCall]
    var ensure_ready_count: Int
    var _next_id: Int

    def __init__(out self, start_seconds: Int64 = Int64(0)):
        self.now_seconds = start_seconds
        self.calls = List[_RetryCall]()
        self.ensure_ready_count = 0
        self._next_id = 0

    def advance(mut self, seconds: Int64):
        """Move the clock forward by `seconds`."""
        self.now_seconds += seconds

    def schedule(
        mut self,
        delay_seconds: Int64,
        callback_path: String,
        payload_json: String,
        dedup_key: String,
    ) raises -> String:
        if delay_seconds < Int64(0):
            raise Error("delay_seconds must not be negative")
        for i in range(len(self.calls)):
            if self.calls[i].pending and self.calls[i].dedup_key == dedup_key:
                return self.calls[i].task_id.copy()
        var tid = String("fake-retry-") + String(self._next_id)
        self._next_id += 1
        self.calls.append(
            _RetryCall(
                tid.copy(),
                delay_seconds,
                self.now_seconds + delay_seconds,
                callback_path.copy(),
                payload_json.copy(),
                dedup_key.copy(),
            )
        )
        return tid^

    def cancel(mut self, task_id: String) raises:
        for i in range(len(self.calls)):
            if self.calls[i].task_id == task_id:
                self.calls[i].pending = False
                return

    def ensure_ready(mut self) raises:
        self.ensure_ready_count += 1

    def take_due(mut self) -> List[DueRetry]:
        """The pending calls due at `now_seconds`, marked fired."""
        var out = List[DueRetry]()
        for i in range(len(self.calls)):
            if self.calls[i].pending and self.calls[i].due_at_seconds <= self.now_seconds:
                self.calls[i].pending = False
                out.append(
                    DueRetry(
                        self.calls[i].task_id.copy(),
                        self.calls[i].due_at_seconds,
                        self.calls[i].callback_path.copy(),
                        self.calls[i].payload_json.copy(),
                        self.calls[i].dedup_key.copy(),
                    )
                )
        return out^

    def schedule_count(self) -> Int:
        """The calls ever armed; a dedup hit arms nothing."""
        return len(self.calls)

    def pending_count(self) -> Int:
        """The calls armed and neither fired nor cancelled."""
        var n = 0
        for i in range(len(self.calls)):
            if self.calls[i].pending:
                n += 1
        return n

    def _last(self) raises -> Int:
        if len(self.calls) == 0:
            raise Error("no call has been armed")
        return len(self.calls) - 1

    def last_delay(self) raises -> Int64:
        return self.calls[self._last()].delay_seconds

    def last_due_at(self) raises -> Int64:
        return self.calls[self._last()].due_at_seconds

    def last_payload(self) raises -> String:
        return self.calls[self._last()].payload_json.copy()

    def last_callback_path(self) raises -> String:
        return self.calls[self._last()].callback_path.copy()

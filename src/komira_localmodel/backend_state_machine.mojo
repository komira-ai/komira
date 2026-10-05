# =============================================================================
# komira_localmodel/backend_state_machine.mojo
#   BackendSupervisor: the local-model lifecycle STATE MACHINE.
#   Per registered model: REGISTERED -> (on the first /v1 request) LOADING ->
#   SERVING -> (keep_alive deadline passes with no request) UNLOADING ->
#   REGISTERED. Least-recently-used eviction when launching would exceed a
#   resident-memory budget. FAILED states that name their reason.
# =============================================================================
#
# The state machine drives N registered models through load / serve / unload
# using only the backend trait, a TTL clock and the bookkeeping here (no OS
# plumbing of its own). It follows the patterns of the common desktop LLM
# servers:
#   * Ollama keep_alive   — unload after a TTL with no request.
#   * LM Studio JIT/evict — load on first request + LRU evict to a budget
#                           (LM Studio defaults to ~1 resident model).
#   * a single router     — one endpoint fronts N models; the caller names the
#                           model and the SM loads it on demand.
#
# THE BACKEND SEAM `[B: LocalBackend]`: the SM is GENERIC over a `LocalBackend`
# trait DEFINED HERE (launch / health / teardown / base_url). A concrete engine
# (a spawned MLX server, a spawned llama.cpp server) conforms to it in the
# package or binary that knows how to start that engine, so this package does
# not depend on any engine. The unit tests bind a STUB backend.
#
# THE TTL CLOCK SEAM `MonotonicClock`: the SM reads a monotonic millisecond
# clock through a TRAIT conformer (`now_ms(mut self) -> Int`), so a unit test
# drives VIRTUAL time (no `sleep`: the idle-unload and keep_alive deadline
# assertions step a deterministic clock). Production binds `SystemClock`
# (std.time.perf_counter_ns); a test binds a clock it advances. A trait
# conformer rather than a function pointer, because a thin function pointer
# cannot carry the test clock's state and Mojo has no mutable module globals.
#
# POINTERS: the surface is owned Strings and value types; no pointer in any
# public signature, no wildcard origin. The backends are owned by value in a
# `Slab[B]` (B is Movable-only, so `List[B]` is rejected; `Slab` is the
# Movable-only owned collection, as in SupervisorRegistry).
# =============================================================================

from std.ffi import external_call
from std.time import perf_counter_ns

from komira_core.collections.slab import Slab

from .fit_resolver import (
    CatalogEntry,
    FitResult,
    FIT_GREEN,
    FIT_YELLOW,
    FIT_RED,
    fit,
    auto_pick_highest_green_quant,
    estimate_resident_bytes,
    DEFAULT_CONTEXT_TOKENS,
    ModelVariant,
)
from .host_profile import HostMemoryProfile


# -----------------------------------------------------------------------------
# Lifecycle states (a small POD enum). The happy-path cycle:
#   REGISTERED -> LOADING -> SERVING -> UNLOADING -> REGISTERED
# FAILED is the loud-and-actionable terminal-ish state (a launch that never
# became healthy, a spill-to-RAM / ctx-OOM / missing-GPU-lib): the SM records
# WHY (failure_reason) so the surface is actionable, never silent degradation.
# -----------------------------------------------------------------------------
comptime LM_REGISTERED: Int = 0  # known to the SM, not loaded (no child).
comptime LM_LOADING: Int = 1     # launch() in flight (JIT, on first request).
comptime LM_SERVING: Int = 2     # healthy + serving; keep_alive deadline armed.
comptime LM_UNLOADING: Int = 3   # teardown() in flight (idle-unload / evict).
comptime LM_FAILED: Int = 4      # loud failure — see failure_reason.

# Type alias for readability.
comptime ModelState = Int


def model_state_name(state: Int) -> StaticString:
    if state == LM_REGISTERED:
        return "registered"
    elif state == LM_LOADING:
        return "loading"
    elif state == LM_SERVING:
        return "serving"
    elif state == LM_UNLOADING:
        return "unloading"
    elif state == LM_FAILED:
        return "failed"
    return "unknown"


# -----------------------------------------------------------------------------
# Failure-reason codes — the loud-and-actionable categories (never a silent
# degrade). Surfaced via ModelStatus.failure_reason so the control API and
# its clients can show an ACTIONABLE message.
# -----------------------------------------------------------------------------
comptime FAIL_NONE: Int = 0
comptime FAIL_LAUNCH_TIMEOUT: Int = 1   # spawned but never became healthy.
comptime FAIL_LAUNCH_SPAWN: Int = 2     # the spawn itself failed (-errno).
comptime FAIL_WONT_FIT: Int = 3         # RED fit even after eviction — refused.


def failure_reason_text(reason: Int) -> StaticString:
    if reason == FAIL_NONE:
        return ""
    elif reason == FAIL_LAUNCH_TIMEOUT:
        return (
            "engine spawned but never became healthy within the launch budget"
            " (model load failed, wrong binary/flags, or spill-to-RAM / ctx-OOM"
            " / missing GPU library)"
        )
    elif reason == FAIL_LAUNCH_SPAWN:
        return (
            "engine process failed to spawn (missing binary, bad path, or fork"
            " limit)"
        )
    elif reason == FAIL_WONT_FIT:
        return (
            "model does not fit in the resident-RAM budget even after evicting"
            " every other resident model (RED fit — would spill / OOM)"
        )
    return "unknown failure"


# -----------------------------------------------------------------------------
# The TTL clock seam — an injectable monotonic-millisecond clock trait. The SM
# reads time through a
# `MonotonicClock` conformer it owns; production binds `SystemClock` (rides
# std.time.perf_counter_ns), a test binds a clock it advances (virtual time, no
# sleep). `now_ms(mut self)` so an auto-advancing test clock CAN mutate per read
# (SystemClock + a fixed MockClock do not need to, but mut keeps the API shape).
# -----------------------------------------------------------------------------
trait MonotonicClock(Movable, Deinitable):
    """An injectable monotonic millisecond clock (the keep_alive TTL seam).

    `now_ms` is monotonically non-decreasing across calls on the same instance.
    Production: SystemClock (perf_counter_ns). Test: a clock advanced explicitly
    so idle-unload / keep_alive-deadline assertions step virtual time."""

    def now_ms(mut self) -> Int:
        ...


struct SystemClock(MonotonicClock, Movable, Deinitable):
    """Production MonotonicClock — monotonic milliseconds via
    std.time.perf_counter_ns. Zero per-instance state; all instances observe
    the same process-global timeline."""

    var _zero: UInt8

    @staticmethod
    def new() -> SystemClock:
        return SystemClock(_zero=UInt8(0))

    def __init__(out self, _zero: UInt8):
        self._zero = _zero

    def now_ms(mut self) -> Int:
        return Int(perf_counter_ns() // 1_000_000)


def default_monotonic_now_ms() -> Int:
    """Monotonic milliseconds (rides std.time.perf_counter_ns). The free-fn form
    of the production clock, for callers that want a raw timestamp without a
    clock instance."""
    return Int(perf_counter_ns() // 1_000_000)


# Default keep_alive TTL: a model with no request for this many ms is idle-
# unloaded (Ollama's keep_alive default is 5 minutes; we mirror it). A config
# overrides per-SM.
comptime DEFAULT_KEEP_ALIVE_MS: Int = 5 * 60 * 1000

# Default max resident models (the LRU budget's COUNT cap). LM Studio defaults
# to ~1 resident; we default to 1 (the conservative "one model at a time")
# default, overridable. The BYTE budget (resident-RAM) is the primary evict
# trigger; this count cap is a secondary guard.
comptime DEFAULT_MAX_RESIDENT: Int = 1


# -----------------------------------------------------------------------------
# ADMISSION CONTROL — per-loaded-model concurrency cap + bounded queue.
#
# WHY: the underlying engine's concurrent decode against ONE loaded model has
# hard limits (mlx_lm.server documents KV cross-contamination at 16+ concurrent
# prompts — ml-explore/mlx-lm#965 — and every engine inflates per-request KV
# under parallelism). Letting unbounded concurrent requests hit one model turns
# "many chats" into a silent wrong-answer / OOM failure. The answer here is
# server-side admission control: cap the in-flight requests per loaded model at
# `max_concurrent` (the SAME N the concurrency-aware FitResolver reserved KV for,
# so the fit budget and the admission cap agree), and QUEUE up to a bounded depth
# beyond the cap. This converts "silent wrong answer / OOM under load" into
# "bounded latency under load" (a queued request waits; an over-the-queue request
# is rejected LOUDLY rather than admitted into a spill).
#
# The cap default mirrors DEFAULT_MAX_CONCURRENT in fit_resolver (4). The queue
# depth default is a small multiple of the cap (admit `cap`, queue up to
# `cap * QUEUE_DEPTH_MULTIPLE`, reject beyond) so a transient burst is absorbed
# but an unbounded backlog cannot accumulate.
# -----------------------------------------------------------------------------
comptime DEFAULT_MAX_CONCURRENT_PER_MODEL: Int = 4
comptime QUEUE_DEPTH_MULTIPLE: Int = 4

# Admission decision codes (the result of admit()).
comptime ADMIT_ADMITTED: Int = 0  # under the cap — run now (in-flight bumped).
comptime ADMIT_QUEUED: Int = 1    # at the cap, within the queue — wait (queued).
comptime ADMIT_REJECTED: Int = 2  # cap + queue full — reject LOUD (no spill).


def admission_decision_name(decision: Int) -> StaticString:
    if decision == ADMIT_ADMITTED:
        return "admitted"
    elif decision == ADMIT_QUEUED:
        return "queued"
    elif decision == ADMIT_REJECTED:
        return "rejected"
    return "unknown"


# -----------------------------------------------------------------------------
# derive_concurrency_cap — the per-model concurrency cap DERIVED FROM the fit
# budget. A model that barely fits cannot also absorb its requested concurrency
# of extra KV-cache; one with generous headroom can. We scale the requested
# `max_concurrent` down toward 1 when the headroom is tight, never up (the
# conservative direction — fewer concurrent chats, never a spill). The fit was
# already computed at `max_concurrent` (the concurrency-aware FitResolver), so a
# GREEN/YELLOW fit means `max_concurrent` streams' KV was already reserved; a RED
# fit (negative headroom) caps at 1 (the model is over budget even single-stream
# — admission should not pretend it can serve N).
# -----------------------------------------------------------------------------
def derive_concurrency_cap(fit_headroom_bytes: Int, max_concurrent: Int) -> Int:
    """The per-model admission cap derived from the fit headroom. Returns at most
    `max_concurrent`, at least 1. A model with NEGATIVE headroom (over budget)
    caps at 1 — it does not fit its requested concurrency, so admission must not
    grant it (the fit already reserved N streams' KV; a negative headroom means
    even that reserved estimate exceeds budget). PURE."""
    var requested = max_concurrent if max_concurrent > 0 else 1
    if fit_headroom_bytes < 0:
        return 1
    return requested


# -----------------------------------------------------------------------------
# LocalBackend — the swappable local-inference engine seam (the SM's backend
# trait). A conformer brings up / probes / releases one engine serving an
# OpenAI `/v1` endpoint; an engine that spawns an MLX or llama.cpp server
# conforms in the code that knows how to start it.
# -----------------------------------------------------------------------------
trait LocalBackend(Movable, Deinitable):
    """A swappable local-inference engine (OpenAI-`/v1` endpoint).

    launch() brings the engine up (spawn-or-reuse) and returns the base URL;
    health() is a liveness probe; teardown() releases it; base_url() reads the
    target without launching.

    `Deinitable` is required (beyond Movable) so the SM can store
    the owned backends in a `Slab[B]` (the Movable-only owned
    collection — Slab's `T` bound is `Deinitable`).
    """

    def launch(mut self) raises -> String:
        ...

    def health(self) -> Bool:
        ...

    def teardown(mut self):
        ...

    def base_url(self) -> String:
        ...


# -----------------------------------------------------------------------------
# ModelStatus — the snapshot of one registered model's lifecycle state. The
# control API renders this (the status verb). A small owned POD.
# -----------------------------------------------------------------------------
struct ModelStatus(Copyable, Movable):
    """One registered model's lifecycle snapshot.

    Fields:
      * id              — the model's stable id (the control-API key).
      * state           — LM_REGISTERED / LOADING / SERVING / UNLOADING / FAILED.
      * resident_bytes  — the conservative resident estimate of the chosen
                          variant (0 when no variant is chosen / not loaded).
      * base_url        — the OpenAI base URL (empty until SERVING).
      * failure_reason  — FAIL_* (FAIL_NONE unless state == LM_FAILED).
      * last_request_ms — the clock value at the last /v1 request (the
                          keep_alive deadline anchor; 0 if never requested).
    """

    var id: String
    var state: Int
    var resident_bytes: Int
    var base_url: String
    var failure_reason: Int
    var last_request_ms: Int

    def __init__(
        out self,
        id: String,
        state: Int,
        resident_bytes: Int,
        base_url: String,
        failure_reason: Int,
        last_request_ms: Int,
    ):
        self.id = id
        self.state = state
        self.resident_bytes = resident_bytes
        self.base_url = base_url
        self.failure_reason = failure_reason
        self.last_request_ms = last_request_ms


# -----------------------------------------------------------------------------
# _ModelSlot — the SM's per-model internal record (NOT public). Holds the owned
# backend + its lifecycle bookkeeping. Stored in parallel `Slab[B]` + lists
# (the SupervisorRegistry shape — B is Movable-only so a plain List[B] is
# rejected; the Slab is the Movable-only owned collection).
# -----------------------------------------------------------------------------


# -----------------------------------------------------------------------------
# THE SM CONCURRENCY GATE.
#
# A server may serve the /v1 passthrough from N pthread workers so N admitted
# requests reach the engine SIMULTANEOUSLY and the engine's OWN continuous
# batching serves them in parallel. The N workers SHARE ONE BackendSupervisor
# (the SM owns the model lifecycle and the per-model admission counters;
# bounding TOTAL in-flight against ONE shared loaded model is the whole point,
# so the SM cannot be per-worker). The SM's bookkeeping is plain (non-atomic)
# parallel List[Int]; N threads mutating it concurrently would race (lost
# counter updates leak the cap past N, into the spill / KV-contamination range
# admission control exists to avoid).
#
# So every request-path MUTATING SM verb (request_load / admit / release /
# release_queued / note_request / tick_idle_unload / stop) brackets its body with
# a process-global mutex (a static pthread_mutex_t behind pthread_once in
# komira_async's reactor/_posix_shim.c, which every komira_async consumer
# links). The mutex serializes
# only the SHORT bookkeeping; the long blocking forward to the engine happens
# OUTSIDE the SM (in the control-API between admit and release), so N workers
# forward concurrently — the gate never holds across the engine round-trip.
#
# Single-threaded callers take an UNCONTENDED lock per call: negligible cost,
# identical behavior.
# -----------------------------------------------------------------------------
@always_inline
def _sm_lock():
    """Take the process-global SM mutex."""
    _ = external_call["komira_localmodel_sm_lock", NoneType]()


@always_inline
def _sm_unlock():
    """Release the process-global SM mutex."""
    _ = external_call["komira_localmodel_sm_unlock", NoneType]()


# =============================================================================
# BackendSupervisor[B: LocalBackend] — the lifecycle state machine.
# =============================================================================
struct BackendSupervisor[B: LocalBackend, C: MonotonicClock](Movable):
    """The local-model lifecycle state machine over N registered models.

    Each model is registered with (id, chosen ModelVariant, backend). The SM
    JIT-loads on the first request (LOADING -> SERVING), idle-unloads after the
    keep_alive TTL (SERVING -> UNLOADING -> REGISTERED), and LRU-auto-evicts a
    resident model when launching a new one would exceed the resident-RAM
    budget (the FitResolver headroom) or the max-resident count.

    Storage (single owner, no shared ownership):
      * _backends      — Slab[B] of the owned backend instances (B is
                         Movable-only; Slab is the Movable-only owned
                         collection).
      * _ids / _states / _resident / _failure / _last_req — parallel
                         per-model bookkeeping, indexed the same as _backends.
    The clock (C) + budget + keep_alive TTL are SM-level config; the clock is
    owned by-value (the injectable MonotonicClock conformer).
    """

    var _clock: Self.C
    var _hw: HostMemoryProfile
    var _budget_bytes: Int
    var _keep_alive_ms: Int
    var _max_resident: Int

    var _backends: Slab[Self.B]
    var _ids: List[String]
    var _states: List[Int]
    var _resident: List[Int]
    var _failure: List[Int]
    # The clock value at each model's last /v1 request (the keep_alive anchor).
    var _last_req: List[Int]
    # A monotonically-increasing "load order" counter stamped on each LOADING
    # transition — the LRU key (the smallest load-order resident is the LRU
    # victim). Re-stamped on each (re)load so an evicted-then-reloaded model is
    # the most-recently-used again.
    var _load_order: List[Int]
    var _next_load_order: Int

    # --- ADMISSION CONTROL — per-model concurrency cap + queue ---
    # Parallel to the per-model lists (indexed the same as _backends). Plain Ints
    # (no heap in the element type, no wildcard origin):
    #   _max_concurrent — the per-model in-flight cap (derived from the fit
    #                     budget at registration; 0 means "not set" -> the SM's
    #                     default cap applies).
    #   _inflight       — the count of currently-admitted (in-flight) requests.
    #   _queued         — the count of requests waiting for an in-flight slot.
    # The SM-level default cap + queue-depth multiple are config (constructor).
    var _max_concurrent: List[Int]
    var _inflight: List[Int]
    var _queued: List[Int]
    var _default_max_concurrent: Int
    var _queue_depth_multiple: Int

    # --- per-model keep_alive TTL ---
    # The idle-unload TTL PER model (indexed the same as _backends; 0 means "use
    # the SM-level _keep_alive_ms default"). One server may host models with
    # different idle policies: an always-resident embedder wants a very long TTL
    # while a chat model wants a short ~5-min idle-unload to free RAM. A
    # per-model TTL lets the SAME SM hold both.
    var _keep_alive_per_model: List[Int]

    def __init__(
        out self,
        var clock: Self.C,
        hw: HostMemoryProfile,
        budget_bytes: Int,
        keep_alive_ms: Int,
        max_resident: Int,
    ):
        """Full config. `budget_bytes` is the resident-RAM budget the LRU evict
        defends (typically hw.gpu_budget_bytes() minus headroom, or a config
        cap); `keep_alive_ms` is the idle-unload TTL; `max_resident` is the
        count cap (LM Studio ~1)."""
        self._clock = clock^
        self._hw = hw
        self._budget_bytes = budget_bytes
        self._keep_alive_ms = keep_alive_ms
        self._max_resident = max_resident
        self._backends = Slab[Self.B]()
        self._ids = List[String]()
        self._states = List[Int]()
        self._resident = List[Int]()
        self._failure = List[Int]()
        self._last_req = List[Int]()
        self._load_order = List[Int]()
        self._next_load_order = 1
        self._max_concurrent = List[Int]()
        self._inflight = List[Int]()
        self._queued = List[Int]()
        self._default_max_concurrent = DEFAULT_MAX_CONCURRENT_PER_MODEL
        self._queue_depth_multiple = QUEUE_DEPTH_MULTIPLE
        self._keep_alive_per_model = List[Int]()

    def __init__(out self, var clock: Self.C, hw: HostMemoryProfile):
        """Defaults: budget = the host's gpu/RAM budget, keep_alive = 5 min,
        max_resident = 1 (LM Studio's default)."""
        self._clock = clock^
        self._hw = hw
        self._budget_bytes = hw.gpu_budget_bytes()
        self._keep_alive_ms = DEFAULT_KEEP_ALIVE_MS
        self._max_resident = DEFAULT_MAX_RESIDENT
        self._backends = Slab[Self.B]()
        self._ids = List[String]()
        self._states = List[Int]()
        self._resident = List[Int]()
        self._failure = List[Int]()
        self._last_req = List[Int]()
        self._load_order = List[Int]()
        self._next_load_order = 1
        self._max_concurrent = List[Int]()
        self._inflight = List[Int]()
        self._queued = List[Int]()
        self._default_max_concurrent = DEFAULT_MAX_CONCURRENT_PER_MODEL
        self._queue_depth_multiple = QUEUE_DEPTH_MULTIPLE
        self._keep_alive_per_model = List[Int]()

    # --- clock ---------------------------------------------------------------

    def clock_mut(mut self) -> ref [self._clock] Self.C:
        """Borrow the owned clock (mut). Production code does not need this;
        a test borrows it to ADVANCE a virtual clock (the SM owns its clock, so
        advancing it goes through this accessor)."""
        return self._clock

    def now_ms(mut self) -> Int:
        """The SM's current clock reading (test / diagnostic — the keep_alive
        deadline anchor uses this internally)."""
        return self._clock.now_ms()

    # --- lookup --------------------------------------------------------------

    def _index_of(self, id: String) -> Int:
        for i in range(len(self._ids)):
            if self._ids[i] == id:
                return i
        return -1

    def contains(self, id: String) -> Bool:
        return self._index_of(id) >= 0

    def count(self) -> Int:
        """The number of registered models."""
        return len(self._ids)

    def state_of(self, id: String) -> Int:
        """The lifecycle state for `id` (-1 if absent)."""
        var idx = self._index_of(id)
        if idx < 0:
            return -1
        return self._states[idx]

    def resident_count(self) -> Int:
        """The number of models currently resident (LOADING or SERVING — i.e.
        holding a launched child)."""
        var n = 0
        for i in range(len(self._states)):
            if self._states[i] == LM_LOADING or self._states[i] == LM_SERVING:
                n += 1
        return n

    def resident_bytes_total(self) -> Int:
        """The summed resident estimate of every currently-resident model."""
        var total = 0
        for i in range(len(self._states)):
            if self._states[i] == LM_LOADING or self._states[i] == LM_SERVING:
                total += self._resident[i]
        return total

    def status_of(mut self, id: String) -> ModelStatus:
        """A snapshot of `id`'s state (the control-API status verb). A
        sentinel (state -1, FAIL_NONE) when `id` is absent. SM-mutex-guarded
        (mut self) — reads `_backends[idx].base_url()`, which a concurrent
        teardown mutates."""
        _sm_lock()
        var st = self._status_of_locked(id)
        _sm_unlock()
        return st^

    def _status_of_locked(self, id: String) -> ModelStatus:
        """Unlocked inner body of `status_of` (caller holds the SM mutex). Reads
        only (no mutation), so `self` not `mut self`. Split out so `all_status`
        can snapshot every model under ONE lock acquisition (a consistent list
        snapshot) without recursively re-locking."""
        var idx = self._index_of(id)
        if idx < 0:
            return ModelStatus(
                id, -1, 0, String(""), FAIL_NONE, 0
            )
        var burl = String("")
        if self._states[idx] == LM_SERVING:
            # Re-bind to Self.B so LocalBackend methods resolve
            # (Slab[B].__getitem__ types to Slab's Deinitable bound).
            ref be: Self.B = self._backends[idx]
            burl = be.base_url()
        return ModelStatus(
            self._ids[idx],
            self._states[idx],
            self._resident[idx],
            burl,
            self._failure[idx],
            self._last_req[idx],
        )

    def all_status(mut self) -> List[ModelStatus]:
        """A snapshot of every registered model (the control-API list verb).
        SM-mutex-guarded (mut self) — the whole list is snapshotted under ONE
        lock acquisition so it is internally consistent vs concurrent
        admit/release/unload on the worker threads."""
        _sm_lock()
        var out = List[ModelStatus]()
        for i in range(len(self._ids)):
            out.append(self._status_of_locked(self._ids[i]))
        _sm_unlock()
        return out^

    # --- registration --------------------------------------------------------

    def register(mut self, id: String, var backend: Self.B, resident_bytes: Int) -> Bool:
        """Register a model under `id` with its owned `backend` and the chosen
        variant's conservative resident estimate. The model starts REGISTERED
        (not loaded — no child yet; the JIT load happens on the first request).
        The admission cap is the SM's default (`_default_max_concurrent`); use
        `register_with_cap` to derive a per-model cap from the fit budget.

        Returns False (no-op) if `id` is already registered. The SM takes
        ownership of `backend`.
        """
        return self.register_with_cap(
            id, backend^, resident_bytes, self._default_max_concurrent
        )

    def register_with_cap(
        mut self,
        id: String,
        var backend: Self.B,
        resident_bytes: Int,
        max_concurrent: Int,
    ) -> Bool:
        """`register` with an EXPLICIT per-model admission concurrency cap (the
        N derived from the fit budget via `derive_concurrency_cap`). A
        `max_concurrent` <= 0 falls back to the SM default. The cap bounds the
        in-flight requests admitted against this model. The per-model
        keep_alive TTL is the SM default (0); use `register_full` for a per-model
        TTL."""
        return self.register_full(
            id, backend^, resident_bytes, max_concurrent, 0
        )

    def register_full(
        mut self,
        id: String,
        var backend: Self.B,
        resident_bytes: Int,
        max_concurrent: Int,
        keep_alive_ms: Int,
    ) -> Bool:
        """`register` with BOTH an explicit per-model admission cap AND a
        per-model keep_alive idle-unload TTL. A `max_concurrent` <= 0
        falls back to the SM default cap; a `keep_alive_ms` <= 0 falls back to the
        SM-level keep_alive TTL. The per-model TTL lets the SAME SM host an
        always-resident embedder (a very long TTL) alongside a chat model (a
        short ~5-min idle-unload)."""
        if self._index_of(id) >= 0:
            return False
        var cap = max_concurrent if max_concurrent > 0 else self._default_max_concurrent
        self._ids.append(id)
        self._backends.append(backend^)
        self._states.append(LM_REGISTERED)
        self._resident.append(resident_bytes)
        self._failure.append(FAIL_NONE)
        self._last_req.append(0)
        self._load_order.append(0)
        self._max_concurrent.append(cap)
        self._inflight.append(0)
        self._queued.append(0)
        self._keep_alive_per_model.append(keep_alive_ms)
        return True

    # --- the JIT-load + LRU-evict core ---------------------------------------

    def _evict_lru_for(mut self, want_bytes: Int) raises:
        """Make room for `want_bytes` of new resident: while adding it would
        exceed the byte budget OR the max-resident count, tear down the LRU
        resident model (smallest _load_order among resident). The LRU victim is
        UNLOADED (SERVING/LOADING -> UNLOADING -> REGISTERED), its child
        terminated (no orphan), so a subsequent request JIT-reloads it.

        Stops if no resident model remains to evict (the caller then decides
        whether the model fits at all — a single model larger than the whole
        budget is FAIL_WONT_FIT, handled by request_load)."""
        while True:
            var resident_now = self.resident_count()
            var bytes_now = self.resident_bytes_total()
            var over_bytes = (bytes_now + want_bytes) > self._budget_bytes
            var over_count = (resident_now + 1) > self._max_resident
            if not over_bytes and not over_count:
                return
            # Find the LRU resident (smallest load_order among LOADING/SERVING).
            var victim = -1
            var victim_order = 0
            for i in range(len(self._states)):
                if self._states[i] == LM_SERVING or self._states[i] == LM_LOADING:
                    if victim < 0 or self._load_order[i] < victim_order:
                        victim = i
                        victim_order = self._load_order[i]
            if victim < 0:
                # Nothing left to evict — the single new model is bigger than
                # the budget. The caller (request_load) decides FAIL_WONT_FIT.
                return
            self._unload_index(victim)

    def _unload_index(mut self, idx: Int):
        """Tear down the model at `idx` (UNLOADING -> teardown -> REGISTERED).
        The backend's teardown stops the child (SIGTERM -> grace -> SIGKILL,
        reap) — no orphan. Idempotent on an already-non-resident slot. Clears the
        admission counters (an unloaded model holds no in-flight / queued slots —
        a reload starts fresh)."""
        if self._states[idx] != LM_SERVING and self._states[idx] != LM_LOADING:
            return
        self._states[idx] = LM_UNLOADING
        ref be_td: Self.B = self._backends[idx]
        be_td.teardown()
        self._states[idx] = LM_REGISTERED
        self._load_order[idx] = 0
        self._inflight[idx] = 0
        self._queued[idx] = 0

    def request_load(mut self, id: String) raises -> Bool:
        """The JIT entry point: ensure `id` is SERVING, loading it on demand.

        The first /v1 request for a REGISTERED model drives it
        REGISTERED -> LOADING -> SERVING. If launching it would exceed the
        resident-memory budget or the max-resident count, the LRU resident model is
        torn down first (LM Studio-style evict). A launch that never becomes healthy
        -> LM_FAILED + the actionable failure_reason (loud, never silent).

        Returns True iff `id` ends SERVING; False on absent-id or a FAILED
        load. Re-arms the keep_alive deadline (stamps last_request) on success.
        Idempotent: a request for an already-SERVING model just re-arms the TTL.

        CONCURRENCY: the whole load decision (idempotent-serving check, LRU evict,
        launch, SERVING transition) runs under the process-global SM mutex — so
        two workers JIT-loading the SAME model concurrently do NOT double-spawn or
        double-evict (the loser observes the model already SERVING under the lock
        and just re-arms the TTL). The launch() inside CAN block on the engine
        readiness poll while holding the lock — that is acceptable: the first load
        of a model is a rare cold-start, and serializing it is exactly the
        "exactly one worker spawns the child" contract we want. Steady-state
        request-path locking (admit/release) never holds across a forward.
        """
        _sm_lock()
        try:
            var r = self._request_load_locked(id)
            _sm_unlock()
            return r
        except e:
            _sm_unlock()
            raise e^

    def _request_load_locked(mut self, id: String) raises -> Bool:
        """The unlocked inner body of `request_load` (the caller holds the SM
        mutex). Split out so the lock is taken exactly once around the whole
        decision, never recursively (the mutex is non-recursive)."""
        var idx = self._index_of(id)
        if idx < 0:
            return False

        # Already serving — re-arm the keep_alive deadline + bump LRU recency.
        if self._states[idx] == LM_SERVING:
            self._last_req[idx] = self._clock.now_ms()
            self._load_order[idx] = self._next_load_order
            self._next_load_order += 1
            return True

        # A prior FAILED load is sticky until re-registered/cleared — surface it
        # rather than silently retry-spinning. (clear_failure resets it.)
        if self._states[idx] == LM_FAILED:
            return False

        # Make room (LRU evict) BEFORE launching the new child.
        self._evict_lru_for(self._resident[idx])

        # If even after eviction the model alone exceeds the budget, refuse it
        # LOUDLY (FAIL_WONT_FIT) rather than launch a child that will spill/OOM.
        if self._resident[idx] > self._budget_bytes:
            self._states[idx] = LM_FAILED
            self._failure[idx] = FAIL_WONT_FIT
            return False

        # LOADING -> launch the backend (spawn-or-reuse + readiness wait).
        self._states[idx] = LM_LOADING
        try:
            ref be_launch: Self.B = self._backends[idx]
            var _url = be_launch.launch()
        except e:
            # launch() raised — the engine never became healthy (or spawn
            # failed). LOUD FAILED state with the actionable reason.
            _ = e
            ref be_fail: Self.B = self._backends[idx]
            be_fail.teardown()
            self._states[idx] = LM_FAILED
            self._failure[idx] = FAIL_LAUNCH_TIMEOUT
            return False

        # Launched + readiness-confirmed by launch(). SERVING.
        self._states[idx] = LM_SERVING
        self._failure[idx] = FAIL_NONE
        self._last_req[idx] = self._clock.now_ms()
        self._load_order[idx] = self._next_load_order
        self._next_load_order += 1
        return True

    def note_request(mut self, id: String):
        """Re-arm the keep_alive deadline for `id` (a /v1 request landed on an
        already-SERVING model). Bumps LRU recency. No-op for a non-SERVING id.
        SM-mutex-guarded (the request path runs under N workers)."""
        _sm_lock()
        var idx = self._index_of(id)
        if idx < 0 or self._states[idx] != LM_SERVING:
            _sm_unlock()
            return
        self._last_req[idx] = self._clock.now_ms()
        self._load_order[idx] = self._next_load_order
        self._next_load_order += 1
        _sm_unlock()

    def base_url_of(mut self, id: String) -> String:
        """The OpenAI base URL for `id` (empty unless SERVING). The control-API
        /v1 passthrough routes to this.

        CONCURRENCY: SM-mutex-guarded (mut self for the lock) — it reads
        `_backends[idx].base_url()`, and a concurrent _unload_index (tick / LRU
        evict) tears that backend down; the lock makes the SERVING-check + the
        base_url read atomic vs the teardown so a worker never reads a base_url
        out of a backend mid-teardown."""
        _sm_lock()
        var idx = self._index_of(id)
        if idx < 0 or self._states[idx] != LM_SERVING:
            _sm_unlock()
            return String("")
        ref be_url: Self.B = self._backends[idx]
        var url = be_url.base_url()
        _sm_unlock()
        return url^

    # --- admission control — per-model concurrency cap + queue ----------------

    def max_concurrent_of(self, id: String) -> Int:
        """The per-model in-flight admission cap for `id` (0 if absent)."""
        var idx = self._index_of(id)
        if idx < 0:
            return 0
        return self._max_concurrent[idx]

    def inflight_of(self, id: String) -> Int:
        """The count of currently-admitted (in-flight) requests for `id`."""
        var idx = self._index_of(id)
        if idx < 0:
            return 0
        return self._inflight[idx]

    def queued_of(self, id: String) -> Int:
        """The count of requests waiting (queued) for an in-flight slot on `id`."""
        var idx = self._index_of(id)
        if idx < 0:
            return 0
        return self._queued[idx]

    def queue_capacity_of(self, id: String) -> Int:
        """The bounded queue depth for `id` (`cap * queue_depth_multiple`) —
        requests beyond cap+queue are REJECTED (0 if absent)."""
        var idx = self._index_of(id)
        if idx < 0:
            return 0
        return self._max_concurrent[idx] * self._queue_depth_multiple

    def set_max_concurrent(mut self, id: String, max_concurrent: Int) -> Bool:
        """Override the per-model admission cap for `id` (>= 1). Returns False if
        absent. Used to re-derive the cap after a re-fit."""
        var idx = self._index_of(id)
        if idx < 0:
            return False
        self._max_concurrent[idx] = max_concurrent if max_concurrent > 0 else 1
        return True

    def admit(mut self, id: String) -> Int:
        """Try to admit ONE request against `id` (admission control). The
        per-model concurrency cap bounds in-flight requests; a bounded queue
        absorbs a burst beyond the cap; anything past cap+queue is rejected LOUD.

        Returns:
          * ADMIT_ADMITTED — under the cap: the in-flight count is bumped; the
            caller runs the request now and MUST call `release(id)` when done.
          * ADMIT_QUEUED   — at the cap but within the bounded queue: the queued
            count is bumped; the caller waits for a slot (a later `release` +
            `promote_one` admits it). The caller MUST call `release(id)` to
            decrement the queue if it abandons the wait.
          * ADMIT_REJECTED — cap + queue full: NOTHING is bumped; the caller must
            reject the request LOUDLY (a 503) rather than admit it into a spill.

        Returns ADMIT_REJECTED for an absent id (nothing to admit against).

        CONCURRENCY: SM-mutex-guarded so the cap check + the in-flight bump are
        ATOMIC across N workers — without the lock, two workers could both read
        `inflight < cap` and both bump, leaking the cap past N (the spill /
        mlx-lm#965 KV-contamination band). The lock makes the cap a true global
        bound on TOTAL in-flight requests against the one shared loaded model.
        """
        _sm_lock()
        var idx = self._index_of(id)
        if idx < 0:
            _sm_unlock()
            return ADMIT_REJECTED
        var cap = self._max_concurrent[idx]
        if cap <= 0:
            cap = self._default_max_concurrent
        if self._inflight[idx] < cap:
            self._inflight[idx] += 1
            _sm_unlock()
            return ADMIT_ADMITTED
        # At the cap — queue if there is bounded room.
        var queue_cap = cap * self._queue_depth_multiple
        if self._queued[idx] < queue_cap:
            self._queued[idx] += 1
            _sm_unlock()
            return ADMIT_QUEUED
        # Cap + queue both full — reject LOUD (no silent spill).
        _sm_unlock()
        return ADMIT_REJECTED

    def release(mut self, id: String):
        """Release ONE in-flight slot on `id` (the caller finished its admitted
        request). Decrements the in-flight count (never below 0). No-op for an
        absent id or an already-zero in-flight count. SM-mutex-guarded (a worker
        releases after its forward completes).

        NOTE (pull promotion): `release` does NOT auto-promote a queued
        waiter into the freed slot — promotion is PULL-based (a queued worker
        spins on `try_promote_if_under_cap` and claims the freed slot itself). So
        the freed in-flight slot is simply decremented here; the next queued
        worker's spin observes `inflight < cap` and converts its own queued slot
        to in-flight. This keeps in-flight a TRUE hard bound (== cap) under N
        concurrent workers. A push promotion here, combined with a queued worker
        that then runs its request, would count that request twice and let
        in-flight drift past the cap."""
        _sm_lock()
        var idx = self._index_of(id)
        if idx < 0:
            _sm_unlock()
            return
        if self._inflight[idx] > 0:
            self._inflight[idx] -= 1
        _sm_unlock()

    def try_promote_if_under_cap(mut self, id: String) -> Bool:
        """A QUEUED worker's PULL-promotion attempt: if `id` has a free in-flight
        slot (inflight < cap) AND this id has a queued waiter, atomically convert
        ONE queued slot to an in-flight slot and return True (the caller — the
        queued worker — now holds an in-flight slot and proceeds to forward).
        Returns False if the cap is still full (the caller keeps spinning) or
        there is no queued waiter / absent id.

        This is the BLOCK-AND-WAIT admission semantic (a queued request WAITS
        for a real slot, turning OOM under load into bounded latency under
        load): a QUEUED worker spins on this until it claims a slot (or times
        out and calls release_queued + 503). It makes in-flight a TRUE hard cap:
        a queued slot only becomes in-flight when a real slot is free, never
        unconditionally. SM-mutex-guarded so the
        cap-check + the queued->inflight move is atomic vs concurrent
        admits/releases."""
        _sm_lock()
        var idx = self._index_of(id)
        if idx < 0:
            _sm_unlock()
            return False
        var cap = self._max_concurrent[idx]
        if cap <= 0:
            cap = self._default_max_concurrent
        if self._queued[idx] > 0 and self._inflight[idx] < cap:
            self._queued[idx] -= 1
            self._inflight[idx] += 1
            _sm_unlock()
            return True
        _sm_unlock()
        return False

    def release_queued(mut self, id: String):
        """Drop ONE queued waiter on `id` (a queued caller abandoned the wait
        without ever being promoted). Decrements the queued count (never below
        0). No-op for an absent id / empty queue. SM-mutex-guarded."""
        _sm_lock()
        var idx = self._index_of(id)
        if idx < 0:
            _sm_unlock()
            return
        if self._queued[idx] > 0:
            self._queued[idx] -= 1
        _sm_unlock()

    # --- the keep_alive TTL tick ---------------------------------------------

    def tick_idle_unload(mut self) -> Int:
        """The keep_alive sweep: idle-unload every SERVING model whose last
        request is older than the keep_alive TTL (SERVING -> UNLOADING ->
        REGISTERED, child terminated, no orphan). Returns the number unloaded.

        The server calls this periodically (ControlApiDispatcher exposes it as
        `tick_idle_unload`). The clock is read through the SM's pluggable `now` seam so a
        test drives it deterministically (virtual time, no sleep). The TTL is
        PER-MODEL: a model with a per-model keep_alive (an always-resident
        embedder's very long TTL, a chat model's short TTL) uses its own; one
        registered without (0) uses the SM-level default.

        CONCURRENCY: SM-mutex-guarded. A server typically drives this from ONE
        worker, but it tears down children + flips states the
        other workers read/write on the request path, so it must hold the lock
        for the sweep. An in-flight request on a SERVING model bumps last_req
        under the SAME lock (note_request/request_load), so the idle check sees a
        consistent last_req — a model with an active request is never idle-swept
        out from under it."""
        _sm_lock()
        var now = self._clock.now_ms()
        var unloaded = 0
        for i in range(len(self._states)):
            if self._states[i] == LM_SERVING:
                var idle = now - self._last_req[i]
                var ttl = self._keep_alive_per_model[i]
                if ttl <= 0:
                    ttl = self._keep_alive_ms
                if idle >= ttl:
                    self._unload_index(i)
                    unloaded += 1
        _sm_unlock()
        return unloaded

    # --- explicit stop / failure clearing ------------------------------------

    def stop(mut self, id: String) -> Bool:
        """Explicitly stop (unload) `id` (the control API's stop verb). SERVING/
        LOADING -> REGISTERED, child terminated. Returns True iff `id` was
        resident (and is now unloaded). SM-mutex-guarded."""
        _sm_lock()
        var idx = self._index_of(id)
        if idx < 0:
            _sm_unlock()
            return False
        if self._states[idx] == LM_SERVING or self._states[idx] == LM_LOADING:
            self._unload_index(idx)
            _sm_unlock()
            return True
        _sm_unlock()
        return False

    def clear_failure(mut self, id: String) -> Bool:
        """Clear a FAILED model back to REGISTERED so a subsequent request can
        retry the load (after the binary/flags/memory were fixed). Returns
        True iff `id` was FAILED."""
        var idx = self._index_of(id)
        if idx < 0 or self._states[idx] != LM_FAILED:
            return False
        self._states[idx] = LM_REGISTERED
        self._failure[idx] = FAIL_NONE
        return True

    def shutdown_all(mut self):
        """Shutdown — tear down every resident model (no orphans). Each
        SERVING/LOADING child is terminated + the slot flips to REGISTERED."""
        for i in range(len(self._states)):
            if self._states[i] == LM_SERVING or self._states[i] == LM_LOADING:
                self._unload_index(i)

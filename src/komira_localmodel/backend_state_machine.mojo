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
# The backend's launch() raised. The backend's own error message is kept in
# ModelStatus.failure_detail, because only the backend knows whether the spawn
# failed or the engine never became healthy.
comptime FAIL_LAUNCH: Int = 1
comptime FAIL_WONT_FIT: Int = 3         # larger than the whole budget — refused.


def failure_reason_text(reason: Int) -> StaticString:
    if reason == FAIL_NONE:
        return ""
    elif reason == FAIL_LAUNCH:
        return (
            "the engine failed to launch (the spawn failed, or the engine never"
            " became healthy: model load failed, wrong binary or flags,"
            " spill-to-RAM, context OOM or a missing GPU library)"
        )
    elif reason == FAIL_WONT_FIT:
        return (
            "model is larger than the whole resident-memory budget, so it"
            " cannot fit even with every other model unloaded"
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
# derive_concurrency_cap — the per-model concurrency cap from a fit that was
# computed at `max_concurrent` streams (fit_concurrent). The decision is binary:
# a fit with non-negative headroom already reserved KV for all
# `max_concurrent` streams, so the cap is `max_concurrent`; a fit with negative
# headroom (over budget at that concurrency) gets a cap of 1. There is no
# scaling in between: to find the largest N that fits, call fit_concurrent at
# decreasing N.
# -----------------------------------------------------------------------------
def derive_concurrency_cap(fit_headroom_bytes: Int, max_concurrent: Int) -> Int:
    """The per-model admission cap from a fit computed at `max_concurrent`
    streams: `max_concurrent` (at least 1) when the headroom is non-negative,
    1 when it is negative. PURE."""
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
      * failure_detail  — the backend's error message when the failure is
                          FAIL_LAUNCH (empty otherwise).
      * max_concurrent / inflight / queued — the admission snapshot, read
                          under the same lock as the rest of the status.
    """

    var id: String
    var state: Int
    var resident_bytes: Int
    var base_url: String
    var failure_reason: Int
    var last_request_ms: Int
    var failure_detail: String
    var max_concurrent: Int
    var inflight: Int
    var queued: Int

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
        self.failure_detail = String("")
        self.max_concurrent = 0
        self.inflight = 0
        self.queued = 0


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
# So every public SM method that reads or writes the per-model bookkeeping
# brackets its body with a process-global mutex (a static pthread_mutex_t
# behind pthread_once in komira_async's reactor/_posix_shim.c, which every
# komira_async consumer links). Internal `_..._locked` helpers assume the
# caller holds it; the mutex is not recursive. The forward to the engine
# happens OUTSIDE the SM (in the control API between admit and release), so N
# workers forward concurrently.
#
# The one long hold: `request_load` keeps the lock through the backend's
# launch() (a cold start, seconds) and through the teardown of any model it
# evicts, so every other SM call in the process waits for that long. Loads are
# rare; serializing them is what keeps a model from being launched twice.
#
# Single-threaded callers take an UNCONTENDED lock per call: negligible cost,
# identical behavior.
#
# BUSY MODELS ARE NEVER UNLOADED BY POLICY. A model with an admitted or queued
# request (inflight + queued > 0) is skipped by the idle sweep, never chosen as
# an eviction victim, and refused by `stop`. The admission counters are never
# reset by an unload, so every admit is balanced by exactly one release.
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
    # How many times launch() was called per model (a reload counts again).
    var _launches: List[Int]
    # The launch() error message per model (empty unless FAIL_LAUNCH).
    var _failure_detail: List[String]

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
        self._launches = List[Int]()
        self._failure_detail = List[String]()

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
        self._launches = List[Int]()
        self._failure_detail = List[String]()

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


    # --- lookup (callers hold the SM mutex) ----------------------------------

    def _index_of(self, id: String) -> Int:
        for i in range(len(self._ids)):
            if self._ids[i] == id:
                return i
        return -1

    def _is_resident(self, idx: Int) -> Bool:
        return (
            self._states[idx] == LM_LOADING or self._states[idx] == LM_SERVING
        )

    def _is_busy(self, idx: Int) -> Bool:
        """An admitted or queued request is outstanding against `idx`."""
        return self._inflight[idx] + self._queued[idx] > 0

    def _cap_of(self, idx: Int) -> Int:
        var cap = self._max_concurrent[idx]
        if cap <= 0:
            cap = self._default_max_concurrent
        return cap

    def _resident_count_locked(self) -> Int:
        var n = 0
        for i in range(len(self._states)):
            if self._is_resident(i):
                n += 1
        return n

    def _resident_bytes_total_locked(self) -> Int:
        var total = 0
        for i in range(len(self._states)):
            if self._is_resident(i):
                total += self._resident[i]
        return total

    # --- lookup (public, each takes the SM mutex) -----------------------------

    def contains(self, id: String) -> Bool:
        _sm_lock()
        var r = self._index_of(id) >= 0
        _sm_unlock()
        return r

    def count(self) -> Int:
        """The number of registered models."""
        _sm_lock()
        var n = len(self._ids)
        _sm_unlock()
        return n

    def state_of(self, id: String) -> Int:
        """The lifecycle state for `id` (-1 if absent)."""
        _sm_lock()
        var idx = self._index_of(id)
        var st = -1 if idx < 0 else self._states[idx]
        _sm_unlock()
        return st

    def resident_count(self) -> Int:
        """The number of models currently resident (LOADING or SERVING — i.e.
        holding a launched child)."""
        _sm_lock()
        var n = self._resident_count_locked()
        _sm_unlock()
        return n

    def resident_bytes_total(self) -> Int:
        """The summed resident estimate of every currently-resident model."""
        _sm_lock()
        var total = self._resident_bytes_total_locked()
        _sm_unlock()
        return total

    def launch_count_of(self, id: String) -> Int:
        """How many times the backend's launch() has been called for `id`
        (0 if absent). A reload after an unload counts again."""
        _sm_lock()
        var idx = self._index_of(id)
        var n = 0 if idx < 0 else self._launches[idx]
        _sm_unlock()
        return n

    def status_of(mut self, id: String) -> ModelStatus:
        """A snapshot of `id`'s state (the control-API status verb). A
        sentinel (state -1, FAIL_NONE) when `id` is absent. SM-mutex-guarded:
        it reads `_backends[idx].base_url()`, which a concurrent teardown
        mutates."""
        _sm_lock()
        var st = self._status_of_locked(id)
        _sm_unlock()
        return st^

    def _status_of_locked(self, id: String) -> ModelStatus:
        """Unlocked inner body of `status_of` (caller holds the SM mutex). Split
        out so `all_status` can snapshot every model under ONE lock acquisition
        (a consistent list snapshot) without recursively re-locking."""
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
        var st = ModelStatus(
            self._ids[idx],
            self._states[idx],
            self._resident[idx],
            burl,
            self._failure[idx],
            self._last_req[idx],
        )
        st.failure_detail = self._failure_detail[idx]
        st.max_concurrent = self._cap_of(idx)
        st.inflight = self._inflight[idx]
        st.queued = self._queued[idx]
        return st^

    def all_status(mut self) -> List[ModelStatus]:
        """A snapshot of every registered model (the control-API list verb),
        taken under ONE lock acquisition so it is internally consistent vs
        concurrent admit/release/unload on the worker threads."""
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
        `max_concurrent` <= 0 falls back to the SM default. The per-model
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
        short ~5-min idle-unload). SM-mutex-guarded: appending may move the
        per-model lists another worker is reading."""
        _sm_lock()
        if self._index_of(id) >= 0:
            _sm_unlock()
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
        self._launches.append(0)
        self._failure_detail.append(String(""))
        _sm_unlock()
        return True

    # --- the JIT-load + LRU-evict core ---------------------------------------

    def _evict_lru_for(mut self, idx_new: Int) -> Bool:
        """Make room for model `idx_new`: unload idle resident models, least
        recently used first, until adding it fits the byte budget and the
        max-resident count.

        Only IDLE models (no admitted or queued request) are candidates. The
        victims are chosen before anything is torn down: if unloading every
        idle candidate would still not make room, nothing is unloaded and
        False is returned, so a load that cannot happen never costs a serving
        model. Returns True when the new model fits (after any unloads)."""
        var want_bytes = self._resident[idx_new]
        var bytes_now = self._resident_bytes_total_locked()
        var count_now = self._resident_count_locked()

        # Idle residents, oldest load order first.
        var candidates = List[Int]()
        for i in range(len(self._states)):
            if i != idx_new and self._is_resident(i) and not self._is_busy(i):
                var pos = len(candidates)
                for j in range(len(candidates)):
                    if self._load_order[i] < self._load_order[candidates[j]]:
                        pos = j
                        break
                candidates.insert(pos, i)

        var victims = List[Int]()
        var k = 0
        while (
            bytes_now + want_bytes > self._budget_bytes
            or count_now + 1 > self._max_resident
        ):
            if k >= len(candidates):
                return False
            var v = candidates[k]
            victims.append(v)
            bytes_now -= self._resident[v]
            count_now -= 1
            k += 1

        for i in range(len(victims)):
            self._unload_index(victims[i])
        return True

    def _unload_index(mut self, idx: Int):
        """Tear down the model at `idx` (UNLOADING -> teardown -> REGISTERED).
        The backend's teardown stops the child (SIGTERM -> grace -> SIGKILL,
        reap) — no orphan. Idempotent on an already-non-resident slot. The
        admission counters are left alone: a request still holding a slot
        releases it later, and that release must find its own count."""
        if not self._is_resident(idx):
            return
        self._states[idx] = LM_UNLOADING
        ref be_td: Self.B = self._backends[idx]
        be_td.teardown()
        self._states[idx] = LM_REGISTERED
        self._load_order[idx] = 0

    def request_load(mut self, id: String) raises -> Bool:
        """The JIT entry point: ensure `id` is SERVING, loading it on demand.

        The first request for a REGISTERED model drives it
        REGISTERED -> LOADING -> SERVING. A model larger than the whole budget
        is refused (FAILED, FAIL_WONT_FIT) before anything else is touched. If
        launching it would exceed the resident-memory budget or the
        max-resident count, idle resident models are unloaded first, least
        recently used first; if the idle ones are not enough (the others are
        serving requests), nothing is unloaded and the load is refused for
        now (False, the model stays REGISTERED, a later retry may succeed). A
        launch that raises -> LM_FAILED, FAIL_LAUNCH and the backend's message.

        Returns True iff `id` ends SERVING; False on absent id, a FAILED model,
        or a load refused because the resident models are busy. Re-arms the
        keep_alive deadline on success. Idempotent: a request for an
        already-SERVING model just re-arms the TTL.

        CONCURRENCY: the whole load decision (idempotent-serving check, LRU
        evict, launch, SERVING transition) runs under the process-global SM
        mutex, so two workers loading the SAME model concurrently do not
        double-launch (the loser observes the model already SERVING under the
        lock). The lock is held through launch() — see the module notes.
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

        # A model larger than the whole budget can never fit: refuse it LOUDLY
        # before evicting anything on its behalf.
        if self._resident[idx] > self._budget_bytes:
            self._states[idx] = LM_FAILED
            self._failure[idx] = FAIL_WONT_FIT
            return False

        # Make room from IDLE residents only; if they are not enough, refuse
        # without unloading anything (the busy ones finish their requests).
        if not self._evict_lru_for(idx):
            return False

        # LOADING -> launch the backend (spawn-or-reuse + readiness wait).
        self._states[idx] = LM_LOADING
        self._launches[idx] += 1
        try:
            ref be_launch: Self.B = self._backends[idx]
            var _url = be_launch.launch()
        except e:
            # launch() raised: the spawn failed or the engine never became
            # healthy. LOUD FAILED state, with the backend's own message.
            ref be_fail: Self.B = self._backends[idx]
            be_fail.teardown()
            self._states[idx] = LM_FAILED
            self._failure[idx] = FAIL_LAUNCH
            self._failure_detail[idx] = String(e)
            return False

        # Launched + readiness-confirmed by launch(). SERVING.
        self._states[idx] = LM_SERVING
        self._failure[idx] = FAIL_NONE
        self._failure_detail[idx] = String("")
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
        _sm_lock()
        var idx = self._index_of(id)
        var n = 0 if idx < 0 else self._max_concurrent[idx]
        _sm_unlock()
        return n

    def inflight_of(self, id: String) -> Int:
        """The count of currently-admitted (in-flight) requests for `id`."""
        _sm_lock()
        var idx = self._index_of(id)
        var n = 0 if idx < 0 else self._inflight[idx]
        _sm_unlock()
        return n

    def queued_of(self, id: String) -> Int:
        """The count of requests waiting (queued) for an in-flight slot on `id`."""
        _sm_lock()
        var idx = self._index_of(id)
        var n = 0 if idx < 0 else self._queued[idx]
        _sm_unlock()
        return n

    def queue_capacity_of(self, id: String) -> Int:
        """The bounded queue depth for `id` (`cap * queue_depth_multiple`) —
        requests beyond cap+queue are REJECTED (0 if absent)."""
        _sm_lock()
        var idx = self._index_of(id)
        var n = 0
        if idx >= 0:
            n = self._max_concurrent[idx] * self._queue_depth_multiple
        _sm_unlock()
        return n

    def set_max_concurrent(mut self, id: String, max_concurrent: Int) -> Bool:
        """Override the per-model admission cap for `id` (>= 1). Returns False if
        absent. Used to re-derive the cap after a re-fit."""
        _sm_lock()
        var idx = self._index_of(id)
        if idx < 0:
            _sm_unlock()
            return False
        self._max_concurrent[idx] = max_concurrent if max_concurrent > 0 else 1
        _sm_unlock()
        return True

    def admit(mut self, id: String) -> Int:
        """Try to admit ONE request against `id` (admission control). The
        per-model concurrency cap bounds in-flight requests; a bounded queue
        absorbs a burst beyond the cap; anything past cap+queue is rejected LOUD.

        Returns:
          * ADMIT_ADMITTED — under the cap: the in-flight count is bumped; the
            caller runs the request now and MUST call `release(id)` when done.
          * ADMIT_QUEUED   — at the cap but within the bounded queue: the queued
            count is bumped; the caller waits, claiming a freed slot with
            `try_promote_if_under_cap`, or calls `release_queued(id)` if it
            gives up.
          * ADMIT_REJECTED — cap + queue full: NOTHING is bumped; the caller must
            reject the request LOUDLY (a 503) rather than admit it into a spill.

        Returns ADMIT_REJECTED for an absent id (nothing to admit against).
        Admission does not depend on the lifecycle state: a caller may admit
        first and load second, so the model it loads is busy (and so not
        unloaded) for as long as it holds the slot.

        CONCURRENCY: SM-mutex-guarded so the cap check + the in-flight bump are
        ATOMIC across N workers — without the lock, two workers could both read
        `inflight < cap` and both bump, leaking the cap past N.
        """
        _sm_lock()
        var idx = self._index_of(id)
        if idx < 0:
            _sm_unlock()
            return ADMIT_REJECTED
        var cap = self._cap_of(idx)
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
        spins on `try_promote_if_under_cap` and claims the freed slot itself).
        This keeps in-flight a TRUE hard bound (== cap) under N concurrent
        workers."""
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
        there is no queued waiter / absent id. SM-mutex-guarded so the
        cap-check + the queued->inflight move is atomic vs concurrent
        admits/releases."""
        _sm_lock()
        var idx = self._index_of(id)
        if idx < 0:
            _sm_unlock()
            return False
        if self._queued[idx] > 0 and self._inflight[idx] < self._cap_of(idx):
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
        """The keep_alive sweep: unload every SERVING model that has no
        admitted or queued request and whose last request is older than its
        keep_alive TTL (SERVING -> UNLOADING -> REGISTERED, child terminated).
        Returns the number unloaded.

        A model with a request in flight is skipped however old its last
        request is: a generation that runs longer than the TTL is not killed
        mid-request. The TTL is PER-MODEL (0 means the SM-level default). The
        clock is read through the SM's MonotonicClock, so a test drives it
        deterministically. SM-mutex-guarded."""
        _sm_lock()
        var now = self._clock.now_ms()
        var unloaded = 0
        for i in range(len(self._states)):
            if self._states[i] == LM_SERVING and not self._is_busy(i):
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
        resident and idle and is now unloaded; False when it is absent, not
        resident, or busy (an admitted or queued request is outstanding — stop
        it again once they finish). SM-mutex-guarded."""
        _sm_lock()
        var idx = self._index_of(id)
        if idx < 0 or not self._is_resident(idx) or self._is_busy(idx):
            _sm_unlock()
            return False
        self._unload_index(idx)
        _sm_unlock()
        return True

    def clear_failure(mut self, id: String) -> Bool:
        """Clear a FAILED model back to REGISTERED so a subsequent request can
        retry the load (after the binary/flags/memory were fixed). Returns
        True iff `id` was FAILED. SM-mutex-guarded."""
        _sm_lock()
        var idx = self._index_of(id)
        if idx < 0 or self._states[idx] != LM_FAILED:
            _sm_unlock()
            return False
        self._states[idx] = LM_REGISTERED
        self._failure[idx] = FAIL_NONE
        self._failure_detail[idx] = String("")
        _sm_unlock()
        return True

    def shutdown_all(mut self):
        """Shutdown — tear down every resident model (no orphans), busy or not.
        Each SERVING/LOADING child is terminated + the slot flips to
        REGISTERED. A request still holding a slot gets a transport error from
        its engine and releases normally. SM-mutex-guarded."""
        _sm_lock()
        for i in range(len(self._states)):
            self._unload_index(i)
        _sm_unlock()

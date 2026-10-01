# =============================================================================
# komira_async.runtime.runtime_trait — the `Runtime` seam
# =============================================================================
# The `Runtime` trait the HTTP client codes against. The trait makes
# `komira_async` a multi-runtime provider:
# `PerCoreAsync` (the existing thread-per-core reactor, this file conforms it)
# and a future tokio-style work-stealing runtime both implement this seam.
# Downstream code parametric on `[RT: Runtime]` monomorphizes against either.
#
# DESIGN — delegating methods, not ref accessors
# ----------------------------------------------------------------------------
# A natural sketch would be `fn reactor(mut self) -> ref [self]
# Reactor[Self.Sink]`. Mojo rejects `ref [self]` returns on TRAIT methods
# because the receiver origin "might expand to a RegisterPassable type". The
# `ref [self._field]` workaround requires a concrete field name, which a trait
# cannot specify across heterogeneous conformers.
#
# Resolution: the trait exposes the operational interface (the things the
# client needs to DO) as delegating methods, NOT ref-accessors. The
# conformer's body forwards each method to its concrete reactor / timer-
# wheel field. The associated-type alias `Self.Sink` and comptime-value
# aliases (`RUNTIME_MODEL`, `TASKS_ARE_THREAD_PINNED`) ARE expressible —
# those don't return refs. The seam's intent (one trait the HTTP client
# is generic over; comptime-branchable runtime-model selector) is
# preserved.
#
# Properties
# ----------------------------------------------------------------------------
# (a) The `Runtime` trait compiles.
# (b) `PerCoreAsyncRuntime[S]` conforms (`PerCoreAsyncRuntimeRT` adapter
#     below).
# (c) Downstream-generic monomorphization against `PerCoreAsync` — verified
#     by `test_runtime_trait.mojo`.
#
# Pointer discipline
# ----------------------------------------------------------------------------
# - ZERO UnsafePointer in any signature on this file.
# - ZERO wildcard origins on this file.
# - ZERO `unsafe_from_address=Int(...)`.
# - ZERO `take_pointee`.
# - ZERO `ArcPointer` introduced here.
# - ZERO additive parallel API (the trait IS the migration, and there is
#   nothing here to migrate AWAY from — net-new surface).
# =============================================================================

from komira_async.ops.waker_sink import WakerSink


# =============================================================================
# RUNTIME_MODEL — comptime value alias namespace
# =============================================================================
# The sketch references a `RuntimeModel` enum / type. Mojo 1.0.0b1's
# `comptime` value space doesn't admit user-defined enums — only POD scalar
# types. We use a `UInt8` sentinel namespace; conformers declare
# `comptime RUNTIME_MODEL: UInt8 = MODEL_SHARE_NOTHING_PER_CORE`, and call
# sites compare with `comptime if RT.RUNTIME_MODEL == MODEL_SHARE_NOTHING_PER_CORE`.
# When Mojo gains true comptime enums, this becomes a 1-line refactor.

comptime MODEL_SHARE_NOTHING_PER_CORE: UInt8 = 0
"""PerCoreAsync — N pinned per-core workers, no work-stealing, share-nothing.
The engine's default runtime. Tasks are thread-pinned: a task started on
worker i resumes on worker i."""

comptime MODEL_WORK_STEALING: UInt8 = 1
"""Tokio-style multi-threaded work-stealing runtime. Tasks may resume on a
different worker than they started on. Reserved for the future
`WorkStealingRuntime` conformer."""

comptime MODEL_CURRENT_THREAD_BLOCKING: UInt8 = 2
"""BlockingRuntime — current-thread, synchronous, single-task. No pthreads,
no scheduler, no work-stealing. The single in-flight op parks by blocking
the calling thread on ONE fd (a single-fd epoll_wait / kevent wait) until
ready, then resumes. This is the tokio `Runtime::new_current_thread()` +
`block_on` model: a SYNC ESCAPE for single-shot calls (a k8s pod GET, a
one-row Postgres query) and for tests, where standing up a full async
runtime (N pinned pthreads) is unwarranted. (keystone).
Conformers set `TASKS_ARE_THREAD_PINNED = True` (there is exactly one
"worker" — the calling thread — and the single task never migrates)."""

comptime MODEL_CLOUD_RUN: UInt8 = 3
"""GcpCloudRunRuntime — request-driven CPU on Google Cloud Run.

`GcpCloudRunRuntime.worker_count()` returns the literal `1` — one inline
reactor on the serve thread, Cloud Run concurrency=1, scale by instances
(see gcp_cloud_run_runtime.mojo). There is no cgroup-derived worker count and
no worker-count override. If you need an explicit worker count, ADD one and
make the binary PRINT what it used — do not infer a knob from prose.

A FIXED worker set — NOT the hardcoded DEFAULT_WORKERS, and NOT
share-nothing-per-core. The distinguishing
property is request-driven CPU AVAILABILITY (CPU is throttled to near-zero
between requests under default request-based billing), not a work-stealing
topology — the sentinel names the CONSTRAINT (throttle), so a future
cooperative scheduler need not disambiguate "work-stealing because we like
it" from "work-stealing because Cloud Run throttles us". Conformers set
`TASKS_ARE_THREAD_PINNED = False` (a task may resume on any worker; Cloud Run
does not promise a task stays on the core it started on)."""


comptime MODEL_AWS_LAMBDA: UInt8 = 4
"""AwsLambdaRuntime — invocation-driven CPU on AWS Lambda.

⚠ THIS IS A SEPARATE SENTINEL FROM `MODEL_CLOUD_RUN` AND THE DIFFERENCE IS NOT
COSMETIC. Both name a constraint of the form "CPU is not yours between units of
work", but they differ in what a unit of work IS and in WHERE its drain edge
falls:

  * Cloud Run THROTTLES CPU to near-zero between REQUESTS. The process keeps
    running; a background thread merely crawls.
  * Lambda FREEZES the whole execution environment between INVOCATIONS, and it
    does so with the runtime blocked mid-`recv` on the Runtime API's `next`
    long poll. Nothing runs. A timer does not fire, a buffered write is not
    flushed, and the freeze may last minutes or end in a teardown that never
    resumes the process at all.

⛔ THE FREEZE IS TRIGGERED BY THE `next` POLL, NOT BY THE RESPONSE. "AWS freezes
the environment the instant the response returns" is MANAGED-HANDLER FOLKLORE
and is FALSE for a custom runtime, where the runtime — not the platform — owns
the loop. The window between `POST /invocation/response` returning and the next
`GET /invocation/next` is CPU-allocated and un-frozen, and it is where a drain
belongs. `komira_log_sink_aws`'s flush sink states the same rule
from the durability side, and `komira_aws_lambda_http.pump` is where it is
implemented.

⇒ So "the unit of work is finished" is a different INSTANT than on Cloud Run —
the moment the result POST returns, not the moment a response is written to a
socket — but it is the same KIND of instant: still-billed, still-running, and
the last one before the CPU goes away. A conformer that reused
`MODEL_CLOUD_RUN` would inherit gating written against the socket edge and
place the drain where this runtime has no socket.

Conformers set `TASKS_ARE_THREAD_PINNED = False`: Lambda promises nothing about
which core resumes a frozen environment."""


# =============================================================================
# Runtime trait — the seam the HTTP client is generic over
# =============================================================================


trait Runtime(Movable, Deinitable):
    """A first-party komira_async runtime. Owns the I/O readiness/
    completion mechanism, the task scheduler, the timer wheel, and the
    thread model. `PerCoreAsync` and the work-stealing runtime both conform.
    The HTTP client is generic over THIS trait — `HttpClient[RT: Runtime]`.

    Associated members
    ------------------------------------------------------------------
    `Sink: WakerSink & Movable & Deinitable`
        The waker-sink type the runtime's reactor uses. The HTTP client
        recovers it as `RT.Sink` for any reactor-touching operations that
        forward to `Reactor[S]`-parametric helpers in `komira_async`.

    `RUNTIME_MODEL: UInt8`
        Comptime value: which runtime-model bucket the conformer is in.
        Allowed values: `MODEL_SHARE_NOTHING_PER_CORE` (PerCoreAsync),
        `MODEL_WORK_STEALING` (the future tokio-style runtime). Read by
        `comptime if RT.RUNTIME_MODEL == ...` at the call site — used by
        the connection-pool selection.

    `TASKS_ARE_THREAD_PINNED: Bool`
        Comptime value. True iff a task started on worker i can ONLY
        resume on worker i. PerCoreAsync sets this True; the future
        work-stealing runtime sets it False. The HTTP client's
        connection-affinity logic branches on this.

    Methods
    ------------------------------------------------------------------
    `worker_count(self) -> Int`
        Number of attached workers. PerCoreAsync returns N (one per
        pinned core); the work-stealing runtime returns its worker-thread
        pool size. The client uses this to size per-worker connection
        sub-pools under PerCoreAsync.

    `poll_completions[worker_idx](mut self, timeout_us) raises -> Int`
        Drive ONE pass of the worker's I/O reactor. The conformer
        forwards to `Reactor[Self.Sink].poll_completions(timeout_us)` for
        worker `worker_idx`. Returns the number of completions drained.
        Under PerCoreAsync, `worker_idx` selects the per-worker reactor;
        under work-stealing, the conformer chooses which worker's reactor
        to drive (typically the calling thread's).

    `timer_advance[worker_idx](mut self, now_ns)` and
    `timer_now_ns[worker_idx](self) -> Int64`
        Advance / query the worker's timer wheel. Forwards to
        `TimerWheel.advance` and `TimerWheel.now_ns` respectively. Used
        by the client's retry / timeout layers.

    Migration / monomorphization invariants
    ------------------------------------------------------------------
    The trait is designed so that AOT inspection verifies the "no fn-ptr table"
    property — the conformer's methods are fully inlined at the
    downstream-generic call site.

    Conformer authoring guidance
    ------------------------------------------------------------------
    1. The associated members use `Self.`-qualified access EVERYWHERE in
       downstream code: `Self.RT.Sink`, `Self.RT.RUNTIME_MODEL`. Bare
       `RT.Sink` is a hard parse error inside generic struct bodies.
    2. Every trait on the seam must declare `Deinitable`
       (this trait does; conformers automatically inherit).
    3. `comptime if Self.RT.RUNTIME_MODEL == ...` branches at comptime;
       the dead branch is eliminated entirely.
    """

    comptime Sink: WakerSink & Movable & Deinitable
    comptime RUNTIME_MODEL: UInt8
    comptime TASKS_ARE_THREAD_PINNED: Bool

    def worker_count(self) -> Int:
        ...

    def poll_completions(
        mut self, worker_idx: Int, timeout_us: Int32,
    ) raises -> Int:
        ...

    def timer_advance(
        mut self, worker_idx: Int, now_ns: Int64,
    ) raises:
        ...

    def timer_now_ns(self, worker_idx: Int) -> Int64:
        ...

    def signal_shutdown_all(mut self):
        ...

# =============================================================================
# komira_async.runtime.aws_lambda_runtime — AwsLambdaRuntime[S]
# =============================================================================
# Goal: an HTTP server on AWS runs as a Lambda behind API Gateway by passing
# in the right runtime, with nothing else changing.
#
# A `Runtime` conformer for AWS Lambda. It is the SIBLING of
# `GcpCloudRunRuntime` and is deliberately built to the same shape: ONE
# `Reactor[S]` owned by value and driven INLINE on the calling thread, no
# pthreads, `worker_count() == 1`. Copying that shape is the point — there is
# one idiom in this tree for "a serverless runtime whose CPU is not continuously
# ours", and a second idiom would be a second thing to keep correct.
#
# WHY ONE INLINE REACTOR IS RIGHT HERE (it is not an inherited assumption)
# ----------------------------------------------------------------------------
# A Lambda execution environment serves EXACTLY ONE invocation at a time. That
# is not a tunable: the platform's concurrency model is one-request-per-sandbox,
# and scale is by sandbox count. So the same argument that collapsed
# GcpCloudRunRuntime from a worker pool to one inline reactor (Cloud
# Run concurrency=1) holds here for a stronger reason — Cloud Run's
# concurrency is configurable and merely happens to be set to 1; Lambda's is 1
# by construction.
#
# WHAT THIS TYPE IS AND IS NOT
# ----------------------------------------------------------------------------
#   * IT IS the reactor the handler's async I/O parks on. `RequestDispatcher.
#     dispatch[RT](reactor, req)` needs a `Reactor[RT.Sink]`; this conformer is
#     where a Lambda-hosted binary gets one, exactly as the HTTP server is where
#     a serving binary gets one.
#   * IT IS NOT the invoke loop, and it does not know what an API Gateway event
#     is. The pump lives in `komira_aws_lambda_http` because it needs
#     `komira_http` types, and `komira_async` sits UNDER `komira_http`.
#     Putting the pump here would invert that edge.
#   * IT IS NOT a client of the Lambda Runtime API. Dialling `/invocation/next`
#     is the Lambda runtime client's job.
#
# ⚠ THE `next` LONG POLL IS WHY `signal_shutdown_all` CANNOT INTERRUPT ANYTHING.
# Between invocations this process is blocked inside the Runtime API client's
# `recv`, and Lambda freezes it there. There is no worker set to signal, no
# select to wake, and — unlike a Cloud Run instance — no SIGTERM contract that
# reliably reaches us first. Shutdown is the platform tearing the sandbox down.
# The method exists so the trait surface is uniform, and says so.
#
# Pointer discipline
# ----------------------------------------------------------------------------
#   * Public API: ZERO `UnsafePointer`, ZERO wildcard origins on any signature.
#   * Internal: ONE `Reactor[S]` owned by value. No Slab, no OwnedPointer worker
#     set, no `unsafe_from_address=Int`, no `take_pointee`, no ArcPointer.
#     safe across destroy-recreate: the single field is a Movable `Reactor[S]` held by value and
#     never placed in a byte-backed slab.
#   * `reactor()` returns `ref [self._reactor] Reactor[Self.S]` — the narrow
#     concrete-field origin (Repro 5b), the SAME form BlockingRuntime.reactor()
#     and GcpCloudRunRuntime.reactor() use. `ref [self]` is rejected by the
#     compiler with "incompatible origin".
#
# def-based, Mojo 1.0.0b2.
# =============================================================================

from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import WakerSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)
from komira_async.runtime.runtime_trait import (
    MODEL_AWS_LAMBDA,
    Runtime,
)


struct AwsLambdaRuntime[
    S: WakerSink & Movable & Deinitable,
](Runtime, Movable, Deinitable):
    """A `Runtime` conformer configured for AWS Lambda.

    Owns exactly ONE `Reactor[S]` and drives it INLINE on the calling thread.
    No pthreads are launched and no worker pool is sized: a Lambda execution
    environment serves one invocation at a time, so a single inline reactor IS
    the correct topology and not a simplification.

    Runtime trait conformance — comptime associated members:
      * `Sink = S`                        — the waker-sink the reactor uses.
      * `RUNTIME_MODEL = MODEL_AWS_LAMBDA` — invocation-driven CPU. ⛔ NOT
        `MODEL_CLOUD_RUN`: the two constraints place the drain-before-suspend
        edge at different instants (see the sentinel's own docstring).
      * `TASKS_ARE_THREAD_PINNED = False` — Lambda promises nothing about which
        core resumes a frozen environment.

    Field set:
      var _reactor: Reactor[Self.S]   — the one reactor, current-thread.

    Construction:
      var rt = AwsLambdaRuntime[NoopSink].new(NoopSink(...))  # comptime backend
      var rt = AwsLambdaRuntime[NoopSink](sink, backend)      # explicit backend

    Movable: `Reactor[S]` is Movable, so the handle is too. It must not be moved
    while a caller is driving its reactor; the borrow checker enforces the
    single-`mut`-borrow that makes that unrepresentable.
    """

    comptime Sink = Self.S
    comptime RUNTIME_MODEL: UInt8 = MODEL_AWS_LAMBDA
    comptime TASKS_ARE_THREAD_PINNED: Bool = False

    var _reactor: Reactor[Self.S]

    def __init__(out self, var sink: Self.S, backend: UInt8) raises:
        """Construct an AwsLambdaRuntime owning one Reactor[S] on `backend`.

        `sink` is consumed (one reactor owns one sink). Prefer the `.new(sink)`
        factory, which comptime-selects the backend the host can actually use —
        Reactor's ctor RAISES on a mismatch rather than degrading.
        """
        self._reactor = Reactor[Self.S](sink^, backend)

    @staticmethod
    def new(var sink: Self.S) raises -> AwsLambdaRuntime[Self.S]:
        """Build an AwsLambdaRuntime with the host-appropriate reactor backend
        comptime-selected (BACKEND_KQUEUE on macOS, BACKEND_EPOLL elsewhere).

        ⚠ The MACOS ARM IS FOR TESTS AND LOCAL RUNS ONLY — Lambda is Linux. It
        is present because the falsifiers for the pump this runtime feeds must
        be runnable on a developer's machine; a conformer that could only be
        constructed on the deployment platform could only be tested there.
        """
        comptime if CompilationTarget.is_macos():
            return AwsLambdaRuntime[Self.S](sink^, BACKEND_KQUEUE)
        else:
            return AwsLambdaRuntime[Self.S](sink^, BACKEND_EPOLL)

    # -------------------------------------------------------------------------
    # The reactor accessor — how the pump reaches the dispatcher's I/O seam.
    # -------------------------------------------------------------------------
    def reactor(mut self) -> ref [self._reactor] Reactor[Self.S]:
        """Return a mutable ref to the owned reactor.

        The caller binds `ref reactor = rt.reactor()` (NOT `var` — `Reactor[S]`
        is Movable-only and `var` would trigger an implicit move) and threads it
        into `run_api_gateway_pump`, which hands it to
        `dispatcher.dispatch[RT](reactor, req)`. That is the same threading the
        HTTP server performs; the pump replaces the socket, not the seam.
        """
        return self._reactor

    # -------------------------------------------------------------------------
    # Runtime trait surface.
    # -------------------------------------------------------------------------
    def worker_count(self) -> Int:
        """Runtime trait. Always 1 — one Lambda execution environment serves one
        invocation at a time, so `[RT]`-generic code that sizes per-worker
        connection sub-pools correctly sees exactly one.
        """
        return 1

    def poll_completions(
        mut self, worker_idx: Int, timeout_us: Int32,
    ) raises -> Int:
        """Runtime trait. Drive ONE pass of the single inline reactor; return the
        number of completions drained.

        `worker_idx` MUST be 0 — any other value RAISES rather than being
        clamped, matching BlockingRuntime / GcpCloudRunRuntime. Silently
        accepting worker 3 on a one-worker runtime would let a caller believe it
        was driving a reactor that does not exist.
        """
        if worker_idx != 0:
            raise Error(
                "AwsLambdaRuntime.poll_completions: worker_idx must be 0 "
                "(single inline-reactor runtime); got "
                + String(worker_idx)
            )
        var completions = self._reactor.poll_completions(timeout_us)
        return len(completions)

    def timer_advance(
        mut self, worker_idx: Int, now_ns: Int64,
    ) raises:
        """Runtime trait. v0.4 stub — `Reactor` does not yet own a TimerWheel,
        exactly as for BlockingRuntime / GcpCloudRunRuntime. `worker_idx` MUST
        be 0.
        """
        if worker_idx != 0:
            raise Error(
                "AwsLambdaRuntime.timer_advance: worker_idx must be 0; got "
                + String(worker_idx)
            )
        _ = now_ns

    def timer_now_ns(self, worker_idx: Int) -> Int64:
        """Runtime trait. v0.4 stub — returns 0 until `Reactor.TimerWheel` is
        wired (matches the sibling conformers). Out-of-range `worker_idx`
        returns 0 with no raise, the same contract the siblings hold.
        """
        _ = worker_idx
        return Int64(0)

    def signal_shutdown_all(mut self):
        """Runtime trait. A TRUE no-op, and the reason is worth reading before
        anyone "implements" it.

        There are no worker pthreads to signal. More importantly there is
        nothing this process can usefully do at shutdown time: between
        invocations it is blocked in the Runtime API's `next` long poll and
        FROZEN there by the platform, and the sandbox is torn down without a
        SIGTERM contract we can rely on reaching us first.

        ⛔ DRAINING THEREFORE BELONGS *AFTER* THE INVOCATION RESULT IS POSTED
        AND *BEFORE* THE NEXT `/invocation/next` POLL — never before the result
        POST, and never here. An earlier revision of this docstring said
        "before the result POST returns" and that was WRONG in a way that costs
        money as well as correctness:

          * WRONG on mechanism. The freeze is triggered by the POLL, not by the
            response. The post-response window is CPU-allocated and un-frozen,
            which is exactly why the drain fits in it. (The premise behind the
            wrong version — "AWS freezes the environment the instant the
            response returns" — is managed-handler folklore and false for a
            custom runtime, which owns its own loop.)
          * WRONG on cost. The drain is an S3 conditional PUT
            (`komira_log_sink_aws`). Pre-response it would weld an S3 round trip
            into every response's BILLED DURATION *and* into the caller's
            latency. Post-response it lands in the un-billed window.

        The rule and its rationale are stated from the durability side in
        `komira_log_sink_aws` (the AWS flush sink), which also names the
        structural twin: the Cloud Run serve loop flushes AFTER writing the
        response. It is implemented in
        `komira_aws_lambda_http.pump.run_api_gateway_pump`, and inverting it
        there is a RED test in that package.

        That placement is also why `MODEL_AWS_LAMBDA` is its own sentinel.
        """
        pass

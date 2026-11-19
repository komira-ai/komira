# =============================================================================
# StreamingMorselSink -- first-class streaming sink contract (CONTRACTS ONLY)
# =============================================================================
#
# Streaming ADR Phase 0, item 2 (an internal doc §5.3 / §6.1,
# / ). DISTINCT from the batch `MorselSinkImpl`
# trait (`morsel_sink.mojo`): a batch sink has `consume` + `finalize` for a
# single bounded run. A streaming sink runs FOREVER across many STEPS and must
# expose the two-phase, step-keyed commit lifecycle that exactly-once recovery
# rides on: `pre_commit(step) -> CommitToken` (phase 1: durable-but-invisible),
# `commit(step)` (phase 2: make visible, idempotent on recovery), `abort(step)`,
# and `restore_from(token)` (recovery).
#
# CONTRACTS-ONLY (Phase 0): trait + type + enum definitions. NO impls, NO
# streaming behavior. The batch path is UNCHANGED — this trait is additive and
# does NOT overload `MorselSinkImpl`.
#
# ENCAPSULATION (maintainer rule): every type here is a safe type. `CommitToken` is a
# safe POD handle (no raw pointers). No `UnsafePointer` crosses any boundary.
# =============================================================================

from .morsel import Morsel


# -----------------------------------------------------------------------------
# StepId -- the deterministic micro-batch step identifier
# -----------------------------------------------------------------------------


struct StepId(ImplicitlyCopyable, Movable, Deinitable):
    """Identifies one deterministic micro-batch STEP (ADR §0, §6.1).

    The streaming model is micro-batch: the step driver runs a deterministic
    step over a `[lo, hi)` input range, snapshots state, lands an offset-log
    + commit-log entry, then re-arms. The `StepId` is the monotonic step
    sequence number — it KEYS the sink's two-phase commit (a `commit(step)`
    re-applied on recovery is idempotent because it is keyed by this id) and
    the offset-log / commit-log entries (`offsets/N`, `commits/N` — ADR
    §6.1 "offset-log-ahead-of-commit-log invariant").

    A plain monotonic `UInt64`; POD / Copyable so it threads freely through
    the driver, the sink, and the durable logs.
    """

    var seq: UInt64

    def __init__(out self, seq: UInt64 = 0):
        self.seq = seq

    def __eq__(self, other: Self) -> Bool:
        return self.seq == other.seq

    def __ne__(self, other: Self) -> Bool:
        return self.seq != other.seq


# -----------------------------------------------------------------------------
# CommitToken -- the opaque phase-1 (pre_commit) durability receipt
# -----------------------------------------------------------------------------


struct CommitToken(ImplicitlyCopyable, Movable, Deinitable):
    """Opaque receipt returned by `pre_commit` (ADR §5.3 / §6.1).

    The two-phase sink protocol: `pre_commit(step)` makes the step's output
    DURABLE-but-INVISIBLE and returns this token; `commit(step)` (or, on
    recovery, `restore_from(token)` then `commit`) makes it VISIBLE. The
    token carries just enough to identify the pending transaction so a
    crash between phase 1 and phase 2 can preemptively commit it on restore
    (the 2PC recovery edge, ADR §6.1) — keyed by `step` so the commit is
    idempotent-on-recovery.

    Phase 0 contracts: a POD pair (step id + an opaque source-owned
    `txn_handle`). The `txn_handle` meaning is sink-defined (a broker 2PC
    transaction id, a staged-file generation, etc.) — the engine treats it
    as opaque. SAFE POD (no raw pointers) — encapsulation-clean.
    """

    var step: StepId
    var txn_handle: UInt64
    """Opaque sink-owned transaction handle. Meaning is sink-defined (broker
    txn id / staged-file generation / etc.); the engine never interprets it."""

    def __init__(out self, step: StepId, txn_handle: UInt64 = 0):
        self.step = step
        self.txn_handle = txn_handle


# -----------------------------------------------------------------------------
# SinkClass -- the EO/ALO capability class the planner consults (ADR §6.1)
# -----------------------------------------------------------------------------

comptime SINK_CLASS_IDEMPOTENT: UInt8 = 0
"""Idempotent-by-key sink (the Komira KG/index shape): re-applying a step's
output collapses the duplicate by key -> end-to-end EXACTLY-ONCE WITHOUT 2PC.
The planner promises EO if the source is also replayable (ADR §6.1)."""
comptime SINK_CLASS_TRANSACTIONAL: UInt8 = 1
"""Transactional sink (broker idempotent-producer + 2PC): the two-phase
pre_commit / commit flips a CAS transaction state. Qualifies for EO to a
non-idempotent destination (ADR §6.1)."""
comptime SINK_CLASS_AT_LEAST_ONCE: UInt8 = 2
"""At-least-once sink (no dedup, no transaction): a replay duplicate is NOT
collapsed. The planner DOWNGRADES the pipeline to ALO LOUDLY at plan time
(ADR §6.1 "ALO as downgrade, NOT a mode") — surfaced in the plan, never a
silent runtime duplicate."""


struct SinkClass(ImplicitlyCopyable, Movable, Deinitable):
    """The exactly-once / at-least-once capability class of a streaming sink
    (ADR §6.1). Consulted by the planner together with the source's
    `capabilities().replayable` to decide EO-vs-ALO at PLAN time:

        replayable source AND (idempotent OR transactional) sink -> EO
        otherwise                                                 -> ALO (loud)

    There is NO `engine.mode = at_least_once` switch; the recovery machinery
    is identical and EO is the ONE contract. The only difference is whether
    the sink collapses the replay duplicate (idempotent/transactional) or
    not (at_least_once -> the loud downgrade).

    A `UInt8` tag (no native Mojo enum) following the in-tree comptime-tag
    idiom; the three values are the `SINK_CLASS_*` constants above.
    """

    var tag: UInt8

    def __init__(out self, tag: UInt8 = SINK_CLASS_AT_LEAST_ONCE):
        self.tag = tag

    @staticmethod
    def idempotent() -> SinkClass:
        return SinkClass(SINK_CLASS_IDEMPOTENT)

    @staticmethod
    def transactional() -> SinkClass:
        return SinkClass(SINK_CLASS_TRANSACTIONAL)

    @staticmethod
    def at_least_once() -> SinkClass:
        return SinkClass(SINK_CLASS_AT_LEAST_ONCE)

    @always_inline
    def is_idempotent(self) -> Bool:
        return self.tag == SINK_CLASS_IDEMPOTENT

    @always_inline
    def is_transactional(self) -> Bool:
        return self.tag == SINK_CLASS_TRANSACTIONAL

    @always_inline
    def is_at_least_once(self) -> Bool:
        return self.tag == SINK_CLASS_AT_LEAST_ONCE

    @always_inline
    def qualifies_for_exactly_once(self) -> Bool:
        """True if this sink can collapse a replay duplicate (idempotent OR
        transactional). The planner ANDs this with the source's
        `replayable` bit to decide EO-vs-ALO (ADR §6.1)."""
        return (
            self.tag == SINK_CLASS_IDEMPOTENT
            or self.tag == SINK_CLASS_TRANSACTIONAL
        )


# -----------------------------------------------------------------------------
# StreamingMorselSink -- the trait (DISTINCT from batch MorselSinkImpl)
# -----------------------------------------------------------------------------


trait StreamingMorselSink(Movable, Deinitable):
    """First-class streaming sink contract (ADR §5.3 / §6.1). CONTRACTS-ONLY.

    DISTINCT from the batch `MorselSinkImpl` trait — do NOT overload it. A
    batch sink (`consume` + `finalize`) runs once over bounded input; a
    streaming sink runs FOREVER across many deterministic STEPS and exposes
    the two-phase, step-keyed commit lifecycle that exactly-once recovery
    rides on.

    The per-step lifecycle the step driver drives:
        for each step N:
            consume(worker_id, delta_morsel)   # 0..M times (the step's output)
            token = pre_commit(StepId(N))      # phase 1: durable-but-invisible
            commit(StepId(N))                  # phase 2: make visible (idempotent)
        on crash mid-step:
            restore_from(token)                # rebuild pending txn state
            commit(StepId(N))                  # idempotent re-apply
        on planner abort:
            abort(StepId(N))                   # discard the step's pending output

    EXACTLY-ONCE: `commit` MUST be idempotent-on-recovery (re-applying a
    completed commit is a no-op — the broker's If-Match CAS `Complete` flip
    already is). `sink_class()` tells the planner whether this sink collapses
    a replay duplicate (idempotent / transactional -> EO) or not
    (at_least_once -> loud plan-time downgrade).

    TRAIT-HIERARCHY BINDING (PINNED, ADR §1.2): a streaming sink that
    allocates positions / decides "which step is committed" binds
    `ConditionalWriteStore` via `CasManifestStore` (the commit-log append is
    a CAS that gates visibility); a checkpoint sink's STATE BODIES are bulk
    IO over `FileSystem`, but the "which checkpoint is current" HEAD advance
    is the CAS manifest. Spill is the ONLY face that binds `FileSystem`
    alone, and spill is not a streaming sink.

    ENCAPSULATION: `consume` takes the delta morsel by OWNED MOVE
    (`var delta_morsel: Morsel`); `pre_commit` returns a SAFE POD
    `CommitToken`. No `UnsafePointer` in any signature.
    """

    def consume(mut self, worker_id: Int, var delta_morsel: Morsel) raises:
        """Absorb one delta morsel for the current step. Owned move."""
        ...

    def pre_commit(mut self, step: StepId) raises -> CommitToken:
        """Phase 1: make the step's output DURABLE-but-INVISIBLE; return a
        receipt. (ADR §5.3 / §6.1)."""
        ...

    def commit(mut self, step: StepId) raises:
        """Phase 2: make the pre-committed step VISIBLE. MUST be
        idempotent-on-recovery (re-applying a completed commit is a no-op)."""
        ...

    def abort(mut self, step: StepId) raises:
        """Discard the step's pending (pre-committed) output (planner abort
        / pipeline-breaker rejection)."""
        ...

    def restore_from(mut self, var token: CommitToken) raises:
        """Recovery: rebuild the pending-transaction state from a token so a
        crash between pre_commit and commit can preemptively `commit` on
        restore (the 2PC recovery edge, ADR §6.1). Owned move."""
        ...

    def sink_class(self) -> SinkClass:
        """The EO/ALO capability class (idempotent | transactional |
        at_least_once). The planner consults this at plan time (ADR §6.1)."""
        ...

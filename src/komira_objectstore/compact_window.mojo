# =============================================================================
# komira_objectstore/compact_window.mojo
#   The compaction substrate. The GENERAL compaction primitive: the shared
#   RESUME -> PLAN -> FOLD -> MATERIALIZE -> ADVANCE -> RETIRE envelope, behind
#   ONE typed trait + a function-shaped driver + 2 shared free-fn helpers.
# =============================================================================
#
# ── THE PROBLEM IT SOLVES ────────────────────────────────────────────────────
# Three+ subsystems independently re-implement the SAME compaction shape: fold a
# committed-chunk tail into ONE immutable base/Parquet object, advance a
# watermark past the folded range (a CAS or a derived high-water), then retire
# the now-subsumed inputs (clamped so a crash between materialize + advance never
# double-materializes into a wrong state or frees an input twice). Today that
# shape is open-coded three times:
#   * `komira_comms_index.comms_index.compact` — the canonical
#     6-step witness: read HEAD + log_start -> fold [start..head] -> project
#     survivors -> append base -> If-Match advance _LOG_START (the K1 412-loser
#     re-reads) -> schedule+reap the retired deltas (the K2 best-effort loop).
#   * `komira_pgstore_columnar.log_compactor.run_once_columnarize_log`
#     — the DERIVED-WATERMARK / cross-lineage variant: fold WAL [lo..hi]
#     -> ONE Parquet object -> PUT -> append a ColumnarFileEntry (the lock-free
#     If-None-Match append IS the watermark advance; no CAS to lose) ->
#     schedule_for_delete the folded WAL chunks.
#   * `komira_broker.sublineage_segment_fold` — the bespoke broker fold (NOT
#     factored here; it stays bespoke).
# This primitive factors the SHARED steps (RESUME / PLAN gating / MATERIALIZE
# fence / ADVANCE-loser-no-op / clamped RETIRE) ONCE, behind a typed trait, so a
# consumer plugs in ONLY its DOMAIN fold/encode/output-target + its watermark +
# its retire, and inherits the crash-atomic, heap-reuse-safe envelope unchanged.
#
# ── THE 6-STEP ENVELOPE (steps 1/4/5/6 shared; step 3 is irreducibly domain) ──
#   1. RESUME      — pick up the durable state (read HEAD / high-water). Folded
#                    INTO plan_range (the trait's step-1+2).
#   2. PLAN        — derive the [lo, hi] range to fold + the no-op early-exit
#                    (lo > hi). `CompactRange.is_noop()`. The trait's plan_range
#                    returns this; the driver returns early on a no-op.
#   3. FOLD        — fold [lo, hi] into survivors (the DOMAIN fold; LSM
#                    last-writer-wins, MVCC version rows, etc.). Irreducibly
#                    per-consumer. Fused with step 4 in fold_and_materialize.
#   4. MATERIALIZE — encode the survivors into ONE durable object + record the
#                    output target (a chunk_seq, a Parquet key, an entry seq).
#                    Fused with FOLD: the consumer owns fold+encode+PUT and
#                    returns a CompactProduct describing what it durably wrote.
#   5. ADVANCE     — advance the watermark past the folded range. A CAS-watermark
#                    consumer races: WON => proceed to RETIRE; LOST (412) => our
#                    materialized object is a HARMLESS REDUNDANT immutable chunk
#                    (the fold is order-independent under seq), so we return
#                    lost-redundant + do NOT retire (the winner owns the reap
#                    window). A DERIVED-watermark consumer (the entry-append IS
#                    the advance) returns True trivially. This is the K1 helper.
#   6. RETIRE      — free the now-subsumed inputs, CLAMPED to safe_retire_floor =
#                    min(desired, durably-materialized + 1): NEVER retire an input
#                    above what the just-materialized object durably covers, so a
#                    crash between MATERIALIZE + ADVANCE (the output wrote but the
#                    watermark did not advance) leaves every input recoverable on
#                    retry — the re-fold re-materializes the SAME survivors, the
#                    watermark advance is idempotent-by-range, and no input is
#                    freed twice. Best-effort per the comms-index lifecycle (a
#                    transient retire failure leaves a dead input below the
#                    watermark that read-state never reads). This is the K2 helper.
#
# ── WHY FUNCTION-SHAPED, NOT A PARAMETRIC _CompactSpine ───────────────────────
# The CoalescingWindow sibling's `_CoalesceSpine[Storage, H, C, A]` is a
# 4-type-parameter, poll-shaped async state machine (it PARKS every I/O phase on
# a reactor). That shape is load-bearing for the WRITE path (the burst-stall
# fix) but it is a comptime HEAVYWEIGHT: instantiating a 4-param spine across N
# consumers risks the `ctx.materialize` comptime wall (the cold-compile blowup
# the dev-gating policy calls out). Compaction is a BACKGROUND, run-once,
# already-off-the-hot-path operation — it does NOT need to park. So this
# primitive is deliberately FUNCTION-SHAPED: ONE trait (`CompactionSource`,
# 1 generic param) + a plain `raises` driver (`compact_once[Src]`) + 2 free-fn
# helpers (synchronous). The generic surface is ONE type parameter per
# instantiation — the minimal comptime footprint that still factors the shared
# steps.
#
# ── THE heap-reuse CONTRACT (a non-issue by construction; here's why) ─────────────
#   * The trait surface is TYPED VALUES ONLY: owned values (CompactRange,
#     CompactProduct[OutputRef], CompactSummary), Int64 watermarks/floors, an
#     opaque Copyable+Movable OutputRef, an Int retire index, and a Bool. ZERO
#     UnsafePointer / wildcard origin (MutAnyOrigin / ImmutAnyOrigin /
#     MutExternalOrigin) / unsafe_from_address / take_pointee crosses ANY seam.
#   * CompactProduct[OutputRef] + CompactSummary are POD-of-owned-bytes in plain
#     Lists — they are NEVER stored as byte-slab elements (no OwnedSlab /
# MutableArray / AtomicSlab storage). So the heap-reuse trap (a Movable struct with
#     a heap-owning inner field laundered through a wildcard cast in a byte-slab)
#     is structurally absent: these are plain owned values that flow by `^` move.
#   * The driver holds NO long-lived state across a park (there are no parks).
#     Each step is a synchronous trait call; the consumer owns its own store
#     handle INSIDE the conformer (only typed values cross out).
#
# ── ENCAPSULATION ────────────────────────────────────────────────────────────
# ZERO UnsafePointer in any signature; ZERO wildcard origin; ZERO
# unsafe_from_address. The consumer's store / manifest / Parquet machinery stays
# INSIDE the conformer — the trait exposes only get/plan/fold/advance/retire over
# typed values. Mojo 1.0.0b1.
# =============================================================================


# =============================================================================
# CompactRange — the PLAN output (steps 1+2: the folded [lo, hi] window).
# =============================================================================
# A PURE POD describing the chunk range to fold this pass. `is_noop()` is the
# step-2 early-exit predicate (nothing committed past the watermark). The
# consumer's plan_range reads its durable HEAD + watermark (step 1, RESUME) and
# derives this; the driver gates on `is_noop()` and returns early.


@fieldwise_init
struct CompactRange(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """The folded chunk range a compaction pass plans. POD.

    Field layout:
      var lo: Int64 — lowest input chunk_seq to fold (inclusive). The
                      watermark + 1 (the first still-uncompacted chunk).
      var hi: Int64 — highest input chunk_seq to fold (inclusive). The
                      authoritative HEAD chunk_seq.

    A range with `lo > hi` is a NO-OP: nothing has been committed past the
    watermark, so there is no tail to fold (the step-2 early-exit). `noop()`
    constructs the canonical empty range.
    """

    var lo: Int64
    var hi: Int64

    @staticmethod
    def noop() -> CompactRange:
        """The empty range: lo=0, hi=-1 (lo > hi => is_noop() True)."""
        return CompactRange(lo=Int64(0), hi=Int64(-1))

    @always_inline
    def is_noop(self) -> Bool:
        """True iff there is no tail to fold (lo > hi). The driver returns a
        no-op summary on this without folding / materializing / advancing."""
        return self.lo > self.hi

    @always_inline
    def span(self) -> Int64:
        """Number of input chunks in this range (0 for a no-op)."""
        if self.is_noop():
            return Int64(0)
        return self.hi - self.lo + Int64(1)


# =============================================================================
# CompactProduct[OutputRef] — the MATERIALIZE output (steps 3+4 fused).
# =============================================================================
# What the consumer durably wrote this pass: the folded range it covers, an
# opaque per-consumer OutputRef (a chunk_seq, a Parquet key, an entry seq —
# whatever the consumer needs to identify its output), and the
# durably-materialized high-water (the K2 crash-atomicity input: an input is
# only safe to retire up to materialized_thru + 1, so a crash before ADVANCE
# never frees an input the re-fold still needs).


struct CompactProduct[
    OutputRef: Copyable & Movable & Deinitable
](Movable, Deinitable):
    """The durable output of one fold_and_materialize. Owned value (NOT a
    byte-slab element).

    Field layout:
      var covered: CompactRange — the input range this output durably folds.
      var output: OutputRef     — the consumer's opaque output identifier (a
                                  chunk_seq, a Parquet object key, an entry seq).
                                  Copyable & Movable; the consumer owns its
                                  meaning. The driver / helpers never inspect it.
      var materialized_thru: Int64 — the highest input chunk_seq this output
                                  DURABLY covers (== covered.hi on the normal
                                  path). The K2 retire floor derives from this:
                                  no input above materialized_thru is ever
                                  retired, so a crash between MATERIALIZE and
                                  ADVANCE is recoverable (the inputs survive).
      var row_count: Int64      — total rows/records folded (observability).
    """

    var covered: CompactRange
    var output: Self.OutputRef
    var materialized_thru: Int64
    var row_count: Int64

    def __init__(
        out self,
        covered: CompactRange,
        var output: Self.OutputRef,
        materialized_thru: Int64,
        row_count: Int64 = Int64(0),
    ):
        self.covered = covered
        self.output = output^
        self.materialized_thru = materialized_thru
        self.row_count = row_count


# =============================================================================
# CompactSummary — the driver's exit summary (POD).
# =============================================================================
# The outcome of one compact_once pass. POD-of-scalars; NOT a byte-slab element.


# CompactSummary.outcome discriminants.
comptime COMPACT_NOOP: UInt8 = 0  # plan was a no-op (lo > hi); nothing folded.
comptime COMPACT_WON: UInt8 = 1  # folded, materialized, watermark WON, retired.
comptime COMPACT_LOST: UInt8 = 2  # materialized but watermark LOST (412) — our
#                                 # output is a harmless redundant chunk; we did
#                                 # NOT retire (the winner owns the reap window).


@fieldwise_init
struct CompactSummary(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """The outcome of one `compact_once` pass. POD.

    Field layout:
      var outcome: UInt8        — COMPACT_NOOP / COMPACT_WON / COMPACT_LOST.
      var lo: Int64             — the planned range lo (-1 / unset on a no-op).
      var hi: Int64             — the planned range hi (-1 / unset on a no-op).
      var materialized_thru: Int64 — the durable high-water the output covered
                                  (-1 on a no-op). The K2 floor input.
      var retired_count: Int64  — how many inputs were retired (0 on noop/lost).
      var row_count: Int64      — rows/records folded (0 on noop).
    """

    var outcome: UInt8
    var lo: Int64
    var hi: Int64
    var materialized_thru: Int64
    var retired_count: Int64
    var row_count: Int64

    @staticmethod
    def noop() -> CompactSummary:
        """The no-op summary: the plan had no tail to fold."""
        return CompactSummary(
            outcome=COMPACT_NOOP,
            lo=Int64(-1),
            hi=Int64(-1),
            materialized_thru=Int64(-1),
            retired_count=Int64(0),
            row_count=Int64(0),
        )

    @always_inline
    def won(self) -> Bool:
        return self.outcome == COMPACT_WON

    @always_inline
    def lost(self) -> Bool:
        return self.outcome == COMPACT_LOST

    @always_inline
    def is_noop(self) -> Bool:
        return self.outcome == COMPACT_NOOP


# =============================================================================
# CompactionSource — the consumer's pluggable seam (ONE trait, 1 param).
# =============================================================================
# The trait surface is TYPED VALUES ONLY (the heap-reuse + encapsulation contract).
# The consumer owns its store / manifest / Parquet machinery INSIDE the
# conformer; the driver sees only the planned range, the materialized product,
# a won/lost Bool, and the retire floor.


trait CompactionSource(Movable, Deinitable):
    """SEAM: the consumer's pluggable compaction surface. The
    function-shaped driver `compact_once[Src]` drives this through the shared
    6-step envelope; the consumer plugs in ONLY its domain fold/encode/output +
    watermark + retire.

    Associated type:
      OutputRef — the consumer's opaque output identifier (Copyable & Movable &
                  Deinitable): a chunk_seq, a Parquet object key, an
                  entry seq. The driver / helpers NEVER inspect it; the consumer
                  owns its meaning.

    Pointer discipline: ZERO UnsafePointer / wildcard origin / unsafe_from_address
    in ANY signature. The store / manifest stays INSIDE the conformer; only typed
    values (CompactRange / CompactProduct / Int64 / Int / Bool) cross the seam.
    """

    comptime OutputRef: Copyable & Movable & Deinitable

    def plan_range(mut self) raises -> CompactRange:
        """Steps 1+2 (RESUME + PLAN): read the durable HEAD + watermark and
        derive the [lo, hi] chunk range to fold this pass. Return
        `CompactRange.noop()` (lo > hi) when nothing is committed past the
        watermark — the driver returns a no-op summary without folding.

        THE REAL-S3 LIST-DELIMITER TRAP (feedback_real_s3_list_delimiter_trap):
        if this plan reconstructs the HEAD via a LIST replay (an object-store
        sub-dir enumeration), it MUST union `common_prefixes` AND `objects` — a
        fold over only `listed.objects` silently returns EMPTY on real S3/GCS
        while passing on the in-mem store. Every conformer honors this."""
        ...

    def fold_and_materialize(
        mut self, range: CompactRange
    ) raises -> CompactProduct[Self.OutputRef]:
        """Steps 3+4 (FOLD + MATERIALIZE), fused: fold the input range [lo, hi]
        into survivors (the DOMAIN fold — LSM last-writer-wins, MVCC version
        rows, etc.), encode them into ONE durable object, PUT/append it, and
        return a CompactProduct describing what was durably written (the covered
        range, the opaque OutputRef, the materialized high-water, the row count).

        The consumer owns the fold + encode + output target ENTIRELY; the driver
        never sees a key / offset / Parquet byte. The returned
        `materialized_thru` is the K2 crash-atomicity input — set it to the
        highest input chunk_seq the just-written object DURABLY covers (== hi on
        the normal path)."""
        ...

    def advance_watermark(
        mut self, product: CompactProduct[Self.OutputRef]
    ) raises -> Bool:
        """Step 5 (ADVANCE): advance the durable watermark past the folded range
        so the retired inputs become unreadable. Returns:
          * True  — WON (this pass's watermark advance committed). A
                    DERIVED-watermark consumer (whose entry-append in
                    fold_and_materialize WAS the advance) returns True trivially.
          * False — LOST (a concurrent compaction advanced the watermark first;
                    the CAS saw a 412). Our materialized object is a HARMLESS
                    REDUNDANT immutable chunk (the fold is order-independent under
                    seq); the driver returns lost-redundant and does NOT retire
                    (the winner owns the reap window).

        A 412 / precondition-conflict MUST be reported as `False` (lost), NOT
        raised — the K1 helper (run_watermark_advance) turns the lost into a
        clean lost-redundant exit. Any OTHER error (transport / auth) is raised."""
        ...

    def retire_input(mut self, idx: Int64) raises:
        """Step 6 (RETIRE), one input: free the now-subsumed input chunk at
        `idx` (schedule_for_delete + reap / delete). Called by the K2 helper for
        each idx in [range.lo, safe_retire_floor) — NEVER above the floor, so a
        crash between MATERIALIZE and ADVANCE leaves every still-needed input
        recoverable. May raise on a transient failure; the K2 helper treats a
        raise as best-effort (a dead input below the watermark that read-state
        never reads; the next pass re-attempts)."""
        ...

    def safe_retire_floor(
        self, product: CompactProduct[Self.OutputRef]
    ) raises -> Int64:
        """The K2 crash-atomicity clamp: the EXCLUSIVE upper bound on retirable
        inputs. The canonical derivation is `min(desired, materialized_thru + 1)`
        where `desired` is what the consumer WOULD retire if it ignored crash
        atomicity (typically range.hi + 1). The clamp guarantees no input above
        what the just-materialized object durably covers is ever freed: if a
        crash interrupts between MATERIALIZE and ADVANCE, the inputs in
        [floor, hi] survive, the retry's re-fold re-materializes the SAME
        survivors, and the watermark advance is idempotent-by-range — so no input
        is double-freed and the output is never folded into a wrong state.

        Returns the exclusive floor (retire idx in [range.lo, floor))."""
        ...


# =============================================================================
# run_watermark_advance — the K1 shared helper (the loser-no-op).
# =============================================================================
# The watermark-CAS-with-loser-no-op control flow, factored ONCE: drive the
# consumer's advance_watermark; on a WON proceed (caller retires); on a LOST
# (a competitor landed in the watermark slot first) treat our materialized
# output as a HARMLESS REDUNDANT immutable chunk (the fold is order-independent
# under seq) and signal lost-redundant — do NOT retire (the winner owns the reap
# window). The consumer's conformer maps a 412/precondition to `False`; this
# helper translates that into the shared exit decision.


def run_watermark_advance[
    Src: CompactionSource
](mut src: Src, product: CompactProduct[Src.OutputRef]) raises -> Bool:
    """K1: advance the watermark past the folded range; return True on WON
    (caller proceeds to RETIRE), False on LOST (a redundant-chunk no-op; caller
    does NOT retire). Mirrors comms_index.compact's `advance_log_start` 412-loser
    branch (the loser's base chunk is a harmless redundant chunk the reaper later
    collects; it cannot corrupt the fold). The consumer reports a 412 as `False`
    via advance_watermark; this helper is the shared decision the driver and
    every consumer share."""
    return src.advance_watermark(product)


# =============================================================================
# run_clamped_retire — the K2 shared helper (the floor-clamped retire).
# =============================================================================
# The retire loop CLAMPED to safe_retire_floor, factored ONCE: retire each input
# in [range.lo, safe_retire_floor) — NEVER above the floor. Best-effort per the
# comms-index lifecycle: a transient retire failure leaves a dead input below the
# watermark that read-state never reads (it starts at the watermark); the next
# pass re-attempts. Returns the count actually retired.


def run_clamped_retire[
    Src: CompactionSource
](
    mut src: Src, range: CompactRange, product: CompactProduct[Src.OutputRef]
) raises -> Int64:
    """K2: retire the now-subsumed inputs in [range.lo, floor), where floor =
    src.safe_retire_floor(product) = min(desired, materialized_thru + 1). NEVER
    retires an input at or above the floor — so a crash between MATERIALIZE and
    ADVANCE leaves the inputs in [floor, hi] recoverable (the re-fold
    re-materializes the SAME survivors; the advance is idempotent-by-range).
    Best-effort: a transient retire failure is swallowed (a dead input below the
    watermark read-state never reads; the next pass re-attempts). Returns the
    count retired."""
    var floor = src.safe_retire_floor(product)
    var retired = Int64(0)
    var idx = range.lo
    while idx < floor:
        try:
            src.retire_input(idx)
            retired += Int64(1)
        except e:
            # Best-effort reclaim (comms_index.compact step 5): a transient reap
            # failure leaves a dead input below the watermark that read-state
            # never reads (it starts at the watermark). The next compaction
            # re-attempts. Do NOT fail the compact on a reclaim hiccup.
            _ = e
        idx += Int64(1)
    return retired


# =============================================================================
# compact_once — the function-shaped driver (the 6-step envelope).
# =============================================================================
# ONE generic function (1 type parameter) that drives the shared envelope:
#   plan -> (noop? exit) -> fold_and_materialize -> run_watermark_advance ->
#   (lost? exit redundant) -> run_clamped_retire -> summary.
# NO parametric spine, NO reactor, NO park (synchronous). The minimal
# comptime footprint that still factors the shared steps across N consumers.


def compact_once[Src: CompactionSource](mut src: Src) raises -> CompactSummary:
    """Drive ONE compaction pass through the shared 6-step envelope (synchronous,
    synchronous):

      1+2 PLAN     — `src.plan_range()`. A no-op (lo > hi) returns
                     CompactSummary.noop() immediately (no fold / materialize /
                     advance / retire).
      3+4 MATERIALIZE — `src.fold_and_materialize(range)` folds [lo, hi] into ONE
                     durable object + records the materialized high-water.
      5   ADVANCE  — `run_watermark_advance` (K1). On LOST (a competitor landed
                     in the watermark slot first) the materialized output is a
                     harmless redundant immutable chunk; return COMPACT_LOST and
                     do NOT retire (the winner owns the reap window).
      6   RETIRE   — `run_clamped_retire` (K2): retire [range.lo, floor) where
                     floor = min(desired, materialized_thru + 1) — the crash-
                     atomicity clamp. Best-effort.

    Returns a CompactSummary (NOOP / WON / LOST + the range + row/retire counts).
    """
    # ---- steps 1+2: PLAN (RESUME folded in) + the no-op early-exit ----
    var range = src.plan_range()
    if range.is_noop():
        return CompactSummary.noop()

    # ---- steps 3+4: FOLD + MATERIALIZE (fused; consumer owns fold+encode+PUT) -
    var product = src.fold_and_materialize(range)
    var materialized_thru = product.materialized_thru
    var row_count = product.row_count

    # ---- step 5: ADVANCE the watermark (K1 — the loser-no-op) ----
    var won = run_watermark_advance[Src](src, product)
    if not won:
        # LOST: our materialized object is a harmless redundant chunk (the fold
        # is order-independent under seq); the winner's watermark stands. Do NOT
        # retire (the winner owns the reap window).
        return CompactSummary(
            outcome=COMPACT_LOST,
            lo=range.lo,
            hi=range.hi,
            materialized_thru=materialized_thru,
            retired_count=Int64(0),
            row_count=row_count,
        )

    # ---- step 6: RETIRE the subsumed inputs (K2 — the floor-clamped loop) ----
    var retired = run_clamped_retire[Src](src, range, product)

    return CompactSummary(
        outcome=COMPACT_WON,
        lo=range.lo,
        hi=range.hi,
        materialized_thru=materialized_thru,
        retired_count=retired,
        row_count=row_count,
    )

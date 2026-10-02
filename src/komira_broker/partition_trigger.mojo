# =============================================================================
# komira_broker/partition_trigger.mojo
#   Dynamic partition scaling — the AUTO-SPLIT TRIGGER
#   (load detection: deciding WHEN to split, object-store-native, no daemon).
# =============================================================================
#
# Scale triggers are object-store-native: there is no always-on scaler
# service. `partition_split.mojo` is the split MECHANISM (`split_topic` — the
# explicitly-invoked primitive). THIS file is the DETECTION that makes hot
# partitions split TRANSPARENTLY — the producer, after a flush, checks the
# just-written partition's accumulated load against a threshold and, if
# crossed, PROPOSES a split via the If-Match CAS. The WRITE PATH drives
# scaling. It also carries the hysteresis, the caps and the hot-key ceiling.
#
# -----------------------------------------------------------------------------
# THE LOAD SIGNAL — MANIFEST-DERIVED, NOT a `_loadstat` sidecar (the cost call)
# -----------------------------------------------------------------------------
# A per-partition `_loadstat` object updated on flush is NOT needed. The
# signal the trigger needs is ALREADY in the
# manifest head that every flush touches:
#
#   * `records_since_base` == the partition manifest's `next_offset` (== the
#     `ProduceResult.last_offset + 1` the producer ALREADY receives on every
#     flush). The partition allocates offsets from 0 at its base, so
#     `next_offset` IS the count of records committed to this partition since
#     its manifest base (its lineage fork point). For a freshly-forked child
#     this starts at 0 — natural hysteresis.
#   * `segment_count` == the manifest's committed chunk count (==
#     `ProduceResult.chunk_seq + 1`). Also free.
#
# So the trigger reads the load signal STRAIGHT OFF the `ProduceResult` the
# flush already returned — ZERO extra object-store reads or writes. A
# `_loadstat` sidecar would cost one extra PUT per flush (or per few flushes)
# for a signal the manifest already carries; the manifest-derived path avoids
# that cost entirely. The trade-off vs the sidecar: the sidecar could carry a
# BYTE rate (the manifest carries RECORD count, not bytes). We pick the
# record/segment signal — it is the simplest robust signal, it is free, and a
# split is about RECORD volume routing to one hash-range (the thing that splits
# the range in half), for which record count is the direct measure. (If a
# byte-rate band is ever wanted, a sidecar can be added additively.)
#
# -----------------------------------------------------------------------------
# THE TRIGGER FLOW (where it checks + proposes)
# -----------------------------------------------------------------------------
# After a flush returns a `ProduceResult` for partition `pid`:
#   1. `evaluate_split` is called with the per-topic `AutoSplitPolicy` + the
#      flush's load signal (`records_since_base`, `segment_count`) + the live
#      partition count.
#   2. It returns a `SplitDecision`: PROPOSE (cross threshold, eligible),
#      SKIP_BELOW_THRESHOLD, SKIP_FRESH_FLOOR (the freshly-forked child floor),
#      or SKIP_AT_CAP (the max_partitions hot-key ceiling — emit the warning).
#   3. On PROPOSE the producer calls `split_topic(pid)` (the If-Match
#      CAS). Concurrent producers proposing the same split → one wins the CAS,
#      the others' `split_at` on the now-retired pid is a clean reject
#      (`split_topic` re-reads + sees pid retired → returns the satisfied
#      result OR raises "not a LIVE partition", which the producer treats as
#      "someone else already split it" — no double-split).
#
# This module is PURE DECISION LOGIC (no store access): it takes the load
# numbers + policy and returns a verdict. The producer owns the store calls
# (read map count, call `split_topic`). Keeping the decision pure makes it
# trivially unit-testable offline (below/at/above threshold; cap; fresh floor;
# idempotent concurrent proposal) without any object store.
#
# -----------------------------------------------------------------------------
# Encapsulation discipline
# -----------------------------------------------------------------------------
#   * ZERO UnsafePointer in any signature — the surface is POD (Ints + an enum
#     UInt8 + small value structs). No pointers anywhere.
#   * ZERO wildcard origins / `unsafe_from_address` / `take_pointee`.
#   * Every type here is a stack POD value, never a byte-slab element.
# =============================================================================


# =============================================================================
# AutoSplitPolicy — the per-topic auto-mode trigger configuration.
# =============================================================================


comptime DEFAULT_SPLIT_THRESHOLD_RECORDS: Int64 = 100_000
comptime DEFAULT_MAX_PARTITIONS: Int = 64
comptime DEFAULT_MIN_SEGMENTS_BEFORE_SPLIT: Int64 = 2

# The lineage-DEPTH cap: a split that would make a child exceed
# this ancestor depth is REFUSED until a compaction pass collapses the lineage.
# Bounds the read-side ancestor walk a deep split tree would otherwise grow
# unbounded. `0` disables the cap.
comptime DEFAULT_MAX_LINEAGE_DEPTH: Int = 4


@fieldwise_init
struct AutoSplitPolicy(Copyable, Movable, Deinitable):
    """The per-topic auto-split trigger config (an `auto`-mode topic's tuning).
    POD.

    Field layout:
      var split_threshold_records: Int64 — the load threshold. A
                              partition whose `records_since_base` reaches this
                              is split-eligible (subject to the cap + floor).
                              Record count (NOT bytes) is the chosen signal: it
                              is manifest-derived (free — no `_loadstat` write),
                              and a split halves a hash-RANGE, for which the
                              record volume routing to that range is the direct
                              measure. Default `DEFAULT_SPLIT_THRESHOLD_RECORDS`.
      var max_partitions: Int — the hot-key ceiling. Once the topic's LIVE
                              partition count reaches this, NO further splits are
                              proposed (and a one-time warning fires). Prevents a
                              single hot KEY (one hash-point — unsplittable) from
                              driving unbounded splits. Default
                              `DEFAULT_MAX_PARTITIONS`.
      var min_segments_before_split: Int64 — the hysteresis floor. A
                              partition must have committed at LEAST this many
                              segments before it is split-eligible, so a
                              freshly-forked child (which starts at
                              records_since_base == 0, segment_count == 0) does
                              NOT instantly re-split on its first flush (a split
                              storm). Default
                              `DEFAULT_MIN_SEGMENTS_BEFORE_SPLIT`.
      var max_lineage_depth: Int — the lineage-DEPTH cap. A split that would
                              push a child past this many ancestors is REFUSED
                              (SKIP_DEPTH_CAP) until a compaction pass collapses
                              the lineage. Bounds the read-side ancestor walk.
                              `0` disables the cap. Default
                              `DEFAULT_MAX_LINEAGE_DEPTH`.
    """

    var split_threshold_records: Int64
    var max_partitions: Int
    var min_segments_before_split: Int64
    var max_lineage_depth: Int

    @staticmethod
    def default() -> AutoSplitPolicy:
        """The default auto-split policy (sane production-ish defaults)."""
        return AutoSplitPolicy(
            split_threshold_records=DEFAULT_SPLIT_THRESHOLD_RECORDS,
            max_partitions=DEFAULT_MAX_PARTITIONS,
            min_segments_before_split=DEFAULT_MIN_SEGMENTS_BEFORE_SPLIT,
            max_lineage_depth=DEFAULT_MAX_LINEAGE_DEPTH,
        )

    @staticmethod
    def with_threshold(
        threshold_records: Int64,
        max_partitions: Int,
        min_segments_before_split: Int64 = DEFAULT_MIN_SEGMENTS_BEFORE_SPLIT,
        max_lineage_depth: Int = DEFAULT_MAX_LINEAGE_DEPTH,
    ) -> AutoSplitPolicy:
        """A policy with an explicit threshold + cap (+ optional floor + depth
        cap). Used by tests (a LOW threshold to force a split on a small load,
        or a LOW depth cap to exercise the lineage refusal) and by an
        auto-topic producer constructed with explicit tuning."""
        return AutoSplitPolicy(
            split_threshold_records=threshold_records,
            max_partitions=max_partitions,
            min_segments_before_split=min_segments_before_split,
            max_lineage_depth=max_lineage_depth,
        )


# =============================================================================
# SplitDecision — the trigger's verdict (POD enum + the carried numbers).
# =============================================================================


comptime SPLIT_DECISION_PROPOSE: UInt8 = 0
comptime SPLIT_DECISION_SKIP_BELOW_THRESHOLD: UInt8 = 1
comptime SPLIT_DECISION_SKIP_FRESH_FLOOR: UInt8 = 2
comptime SPLIT_DECISION_SKIP_AT_CAP: UInt8 = 3
comptime SPLIT_DECISION_SKIP_DEPTH_CAP: UInt8 = 4


@always_inline
def _write_split_decision_name[W: Writer](mut writer: W, kind: UInt8):
    """WRITE what `split_decision_name` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link can bind INDEPENDENTLY — and a pair bound
    CROSSED reads the wrong string, or out of bounds."""
    if kind == SPLIT_DECISION_PROPOSE:
        writer.write(String("PROPOSE"))
        return
    if kind == SPLIT_DECISION_SKIP_BELOW_THRESHOLD:
        writer.write(String("SKIP_BELOW_THRESHOLD"))
        return
    if kind == SPLIT_DECISION_SKIP_FRESH_FLOOR:
        writer.write(String("SKIP_FRESH_FLOOR"))
        return
    if kind == SPLIT_DECISION_SKIP_AT_CAP:
        writer.write(String("SKIP_AT_CAP"))
        return
    if kind == SPLIT_DECISION_SKIP_DEPTH_CAP:
        writer.write(String("SKIP_DEPTH_CAP"))
        return
    writer.write(String("UNKNOWN"))
    return


@always_inline
def split_decision_name(kind: UInt8) -> String:
    """Human name for a decision kind (for logs / test assertions)."""
    var out = String()
    _write_split_decision_name(out, kind)
    return out^


@fieldwise_init
struct SplitDecision(Copyable, Movable, Deinitable):
    """The trigger's verdict for one (partition, load-signal) check. POD.

    Field layout:
      var kind: UInt8       — one of the SPLIT_DECISION_* constants:
                              * PROPOSE — threshold crossed AND eligible (count
                                < cap, segments >= floor). The caller proposes a
                                split via `split_topic(pid)`.
                              * SKIP_BELOW_THRESHOLD — load under the threshold;
                                no proposal (the common case).
                              * SKIP_FRESH_FLOOR — a fresh partition under the
                                min-segments floor; no proposal (anti-storm).
                              * SKIP_AT_CAP — the topic is at `max_partitions`;
                                no proposal + a hot-key warning should fire.
                              * SKIP_DEPTH_CAP — the split would push a child
                                past `max_lineage_depth` ancestors; no
                                proposal + the `needs_compaction` flag is set so
                                the caller can run a compaction pass to collapse
                                the lineage before re-attempting.
      var should_propose: Bool — convenience == (kind == PROPOSE). The caller
                              branches on this.
      var at_cap_warning: Bool — convenience == (kind == SKIP_AT_CAP). When True
                              the caller emits the one-time hot-key warning.
      var needs_compaction: Bool — convenience == (kind == SKIP_DEPTH_CAP). When
                              True the caller should run a lineage-collapse
                              compaction pass before the split
                              can proceed.
    """

    var kind: UInt8
    var should_propose: Bool
    var at_cap_warning: Bool
    var needs_compaction: Bool

    @staticmethod
    def propose() -> SplitDecision:
        return SplitDecision(
            kind=SPLIT_DECISION_PROPOSE,
            should_propose=True,
            at_cap_warning=False,
            needs_compaction=False,
        )

    @staticmethod
    def skip_below_threshold() -> SplitDecision:
        return SplitDecision(
            kind=SPLIT_DECISION_SKIP_BELOW_THRESHOLD,
            should_propose=False,
            at_cap_warning=False,
            needs_compaction=False,
        )

    @staticmethod
    def skip_fresh_floor() -> SplitDecision:
        return SplitDecision(
            kind=SPLIT_DECISION_SKIP_FRESH_FLOOR,
            should_propose=False,
            at_cap_warning=False,
            needs_compaction=False,
        )

    @staticmethod
    def skip_at_cap() -> SplitDecision:
        return SplitDecision(
            kind=SPLIT_DECISION_SKIP_AT_CAP,
            should_propose=False,
            at_cap_warning=True,
            needs_compaction=False,
        )

    @staticmethod
    def skip_depth_cap() -> SplitDecision:
        return SplitDecision(
            kind=SPLIT_DECISION_SKIP_DEPTH_CAP,
            should_propose=False,
            at_cap_warning=False,
            needs_compaction=True,
        )


# =============================================================================
# evaluate_split — the PURE decision function (the trigger's core logic).
# =============================================================================


def evaluate_split(
    policy: AutoSplitPolicy,
    records_since_base: Int64,
    segment_count: Int64,
    live_partition_count: Int,
    candidate_parent_depth: Int = 0,
) -> SplitDecision:
    """Decide whether the just-flushed partition should PROPOSE a split.

    Inputs (all manifest-derived — free, no `_loadstat` sidecar):
      * `records_since_base` — the partition manifest's `next_offset` (==
        `ProduceResult.last_offset + 1`): the count of records committed to
        this partition since its lineage base. For a fresh child this starts
        at 0 (natural hysteresis).
      * `segment_count` — the partition's committed chunk count (==
        `ProduceResult.chunk_seq + 1`): the freshly-forked-child floor signal.
      * `live_partition_count` — the topic's current live partition count (==
        `PartitionMap.num_partitions()`): the cap signal.
      * `candidate_parent_depth` — the lineage depth of the partition being
        considered for split (== its ancestor count; an original root is 0). A
        split would create children at depth `candidate_parent_depth + 1`. The
        lineage-depth cap gate. Defaults to 0 (no depth pressure) so the
        4-arg call sites keep their meaning (cap disabled when
        `policy.max_lineage_depth == 0`).

    Decision order (each gate short-circuits to a SKIP verdict):
      1. CAP — checked FIRST so a topic at its cap NEVER
         proposes (and fires the hot-key warning) regardless of load.
      2. THRESHOLD — below the threshold, no proposal.
      3. FRESH-FLOOR — a partition that crossed the threshold
         but has committed FEWER than `min_segments_before_split` segments is a
         freshly-forked child that hasn't accumulated real sustained load yet;
         hold off (anti-split-storm).
      4. DEPTH-CAP — a split that would push a child past
         `max_lineage_depth` ancestors is REFUSED (SKIP_DEPTH_CAP +
         needs_compaction) until a compaction pass collapses the lineage.
         `max_lineage_depth == 0` disables the gate. Checked AFTER the floor so a
         genuinely hot deep partition surfaces the compaction need (rather than
         a fresh deep child storming).
      5. PROPOSE — threshold crossed, under the cap, past the floor + depth cap.

    PURE — no store access, no side effects. The caller (the producer) owns the
    store calls (reading the map count + the lineage depth, invoking
    `split_topic` / a compaction pass) and the warning emission.
    """
    # 1. Cap gate — at/over the cap: never split, warn.
    if live_partition_count >= policy.max_partitions:
        return SplitDecision.skip_at_cap()

    # 2. Threshold gate.
    if records_since_base < policy.split_threshold_records:
        return SplitDecision.skip_below_threshold()

    # 3. Fresh-floor gate.
    if segment_count < policy.min_segments_before_split:
        return SplitDecision.skip_fresh_floor()

    # 4. Depth-cap gate — a child at depth (parent_depth + 1) past the cap
    # is refused until compaction collapses the lineage.
    if (
        policy.max_lineage_depth > 0
        and candidate_parent_depth + 1 > policy.max_lineage_depth
    ):
        return SplitDecision.skip_depth_cap()

    # 5. Eligible — propose the split.
    return SplitDecision.propose()


# =============================================================================
# AutoMergePolicy — the per-topic auto-merge (scale-IN) trigger config.
# =============================================================================


comptime DEFAULT_MERGE_THRESHOLD_RECORDS: Int64 = 10_000
comptime DEFAULT_MIN_PARTITIONS: Int = 1


@fieldwise_init
struct AutoMergePolicy(Copyable, Movable, Deinitable):
    """The per-topic auto-merge trigger config (an `auto`-mode topic's scale-IN
    tuning). Merge is the DUAL of split + INTENTIONALLY CONSERVATIVE: the
    read-side lineage fan-in grows on a merge, so we merge only when
    BOTH adjacent ranges are sustainedly cold + we never merge a recently-split
    range (anti-flap) + we respect a min-partitions floor. POD.

    Field layout:
      var merge_threshold_records: Int64 — `T_low`. BOTH adjacent ranges must be
                              BELOW this load to be merge-eligible. Much lower
                              than the split threshold (a merge folds two cold
                              ranges). Default `DEFAULT_MERGE_THRESHOLD_RECORDS`.
      var min_partitions: Int — the floor. A merge that would drop
                              the topic below this many live partitions is
                              REFUSED (a topic must keep at least this much
                              parallelism). Default `DEFAULT_MIN_PARTITIONS` (1 —
                              never merge to zero partitions).
      var allow_recently_split: Bool — anti-flap. When
                              False (the default + recommended) a range that is
                              ITSELF a recent split child (its `HashRange` still
                              carries a split back-edge — `parent_split_offset !=
                              NO_PARENT_BASE`) is NOT merge-eligible, so a
                              split-then-immediately-merge flap cannot happen.
                              True only for tests that deliberately exercise the
                              merge of a just-split pair.
    """

    var merge_threshold_records: Int64
    var min_partitions: Int
    var allow_recently_split: Bool

    @staticmethod
    def default() -> AutoMergePolicy:
        """The default auto-merge policy (conservative: low threshold, floor 1,
        anti-flap ON)."""
        return AutoMergePolicy(
            merge_threshold_records=DEFAULT_MERGE_THRESHOLD_RECORDS,
            min_partitions=DEFAULT_MIN_PARTITIONS,
            allow_recently_split=False,
        )

    @staticmethod
    def with_threshold(
        threshold_records: Int64,
        min_partitions: Int = DEFAULT_MIN_PARTITIONS,
        allow_recently_split: Bool = False,
    ) -> AutoMergePolicy:
        """A policy with an explicit T_low + floor (+ optional anti-flap
        override). Used by tests + an auto-topic producer with explicit
        tuning."""
        return AutoMergePolicy(
            merge_threshold_records=threshold_records,
            min_partitions=min_partitions,
            allow_recently_split=allow_recently_split,
        )


# =============================================================================
# MergeDecision — the merge trigger's verdict (POD enum + carried flags).
# =============================================================================


comptime MERGE_DECISION_PROPOSE: UInt8 = 0
comptime MERGE_DECISION_SKIP_NOT_COLD: UInt8 = 1
comptime MERGE_DECISION_SKIP_RECENTLY_SPLIT: UInt8 = 2
comptime MERGE_DECISION_SKIP_AT_FLOOR: UInt8 = 3


@always_inline
def _write_merge_decision_name[W: Writer](mut writer: W, kind: UInt8):
    """WRITE what `merge_decision_name` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link can bind INDEPENDENTLY — and a pair bound
    CROSSED reads the wrong string, or out of bounds."""
    if kind == MERGE_DECISION_PROPOSE:
        writer.write(String("PROPOSE"))
        return
    if kind == MERGE_DECISION_SKIP_NOT_COLD:
        writer.write(String("SKIP_NOT_COLD"))
        return
    if kind == MERGE_DECISION_SKIP_RECENTLY_SPLIT:
        writer.write(String("SKIP_RECENTLY_SPLIT"))
        return
    if kind == MERGE_DECISION_SKIP_AT_FLOOR:
        writer.write(String("SKIP_AT_FLOOR"))
        return
    writer.write(String("UNKNOWN"))
    return


@always_inline
def merge_decision_name(kind: UInt8) -> String:
    """Human name for a merge-decision kind (for logs / test assertions)."""
    var out = String()
    _write_merge_decision_name(out, kind)
    return out^


@fieldwise_init
struct MergeDecision(Copyable, Movable, Deinitable):
    """The merge trigger's verdict for one adjacent (A, B) pair. POD.

    Field layout:
      var kind: UInt8        — one of the MERGE_DECISION_* constants:
                              * PROPOSE — BOTH ranges cold, under the floor's
                                opposite (live_count > min_partitions), neither
                                recently split. The caller proposes a merge via
                                `merge_topic_if_eligible(A, B)`.
                              * SKIP_NOT_COLD — at least one of A/B is at/above
                                T_low (not both cold); no merge.
                              * SKIP_RECENTLY_SPLIT — A or B is a recent split
                                child (anti-flap); no merge.
                              * SKIP_AT_FLOOR — merging would drop below
                                min_partitions; no merge.
      var should_propose: Bool — convenience == (kind == PROPOSE).
    """

    var kind: UInt8
    var should_propose: Bool

    @staticmethod
    def propose() -> MergeDecision:
        return MergeDecision(kind=MERGE_DECISION_PROPOSE, should_propose=True)

    @staticmethod
    def skip_not_cold() -> MergeDecision:
        return MergeDecision(
            kind=MERGE_DECISION_SKIP_NOT_COLD, should_propose=False
        )

    @staticmethod
    def skip_recently_split() -> MergeDecision:
        return MergeDecision(
            kind=MERGE_DECISION_SKIP_RECENTLY_SPLIT, should_propose=False
        )

    @staticmethod
    def skip_at_floor() -> MergeDecision:
        return MergeDecision(
            kind=MERGE_DECISION_SKIP_AT_FLOOR, should_propose=False
        )


# =============================================================================
# evaluate_merge — the PURE merge decision function (the scale-IN trigger core).
# =============================================================================


def evaluate_merge(
    policy: AutoMergePolicy,
    a_records_since_base: Int64,
    b_records_since_base: Int64,
    live_partition_count: Int,
    a_recently_split: Bool,
    b_recently_split: Bool,
) -> MergeDecision:
    """Decide whether the ADJACENT pair (A, B) should PROPOSE a merge (scale-IN).

    INTENTIONALLY CONSERVATIVE — merge is the rarer event because
    its read-side fan-in grows. The gates, in order:
      1. FLOOR — merging removes one live partition. If the topic is at
         (or below) `min_partitions`, a merge would underflow the floor; SKIP.
         Checked FIRST so a small topic never merges away its parallelism.
      2. RECENTLY-SPLIT anti-flap — if `allow_recently_split` is
         False (the default) and EITHER A or B is itself a recent split child,
         SKIP (so a split-then-immediately-merge flap can't happen). The caller
         derives `a_recently_split`/`b_recently_split` from each range's split
         back-edge (`HashRange.parent_split_offset != NO_PARENT_BASE`).
      3. COLD — BOTH A and B must be BELOW `T_low` (sustainedly cold). If
         either is at/above the threshold, the pair is not jointly cold; SKIP.
      4. PROPOSE — both cold, above the floor, neither recently split.

    PURE — no store access. The caller owns the store calls (reading each range's
    load + recently-split flag, invoking `merge_topic_if_eligible`)."""
    # 1. Floor gate — never merge below min_partitions.
    if live_partition_count <= policy.min_partitions:
        return MergeDecision.skip_at_floor()

    # 2. Anti-flap gate — don't merge a recently-split range.
    if not policy.allow_recently_split:
        if a_recently_split or b_recently_split:
            return MergeDecision.skip_recently_split()

    # 3. Cold gate — BOTH must be below T_low.
    if (
        a_records_since_base >= policy.merge_threshold_records
        or b_records_since_base >= policy.merge_threshold_records
    ):
        return MergeDecision.skip_not_cold()

    # 4. Eligible — propose the merge.
    return MergeDecision.propose()

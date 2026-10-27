# =============================================================================
# streaming_agg_count_distinct.mojo — the per-worker state of the streaming
# COUNT(DISTINCT) aggregation
# =============================================================================
#
# PERF-CRITICAL: the parallel count(DISTINCT) of a scan -> aggregate pipeline.
# Each worker folds the morsels it claims into its own `WorkerCDState`; the
# sink (`agg_sink_count_distinct`) merges the workers' states and finalizes.
#
#   * GROUPED (one key, `consume_batch`): every row's group key resolves to a
#     group id (`gid`), and each COUNT(DISTINCT) slot appends the row's value
#     to its (agg, gid) CELL. The finalize moves the cells straight into the
#     across-groups radix driver (`cd_radix_grouped`).
#   * UNGROUPED (no key, `consume_batch_ungrouped`): values are deduped during
#     the scan into per-agg, per-value-partition hash sets; the finalize unions
#     partition p across workers independently and sums the partition sizes.
#
# The mechanisms of the grouped row loop, each with its observable counter:
#
#   * GROUP-ID RESOLUTION. When the observed key domain spans at most
#     `_CD_DENSE_GID_DOMAIN_CAP` keys, the gid is read out of a flat window
#     (`dense_idx[key - dense_lo]`, one subtract, one unsigned range test, one
#     L1 load); otherwise through `group_map`, a `Dict[Int, Int]` (measured:
#     the two Dict probes were 49% of the row loop's cycles on a 91-group
#     query). The window is discovered from the keys themselves, so every
#     source and key channel is covered. A new key gets
#     `gid = len(group_keys)` the moment it is first seen on BOTH paths, so
#     `group_keys` is identical index for index whichever path ran.
#     ONE KEY, ONE HOME: the first key the window cannot cover FREEZES it
#     (`dense_frozen`), so the in-window test is constant afterwards and no
#     key can get a second gid. The window is sized off the OCCUPIED key span
#     (`[dense_key_lo, dense_key_hi]`), never off its own length (doubling
#     its length inflates it to the cap on a descending key stream). The
#     in-window test is `UInt64(key - dense_lo) < n` on wrapping Int64: one
#     compare, total, correct for negative keys and a window across zero.
#     Witnesses: `stat_gid_dense` + `stat_gid_dict` (they partition the
#     non-NULL key rows).
#   * LAST-KEY MEMO. A key outside the window that equals the previous row's
#     key takes the previous gid with one compare instead of a Dict probe
#     (rows are clustered by key). A key's gid never changes once assigned,
#     so the memo only repeats the Dict's answer. Witness: `stat_gid_lastkey`.
#   * ADJACENT DEDUP. A value equal to its cell's LAST element is not appended
#     (a distinct count does not change when a value already present is
#     dropped; measured: 77.9% of the rows of a clustered 100M-row input).
#     Witness: `stat_adj_skipped`; `stat_appends + stat_set_inserts +
#     stat_adj_skipped` is the non-NULL value count.
#   * SCAN-TIME DEDUP OF A CELL (off by default: `cd_scan_dedup_off`). A cell
#     that has buffered `_CD_GROUPED_PROMOTE_MIN_VALUES` values (the size at
#     which its buffer equals the directory floor of the sets replacing it)
#     and whose prefix is at most 3/4 distinct is PROMOTED into
#     `_CD_VALUE_NUM_PARTITIONS` dedup-on-insert hash sets. It measured slower
#     than appending (+18.6% on a 91-group, 100M-row query: the set probes are
#     random DRAM loads), so it is kept, value-correct, behind the field.
#     Witnesses: `stat_appends` and `stat_set_inserts` (they partition the
#     appended-or-inserted values).
#   * THE FIXED-CELL PASSENGER LANE. A grouped aggregate that mixes
#     COUNT(DISTINCT) with SUM / COUNT / MIN / MAX / AVG folds those fixed
#     aggregates against the gid the CD lane already resolved, in the same row
#     iteration, so the group key is decoded and hashed once (measured: a
#     second scan was 20% of the column-chunk decodes). `consume_batch` takes
#     `comptime has_fixed`; the all-CD instantiation contains no passenger
#     code at all (one that skipped the lane at run time measured +4.32%).
#     With `fxcol_on` (the default) the lane folds column-major per batch.
#     Witnesses: `stat_batches` and `stat_fx_batches`.
#
# Each mechanism's switch is a field of `WorkerCDState`, set to the default
# at construction; the tests set the other value to compare both arms on one
# fixture.
# =============================================================================

from std.memory import alloc, UnsafePointer

from komira_arrow.schema import RecordBatch
from komira_agg_api.agg_column_ptrs import ValidityLanes
from komira_agg_api.cd_distinct_key import (
    CDK_RAW_I64,
    cd_distinct_key_channel,
    cd_distinct_keys_for_column,
)
from komira_op_agg_state.growable_hash_set_i64 import (
    GrowableHashSetI64,
)

from komira_op_agg_distinct.cd_stream_consume import _cd_consume_grouped


# Value partitions of the scan-time dedup sets: the top 3 bits of the
# Fibonacci hash, so equal values share a partition and the per-partition
# distinct counts sum to the global one.
comptime _CD_VALUE_NUM_PARTITIONS: Int = 8
comptime _CD_VALUE_PARTITION_MASK: UInt64 = 7  # _CD_VALUE_NUM_PARTITIONS - 1
comptime _CD_VALUE_PARTITION_SHIFT: UInt64 = 61  # top 3 bits of the 64-bit mix


@always_inline
def _cd_value_partition(v: Int) -> Int:
    """Map an INT64 value to its dedup partition (0.._CD_VALUE_NUM_PARTITIONS).

    Pure function of `v` — the top 3 bits of the Fibonacci multiplicative
    hash. Equal values always hash to the same partition, so per-partition
    distinct counts sum exactly to the global distinct count.
    """
    var h = UInt64(v) * UInt64(11400714819323198485)
    return Int((h >> _CD_VALUE_PARTITION_SHIFT) & _CD_VALUE_PARTITION_MASK)


@always_inline
def _cd_value_partition_i64(v: Int64) -> Int:
    """`_cd_value_partition` for an `Int64` value. It FORWARDS rather than
    re-deriving the mix: a partition function spelled twice could disagree for
    some value, and then equal values would land in different partitions and
    be counted twice. `Int(Int64)` is exact on this target."""
    return _cd_value_partition(Int(v))


# Values a (worker, agg, group) cell must buffer before it may be promoted to
# dedup-on-scan sets: at this count its buffer (16384 x 8 B = 128 KiB) is the
# size of the 8 sets' directory floor, so promotion is memory-neutral when it
# fires, and the number of sets that can exist is bounded by
# `8 * total_values / 16384` whatever the group count.
comptime _CD_GROUPED_PROMOTE_MIN_VALUES: Int = 16384

# Promotion declines (and pins the cell to appending) when the measured prefix
# is more than NUM/DEN distinct: a cell that does not repeat gains nothing
# from a set (~28 B per key against the list's 8 B per value).
comptime _CD_GROUPED_PROMOTE_MAX_DISTINCT_NUM: Int = 3
comptime _CD_GROUPED_PROMOTE_MAX_DISTINCT_DEN: Int = 4

# Per-cell storage mode. Exactly one of the two stores holds a cell's values.
comptime _CD_CELL_BUFFERING: UInt8 = 0
comptime _CD_CELL_SETS: UInt8 = 1
comptime _CD_CELL_PINNED: UInt8 = 2

# The widest key domain served by the dense window — the same 65,536 the
# hash aggregation's perfect-hash route uses. At the cap the window is
# 65,536 x 4 B = 256 KB per worker.
comptime _CD_DENSE_GID_DOMAIN_CAP: Int = 65_536

# The window's floor size. It is sized to twice the OCCUPIED key span, so a
# query with three groups allocates 16 slots; reshapes over a scan are
# O(log(domain)), at most ~12 to the cap.
comptime _CD_DENSE_GID_SEED_SLOTS: Int = 16

# The window stores `gid + 1` as `Int32` (0 = unassigned). A frozen window
# holds at most `_CD_DENSE_GID_DOMAIN_CAP` slots, so a gid written there never
# exceeds 65,537; this bound is checked on the (cold) new-group path.
comptime _CD_DENSE_GID_MAX_GID: Int = 2_000_000_000

# The ends of the key axis the window arithmetic refuses to reason about, so
# the reach test never subtracts two arbitrary Int64 keys. A key within
# 65,536 of Int64's extremes is served by the Dict.
comptime _CD_DENSE_GID_KEY_CEIL: Int64 = Int64.MAX - Int64(
    _CD_DENSE_GID_DOMAIN_CAP
)
comptime _CD_DENSE_GID_KEY_FLOOR: Int64 = Int64.MIN + Int64(
    _CD_DENSE_GID_DOMAIN_CAP
)

# The fixed lane's INPUT channel, classified ONCE per batch (never per row).
comptime FXC_NONE: UInt8 = 0     # a bare COUNT(*) — no input column at all
comptime FXC_I64: UInt8 = 1
comptime FXC_I32: UInt8 = 2
comptime FXC_F64: UInt8 = 3
comptime FXC_F32: UInt8 = 4


@fieldwise_init
struct FixedAggCell(Copyable, Movable, ImplicitlyCopyable, Deinitable):
    """One (group, fixed agg) accumulator.

    `n` is the CONTRIBUTING count — non-null input rows for
    COUNT(col)/SUM/MIN/MAX/MEAN, and every row of the group for a bare
    COUNT(*). `n == 0` is what makes SUM/MIN/MAX/MEAN emit NULL (zero
    contributing rows -> NULL), and `n == 1` marks the first contributing
    value, which seeds MIN/MAX rather than comparing against an invented
    sentinel. The same three fields as the serial mixed fold's cell, which is
    the oracle for this lane's semantics."""

    var i_acc: Int64
    var f_acc: Float64
    var n: Int64


@always_inline
def _fx_identity() -> FixedAggCell:
    return FixedAggCell(Int64(0), Float64(0.0), Int64(0))


# Per-worker count-distinct state: group mapping + per-group value buffers.
struct WorkerCDState(Copyable, Movable):
    """Per-worker count-distinct accumulator state.

    Two storage layouts, selected by aggregation arity:

    GROUPED (num_keys==1, `consume_batch`): a Dict[Int, Int] for group
    key -> group index, plus per-(agg, group) CELLS. A cell is an
    append-only `List[Int64]` (`cd_bufs`) — that is the DEFAULT and the
    shipped path.

    With `cd_scan_dedup_off = False` (off by default; it measured slower): a
    cell that has buffered `_CD_GROUPED_PROMOTE_MIN_VALUES` values AND whose
    prefix is shown to repeat is PROMOTED into `_CD_VALUE_NUM_PARTITIONS`
    dedup-on-scan `GrowableHashSetI64` sets (`cd_gsets`). `cd_gmode`
    records which store holds the cell; a cell's values are in EXACTLY ONE
    of the two at all times. See the module header.

    `cd_bufs` is `Int64` (not `Int`) so at finalize the per-(group, worker)
    buffers MOVE directly into the across-groups radix driver
    `radix_distinct_count_grouped` (`List[List[List[Int64]]]`) with NO copy
    and no serial fold into worker 0.

    UNGROUPED / SCALAR (num_keys==0, `consume_batch_ungrouped`): DEDUPS
    DURING SCAN into per-agg, per-value-partition
    `GrowableHashSetI64` sets (`cd_sets`, `[agg_slot][partition]`).
    Insert-on-scan keeps memory bounded at distinct-cardinality (not raw
    row count) and avoids the prior append-all -> bulk-extend-100M ->
    radix-dedup pipeline that lost to the serial HashSetI64. The partition
    is a pure function of the value (`_cd_value_partition`), so finalize
    unions partition-p across workers independently (8-way parallel) and
    sums the 8 union'd partition sizes — no cross-partition union.

    Copyable + Movable: all fields are themselves Copyable + Movable
    (`GrowableHashSetI64` wraps `_DenseAggDirectory` = List[POD] only), so
    the compiler synthesizes the lifecycle methods.
    """
    var group_map: Dict[Int, Int]
    var group_keys: List[Int]
    # ★ CD-KEY-NULL (2026-09-13) — THE GROUP KEY'S VALIDITY, which this state
    # had no seat for. `group_map` is keyed on the key's Int BITS, and the key
    # was read straight out of the Arrow data buffer with no validity consulted
    # — so a NULL key row was grouped by whatever word the writer left in its
    # slot (0 for every writer here). If that word is a REAL key in the column,
    # the null rows JOIN THAT GROUP and its count comes back too high under a
    # row set that looks correct. SQL says every NULL key is ONE group.
    #
    # `group_key_null[g]` is parallel to `group_keys[g]`; at most one entry is
    # True and `null_gid` is its index (-1 = no null key seen). The NULL group
    # is deliberately NOT in `group_map`: there is no Int64 that means NULL, and
    # inventing a sentinel would collide with the real key equal to it.
    var group_key_null: List[Bool]
    var null_gid: Int
    # ★ CD-DENSE-GID (2026-09-17) — THE DENSE DIRECT INDEX. See the
    # CD-DENSE-GID block above for what it replaces and why it is adaptive.
    # `dense_idx[key - dense_lo]` holds `gid + 1`; 0 means "this key has not
    # been seen". An EMPTY `dense_idx` means no key has been seen at all (the
    # window is not seeded yet), which is distinct from `dense_frozen`.
    var dense_idx: List[Int32]
    var dense_lo: Int
    # The MIN and MAX key that has actually been GIVEN a dense slot — the TRUE
    # occupied range, which is NOT the window: the window carries slack on both
    # sides so that the next key just outside the occupied range is usually
    # already covered. Growth is sized off THIS pair, never off the window's own
    # length; see `_dense_reshape` for why that distinction is the difference
    # between a window that tracks the domain and one that inflates to the cap
    # on a descending key stream. Meaningless while `dense_idx` is empty.
    var dense_key_lo: Int
    var dense_key_hi: Int
    # Set by the FIRST key that cannot be covered within
    # `_CD_DENSE_GID_DOMAIN_CAP`. Once set the window never grows again, which
    # is what makes "in window" a constant predicate for the rest of the scan
    # and therefore what gives every key exactly ONE home. See the ONE KEY, ONE
    # HOME paragraph above.
    var dense_frozen: Bool
    # False by default (the dense window serves keys it can cover). True
    # resolves every key through `group_map`: the Dict-only route, which the
    # regression test compares against on one fixture.
    var dense_gid_off: Bool
    # GROUPED: [agg_slot][group_id] -> Int64 values (moved directly into the
    # parallel across-groups radix driver at finalize; no serial fold).
    # Holds a cell's values only while that cell is BUFFERING or PINNED.
    var cd_bufs: List[List[List[Int64]]]
    # GROUPED CD-GROUPED-SCAN-DEDUP: [agg_slot][group_id][value_partition]
    # dedup-on-insert sets. The inner list is EMPTY until the cell is
    # promoted, and has exactly `_CD_VALUE_NUM_PARTITIONS` entries after.
    var cd_gsets: List[List[List[GrowableHashSetI64]]]
    # GROUPED: [agg_slot][group_id] -> one of _CD_CELL_{BUFFERING,SETS,PINNED}.
    var cd_gmode: List[List[UInt8]]
    # UNGROUPED CD-v2: [agg_slot][value_partition] -> dedup-on-insert set.
    var cd_sets: List[List[GrowableHashSetI64]]
    var num_aggs: Int
    # When True (the default) the grouped path never promotes a cell: every
    # value is appended. False arms the scan-time dedup, which measured slower
    # (+18.6% on a 91-group query); see the module header.
    var cd_scan_dedup_off: Bool
    # Structural counters (grouped path). Exact, not sampled, and they
    # PARTITION the input: `stat_appends + stat_set_inserts` is the row count
    # on either arm, which is what makes them a conservation check rather
    # than two independent readings. Counting only `stat_appends` is what let
    # this lever land as a measured regression — see the
    # "THE COUNTER MEASURED THE SIDE THAT SHRANK" block above and the
    # `[CD-BOTH-SIDES]` readout in `agg_sink_count_distinct.mojo`.
    # `stat_appends` reading ~= the row count while `stat_set_inserts` reads
    # 0 is the signature of the lever not applying — see
    # `tests/engine/test_cd_grouped_scan_dedup.mojo`, which is built around
    # the fact that the two arms produce IDENTICAL output and differ ONLY
    # here.
    var stat_appends: Int
    var stat_set_inserts: Int
    # ★ CD-DENSE-GID structural counters. Same contract as the pair above:
    # they PARTITION the NON-NULL key rows — `stat_gid_dense + stat_gid_dict`
    # is the count of rows whose key was not NULL — so they are a conservation
    # check rather than two independent readings, and `stat_gid_dense` reading
    # 0 while `stat_gid_dict` reads ~the row count is the exact signature of
    # the dense route not applying. That signature is what
    # `test_cd_dense_gid_direct_index.mojo` asserts; without it a byte-equal
    # result proves only that the two arms agree, not that the fast one ran.
    var stat_gid_dense: Int
    var stat_gid_dict: Int
    # ⭐ CD-ADJDEDUP — the gate (read once, at construction) and its exact
    # structural counter: values NOT appended because they equalled their
    # cell's tail. See the CD-ADJDEDUP block above `FixedAggCell`.
    var adj_dedup_on: Bool
    var stat_adj_skipped: Int
    # ⭐ CD-LASTKEY — the gate (read once, at construction) and its witness:
    # out-of-window rows whose gid came from the one-entry memo instead of a
    # `group_map` probe. Also counted in `stat_gid_dict` (see the row loop).
    var lastkey_on: Bool
    var stat_gid_lastkey: Int
    # ⭐⭐ MIXEDFUSE (2026-09-21) — THE FIXED-CELL PASSENGER LANE. See the
    # MIXEDFUSE block above this struct. `fx_func[f]` is the plan's `AGG_*`
    # tag, `fx_is_int[f]` selects the Int64 accumulator over the Float64 one,
    # and `fx_cells[f][gid]` is the (fixed agg, group) accumulator — indexed by
    # the SAME gid the CD lane resolved, which is the whole point.
    #
    # ⚠ EMPTY ON EVERY ALL-COUNT(DISTINCT) QUERY — and that alone did NOT make
    # the lane free (see the MIXEDFUSE header: +4.32% on an all-COUNT(DISTINCT) query). What makes it free
    # is that the all-CD route runs the `has_fixed=False` instantiation, which
    # never names these fields at all.
    var fx_func: List[UInt8]
    var fx_is_int: List[Bool]
    var fx_cells: List[List[FixedAggCell]]
    var num_fixed: Int
    # ★ MIXEDFUSE-ALLCD route counters, one add per BATCH (never per row).
    # `stat_batches` counts every non-empty grouped `consume_batch`;
    # `stat_fx_batches` counts the ones that ran the passenger-lane setup. On
    # an all-COUNT(DISTINCT) query the second MUST read 0 — the finalize folds
    # both into `cd_passenger_lane_counter` once per worker, which is what the
    # regression test reads. See that module's header for why no value
    # assertion can witness this.
    var stat_batches: Int
    var stat_fx_batches: Int
    # The passenger lane's fold shape: column-major per batch (True, the
    # default; `_fx_fold_batch`) or per row inside the CD row loop (False).
    # Both fold every cell's rows in ascending row order, so the answers are
    # identical.
    var fxcol_on: Bool

    def __init__(out self, num_aggs: Int):
        self.group_map = Dict[Int, Int]()
        self.group_keys = List[Int]()
        self.group_key_null = List[Bool]()
        self.null_gid = -1
        # CD-DENSE-GID: the window is seeded by the first key, not here — a
        # state that never sees a row allocates nothing.
        self.dense_idx = List[Int32]()
        self.dense_lo = 0
        self.dense_key_lo = 0
        self.dense_key_hi = 0
        self.dense_frozen = False
        self.dense_gid_off = False
        self.cd_bufs = List[List[List[Int64]]]()
        self.cd_gsets = List[List[List[GrowableHashSetI64]]]()
        self.cd_gmode = List[List[UInt8]]()
        self.cd_sets = List[List[GrowableHashSetI64]]()
        self.num_aggs = num_aggs
        self.cd_scan_dedup_off = True
        self.stat_appends = 0
        self.stat_set_inserts = 0
        self.stat_gid_dense = 0
        self.stat_gid_dict = 0
        self.adj_dedup_on = True
        self.stat_adj_skipped = 0
        self.lastkey_on = True
        self.stat_gid_lastkey = 0
        # MIXEDFUSE: no passenger until `configure_fixed` says otherwise.
        self.fx_func = List[UInt8]()
        self.fx_is_int = List[Bool]()
        self.fx_cells = List[List[FixedAggCell]]()
        self.num_fixed = 0
        self.stat_batches = 0
        self.stat_fx_batches = 0
        self.fxcol_on = True
        for _ in range(num_aggs):
            self.cd_bufs.append(List[List[Int64]]())
            self.cd_gsets.append(List[List[GrowableHashSetI64]]())
            self.cd_gmode.append(List[UInt8]())
            self.cd_sets.append(List[GrowableHashSetI64]())

    @always_inline
    def group_is_null(self, g: Int) -> Bool:
        """True iff group `g` is THE NULL-KEY group (CD-KEY-NULL, 2026-09-13).

        Defensive on length on purpose: the UNGROUPED finalize path registers a
        sentinel group directly in `group_keys` without a validity entry, and
        that path never asks this question. A bare index would turn a benign
        asymmetry into a crash in the 0-key arm.
        """
        if g < 0 or g >= len(self.group_key_null):
            return False
        return self.group_key_null[g]

    @always_inline
    def _append_group[
        has_fixed: Bool
    ](mut self, key: Int, is_null: Bool) raises -> Int:
        """Register a brand-new group and return its id.

        ★ FOUR ARRAYS ARE INDEXED BY `gid` AND MUST GROW IN LOCKSTEP:
        `group_keys`, `group_key_null`, and `cd_bufs[a]` / `cd_gsets[a]` /
        `cd_gmode[a]` for every agg slot. A new group that extends only some of
        them desynchronises the cell index space and mis-attributes values to
        the wrong group. This method is the ONE place that growth happens, so
        the lockstep is structural rather than repeated at three call sites.

        `gid = len(self.group_keys)` — FIRST-SEEN ORDER, and it is the whole
        byte-equivalence argument: the dense route and the Dict route call this
        at exactly the same rows, so they hand out exactly the same ids.

        For the NULL-key group (`is_null`) `key` is a PLACEHOLDER that is never
        read back as a key; `group_key_null` is what finalize reads.
        """
        var gid = len(self.group_keys)
        self.group_keys.append(key)
        self.group_key_null.append(is_null)
        for a in range(self.num_aggs):
            self.cd_bufs[a].append(List[Int64]())
            self.cd_gsets[a].append(List[GrowableHashSetI64]())
            self.cd_gmode[a].append(_CD_CELL_BUFFERING)
        # ⭐ MIXEDFUSE — the FIFTH array in the lockstep. `fx_cells[f]` is
        # indexed by the SAME gid as `cd_bufs[a]`, so it has to grow at the SAME
        # call, in the same method, for the same reason the four above do: a new
        # group that extends only some of them mis-attributes values to the
        # wrong group. Compiled OUT of the all-CD (`has_fixed=False`)
        # instantiation, whose caller has already refused an ARMED state — so
        # `fx_cells` is empty there and there is nothing to keep in lockstep.
        comptime if has_fixed:
            for f in range(self.num_fixed):
                self.fx_cells[f].append(_fx_identity())
        return gid

    def configure_fixed(
        mut self, imm funcs: List[UInt8], imm is_int: List[Bool]
    ) raises:
        """⭐ MIXEDFUSE — arm the fixed-cell passenger lane.

        Called ONCE, at Local construction, BEFORE any row is consumed. Arming
        it after rows have been consumed would leave `fx_cells[f]` shorter than
        `group_keys`, so it REFUSES rather than silently producing a cell space
        that does not cover every group."""
        if len(self.group_keys) != 0:
            raise Error(
                "WorkerCDState.configure_fixed: the fixed-cell lane must be"
                " armed before the first row is consumed (groups already"
                " exist, so their cells could never be created)."
            )
        if len(funcs) != len(is_int):
            raise Error(
                "WorkerCDState.configure_fixed: func and int-family lists"
                " disagree on length."
            )
        self.fx_func = List[UInt8]()
        self.fx_is_int = List[Bool]()
        self.fx_cells = List[List[FixedAggCell]]()
        for f in range(len(funcs)):
            self.fx_func.append(funcs[f])
            self.fx_is_int.append(is_int[f])
            self.fx_cells.append(List[FixedAggCell]())
        self.num_fixed = len(funcs)

    @no_inline
    def _gid_for_key_slow[has_fixed: Bool](mut self, key: Int) raises -> Int:
        """Resolve a key the dense window does not cover — CD-DENSE-GID's cold
        arm. Reshapes the window when the key can still be covered within
        `_CD_DENSE_GID_DOMAIN_CAP`; otherwise FREEZES the window and resolves
        through `group_map`.

        ⚠ THE FREEZE IS NOT AN OPTIMISATION, IT IS THE ONE-KEY-ONE-HOME
        INVARIANT. A window that grew after a key had already been routed to
        `group_map` could later cover that key, giving it a second home and
        splitting its values across two output rows. See the CD-DENSE-GID block.

        ⚠⚠ `dense_gid_off` IS CHECKED HERE AND NOWHERE ELSE, AND THIS IS THE
        SITE THAT MAKES THE DICT-ONLY ARM REAL. With `dense_gid_off` every
        row arrives through this method; refusing to seed the window here is
        what keeps `dense_idx` EMPTY, which is in turn what makes the hot loop's
        own `du < len(dense_idx)` False for every row without the hot loop ever
        naming the lever. Seed from here and the "off" arm allocates, stops
        being the byte-for-byte pre-change route the regression test uses as its
        oracle.

        ⭐ `@no_inline`. The row loop reaches this
        method only on a cache MISS of the one-entry last-key memo (see the
        CD-LASTKEY block above `FixedAggCell`), so it is off the per-row path on
        clustered keys. Pinning it out of line is deliberate: on trunk LLVM
        happened to inline all of it into the all-CD row loop, a later loop
        change tipped that to a per-row CALL (+8.0% on a query whose frozen
        window sends ~every row here), and forcing the Dict arm back INLINE
        cost the dense-window queries +3.5% to +19.8%. The memo, not the
        inliner, is what takes the Dict off the row path.
        """
        if not self.dense_frozen and not self.dense_gid_off:
            if len(self.dense_idx) == 0:
                # SEED. The occupied range is this one key.
                if self._dense_reshape(key, key):
                    self.dense_key_lo = key
                    self.dense_key_hi = key
                    return self._dense_assign_at_key[has_fixed](key)
            else:
                var t_lo = self.dense_key_lo
                var t_hi = self.dense_key_hi
                if key < t_lo:
                    t_lo = key
                if key > t_hi:
                    t_hi = key
                if self._dense_reshape(t_lo, t_hi):
                    self.dense_key_lo = t_lo
                    self.dense_key_hi = t_hi
                    return self._dense_assign_at_key[has_fixed](key)
            # Out of reach: the OCCUPIED domain would be wider than the cap (or
            # it sits where the window arithmetic refuses to reason). FREEZE.
            self.dense_frozen = True

        # The Dict arm — the pre-CD-DENSE-GID resolution, unchanged, and the
        # only arm when `dense_gid_off` is set.
        self.stat_gid_dict += 1
        if key in self.group_map:
            return self.group_map[key]
        var gid = self._append_group[has_fixed](key, False)
        self.group_map[key] = gid
        return gid

    def _dense_reshape(mut self, t_lo: Int, t_hi: Int) raises -> Bool:
        """Rebuild the window so it covers the OCCUPIED range `[t_lo, t_hi]`
        with slack on both sides. `False` means the range is out of reach and
        the caller must freeze; the window is then left untouched.

        ★★ THE SIZE IS TAKEN FROM THE OCCUPIED RANGE, NOT FROM THE WINDOW'S OWN
        LENGTH, AND THAT IS THE WHOLE DESIGN. Doubling the WINDOW is the obvious
        policy and it is wrong: growing downward by one key would double a
        length whose slack all sits ABOVE, so a strictly descending stream of 50
        keys inflates the window to the 65_536 cap in twelve steps and then
        FREEZES — the domain is 50 wide and the map gives up. That is not a
        thought experiment; it is what `test_all_negative_keys` measured before
        this method existed (156 of 600 rows dense, the rest on the Dict).
        Sizing off the occupied span keeps `len(dense_idx) <= 2 * span`, so the
        window freezes when — and only when — the real domain exceeds the cap.

        ★ UNASSIGNED SLOTS ARE DROPPED, NOT COPIED. A slot holding 0 carries no
        information, so the rebuild re-homes each ASSIGNED slot BY ITS KEY and
        lets the window move in either direction. That is what lets the slack be
        re-centred on every growth instead of accumulating on one side.

        ⚠ NO SUBTRACTION OF TWO ARBITRARY KEYS ANYWHERE IN THE REACH TEST — see
        `_CD_DENSE_GID_KEY_CEIL`.
        """
        if Int64(t_lo) > _CD_DENSE_GID_KEY_CEIL:
            return False
        if Int64(t_hi) > Int64(t_lo) + Int64(_CD_DENSE_GID_DOMAIN_CAP - 1):
            return False
        var span = Int(Int64(t_hi) - Int64(t_lo)) + 1

        var target = span * 2
        if target < _CD_DENSE_GID_SEED_SLOTS:
            target = _CD_DENSE_GID_SEED_SLOTS
        if target > _CD_DENSE_GID_DOMAIN_CAP:
            target = _CD_DENSE_GID_DOMAIN_CAP
        var slack = target - span

        # Half the slack goes BELOW the occupied range and the remainder above,
        # so a descending stream and an ascending one are served equally well.
        # `target - span - below >= slack - slack // 2 >= 0` keeps `t_hi` inside
        # the window even when `target` was clamped to the cap.
        var below = slack // 2
        if Int64(t_lo) < _CD_DENSE_GID_KEY_FLOOR:
            below = 0
        var new_lo = Int(Int64(t_lo) - Int64(below))

        var fresh = List[Int32](length=target, fill=Int32(0))
        var n = len(self.dense_idx)
        for i in range(n):
            var v = self.dense_idx[i]
            if v != Int32(0):
                # Every ASSIGNED key lies in [t_lo, t_hi] by construction, and
                # the window covers that range, so this index is in bounds.
                var k = Int64(self.dense_lo) + Int64(i)
                fresh[Int(k - Int64(new_lo))] = v
        self.dense_idx = fresh^
        self.dense_lo = new_lo
        return True

    @always_inline
    def _dense_assign_at_key[has_fixed: Bool](mut self, key: Int) raises -> Int:
        """`_dense_assign` for a key already proven to be inside the window."""
        var du = (Int64(key) - Int64(self.dense_lo)).cast[DType.uint64]()
        return self._dense_assign[has_fixed](Int(du), key)

    @always_inline
    def _dense_assign[
        has_fixed: Bool
    ](mut self, slot: Int, key: Int) raises -> Int:
        """Give `key` a fresh gid and record it in dense slot `slot`.

        The `_CD_DENSE_GID_MAX_GID` guard can only fire if the freeze invariant
        above is ever broken — before the freeze the only groups that exist come
        from this method (at most `_CD_DENSE_GID_DOMAIN_CAP` of them) and from
        the single NULL group, so it is unreachable today. It is here so that
        argument is enforced rather than merely written down: rather than
        truncate a gid into `Int32`, or hand the same in-window key a second
        gid, it raises.
        """
        var gid = self._append_group[has_fixed](key, False)
        if gid >= _CD_DENSE_GID_MAX_GID:
            raise Error(
                "WorkerCDState: the dense group id space is exhausted; the"
                " freeze invariant was broken."
            )
        self.dense_idx[slot] = Int32(gid + 1)
        # Widen the OCCUPIED range. A key first seen through the HOT path is
        # inside the window but can still be outside `[key_lo, key_hi]`, and the
        # next reshape sizes itself off this pair.
        if key < self.dense_key_lo:
            self.dense_key_lo = key
        if key > self.dense_key_hi:
            self.dense_key_hi = key
        self.stat_gid_dense += 1
        return gid

    def consume_batch(
        mut self,
        batch: RecordBatch,
        key_col_idx: Int,
        val_col_indices: List[Int],
    ) raises:
        """Consume a morsel batch into the worker's cd state — the ALL-CD
        arity, i.e. no MIXEDFUSE passenger lane.

        ⭐ Instantiates `has_fixed=False`: the passenger lane is compiled OUT,
        not skipped. The first MIXEDFUSE landing forwarded an EMPTY fixed list
        into the fused body instead and cost +4.32% on an all-COUNT(DISTINCT) query (see the MIXEDFUSE
        header). An ARMED state (`num_fixed > 0`) is REFUSED rather than fed
        through an instantiation that cannot fold its fixed cells."""
        var no_fixed = List[Int]()
        self.consume_batch[has_fixed=False](
            batch, key_col_idx, val_col_indices, no_fixed
        )

    def consume_batch[
        has_fixed: Bool
    ](
        mut self,
        batch: RecordBatch,
        key_col_idx: Int,
        val_col_indices: List[Int],
        imm fx_col_indices: List[Int],
    ) raises:
        """Consume a morsel batch into the worker's cd state.

        Single INT64 key path — the key column is read as INT64 and used
        directly as the Dict key. Each COUNT_DISTINCT agg slot appends
        its value to the group's buffer.

        ⭐ MIXEDFUSE — `fx_col_indices[f]` is the batch column index feeding
        fixed slot `f` (`-1` for a bare COUNT(*)). The fixed cells fold against
        the SAME `gid` the CD lane just resolved, in the SAME row iteration:
        that is the entire mechanism, and it is why the group key is decoded and
        hashed ONCE for a mixed aggregate instead of twice.

        ⭐ `has_fixed` SELECTS THE INSTANTIATION, and the caller picks it from
        whether any fixed slot exists (`CountDistinctAggSink.consume`). With
        `has_fixed=False` the per-batch passenger setup, the per-row passenger
        fold and `_append_group`'s fixed-cell growth are all compiled OUT, and
        `fx_col_indices` is not read. `has_fixed=False` on an ARMED state
        raises; `has_fixed=True` requires `fx_col_indices` to cover every armed
        slot, exactly as before.
        """
        _cd_consume_grouped[has_fixed](
            self, batch, key_col_idx, val_col_indices, fx_col_indices
        )

    def _promote_cell(mut self, a: Int, gid: Int) raises:
        """Try to convert cell (agg `a`, group `gid`) from append to
        dedup-on-scan. Called once, when the cell's buffer first reaches
        `_CD_GROUPED_PROMOTE_MIN_VALUES`.

        VALUE-PRESERVING IN BOTH OUTCOMES. The buffered prefix is inserted
        into the fresh partition sets FIRST and the buffer is released ONLY on
        the commit branch, so a cell's values live in exactly one of the two
        stores at every point — never zero, never both. On decline the sets
        are dropped and the buffer is untouched.

        The decline branch pins the cell (`_CD_CELL_PINNED`) so the measurement
        is not repeated every subsequent value: without it, a cell that is 100%
        distinct would rebuild and discard 8 hash sets on every single row past
        the threshold.
        """
        if self.cd_scan_dedup_off:
            self.cd_gmode[a][gid] = _CD_CELL_PINNED
            return

        var n = len(self.cd_bufs[a][gid])
        var sets = List[GrowableHashSetI64](
            capacity=_CD_VALUE_NUM_PARTITIONS
        )
        for _ in range(_CD_VALUE_NUM_PARTITIONS):
            sets.append(GrowableHashSetI64())

        var distinct = 0
        for i in range(n):
            var v = self.cd_bufs[a][gid][i]
            if sets[_cd_value_partition_i64(v)].insert(v):
                distinct += 1

        # DUPLICATION GATE — decline when the prefix barely repeats.
        # Integer form of `distinct / n > NUM / DEN`; no float, no division.
        if (
            distinct * _CD_GROUPED_PROMOTE_MAX_DISTINCT_DEN
            > n * _CD_GROUPED_PROMOTE_MAX_DISTINCT_NUM
        ):
            self.cd_gmode[a][gid] = _CD_CELL_PINNED
            _ = sets^
            return

        # COMMIT. The prefix is now held by `sets`; release the buffer by
        # swapping in a fresh empty List (a `clear()` would keep the 128 KiB
        # capacity alive, which is the memory this promotion exists to reclaim).
        swap(self.cd_gsets[a][gid], sets)
        _ = sets^
        var released = List[Int64]()
        swap(self.cd_bufs[a][gid], released)
        _ = released^
        self.cd_gmode[a][gid] = _CD_CELL_SETS

    def consume_batch_ungrouped(
        mut self,
        batch: RecordBatch,
        val_col_indices: List[Int],
    ) raises:
        """Consume a morsel batch into the worker's cd state, ungrouped (CB-04).

        DEDUP-ON-INSERT into per-value-partition
        `GrowableHashSetI64` sets. For each value we compute its partition
        (`_cd_value_partition`, a pure function of the value) and insert it
        into `cd_sets[a][p]`. No raw value is ever appended to an unbounded
        buffer — memory is bounded at distinct-cardinality and the heavy
        100M-value bulk-extend + radix-dedup of CD-v1 is eliminated.

        Per-partition sets keep the per-set directory small enough to stay
        cache-resident (distinct/8 entries) AND let finalize union each
        partition across workers independently (8-way parallel), since equal
        values always land in the same partition.
        """
        var num_rows = batch.num_rows()
        if num_rows == 0:
            return

        # Lazily create the per-agg partition sets on first non-empty batch.
        # group_keys stays as the [0] sentinel so the finalize/grouped paths
        # can detect "this worker saw data" uniformly.
        if len(self.group_keys) == 0:
            self.group_keys.append(0)
            self.group_map[0] = 0
            for a in range(self.num_aggs):
                for _ in range(_CD_VALUE_NUM_PARTITIONS):
                    self.cd_sets[a].append(GrowableHashSetI64())

        # Pre-extract value column pointers.
        # Parent-origin anchoring: value pointers borrow from `batch`.
        comptime bo = origin_of(batch)
        var val_ptrs = List[UnsafePointer[Scalar[DType.int64], bo]]()
        var val_offs = List[Int]()
        for a in range(self.num_aggs):
            var vi = val_col_indices[a]
            ref vp = batch.column_at(vi)
            # Two-step cast: origin_of(vp._data) is a sub-origin of `bo` (vp
            # lives inside batch); the widening tail
            # `unsafe_mut_cast[bo.mut]().unsafe_origin_cast[bo]()` is what lets
            # the pointer be stored in a `List[UnsafePointer[..., bo]]`.
            # SAFETY: vp._data is owned by batch; pointer outlives this scope.
            val_ptrs.append(
                vp._data.view_ro()
                    ._unsafe_ptr()
                    .bitcast[Scalar[DType.int64]]()
                    .unsafe_mut_cast[bo.mut]()
                    .unsafe_origin_cast[bo]()
            )
            val_offs.append(vp._offset)

        # ★ THE VALIDITY CHANNEL.
        # THIS is the arm a plain `SELECT count(DISTINCT c) FROM t` reaches
        # (`CountDistinctAggSink.consume` delegates here at `num_keys == 0`),
        # so this is where the shipped wrong answer came from: 4 where DuckDB
        # v1.5.3 says 3 over `[10, 30, NULL, NULL, 7]`. See the grouped
        # sibling above for the full rationale.
        var vlanes = ValidityLanes[bo].from_batch_columns(
            batch, val_col_indices
        )

        # ★ CD-TYPE-WIDTH (2026-09-11) — THE NARROW-WIDTH CHANNEL.
        #
        # The `val_ptrs` block above bitcasts EVERY value column to
        # `Scalar[DType.int64]` and indexes it at the row number. That is an
        # 8-BYTE STRIDE, and it is correct ONLY for a column whose storage IS
        # int64. MEASURED over 15 rows holding exactly 3 distinct values:
        # int32 answered 11, int16 10, float32 7, date32 7, string 9,
        # dictionary 7 — SILENT WRONG COUNTS, because an int32 column read at
        # stride 8 pairs adjacent elements into one arbitrary 64-bit word and a
        # string column yields its OFFSETS.
        #
        # So each lane is classified ONCE per batch and a lane that is not
        # int64-storage gets its per-row Int64 DISTINCT KEY materialised at its
        # OWN width (`cd_distinct_keys_for_column`, offset-aware). The
        # `CDK_RAW_I64` lane keeps the pointer read byte for byte — all-int64
        # aggregands must not pay for this.
        #
        # An UNSUPPORTED type never reaches here: `cd_value_type_supported`
        # gates both detectors that build this sink's `AggSinkData`. If one ever
        # regresses, `cd_distinct_keys_for_column` RAISES naming the type rather
        # than counting something arbitrary.
        var val_chans = List[UInt8]()
        var val_keys = List[List[Int64]]()
        var any_narrow = False
        for a in range(self.num_aggs):
            var ch = cd_distinct_key_channel(
                batch.column_arrow_type(val_col_indices[a])
            )
            val_chans.append(ch)
            if ch == CDK_RAW_I64:
                val_keys.append(List[Int64]())
            else:
                any_narrow = True
                val_keys.append(
                    cd_distinct_keys_for_column(batch, val_col_indices[a])
                )

        # Single-agg fast path: one COUNT_DISTINCT (the overwhelming majority
        # of CB-04). Tight inner loop: load value -> partition -> insert.
        if self.num_aggs == 1 and val_chans[0] == CDK_RAW_I64:
            ref sets0 = self.cd_sets[0]
            var ptr0 = val_ptrs[0]
            var off0 = val_offs[0]
            # HOISTED so a NON-NULLABLE input (no validity bitmap at all —
            # every CB-04 fixture) pays one register-resident, perfectly
            # predicted branch per row rather than a bitmap read.
            var nullable0 = vlanes.lane_is_nullable(0)
            for row in range(num_rows):
                if nullable0 and vlanes.is_null_at(0, row):
                    continue
                var v = Int((ptr0 + off0 + row)[])
                _ = sets0[_cd_value_partition(v)].insert(Int64(v))
        elif self.num_aggs == 1:
            # The single-agg NARROW lane: same loop shape, key read from the
            # pre-materialised list instead of the mis-strided pointer.
            ref sets0 = self.cd_sets[0]
            ref keys0 = val_keys[0]
            var nullable0 = vlanes.lane_is_nullable(0)
            for row in range(num_rows):
                if nullable0 and vlanes.is_null_at(0, row):
                    continue
                var v = Int(keys0[row])
                _ = sets0[_cd_value_partition(v)].insert(Int64(v))
        elif not any_narrow:
            for row in range(num_rows):
                for a in range(self.num_aggs):
                    if vlanes.is_null_at(a, row):
                        continue
                    var v = Int((val_ptrs[a] + val_offs[a] + row)[])
                    _ = self.cd_sets[a][_cd_value_partition(v)].insert(
                        Int64(v)
                    )
        else:
            for row in range(num_rows):
                for a in range(self.num_aggs):
                    if vlanes.is_null_at(a, row):
                        continue
                    var v: Int
                    if val_chans[a] == CDK_RAW_I64:
                        v = Int((val_ptrs[a] + val_offs[a] + row)[])
                    else:
                        v = Int(val_keys[a][row])
                    _ = self.cd_sets[a][_cd_value_partition(v)].insert(
                        Int64(v)
                    )

        _ = batch  # keepalive

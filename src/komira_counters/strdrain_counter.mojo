# =============================================================================
# strdrain_counter — the REACH count for the `List[String]` staging drain class
# =============================================================================
#
# WHY THIS EXISTS. Columnar drain sites of the shape
# `Column.from_string(StringArray.from_strings(staging))` pay two heap
# allocations per VALUE plus three full byte passes. How much of a query that
# class costs is a claim about RUN TIME, and a grep of the call sites cannot
# answer it: a site that exists is not a site that runs. These counters
# measure which sites a query actually reaches, and with how many values.
#
# WHAT IS OBSERVED, and why each counter cannot be faked by a lever that
# stopped applying:
#
#   PROCESS-WIDE, recorded INSIDE `StringArray.from_strings` and
#   `StringArray.from_strings_with_validity` — the TWO functions every drain
#   site in the class must route through:
#     * `strdrain_calls`   — drain calls. The denominator. A cell that reads 0
#                        here reaches NO site in the class, and no per-site
#                        counter can contradict that.
#     * `strdrain_values`  — values staged, summed. This is an UPPER BOUND on
#                        the whole class for the cell: no single site can
#                        exceed the process-wide total, so a small number here
#                        prices every site at once without instrumenting
#                        each one. That is the whole design.
#     * `strdrain_bytes`   — value bytes staged, summed. Pairs with `values` to
#                        separate "many tiny strings" (allocation-bound) from
#                        "few large strings" (bandwidth-bound) — the two
#                        regimes have different levers and the residency rule
#                        only governs the second.
#
#   AT THE CONVERTED SITE (`agg_dict._execute_dict_perfect_hash_agg`'s key
#   emit) — a PAIR plus a DENOMINATOR, so a zero is never
#   ambiguous between "the arm declined" and "nobody looked":
#     * `strdrain_aggdict_calls`          — key columns emitted by that loop,
#                        counted BEFORE the arm branch. NONZERO IS THE PROOF OF
#                        REACH. Zero means the site was never entered, in which
#                        case BOTH arm counters are zero for a reason that has
#                        nothing to do with the arm choice.
#     * `strdrain_aggdict_stage_values`   — values drained through the incumbent
#                        `List[String]` staging arm.
#     * `strdrain_aggdict_builder_values` — values drained through the
#                        `ArrowStringBuilder` arm.
#   The two arm counters are mutually exclusive by construction and must sum to
#   the site's value total. `calls > 0 and stage == 0 and builder == 0` is
#   IMPOSSIBLE and would indict the instrument, not the lever.
#
# COST. Three relaxed `fetch_add`s per DRAIN CALL — per column per batch, never
# per value and never per row. The call they sit in front of already allocates
# two Arrow buffers and memcpys every value. The hook is UNCONDITIONAL, so it
# taxes both drain arms identically; a count that only runs in one arm cannot
# compare the arms.
#
# Same `GlobalCounter` primitive (`global_counter.mojo`) as
# `planner_scale_counter.mojo` and `join_index_window_counter.mojo` -- no
# environment read, no `unsafe_from_address` laundering, no wildcard-origin
# field.
# =============================================================================

from komira_counters.global_counter import GlobalCounter


comptime _SD_CALLS = GlobalCounter["komira_counters_strdrain_calls"]
comptime _SD_VALUES = GlobalCounter["komira_counters_strdrain_values"]
comptime _SD_BYTES = GlobalCounter["komira_counters_strdrain_bytes"]
comptime _SD_AGGDICT_CALLS = GlobalCounter[
    "komira_counters_strdrain_aggdict_calls"
]
comptime _SD_AGGDICT_STAGE_VALUES = GlobalCounter[
    "komira_counters_strdrain_aggdict_stage_values"
]
comptime _SD_AGGDICT_BUILDER_VALUES = GlobalCounter[
    "komira_counters_strdrain_aggdict_builder_values"
]


# -----------------------------------------------------------------------------
# The 8-slot SITE ATTRIBUTION table
# -----------------------------------------------------------------------------
#
# The process-wide `strdrain_values` is an UPPER BOUND on every site at once,
# which is enough to REFUTE the class on a cell but not enough to direct a
# conversion if the bound turns out to be large. These eight slots partition
# the class by FAMILY so one binary answers both questions. A site not named in
# any slot still lands in the process-wide total, so the slots can only
# under-attribute, never over-attribute: `sum(slots) <= strdrain_values` is an
# invariant the printed line can be checked against.
comptime SD_SITE_AGG_DICT = 0
"""`agg_dict` — dict-perfect-hash + dict-agg-sink key emit."""
comptime SD_SITE_SORT_BUFFER = 1
"""`sort_buffer` — SORT/TOPN key + payload string emit. PER OUTPUT ROW."""
comptime SD_SITE_UNTYPED_HASH_AGG = 2
"""hash_agg_untyped / radix_hash_agg_untyped string key drain. PER GROUP."""
comptime SD_SITE_CAST_VARCHAR = 3
"""cast_to_varchar + cast_to_varchar_kernels. PER ROW."""
comptime SD_SITE_JOIN_PAYLOAD = 4
"""join_probe_borrowed_state string payload gather. PER OUTPUT ROW."""
comptime SD_SITE_PARTITION_EVAL = 5
"""partition_value_fns: LAG / LEAD with a STRING default. PER ROW. (The
no-default value functions are a byte gather and stage no `String`.)"""
comptime SD_SITE_COUNT_DISTINCT = 6
"""agg_count_distinct{,_parallel} + cd_grouped_fold + agg_mixed_cd_fold."""
comptime SD_SITE_OTHER = 7
"""distinct_*, part_key_block, partition_topn_hash_state, columnar_acc_utf8,
columnar_agg_sink_combine, streaming_agg_dict_build, agg_struct,
parquet_helpers — the remainder of the class."""

# -----------------------------------------------------------------------------
# The 4-cell OWNER table — one level BELOW a site family
# -----------------------------------------------------------------------------
#
# WHY A SECOND AXIS. Two of the eight site families are shared by more than one
# FUNCTION, and a family total cannot say which of them ran:
#
#   * `SD_SITE_UNTYPED_HASH_AGG` (s2) is emitted by BOTH
#     `hash_agg_untyped.drain_hash_agg_untyped_to_record_batch` and
#     `radix_hash_agg_untyped.drain_radix_hash_agg_untyped_to_record_batch`.
#   * `SD_SITE_COUNT_DISTINCT` (s6) is emitted by BOTH
#     `agg_count_distinct._execute_count_distinct_agg` (serial) and
#     `agg_count_distinct_parallel._execute_count_distinct_agg_parallel`.
#
# In each pair the two arms are ROUTE-selected at run time
# (`_should_use_parallel_count_distinct`, and the radix/non-radix planner
# choice), so which one owns a cell's values is EXACTLY the question a static
# read cannot answer. One `fetch_add` per drain CALL settles it.
#
# ⚠ THE OWNER TABLE IS CHECKABLE AGAINST THE FAMILY TABLE, which is why it
# cannot silently drift: every owner cell is incremented on the SAME line as
# its family slot, so
#
#     owner(0) + owner(1) == site(2)      and      owner(2) + owner(3) == site(6)
#
# hold exactly. A printed line violating either indicts the instrument.
comptime SD_OWNER_HASH_AGG_UNTYPED = 0
"""hash_agg_untyped.drain_hash_agg_untyped_to_record_batch (family s2)."""
comptime SD_OWNER_RADIX_HASH_AGG_UNTYPED = 1
"""radix_hash_agg_untyped.drain_radix_hash_agg_untyped_to_record_batch (s2)."""
comptime SD_OWNER_CD_SERIAL = 2
"""agg_count_distinct._execute_count_distinct_agg key emit (family s6)."""
comptime SD_OWNER_CD_PARALLEL = 3
"""agg_count_distinct_parallel._execute_count_distinct_agg_parallel (s6)."""

comptime _SD_OWNER_0 = GlobalCounter["komira_counters_strdrain_owner0"]
comptime _SD_OWNER_1 = GlobalCounter["komira_counters_strdrain_owner1"]
comptime _SD_OWNER_2 = GlobalCounter["komira_counters_strdrain_owner2"]
comptime _SD_OWNER_3 = GlobalCounter["komira_counters_strdrain_owner3"]


@always_inline
def strdrain_note_owner(owner: Int, n_values: Int) raises:
    """Attribute `n_values` staged values to one of the four contested-family
    OWNER functions. Called on the same line as `strdrain_note_site`, so the
    owner pair always sums to its family slot."""
    if n_values == 0:
        return
    if owner == 0:
        _SD_OWNER_0.add(n_values)
    elif owner == 1:
        _SD_OWNER_1.add(n_values)
    elif owner == 2:
        _SD_OWNER_2.add(n_values)
    else:
        _SD_OWNER_3.add(n_values)


def strdrain_owner_values(owner: Int) raises -> Int:
    """Values attributed to owner function `owner` since the last reset."""
    if owner == 0:
        return _SD_OWNER_0.read()
    elif owner == 1:
        return _SD_OWNER_1.read()
    elif owner == 2:
        return _SD_OWNER_2.read()
    return _SD_OWNER_3.read()


comptime _SD_SITE_0 = GlobalCounter["komira_counters_strdrain_site0"]
comptime _SD_SITE_1 = GlobalCounter["komira_counters_strdrain_site1"]
comptime _SD_SITE_2 = GlobalCounter["komira_counters_strdrain_site2"]
comptime _SD_SITE_3 = GlobalCounter["komira_counters_strdrain_site3"]
comptime _SD_SITE_4 = GlobalCounter["komira_counters_strdrain_site4"]
comptime _SD_SITE_5 = GlobalCounter["komira_counters_strdrain_site5"]
comptime _SD_SITE_6 = GlobalCounter["komira_counters_strdrain_site6"]
comptime _SD_SITE_7 = GlobalCounter["komira_counters_strdrain_site7"]


@always_inline
def strdrain_note_site(site: Int, n_values: Int) raises:
    """Attribute `n_values` staged values to one of the eight site FAMILIES.

    Called at the drain SITE (which knows who it is), unlike
    `strdrain_note_from_strings`, which is called inside the shared constructor
    (which does not). An unattributed site is not a bug — it simply stays in
    the process-wide total, which is why `sum(slots) <= values` and never `==`.
    """
    if n_values == 0:
        return
    if site == 0:
        _SD_SITE_0.add(n_values)
    elif site == 1:
        _SD_SITE_1.add(n_values)
    elif site == 2:
        _SD_SITE_2.add(n_values)
    elif site == 3:
        _SD_SITE_3.add(n_values)
    elif site == 4:
        _SD_SITE_4.add(n_values)
    elif site == 5:
        _SD_SITE_5.add(n_values)
    elif site == 6:
        _SD_SITE_6.add(n_values)
    else:
        _SD_SITE_7.add(n_values)


def strdrain_site_values(site: Int) raises -> Int:
    """Values attributed to site family `site` since the last reset."""
    if site == 0:
        return _SD_SITE_0.read()
    elif site == 1:
        return _SD_SITE_1.read()
    elif site == 2:
        return _SD_SITE_2.read()
    elif site == 3:
        return _SD_SITE_3.read()
    elif site == 4:
        return _SD_SITE_4.read()
    elif site == 5:
        return _SD_SITE_5.read()
    elif site == 6:
        return _SD_SITE_6.read()
    return _SD_SITE_7.read()


# -----------------------------------------------------------------------------
# PER-CONVERTED-SITE ARM PAIRS (+ a reach DENOMINATOR each)
# -----------------------------------------------------------------------------
#
# The owner table above answers WHICH function owns a contested family's
# values. These are the per-arm instrument for two of those functions:
#
#   rx*  -> `radix_hash_agg_untyped.drain_radix_hash_agg_untyped_to_record_batch`
#           (owner 1, family s2)
#   cdp* -> `agg_count_distinct_parallel._execute_count_distinct_agg_parallel`
#           (owner 3, family s6)
#
# Each is a TRIPLE, exactly as the `agg_dict` site is: a `_calls`
# denominator counted BEFORE the arm branch, plus one counter per arm. The
# denominator is what makes a zero legible — `calls == 0` says the site was
# never entered (so neither arm counter could have moved for a reason the arm
# choice had any part in), while `calls > 0 and stage == 0 and builder == 0` is
# IMPOSSIBLE and indicts the instrument rather than the lever.
comptime _SD_RX_CALLS = GlobalCounter["komira_counters_strdrain_rx_calls"]
comptime _SD_RX_STAGE = GlobalCounter["komira_counters_strdrain_rx_stage"]
comptime _SD_RX_BUILDER = GlobalCounter["komira_counters_strdrain_rx_builder"]
comptime _SD_CDP_CALLS = GlobalCounter["komira_counters_strdrain_cdp_calls"]
comptime _SD_CDP_STAGE = GlobalCounter["komira_counters_strdrain_cdp_stage"]
comptime _SD_CDP_BUILDER = GlobalCounter["komira_counters_strdrain_cdp_builder"]


@always_inline
def strdrain_note_rx_call() raises:
    """Record ONE string key column emitted by the RADIX untyped hash-agg
    drain. Counted BEFORE the arm branch — the REACH witness."""
    _SD_RX_CALLS.incr()


@always_inline
def strdrain_note_rx_stage(n_values: Int) raises:
    """Values the radix drain emitted through the INCUMBENT staging arm."""
    if n_values == 0:
        return
    _SD_RX_STAGE.add(n_values)


@always_inline
def strdrain_note_rx_builder(n_values: Int) raises:
    """Values the radix drain emitted through the `ArrowStringBuilder` arm."""
    if n_values == 0:
        return
    _SD_RX_BUILDER.add(n_values)


@always_inline
def strdrain_note_cdp_call() raises:
    """Record ONE string key column emitted by the PARALLEL count-distinct
    executor. Counted BEFORE the arm branch — the REACH witness."""
    _SD_CDP_CALLS.incr()


@always_inline
def strdrain_note_cdp_stage(n_values: Int) raises:
    """Values the parallel count-distinct emitted through the INCUMBENT arm."""
    if n_values == 0:
        return
    _SD_CDP_STAGE.add(n_values)


@always_inline
def strdrain_note_cdp_builder(n_values: Int) raises:
    """Values the parallel count-distinct emitted through the builder arm."""
    if n_values == 0:
        return
    _SD_CDP_BUILDER.add(n_values)


def strdrain_rx_calls() raises -> Int:
    """String key columns emitted by the radix drain. Nonzero == REACHED."""
    return _SD_RX_CALLS.read()


def strdrain_rx_stage_values() raises -> Int:
    """Radix-drain values through the incumbent staging arm."""
    return _SD_RX_STAGE.read()


def strdrain_rx_builder_values() raises -> Int:
    """Radix-drain values through the `ArrowStringBuilder` arm."""
    return _SD_RX_BUILDER.read()


def strdrain_cdp_calls() raises -> Int:
    """String key columns emitted by the parallel count-distinct executor."""
    return _SD_CDP_CALLS.read()


def strdrain_cdp_stage_values() raises -> Int:
    """Parallel count-distinct values through the incumbent staging arm."""
    return _SD_CDP_STAGE.read()


def strdrain_cdp_builder_values() raises -> Int:
    """Parallel count-distinct values through the `ArrowStringBuilder` arm."""
    return _SD_CDP_BUILDER.read()


# -----------------------------------------------------------------------------
# Recorders
# -----------------------------------------------------------------------------


@always_inline
def strdrain_note_from_strings(n_values: Int, n_bytes: Int) raises:
    """Record ONE `StringArray.from_strings*` call staging `n_values` values
    totalling `n_bytes` value bytes.

    Called from inside the two staging constructors themselves, so the count
    cannot drift away from the cost it stands for the way a parallel walk over
    call sites would.
    """
    _SD_CALLS.incr()
    if n_values != 0:
        _SD_VALUES.add(n_values)
    if n_bytes != 0:
        _SD_BYTES.add(n_bytes)


@always_inline
def strdrain_note_aggdict_call() raises:
    """Record ONE string key column emitted by
    `agg_dict._execute_dict_perfect_hash_agg`'s key loop.

    ⚠ Recorded BEFORE the arm branch. This is the REACH witness: a cell whose
    `strdrain_aggdict_calls` is 0 never entered the site, so its two arm
    counters are zero for a reason the arm choice had no part in.
    """
    _SD_AGGDICT_CALLS.incr()


@always_inline
def strdrain_note_aggdict_stage(n_values: Int) raises:
    """Record `n_values` drained through the INCUMBENT `List[String]` staging
    arm at the converted site. Positive exactly when the site was reached and
    took the staging arm."""
    if n_values == 0:
        return
    _SD_AGGDICT_STAGE_VALUES.add(n_values)


@always_inline
def strdrain_note_aggdict_builder(n_values: Int) raises:
    """Record `n_values` drained through the `ArrowStringBuilder` arm at the
    converted site. Positive exactly when the site was reached and took the
    builder arm."""
    if n_values == 0:
        return
    _SD_AGGDICT_BUILDER_VALUES.add(n_values)


# -----------------------------------------------------------------------------
# Readers
# -----------------------------------------------------------------------------


def strdrain_calls() raises -> Int:
    """`StringArray.from_strings*` calls since the last reset — the class's
    reach denominator for the cell."""
    return _SD_CALLS.read()


def strdrain_values() raises -> Int:
    """Values staged through `List[String]` since the last reset. An UPPER
    BOUND on every site in the class simultaneously."""
    return _SD_VALUES.read()


def strdrain_bytes() raises -> Int:
    """Value bytes staged through `List[String]` since the last reset."""
    return _SD_BYTES.read()


def strdrain_aggdict_calls() raises -> Int:
    """String key columns emitted by the converted site. Nonzero == REACHED."""
    return _SD_AGGDICT_CALLS.read()


def strdrain_aggdict_stage_values() raises -> Int:
    """Values the converted site drained through the incumbent staging arm."""
    return _SD_AGGDICT_STAGE_VALUES.read()


def strdrain_aggdict_builder_values() raises -> Int:
    """Values the converted site drained through the `ArrowStringBuilder`
    arm."""
    return _SD_AGGDICT_BUILDER_VALUES.read()


def reset_strdrain_counters() raises:
    """Reset every counter to 0 (test setup / per-cell delta harness)."""
    _SD_CALLS.reset()
    _SD_VALUES.reset()
    _SD_BYTES.reset()
    _SD_AGGDICT_CALLS.reset()
    _SD_AGGDICT_STAGE_VALUES.reset()
    _SD_AGGDICT_BUILDER_VALUES.reset()
    _SD_SITE_0.reset()
    _SD_SITE_1.reset()
    _SD_SITE_2.reset()
    _SD_SITE_3.reset()
    _SD_SITE_4.reset()
    _SD_SITE_5.reset()
    _SD_SITE_6.reset()
    _SD_SITE_7.reset()
    _SD_OWNER_0.reset()
    _SD_OWNER_1.reset()
    _SD_OWNER_2.reset()
    _SD_OWNER_3.reset()
    _SD_RX_CALLS.reset()
    _SD_RX_STAGE.reset()
    _SD_RX_BUILDER.reset()
    _SD_CDP_CALLS.reset()
    _SD_CDP_STAGE.reset()
    _SD_CDP_BUILDER.reset()

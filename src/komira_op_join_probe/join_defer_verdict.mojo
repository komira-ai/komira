# =============================================================================
# join_defer_verdict -- the deferral predicate of the streaming join probe,
# and which line of it decided each morsel.
# =============================================================================
#
# A streaming join probe either STAGES a morsel's output (assembles it now) or
# DEFERS it (retains the probe morsel and its match indices, and gathers the
# output once at the end; `join_deferred`). Two routes emit identical bytes, so
# a route change is invisible in values and only visible in time.
# `deferral_verdict` IS the predicate (`admits_deferral` wraps it), and it
# returns the line that decided, so the reason reported and the branch taken
# cannot drift apart. The per-line counters are unconditional (one relaxed
# add per morsel), so an all-zero reading means the site was never reached.
# =============================================================================

from std.ffi import _Global
from std.memory import alloc, OwnedPointer

from komira_atomic_alias import AtomicI64


comptime DEFER_ADMIT: Int = 0
"""The morsel defers."""

comptime DEFER_NO_MATCHES: Int = 1
"""`matches <= 0` -- correctness refusal, not a cost decision."""

comptime DEFER_NO_WIDTH: Int = 2
"""`out_row_width <= 0` -- the denominator is not meaningful."""

comptime DEFER_UNPRICEABLE: Int = 3
"""`probe_bytes < 0` -- a STRING / BINARY / BOOL / DICTIONARY probe column."""

comptime DEFER_FOOTPRINT_CAP: Int = 4
"""The traffic rule's FOOTPRINT CAP declined: retaining would overshoot the
staged arm's peak by more than the index lists the mechanism holds anyway.
"""

comptime DEFER_TRAFFIC: Int = 5
"""The traffic rule's DRAM inequality declined: deferring moves more bytes."""

comptime DEFER_MEMORY: Int = 6
"""The MEMORY rule declined (the traffic rule not asked for, or a caller that
did not pass `out_num_cols`)."""

comptime DEFER_SHAPE: Int = 7
"""The caller's per-morsel shape check failed (it is about the batch, not
about cost, so it sits outside `deferral_verdict`). Recorded here so the
reasons sum to the morsel population."""

comptime DEFER_VERDICT_COUNT: Int = 8


def _init_jdv_i64() -> OwnedPointer[AtomicI64]:
    var raw = alloc[AtomicI64](1)
    # SAFETY: `raw` is a fresh one-element allocation; zeroing it as the
    # counter's int64 initialises it, and the `OwnedPointer` then owns and
    # frees it.
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _JDV_ADMIT = _Global["komira_jdv_admit", _init_jdv_i64]
comptime _JDV_NO_MATCHES = _Global["komira_jdv_no_matches", _init_jdv_i64]
comptime _JDV_NO_WIDTH = _Global["komira_jdv_no_width", _init_jdv_i64]
comptime _JDV_UNPRICEABLE = _Global["komira_jdv_unpriceable", _init_jdv_i64]
comptime _JDV_CAP = _Global["komira_jdv_cap", _init_jdv_i64]
comptime _JDV_TRAFFIC = _Global["komira_jdv_traffic", _init_jdv_i64]
comptime _JDV_MEMORY = _Global["komira_jdv_memory", _init_jdv_i64]
comptime _JDV_SHAPE = _Global["komira_jdv_shape", _init_jdv_i64]


def defer_verdict_note(code: Int) raises:
    """Record ONE morsel's deferral verdict."""
    # SAFETY: FFI carve-out -- a process-wide relaxed counter behind a
    # `_Global`, the same construction `join_probe_levers` uses; the pointer
    # never leaves this module.
    if code == DEFER_ADMIT:
        _ = _JDV_ADMIT.get_or_create_ptr()[][].fetch_add(Int64(1))
    elif code == DEFER_NO_MATCHES:
        _ = _JDV_NO_MATCHES.get_or_create_ptr()[][].fetch_add(Int64(1))
    elif code == DEFER_NO_WIDTH:
        _ = _JDV_NO_WIDTH.get_or_create_ptr()[][].fetch_add(Int64(1))
    elif code == DEFER_UNPRICEABLE:
        _ = _JDV_UNPRICEABLE.get_or_create_ptr()[][].fetch_add(Int64(1))
    elif code == DEFER_FOOTPRINT_CAP:
        _ = _JDV_CAP.get_or_create_ptr()[][].fetch_add(Int64(1))
    elif code == DEFER_TRAFFIC:
        _ = _JDV_TRAFFIC.get_or_create_ptr()[][].fetch_add(Int64(1))
    elif code == DEFER_MEMORY:
        _ = _JDV_MEMORY.get_or_create_ptr()[][].fetch_add(Int64(1))
    else:
        _ = _JDV_SHAPE.get_or_create_ptr()[][].fetch_add(Int64(1))


def defer_verdict_count(code: Int) raises -> Int:
    """Morsels that took verdict `code`, process-wide."""
    # SAFETY: FFI carve-out (see `defer_verdict_note`).
    if code == DEFER_ADMIT:
        return Int(_JDV_ADMIT.get_or_create_ptr()[][].load())
    elif code == DEFER_NO_MATCHES:
        return Int(_JDV_NO_MATCHES.get_or_create_ptr()[][].load())
    elif code == DEFER_NO_WIDTH:
        return Int(_JDV_NO_WIDTH.get_or_create_ptr()[][].load())
    elif code == DEFER_UNPRICEABLE:
        return Int(_JDV_UNPRICEABLE.get_or_create_ptr()[][].load())
    elif code == DEFER_FOOTPRINT_CAP:
        return Int(_JDV_CAP.get_or_create_ptr()[][].load())
    elif code == DEFER_TRAFFIC:
        return Int(_JDV_TRAFFIC.get_or_create_ptr()[][].load())
    elif code == DEFER_MEMORY:
        return Int(_JDV_MEMORY.get_or_create_ptr()[][].load())
    return Int(_JDV_SHAPE.get_or_create_ptr()[][].load())


def reset_defer_verdict_counters() raises:
    """TEST-ONLY: zero every verdict counter."""
    # SAFETY: FFI carve-out (see `defer_verdict_note`).
    _JDV_ADMIT.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _JDV_NO_MATCHES.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _JDV_NO_WIDTH.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _JDV_UNPRICEABLE.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _JDV_CAP.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _JDV_TRAFFIC.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _JDV_MEMORY.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _JDV_SHAPE.get_or_create_ptr()[][].store(Scalar[DType.int64](0))


def defer_verdict_word(code: Int) -> StaticString:
    """The one-word name of a verdict code, for the ledger line."""
    if code == DEFER_ADMIT:
        return StaticString("admit")
    elif code == DEFER_NO_MATCHES:
        return StaticString("no_matches")
    elif code == DEFER_NO_WIDTH:
        return StaticString("no_width")
    elif code == DEFER_UNPRICEABLE:
        return StaticString("unpriceable")
    elif code == DEFER_FOOTPRINT_CAP:
        return StaticString("cap")
    elif code == DEFER_TRAFFIC:
        return StaticString("traffic")
    elif code == DEFER_MEMORY:
        return StaticString("memory")
    elif code == DEFER_SHAPE:
        return StaticString("shape")
    return StaticString("unknown")


def defer_verdict_why() raises -> StaticString:
    """Name the line that decided most morsels (more than half), else
    `mixed`; `unreached` when no morsel was recorded."""
    var best = -1
    var best_n = 0
    var total = 0
    for c in range(DEFER_VERDICT_COUNT):
        var n = defer_verdict_count(c)
        total += n
        if n > best_n:
            best_n = n
            best = c
    if total == 0:
        return StaticString("unreached")
    if best_n * 2 <= total:
        return StaticString("mixed")
    return defer_verdict_word(best)


def defer_verdict_fields() raises -> String:
    """The verdict counts as ` defer_<line>=<n>` fields, then `defer_why=`."""
    return (
        String(" defer_admit=")
        + String(defer_verdict_count(DEFER_ADMIT))
        + " defer_cap="
        + String(defer_verdict_count(DEFER_FOOTPRINT_CAP))
        + " defer_traffic="
        + String(defer_verdict_count(DEFER_TRAFFIC))
        + " defer_memory="
        + String(defer_verdict_count(DEFER_MEMORY))
        + " defer_shape="
        + String(defer_verdict_count(DEFER_SHAPE))
        + " defer_nomatch="
        + String(defer_verdict_count(DEFER_NO_MATCHES))
        + " defer_nowidth="
        + String(defer_verdict_count(DEFER_NO_WIDTH))
        + " defer_unpriceable="
        + String(defer_verdict_count(DEFER_UNPRICEABLE))
        + " defer_why="
        + String(defer_verdict_why())
    )


comptime DEFER_IDX_BYTES_PER_COL: Int = 4
"""The match-index width the traffic rule prices: the 4-byte indices the
deferred assembly reads (`try_narrow_index_pair`). A record whose indices could
not be narrowed keeps 8-byte ones; 8 is the width the rule was first written
with."""


comptime DEFER_SEG_BUILD_RESIDENT_BYTES: Int = 4 * 1024 * 1024
"""Build-side bytes above which the build side is NOT cache-resident."""


@always_inline
def deferred_gather_outprices_segments(
    build_side_bytes: Int,
    resident_bytes: Int = DEFER_SEG_BUILD_RESIDENT_BYTES,
) -> Bool:
    """Is the DEFERRED gather the better producer than PER-MORSEL SEGMENTS?

    Args:
        build_side_bytes: The build batch's priced bytes -- `num_rows() *
            deferred_output_row_width(build_schema)` -- or a NEGATIVE value when
            that width could not be priced.
        resident_bytes: The residency threshold. A parameter, not a read of the
            environment, so a test can drive both sides of the band; defaults to
            `DEFER_SEG_BUILD_RESIDENT_BYTES`.

    Returns:
        True when the build side is too large to be cache-resident, i.e. when
        the deferred route's memory-level parallelism in the build-side gather
        outweighs the probe + index re-read it costs.
    """
    if build_side_bytes < 0:
        return False
    return build_side_bytes > resident_bytes


@always_inline
def deferral_verdict(
    probe_bytes: Int,
    matches: Int,
    out_row_width: Int,
    force: Bool = False,
    out_num_cols: Int = 0,
    traffic_rule: Bool = False,
    retained_bytes_per_match: Int = 16,
    idx_bytes_per_match_per_col: Int = 8,
) -> Int:
    """Should THIS morsel defer, and which line said so (a `DEFER_*` code)?

    Three correctness refusals come first and `force` cannot bypass them: no
    matches, a non-positive output row width, and an unpriceable probe morsel
    (`probe_bytes < 0`: a STRING / BINARY / BOOL / DICTIONARY column, which a
    deferred gather would copy as fixed-width values). Then `force` admits.
    Then one of two cost rules:

      * the TRAFFIC rule (`traffic_rule` and `out_num_cols > 0`): admit when
        `probe_bytes <= matches * out_row_width` (the footprint cap) and
        `probe_bytes + IDXW * out_num_cols * matches
        < 2 * matches * out_row_width` (deferring moves fewer DRAM bytes), with
        `IDXW = idx_bytes_per_match_per_col`;
      * the MEMORY rule otherwise: admit when retaining
        (`probe_bytes + retained_bytes_per_match * matches`) costs no more than
        staging (`matches * out_row_width`).

    The defaults (memory rule, 16 retained bytes and 8-byte indices per match)
    make a three-argument call the memory rule's oracle; a join's real
    arguments come from its `JoinDeferredState`.
    """
    if matches <= 0:
        return DEFER_NO_MATCHES
    if out_row_width <= 0:
        return DEFER_NO_WIDTH
    if probe_bytes < 0:
        return DEFER_UNPRICEABLE
    if force:
        return DEFER_ADMIT
    if traffic_rule and out_num_cols > 0:
        if probe_bytes > matches * out_row_width:
            return DEFER_FOOTPRINT_CAP
        if (
            probe_bytes + idx_bytes_per_match_per_col * out_num_cols * matches
            >= 2 * matches * out_row_width
        ):
            return DEFER_TRAFFIC
        return DEFER_ADMIT
    if (
        probe_bytes + retained_bytes_per_match * matches
        > matches * out_row_width
    ):
        return DEFER_MEMORY
    return DEFER_ADMIT

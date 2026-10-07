# =============================================================================
# scan_copy_trace — the gates that let the scan skip a copy + their per-site
#                   fire COUNTERS
# =============================================================================
#
# A Parquet scan has several sites where a whole decoded buffer can either be
# copied into its next owner or handed over without a copy. Each site has two
# arms, chosen at run time by a gate in this module, and a pair of counters
# that say which arm ran:
#
#   | # | gate                 | default | the copy the ON arm removes          |
#   |---|----------------------|---------|--------------------------------------|
#   | 1 | dict_resolve_move    | OFF     | a dict-resolved chunk's buffer       |
#   |   |                      |         | copied into its Column               |
#   | 2 | proj_share           | ON      | decoded columns deep-copied only to  |
#   |   |                      |         | reorder them into projection order   |
#   | 3 | bss_decode_into      | ON      | a BYTE_STREAM_SPLIT page decoded to  |
#   |   |                      |         | an array, then copied into the chunk |
#   | 4 | string_share         | ON      | a string chunk deep-copied into its  |
#   |   |                      |         | Column                               |
#   | 5 | plain_ba_fused       | ON      | the second walk of a PLAIN           |
#   |   |                      |         | BYTE_ARRAY page                      |
#   | 6 | string_page_move     | ON      | a single-page string chunk rebuilt   |
#   |   |                      |         | by a concat                          |
#
# ⛔ WHAT DELETING A COPY SAVES IS A PROPERTY OF THE MEMORY SYSTEM. Whether
# deleting a copy shows up in wall time depends on whether the copied buffer
# was cache-resident on the measuring box: the same lever can measure a win on
# a box at its DRAM-bandwidth ceiling and nothing on one with a large L2. The
# allocation and the instructions are deleted everywhere, so a lever is not
# expected to REGRESS a big-cache box either. Never settle one of these on a
# high-bandwidth box alone, and do not sum levers on one path: gates that each
# delete a copy on the same path have measured SUB-ADDITIVE when they meet.
#
# ⚠ `plain_ba_fused_enabled`, THE BOUND. `plain.decode_plain_byte_array` has
# two walks. The two-pass walk reads every 4-byte length prefix to size the
# destination, then re-reads them all to copy the bodies; the second walk
# exists ONLY because the destination size is not known until every length has
# been read. The fused walk sizes the destination from an exact bound instead:
# a PLAIN BYTE_ARRAY values section is `[u32 len][body]` repeated `num_values`
# times, so `cap = data_len - 4*num_values` bounds the payload and EQUALS it
# for a conforming, exactly-packed page. `plain-ba-slack` measures the
# difference in BYTES, so the claim "the fused arm allocates nothing extra" is
# a reading, not an assertion. The fused walk also reserves the later values'
# prefixes in its per-value bound, which keeps an early value from writing past
# `cap` while accepting exactly the pages the two-pass walk accepts (the proof
# is on `plain._decode_plain_ba_fused`).
#
# ⚠ `string_page_move_enabled` DECLINES A PAGE CARRYING A VALIDITY BITMAP. The
# concat emits `validity=None` unconditionally, so moving a page that HAS one
# would not be byte-identical. The guard is a presence test on the page, never a
# `null_count == 0` read: a stale count would turn SQL NULLs into values.
#
# ⚠ THE GATES ARE SET, NEVER READ FROM THE ENVIRONMENT. A program turns an arm
# on or off with its setter (`set_*_enabled`), typically from its own
# command-line flag; `reset_scan_copy_gates` restores the defaults.
#
# ⚠ THE OBSERVABLE IS A COUNT, NOT A FLAG. A lever that never ARMS measures a
# perfect null, which is indistinguishable from a lever that armed and did
# nothing. With the trace on (`set_scan_copy_trace_enabled(True)`),
# `scan_copy_trace_dump` prints the per-site fire counts, so:
#   * `proj-share + proj-COPY` MEASURES the arm fraction `f` (it is the number
#     of (row group x projected column) rebuilds that reached the gated arm);
#   * `proj-COPY-other` counts the copy_column_ref fires at the OTHER arms of
#     the same function, so a WRONG ARM MAP is diagnosed, not merely detected —
#     if the gated pair is ~0 and this one is large, the scan is taking the
#     high-selectivity or survivor-gather arm instead;
#   * `dict-resolve-move + dict-resolve-COPY` is the number of dict-resolved
#     column chunks, so `move == 0` with the gate ON means the arm declined
#     (nullable / decimal / numeric-dict-vec), not that the gate was unread.
#
# The counters are ALWAYS-ON (one relaxed atomic per COLUMN-CHUNK or per
# (row-group x column) rebuild — never per row, never per page) so a test can
# read them directly. Only the PRINT is gated.
#
# ⛔⛔ A COUNTER THAT DOES NOT PRINT ON THE ROUTE UNDER TEST IS NOT AN
# OBSERVABLE. WHEN YOU ADD A GATE, ENUMERATE THE DRIVERS THAT CAN REACH ITS
# ARMS AND PUT THE DUMP ON EVERY ONE. A gate whose arms sit in a shared source
# is reachable from every driver of that source; reason from "which function
# returns last", not from "the scan code is the same".
#
# Mechanism: name-keyed, init-once, cross-compile-unit process-global
# `Atomic[int64]` via the stdlib `_Global` runtime slot — the same idiom as
# `decode_arm_trace.mojo`. No address rebuilt from an integer, no
# UnsafePointer in any public signature.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import OwnedPointer, UnsafePointer, alloc

from .payload_sel_trace import (
    payload_sel_decline_count,
    payload_sel_decode_mode,
    payload_sel_hit_count,
    payload_sel_policy_skip_count,
    payload_sel_rows_decoded,
    payload_sel_rows_total,
    payload_sel_skip_count,
)
from .staged_filter_trace import (
    staged_filter_declined_count,
    staged_filter_enabled,
    staged_filter_gather_count,
    staged_filter_rg_count,
    staged_filter_rows_full,
    staged_filter_rows_sel,
    staged_filter_sel_count,
)
from .decode_arm_trace import (
    delta_page_bytecopy_count,
    delta_page_memcpy_count,
    dict_resolve_fused_count,
    dict_resolve_fused_enabled,
    dict_resolve_legacy_count,
    dict_string_copy_count,
    dict_string_share_count,
    dict_string_share_enabled,
    delta_page_memcpy_enabled,
    flat_gather_fused_count,
    flat_gather_legacy_count,
)


# -----------------------------------------------------------------------------
# The process-global slots.
# -----------------------------------------------------------------------------
#
# ONE shared init_fn across every slot: `_Global` keys on the NAME, so the same
# function safely initialises N independent counters. The Atomic-init pattern
# (`alloc` + an in-place write + `OwnedPointer(unsafe_from_raw_pointer=)`) is
# needed because `Atomic` is not movable-by-value.
def _init_scan_copy_slot() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn (non-raising): allocate one counter/latch Atomic per
    process, initialised to 0."""
    var raw = alloc[AtomicI64](1)
    # SAFETY: module-private init, concrete origin from `to=`. `Atomic` is not
    # movable-by-value, so its interior scalar must be initialised in place
    # before the `OwnedPointer` takes ownership; the raw pointer never leaves
    # this function (the return type is `OwnedPointer`).
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _C_DICT_MOVE = _Global[
    "komira_parquet_scan_copy_dict_resolve_move", _init_scan_copy_slot
]
comptime _C_DICT_COPY = _Global[
    "komira_parquet_scan_copy_dict_resolve_copy", _init_scan_copy_slot
]
comptime _C_PROJ_SHARE = _Global[
    "komira_parquet_scan_copy_proj_share", _init_scan_copy_slot
]
comptime _C_PROJ_COPY = _Global[
    "komira_parquet_scan_copy_proj_copy", _init_scan_copy_slot
]
comptime _C_PROJ_COPY_OTHER = _Global[
    "komira_parquet_scan_copy_proj_copy_other", _init_scan_copy_slot
]
comptime _C_BSS_INTO = _Global[
    "komira_parquet_scan_copy_bss_decode_into", _init_scan_copy_slot
]
comptime _C_BSS_COPY = _Global[
    "komira_parquet_scan_copy_bss_decode_copy", _init_scan_copy_slot
]
comptime _C_STR_SHARE = _Global[
    "komira_parquet_scan_copy_string_share", _init_scan_copy_slot
]
comptime _C_STR_COPY = _Global[
    "komira_parquet_scan_copy_string_copy", _init_scan_copy_slot
]
comptime _C_PLAIN_BA_FUSED = _Global[
    "komira_parquet_scan_copy_plain_ba_fused", _init_scan_copy_slot
]
comptime _C_PLAIN_BA_2PASS = _Global[
    "komira_parquet_scan_copy_plain_ba_two_pass", _init_scan_copy_slot
]
comptime _C_PLAIN_BA_SLACK = _Global[
    "komira_parquet_scan_copy_plain_ba_slack", _init_scan_copy_slot
]
comptime _C_PLAIN_BA_ALLOC = _Global[
    "komira_parquet_scan_copy_plain_ba_fused_alloc", _init_scan_copy_slot
]
comptime _C_STR_PAGE_MOVE = _Global[
    "komira_parquet_scan_copy_string_page_move", _init_scan_copy_slot
]
comptime _C_STR_PAGE_CONCAT = _Global[
    "komira_parquet_scan_copy_string_page_concat", _init_scan_copy_slot
]
# The next-row-group readahead hint is a MADV_WILLNEED over a byte range.
# MADV_WILLNEED POPULATES PAGE TABLES, so on a page-cache-warm scan every
# advised byte is charged as soft faults whether or not the query decodes it.
#
# ⚠ THE OBSERVABLE HAS TO BE BYTES, NOT A FLAG. A `madvise` is a hint: it is
# invisible to every value test and to every row count, and the ONLY way to
# tell "advised the right range" from "advised nothing" from "advised a
# different column" is to record the range's SIZE. `prefetch-calls` alone
# cannot: advising the wrong column keeps the call count identical.
comptime _C_PREFETCH_CALLS = _Global[
    "komira_parquet_scan_copy_prefetch_calls", _init_scan_copy_slot
]
comptime _C_PREFETCH_BYTES = _Global[
    "komira_parquet_scan_copy_prefetch_bytes", _init_scan_copy_slot
]

# Gate latches. Tri-state: 0 = UNRESOLVED (no setter has run: the gate's
# default), 1 = ON, 2 = OFF. A setter stores 1 or 2; `reset_scan_copy_gates`
# stores 0 again.
comptime _G_DICT_MOVE = _Global[
    "komira_parquet_gate_dict_resolve_move", _init_scan_copy_slot
]
comptime _G_PROJ_SHARE = _Global[
    "komira_parquet_gate_proj_share", _init_scan_copy_slot
]
comptime _G_TRACE = _Global[
    "komira_parquet_gate_scan_copy_trace", _init_scan_copy_slot
]
comptime _G_BSS_INTO = _Global[
    "komira_parquet_gate_bss_decode_into", _init_scan_copy_slot
]
comptime _G_STR_SHARE = _Global[
    "komira_parquet_gate_string_share", _init_scan_copy_slot
]
comptime _G_PLAIN_BA_FUSED = _Global[
    "komira_parquet_gate_plain_ba_fused", _init_scan_copy_slot
]
comptime _G_STR_PAGE_MOVE = _Global[
    "komira_parquet_gate_string_page_move", _init_scan_copy_slot
]
comptime _G_PREFETCH_PROJ = _Global[
    "komira_parquet_gate_prefetch_proj", _init_scan_copy_slot
]

comptime _GATE_UNRESOLVED: Int64 = 0
comptime _GATE_ON: Int64 = 1
comptime _GATE_OFF: Int64 = 2


# -----------------------------------------------------------------------------
# Counters — one relaxed atomic add per COLUMN-CHUNK / per (RG x column).
# -----------------------------------------------------------------------------


@always_inline
def incr_dict_resolve_move() raises:
    """Record one dict-resolve column chunk that took the ZERO-COPY share arm.
    `raises` only to propagate `_Global.get_or_create_ptr`'s signature."""
    # SAFETY: `get_or_create_ptr` targets KGEN-runtime-managed
    # static storage (process-lifetime); the `MutUntrackedOrigin` is the stdlib
    # `_Global` API's own return type and is confined to this helper.
    _ = _C_DICT_MOVE.get_or_create_ptr()[][].fetch_add(Int64(1))


@always_inline
def incr_dict_resolve_copy() raises:
    """Record one dict-resolve column chunk that took the `from_primitive`
    COPY arm (gate OFF, or an arm that declines: nullable / decimal)."""
    # SAFETY: see `incr_dict_resolve_move`.
    _ = _C_DICT_COPY.get_or_create_ptr()[][].fetch_add(Int64(1))


@always_inline
def incr_proj_share() raises:
    """Record one projection-order rebuild column that was Arc-SHARED."""
    # SAFETY: see `incr_dict_resolve_move`.
    _ = _C_PROJ_SHARE.get_or_create_ptr()[][].fetch_add(Int64(1))


@always_inline
def incr_proj_copy() raises:
    """Record one projection-order rebuild column that took `copy_column_ref`
    at a GATED site (gate OFF, or the length/offset guard declined)."""
    # SAFETY: see `incr_dict_resolve_move`.
    _ = _C_PROJ_COPY.get_or_create_ptr()[][].fetch_add(Int64(1))


@always_inline
def incr_proj_copy_other() raises:
    """Record one `copy_column_ref` fire at an UNGATED arm of the same
    late-materialisation ladder (high-selectivity gather, survivor gather,
    shared-key rebuild). Pure diagnosis of the arm map — see the header."""
    # SAFETY: see `incr_dict_resolve_move`.
    _ = _C_PROJ_COPY_OTHER.get_or_create_ptr()[][].fetch_add(Int64(1))


@always_inline
def incr_bss_decode_into() raises:
    """Record one BYTE_STREAM_SPLIT data PAGE that transposed STRAIGHT INTO
    the chunk buffer (`bss_decode_into_enabled` armed) — no intermediate
    array, no memcpy."""
    # SAFETY: see `incr_dict_resolve_move`.
    _ = _C_BSS_INTO.get_or_create_ptr()[][].fetch_add(Int64(1))


@always_inline
def incr_bss_decode_copy() raises:
    """Record one BYTE_STREAM_SPLIT data PAGE that took the
    allocate-transpose-COPY-free arm (gate OFF).

    ⚠ COUNTED PER PAGE, NOT PER COLUMN CHUNK, and that is deliberate: the
    redundant buffer this gate deletes is allocated once per PAGE, so `into +
    COPY` is the number of round-trips the lever is being asked to remove. On
    a multi-page chunk it is larger than the chunk count, which is the honest
    number."""
    # SAFETY: see `incr_dict_resolve_move`.
    _ = _C_BSS_COPY.get_or_create_ptr()[][].fetch_add(Int64(1))


@always_inline
def incr_string_share() raises:
    """Record one BYTE_ARRAY fallback column chunk whose whole-chunk
    `StringArray` was Arc-SHARED into its `Column` (`string_share_enabled`
    armed) — no byte copy of the payload or the offsets."""
    # SAFETY: see `incr_dict_resolve_move`.
    _ = _C_STR_SHARE.get_or_create_ptr()[][].fetch_add(Int64(1))


@always_inline
def incr_string_copy() raises:
    """Record one BYTE_ARRAY fallback column chunk that took the
    `Column.from_string` DEEP-COPY arm (gate OFF).

    ⚠ COUNTED PER COLUMN CHUNK, and `share + COPY` is therefore the number of
    whole-chunk string payload copies the lever is being asked to remove — the
    arm fraction, not a flag. `share == 0` with the gate ON means the arm was
    never REACHED (the chunk did not take the BYTE_ARRAY fallback route at
    all), which is a different fact from the gate being unread."""
    # SAFETY: see `incr_dict_resolve_move`.
    _ = _C_STR_COPY.get_or_create_ptr()[][].fetch_add(Int64(1))


@always_inline
def incr_string_page_move() raises:
    """Record one BYTE_ARRAY fallback column chunk whose whole-chunk
    `StringArray` was MOVED out of its single decoded page
    (`string_page_move_enabled` armed) — no second allocation of the payload,
    no second traversal of the offsets.

    ⚠ COUNTED PER COLUMN CHUNK, and only on chunks that presented EXACTLY ONE
    page. `move + CONCAT` is the fallback-chunk population; `move` alone is the
    subset the lever can reach, and on a multi-page chunk the concat is real
    work that nothing here deletes."""
    # SAFETY: see `incr_dict_resolve_move`.
    _ = _C_STR_PAGE_MOVE.get_or_create_ptr()[][].fetch_add(Int64(1))


@always_inline
def incr_string_page_concat() raises:
    """Record one BYTE_ARRAY fallback column chunk that ran the full
    concat build (gate OFF, or more than one page, or a page
    carrying a validity bitmap the concat output would not have). See
    `incr_string_page_move` for the pairing."""
    # SAFETY: see `incr_dict_resolve_move`.
    _ = _C_STR_PAGE_CONCAT.get_or_create_ptr()[][].fetch_add(Int64(1))


@always_inline
def incr_plain_ba_fused() raises:
    """Record one PLAIN BYTE_ARRAY page decoded by the SINGLE-pass arm
    (`plain_ba_fused_enabled` armed) — validate + offsets + copy in one walk.

    ⚠ COUNTED PER CALL of `decode_plain_byte_array`, i.e. per PLAIN BYTE_ARRAY
    DATA PAGE on the fallback route and per PLAIN BYTE_ARRAY DICTIONARY PAGE on
    the dict route. `fused + 2PASS` is therefore the number of redundant page
    traversals the lever is being asked to delete — never a flag. Zero-value
    calls short-circuit before the gate and are counted by NEITHER."""
    # SAFETY: see `incr_dict_resolve_move`.
    _ = _C_PLAIN_BA_FUSED.get_or_create_ptr()[][].fetch_add(Int64(1))


@always_inline
def incr_plain_ba_two_pass() raises:
    """Record one PLAIN BYTE_ARRAY page decoded by the TWO-pass arm
    (gate OFF). See `incr_plain_ba_fused` for the pairing."""
    # SAFETY: see `incr_dict_resolve_move`.
    _ = _C_PLAIN_BA_2PASS.get_or_create_ptr()[][].fetch_add(Int64(1))


@always_inline
def incr_prefetch_advise(advised_bytes: Int) raises:
    """Record ONE `madvise(MADV_WILLNEED)` readahead hint and the SIZE of the
    range it covered.

    Called once per advised COLUMN CHUNK, so `prefetch-calls` is
    (row groups claimed x projected columns) and `prefetch-bytes` is the
    compressed byte total the kernel was asked to populate. ⭐ The BYTES are
    the oracle: a hint changes no value and no row count, so an A/B over it is
    unreadable without them (see the readahead block in this file's
    globals). A run whose `prefetch-bytes` exceeds the projected columns'
    footprint is advising a column the query does not read."""
    # SAFETY: see `incr_dict_resolve_move`.
    _ = _C_PREFETCH_CALLS.get_or_create_ptr()[][].fetch_add(Int64(1))
    _ = _C_PREFETCH_BYTES.get_or_create_ptr()[][].fetch_add(
        Int64(advised_bytes)
    )


@always_inline
def prefetch_advise_calls() raises -> Int:
    """Process-cumulative count of readahead hints issued."""
    # SAFETY: see `incr_dict_resolve_move`.
    return Int(_C_PREFETCH_CALLS.get_or_create_ptr()[][].load())


@always_inline
def prefetch_advise_bytes() raises -> Int:
    """Process-cumulative BYTES covered by the readahead hints issued."""
    # SAFETY: see `incr_dict_resolve_move`.
    return Int(_C_PREFETCH_BYTES.get_or_create_ptr()[][].load())


@always_inline
def add_plain_ba_slack(slack_bytes: Int) raises:
    """Accumulate the BYTES by which the fused arm's exact-bound allocation
    `data_len - 4*num_values` exceeded the true `total_data_bytes`.

    ⭐ THIS IS THE "DOES THE LEVER ADD ANYTHING" READING, AND IT IS A
    MEASUREMENT, NOT A MODEL. A conforming, exactly-packed values section makes
    the bound EQUAL to the payload, so a corpus run with `plain-ba-slack=0` is
    direct evidence that the single-pass arm allocates byte-for-byte what the
    two-pass arm allocated. A non-zero total is the honest size of the one
    thing this deletion introduces, and it is reported rather than
    argued away. Only called when the slack is non-zero, so the common path
    pays no atomic."""
    # SAFETY: see `incr_dict_resolve_move`.
    _ = _C_PLAIN_BA_SLACK.get_or_create_ptr()[][].fetch_add(Int64(slack_bytes))


def plain_ba_fused_count() raises -> Int:
    """Process-wide `plain-ba-fused` fire count (pages walked ONCE)."""
    # SAFETY: see `incr_dict_resolve_move`.
    return Int(_C_PLAIN_BA_FUSED.get_or_create_ptr()[][].load())


def plain_ba_two_pass_count() raises -> Int:
    """Process-wide `plain-ba-2PASS` fire count (pages walked TWICE)."""
    # SAFETY: see `incr_dict_resolve_move`.
    return Int(_C_PLAIN_BA_2PASS.get_or_create_ptr()[][].load())


def plain_ba_slack_bytes() raises -> Int:
    """Process-wide total over-allocation, in BYTES, of the fused arm."""
    # SAFETY: see `incr_dict_resolve_move`.
    return Int(_C_PLAIN_BA_SLACK.get_or_create_ptr()[][].load())


@always_inline
def add_plain_ba_fused_alloc(capacity_bytes: Int) raises:
    """Accumulate the fused arm's data-buffer CAPACITY, read back from the
    buffer itself.

    ⛔ THIS EXISTS BECAUSE `plain-ba-slack` CANNOT SEE A CHANGE TO THE
    ALLOCATION ALONE. `slack` is derived from the BOUND
    (`cap - total_data_bytes`); replacing the allocation with
    `OwnedAlignedBuffer(max(data_len, 1))` while leaving `cap` alone changes the
    ALLOCATION and not the bound, so the slack stays 0 and the mutation is
    GREEN — a counter that reports a model of the allocation instead of the
    allocation. This one reads `data_buf.capacity()`, so the two cannot
    decouple.

    ⚠ FUSED ARM ONLY, deliberately: the two-pass arm is the A/B control and
    must not change, so it does not pay this atomic. The claim
    "the deletion allocates no extra bytes" is therefore asserted against the
    PAYLOAD (`alloc <= total_data_bytes + 64`, one 64-byte SIMD pad) rather
    than against a control-arm counter."""
    # SAFETY: see `incr_dict_resolve_move`.
    _ = _C_PLAIN_BA_ALLOC.get_or_create_ptr()[][].fetch_add(
        Int64(capacity_bytes)
    )


def plain_ba_fused_alloc_bytes() raises -> Int:
    """Process-wide total data-buffer CAPACITY allocated by the fused arm."""
    # SAFETY: see `incr_dict_resolve_move`.
    return Int(_C_PLAIN_BA_ALLOC.get_or_create_ptr()[][].load())


def dict_resolve_move_count() raises -> Int:
    """Process-wide `dict-resolve-move` fire count."""
    # SAFETY: see `incr_dict_resolve_move`.
    return Int(_C_DICT_MOVE.get_or_create_ptr()[][].load())


def dict_resolve_copy_count() raises -> Int:
    """Process-wide `dict-resolve-COPY` fire count."""
    # SAFETY: see `incr_dict_resolve_move`.
    return Int(_C_DICT_COPY.get_or_create_ptr()[][].load())


def proj_share_count() raises -> Int:
    """Process-wide `proj-share` fire count."""
    # SAFETY: see `incr_dict_resolve_move`.
    return Int(_C_PROJ_SHARE.get_or_create_ptr()[][].load())


def proj_copy_count() raises -> Int:
    """Process-wide `proj-COPY` fire count (gated sites only)."""
    # SAFETY: see `incr_dict_resolve_move`.
    return Int(_C_PROJ_COPY.get_or_create_ptr()[][].load())


def proj_copy_other_count() raises -> Int:
    """Process-wide `proj-COPY-other` fire count (ungated arms)."""
    # SAFETY: see `incr_dict_resolve_move`.
    return Int(_C_PROJ_COPY_OTHER.get_or_create_ptr()[][].load())


def bss_decode_into_count() raises -> Int:
    """Process-wide `bss-into` fire count (pages transposed into the chunk
    buffer)."""
    # SAFETY: see `incr_dict_resolve_move`.
    return Int(_C_BSS_INTO.get_or_create_ptr()[][].load())


def bss_decode_copy_count() raises -> Int:
    """Process-wide `bss-COPY` fire count (pages that allocated + copied)."""
    # SAFETY: see `incr_dict_resolve_move`.
    return Int(_C_BSS_COPY.get_or_create_ptr()[][].load())


def string_share_count() raises -> Int:
    """Process-wide `string-share` fire count (chunks Arc-shared)."""
    # SAFETY: see `incr_dict_resolve_move`.
    return Int(_C_STR_SHARE.get_or_create_ptr()[][].load())


def string_copy_count() raises -> Int:
    """Process-wide `string-COPY` fire count (chunks deep-copied)."""
    # SAFETY: see `incr_dict_resolve_move`.
    return Int(_C_STR_COPY.get_or_create_ptr()[][].load())


def string_page_move_count() raises -> Int:
    """Process-wide `string-page-move` fire count (single-page fallback chunks
    whose `StringArray` was moved out rather than rebuilt)."""
    # SAFETY: see `incr_dict_resolve_move`.
    return Int(_C_STR_PAGE_MOVE.get_or_create_ptr()[][].load())


def string_page_concat_count() raises -> Int:
    """Process-wide `string-page-CONCAT` fire count (fallback chunks that ran
    the full concat build)."""
    # SAFETY: see `incr_dict_resolve_move`.
    return Int(_C_STR_PAGE_CONCAT.get_or_create_ptr()[][].load())


def reset_scan_copy_counts() raises:
    """Zero every site counter.

    ⚠ TEST SETUP ONLY. Production must NEVER reset these: the counters being
    process-CUMULATIVE is what lets the join route account for its build phase
    and its probe phase from ONE dump site (see `scan_copy_trace_dump`)."""
    # SAFETY: see `incr_dict_resolve_move`.
    _C_DICT_MOVE.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _C_DICT_COPY.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _C_PROJ_SHARE.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _C_PROJ_COPY.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _C_PROJ_COPY_OTHER.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _C_BSS_INTO.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _C_BSS_COPY.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _C_STR_SHARE.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _C_STR_COPY.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _C_PLAIN_BA_FUSED.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _C_PLAIN_BA_2PASS.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _C_PLAIN_BA_SLACK.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _C_PLAIN_BA_ALLOC.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _C_STR_PAGE_MOVE.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _C_STR_PAGE_CONCAT.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _C_PREFETCH_CALLS.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _C_PREFETCH_BYTES.get_or_create_ptr()[][].store(Scalar[DType.int64](0))


# -----------------------------------------------------------------------------
# Gates — set by a setter, read BY VALUE (one relaxed atomic load).
# -----------------------------------------------------------------------------


@always_inline
def dict_resolve_move_enabled() raises -> Bool:
    """The dict-resolve move gate, DEFAULT OFF: OFF because it was measured
    and bought nothing, not because nobody has run it.

    It arms exactly where its counter pair predicts (once per dict-resolved
    row group), and its wall effect there sat inside the null of the inert
    (cell x lever) pairs of the same run. What it deletes — one
    `Column.from_primitive` memcpy per dict-resolved chunk — is evidently
    absorbed: the resolve loop has just written that buffer, so the copy's
    READ is a cache hit on the same core.

    A relaxed atomic load, so this is safe to call per column chunk."""
    # SAFETY: see `incr_dict_resolve_move`.
    return _G_DICT_MOVE.get_or_create_ptr()[][].load() == _GATE_ON


@always_inline
def proj_share_enabled() raises -> Bool:
    """The projection-share gate, DEFAULT ON. `set_proj_share_enabled(False)`
    is the kill switch and the A/B arm.

    Promoted on the one cell where it arms, where it measured faster in every
    round, while moving none of the cells where it never arms. `proj-COPY` is
    the count of (row group x projected column) late-mat merge rebuilds, so
    reach is a property of the PLAN (`surviving == total` on a multi-column
    projection), not of the fixture."""
    # SAFETY: see `incr_dict_resolve_move`.
    return _G_PROJ_SHARE.get_or_create_ptr()[][].load() != _GATE_OFF


@always_inline
def scan_copy_trace_enabled() raises -> Bool:
    """Print the per-site counts at scan teardown (`scan_copy_trace_dump`).
    DEFAULT OFF."""
    # SAFETY: see `incr_dict_resolve_move`.
    return _G_TRACE.get_or_create_ptr()[][].load() == _GATE_ON


@always_inline
def bss_decode_into_enabled() raises -> Bool:
    """The BYTE_STREAM_SPLIT decode-into gate, DEFAULT ON.
    `set_bss_decode_into_enabled(False)` is the kill switch and the A/B arm.

    THE SITE. The BYTE_STREAM_SPLIT arm of the column decode either decodes a
    page into a fresh array and then copies it WHOLESALE into the chunk
    buffer (allocate -> transpose -> copy -> free, once per PAGE), or (ON)
    transposes straight into the chunk buffer through
    `decode_byte_stream_split_float{32,64}_into`. Promoted on per-cell
    evidence: every cell the lever reaches got faster, value-identical, with
    no new regression."""
    # SAFETY: see `incr_dict_resolve_move`.
    return _G_BSS_INTO.get_or_create_ptr()[][].load() != _GATE_OFF


@always_inline
def string_share_enabled() raises -> Bool:
    """The string-share gate, DEFAULT ON. `set_string_share_enabled(False)` is
    the kill switch and the A/B arm.

    THE SITE. The BYTE_ARRAY fallback assembly of the column decode builds its
    whole-chunk `StringArray` fresh and then hands it to its `Column`:
    `Column.from_string` DEEP-COPIES both buffers, `Column.from_string_shared`
    (ON) Arc-shares them. The whole-chunk string payload is usually too large
    to still be cache-resident when the copy reads it, so the copy costs a
    full read and write round trip of the payload."""
    # SAFETY: see `incr_dict_resolve_move`.
    return _G_STR_SHARE.get_or_create_ptr()[][].load() != _GATE_OFF


@always_inline
def plain_ba_fused_enabled() raises -> Bool:
    """The fused PLAIN BYTE_ARRAY gate, DEFAULT ON.
    `set_plain_ba_fused_enabled(False)` is the kill switch, the A/B arm and
    the byte-equivalence oracle.

    Promoted on the cells where it arms, with `plain-ba-slack` reading
    EXACTLY 0 over every real page: the bound is exact on every page the
    corpus emits, so the fused arm allocates nothing the two-pass arm did
    not. A relaxed atomic load per PLAIN BYTE_ARRAY page."""
    # SAFETY: see `incr_dict_resolve_move`.
    return _G_PLAIN_BA_FUSED.get_or_create_ptr()[][].load() != _GATE_OFF


@always_inline
def string_page_move_enabled() raises -> Bool:
    """The string page-move gate, DEFAULT ON.
    `set_string_page_move_enabled(False)` is the kill switch, the A/B arm and
    the byte-equivalence oracle.

    THE SITE. The concat of a chunk's decoded string pages allocates two
    fresh buffers and copies every page into them. ON A SINGLE-PAGE CHUNK
    THAT PRODUCES A BYTE-IDENTICAL COPY OF ITS ONLY INPUT AND FREES THE
    ORIGINAL; ON, the page is returned instead. A page carrying a validity
    bitmap is declined (see the header)."""
    # SAFETY: see `incr_dict_resolve_move`.
    return _G_STR_PAGE_MOVE.get_or_create_ptr()[][].load() != _GATE_OFF


def set_dict_resolve_move_enabled(on: Bool) raises:
    """Turn the dict-resolve move gate on (share) or off (copy) for the
    process. A program maps its own flag to this setter."""
    # SAFETY: see `incr_dict_resolve_move`.
    _G_DICT_MOVE.get_or_create_ptr()[][].store(_GATE_ON if on else _GATE_OFF)


def set_proj_share_enabled(on: Bool) raises:
    """Turn the projection-share gate on (share) or off (copy) for the
    process."""
    # SAFETY: see `incr_dict_resolve_move`.
    _G_PROJ_SHARE.get_or_create_ptr()[][].store(_GATE_ON if on else _GATE_OFF)


def set_scan_copy_trace_enabled(on: Bool) raises:
    """Turn the trace line of `scan_copy_trace_dump` on or off."""
    # SAFETY: see `incr_dict_resolve_move`.
    _G_TRACE.get_or_create_ptr()[][].store(_GATE_ON if on else _GATE_OFF)


def set_bss_decode_into_enabled(on: Bool) raises:
    """Turn the decode-into gate on (decode into) or off (decode, then copy)."""
    # SAFETY: see `incr_dict_resolve_move`.
    _G_BSS_INTO.get_or_create_ptr()[][].store(_GATE_ON if on else _GATE_OFF)


def set_string_share_enabled(on: Bool) raises:
    """Turn the string-share gate on (share) or off (copy)."""
    # SAFETY: see `incr_dict_resolve_move`.
    _G_STR_SHARE.get_or_create_ptr()[][].store(_GATE_ON if on else _GATE_OFF)


def set_plain_ba_fused_enabled(on: Bool) raises:
    """Turn the fused-walk gate on (one walk) or off (two walks).

    A byte-equivalence test decodes the SAME page twice in ONE process with
    the arm flipped in between."""
    # SAFETY: see `incr_dict_resolve_move`.
    _G_PLAIN_BA_FUSED.get_or_create_ptr()[][].store(
        _GATE_ON if on else _GATE_OFF
    )


def set_string_page_move_enabled(on: Bool) raises:
    """Turn the page-move gate on (move the page) or off (concat)."""
    # SAFETY: see `incr_dict_resolve_move`.
    _G_STR_PAGE_MOVE.get_or_create_ptr()[][].store(
        _GATE_ON if on else _GATE_OFF
    )


def reset_scan_copy_gates() raises:
    """Drop every gate, and the readahead mode, back to its default, as if no
    setter had run."""
    # SAFETY: see `incr_dict_resolve_move`.
    _G_DICT_MOVE.get_or_create_ptr()[][].store(_GATE_UNRESOLVED)
    _G_PROJ_SHARE.get_or_create_ptr()[][].store(_GATE_UNRESOLVED)
    _G_TRACE.get_or_create_ptr()[][].store(_GATE_UNRESOLVED)
    _G_BSS_INTO.get_or_create_ptr()[][].store(_GATE_UNRESOLVED)
    _G_STR_SHARE.get_or_create_ptr()[][].store(_GATE_UNRESOLVED)
    _G_PLAIN_BA_FUSED.get_or_create_ptr()[][].store(_GATE_UNRESOLVED)
    _G_STR_PAGE_MOVE.get_or_create_ptr()[][].store(_GATE_UNRESOLVED)
    _G_PREFETCH_PROJ.get_or_create_ptr()[][].store(_GATE_UNRESOLVED)


# -----------------------------------------------------------------------------
# The readahead mode, and the trace line.
# -----------------------------------------------------------------------------


comptime PREFETCH_MODE_LEGACY = 0
"""`columns[0]` of the next row group, whatever the query reads."""
comptime PREFETCH_MODE_PROJ = 1
"""The scan's projected column indices."""
comptime PREFETCH_MODE_NONE = 2
"""No readahead hint at all. **THE DEFAULT.**"""


@always_inline
def prefetch_mode() raises -> Int:
    """The next-row-group readahead hint: one of three arms, on ONE binary.
    **DEFAULT `PREFETCH_MODE_NONE`.** Set with `set_prefetch_mode`.

        PREFETCH_MODE_LEGACY  advise `next_rg.columns[0]`
        PREFETCH_MODE_PROJ    advise the scan's projected column chunks
        PREFETCH_MODE_NONE    advise nothing               (DEFAULT)

    ⭐⭐ WHY THE DEFAULT IS NONE, AND WHY PROJ IS NOT THE FIX IT LOOKS LIKE.
    The hint is `madvise(MADV_WILLNEED)`, which POPULATES PAGE TABLES — on a
    warm page cache it performs NO I/O and its entire cost is soft faults.
    Advising `columns[0]` charges a column the query may never read; advising
    the projection can be WORSE, because a scan's projection can be far wider
    than its decode set (a filter that prunes most row groups still projects
    every column). Measured on a selective filter cell, both non-NONE arms
    advised three to four orders of magnitude more bytes than the cell
    decodes. That is the whole reason this gate has three arms and not two: a
    two-arm A/B would have measured PROJ against LEGACY, found a regression,
    and concluded the defect was load-bearing.

    ⚠ THE HINT'S VALUE IS COLD-CACHE ONLY. Nothing here establishes that
    readahead is worthless on a cold file — it establishes that on a
    page-cache-warm scan it is pure page-table population. LEGACY and PROJ
    are kept reachable for a cold-cache measurement."""
    # SAFETY: see `incr_dict_resolve_move`.
    var p = _G_PREFETCH_PROJ.get_or_create_ptr()
    var cur = p[][].load()
    if cur != 0:
        return Int(cur) - 1
    return PREFETCH_MODE_NONE


def set_prefetch_mode(mode: Int) raises:
    """Set the readahead mode for the process to one of the three
    `PREFETCH_MODE_*` values. A program maps its own flag to this setter.

    Raises:
        Error if `mode` is not one of the three modes.
    """
    if mode != PREFETCH_MODE_LEGACY and mode != PREFETCH_MODE_PROJ and mode != PREFETCH_MODE_NONE:
        raise Error("parquet: unknown readahead mode " + String(mode))
    # SAFETY: see `incr_dict_resolve_move`.
    _G_PREFETCH_PROJ.get_or_create_ptr()[][].store(Scalar[DType.int64](mode + 1))


def scan_copy_trace_dump(site: StaticString) raises:
    """Print the per-site fire counts when the trace is on
    (`set_scan_copy_trace_enabled(True)`).

    Counts are process-CUMULATIVE and monotone, so with several scans (or
    several bench reps) per process the LAST line is the total. `site` names the
    teardown that emitted the line so multiple emitters stay distinguishable.

    ★ EMITTERS. The scan package calls this at the single last return of
    every driver that can reach a gated arm: the collect funnel, the
    scan-fused join funnel, the sub-row-group aggregate route and the
    streaming aggregate route. An arm reachable from a driver with no dump
    here is an arm whose A/B cannot be read (see the file header).
    """
    if not scan_copy_trace_enabled():
        return
    print(
        "[scan-copy] at=", site,
        " dict-resolve-move=", dict_resolve_move_count(),
        " dict-resolve-COPY=", dict_resolve_copy_count(),
        " proj-share=", proj_share_count(),
        " proj-COPY=", proj_copy_count(),
        " proj-COPY-other=", proj_copy_other_count(),
        " bss-into=", bss_decode_into_count(),
        " bss-COPY=", bss_decode_copy_count(),
        " string-share=", string_share_count(),
        " string-COPY=", string_copy_count(),
        " plain-ba-fused=", plain_ba_fused_count(),
        " plain-ba-2PASS=", plain_ba_two_pass_count(),
        " plain-ba-slack=", plain_ba_slack_bytes(),
        " plain-ba-fused-alloc=", plain_ba_fused_alloc_bytes(),
        " string-page-move=", string_page_move_count(),
        " string-page-CONCAT=", string_page_concat_count(),
        " prefetch-calls=", prefetch_advise_calls(),
        " prefetch-bytes=", prefetch_advise_bytes(),
        " | gates: dict_resolve_move=", dict_resolve_move_enabled(),
        " proj_share=", proj_share_enabled(),
        " bss_decode_into=", bss_decode_into_enabled(),
        " string_share=", string_share_enabled(),
        " plain_ba_fused=", plain_ba_fused_enabled(),
        " string_page_move=", string_page_move_enabled(),
        " prefetch_mode=", prefetch_mode(),
        sep="",
    )
    # The decode arms (`decode_arm_trace.mojo`) and the payload-selection and
    # staged-filter counters are printed from the SAME emitters deliberately:
    # their arms sit in decoders and scan stages that every driver reaches,
    # and reusing a dump already wired to every driver is what keeps an arm
    # from going unread. `hit=0 DECLINE=0 SKIP=0` means this route never
    # reached the payload-decode site at all — a WRONG ARM MAP, not a null.
    # `rows-sel` / `rows-full` is the byte claim: the values the selected arm
    # materialised against the values the full decode would have, over the
    # SAME row groups.
    print(
        "[payload-sel] at=", site,
        " hit=", payload_sel_hit_count(),
        " DECLINE=", payload_sel_decline_count(),
        " SKIP=", payload_sel_skip_count(),
        " policy_skip=", payload_sel_policy_skip_count(),
        " rows-sel=", payload_sel_rows_decoded(),
        " rows-full=", payload_sel_rows_total(),
        " | gate: payload_sel_mode=", payload_sel_decode_mode(),
        sep="",
    )
    # The staged filter decode: see `staged_filter_trace.mojo` for what each
    # count means. `rg=0` on a cell you expected to arm is a wrong arm map or
    # an ineligible predicate, not a null.
    print(
        "[staged-filter] at=", site,
        " rg=", staged_filter_rg_count(),
        " DECLINED=", staged_filter_declined_count(),
        " sel=", staged_filter_sel_count(),
        " GATHER=", staged_filter_gather_count(),
        " rows-sel=", staged_filter_rows_sel(),
        " rows-full=", staged_filter_rows_full(),
        " | gate: staged_filter=", staged_filter_enabled(),
        sep="",
    )
    print(
        "[decode-arm] at=", site,
        " delta-page-memcpy=", delta_page_memcpy_count(),
        " delta-page-BYTECOPY=", delta_page_bytecopy_count(),
        " dict-resolve-fused=", dict_resolve_fused_count(),
        " dict-resolve-LEGACY=", dict_resolve_legacy_count(),
        " flat-gather-fused=", flat_gather_fused_count(),
        " flat-gather-LEGACY=", flat_gather_legacy_count(),
        " dict-string-share=", dict_string_share_count(),
        " dict-string-COPY=", dict_string_copy_count(),
        " | gates: delta_page_memcpy=", delta_page_memcpy_enabled(),
        " dict_resolve_fused=", dict_resolve_fused_enabled(),
        " dict_string_share=", dict_string_share_enabled(),
        sep="",
    )

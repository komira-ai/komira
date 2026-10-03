# =============================================================================
# join_key_cse — the JOIN-KEY common-subexpression elimination for the
# probe-then-build FULL join output
# =============================================================================
#
# WHAT IS DUPLICATED, AND WHY IT IS PROVABLE
# ------------------------------------------
# `SELECT l.skey, l.left_val, r.skey AS skey_right, r.right_val
#    FROM l INNER JOIN r ON l.skey = r.skey`
#
# On every emitted row, `l.skey` and `r.skey` hold the SAME VALUE — that is what
# the join condition means. We nonetheless gather both: two independent random-
# access gathers over the same logical bytes, two output buffers, two sets of
# first-touch page faults.
#
# For a wide string key the second gather materialises gigabytes that are a
# byte-for-byte duplicate of the first.
#
# THIS FILE IS THE PROOF OBLIGATION, NOT THE GATHER
# -------------------------------------------------
# `assemble_join_result_dispatch` cannot decide this: it sees two batches, two
# index lists and an output schema, and NOT the join condition. The JOIN LEAF
# knows the join type and the positional key pairing, so the leaf computes the
# alias map and the assemble merely EXECUTES it. Everything that can make the
# claim false is checked here, once per join, and every decline is counted.
#
# ⛔ WHERE THE CLAIM IS FALSE — the decline conditions, each with its reason:
#
#   * NON-INNER (LEFT / RIGHT / FULL / SEMI / ANTI). An outer join emits NULL on
#     the non-matching side, so the two columns differ exactly on the rows that
#     make an outer join an outer join. `join_key_cse_aliases` takes the join
#     type and refuses anything but INNER.
#   * A PROJECTED output (`output_cols is Some`). The alias map is expressed in
#     SOURCE column indices and is only meaningful when the assemble emits every
#     probe column in schema order followed by every build column — the full
#     `[probe..., build...]` shape. The projected assemble is a different
#     function and is not wired.
#   * TYPE MISMATCH. If the two key columns have different `arrow_type`, the
#     join compares after a widening/decode and the OUTPUT REPRESENTATIONS can
#     differ even where the values compare equal. Requires `arrow_type` equality.
#   * FLOAT / DECIMAL / DICTIONARY / NESTED / BOOL. Only STRING, BINARY and the
#     fixed-width INTEGER types are admitted, because those are the ones for
#     which "compares equal" and "is the same bytes" coincide:
#       - FLOAT: the key extract canonicalises for hashing
#         (`_canonicalize_float64_for_hash`, `_NAN_SENTINEL_BITS`), so `-0.0`
#         can match `0.0` and one NaN payload can match another. Equal keys,
#         DIFFERENT bytes.
#       - DECIMAL: `arrow_type` equality does not pin `(precision, scale)`.
#       - DICTIONARY: two sides can carry different dictionaries whose decoded
#         values agree; the physical columns then differ.
#       - NESTED / BOOL: bit-packing and child-offset composition are not worth
#         the argument for a key type nothing joins on.
#   * NULLS. `NULL = NULL` is false in SQL and an INNER join emits no row where
#     either key is NULL — but that is a property of the KERNEL, not of this
#     file, so it is not assumed. Both key columns must be provably null-free:
#     no validity bitmap at all, OR a bitmap with `null_count == 0`. AND the two
#     sides must AGREE on whether a bitmap is present, because the gather emits
#     a bitmap iff its source has one and the shared column must carry the same
#     physical shape the gather would have produced.
#   * COLLATION. Not a decline condition but a stated dependency: STRING
#     equality on this path is BYTE equality. `MultiKeyHashJoinBuilder`'s chain
#     walk re-checks every candidate with a byte compare over the decoded
#     `StringArray` (`_build_string_keys[k]`), and the same-dictionary fast path
#     compares Int32 dict indices INTO ONE dictionary. There is no collation
#     layer anywhere on this path. If one is ever added, this file must gate on
#     it.
#
# WHERE THE MAP IS BUILT -- the composite-key INNER join leaves of the engine
# dispatch package that emit the canonical `[probe..., build...]` FULL shape
# (`materialize_composite_join_over_batches` and its chunked twin). The
# PROJECTED arm of either leaf is never handed the map; see the index-space
# warning on `join_key_cse_aliases`.
#
# ⚠ THE COUNTERS ARE THE FALSIFIER, NOT THE VALUES. A correct CSE is INVISIBLE
# in the output: every row of every column is unchanged, so no value assertion
# anywhere can see the lever stop applying. `join_key_cse_shared_columns()` and
# `join_key_cse_shared_bytes()` are what a test asserts EXACT values on.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import OwnedPointer, UnsafePointer, alloc

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.schema import RecordBatch, Schema
from komira_buffer.heap_region import HeapRegion
from komira_plan_ir.logical_plan import JOIN_INNER


# =============================================================================
# The PROVEN map — a type, not a `List[Int]`
# =============================================================================


struct JoinKeyAliasMap(Movable, Sized):
    """A build-side output alias map that has been PROVED by
    `join_key_cse_aliases`.

    ⛔ WHY THIS IS A TYPE AND NOT A `List[Int]`. Every entry is a CLAIM that two
    output columns are byte-identical on every emitted row, and the claim rests
    entirely on the join being an equi-join on THESE key pairs. But
    `assemble_join_result` — the frame that EXECUTES the map — is shared with
    kernels for which that premise is false by construction:

      * `komira_engine_operators.asof_join_sink` — an INEQUALITY join. The matched build row is
        the nearest one at or before the probe timestamp, so probe key != build
        key is the NORMAL case, not an edge case.
      * `komira_engine_operators.cross_join_kernel` — NO join condition at all. Every probe row is
        paired with every build row; there is no column pair to alias.

    As a bare `Optional[List[Int]]` nothing in the type system would
    distinguish a proven map from an arbitrary list of integers, so either of
    those call sites could hand one in — accidentally or by a plausible-looking
    refactor — and the assemble's `cse_on` would evaluate True for a
    non-equi-join. That is a SILENT WRONG ANSWER: the row count does not move
    and every emitted value is a real value from a real column, just the wrong
    one. Making the map a distinct type means a caller cannot reach that state
    without deliberately naming the private constructor.

    ⚠ THE CONSTRUCTOR IS KEYWORD-ONLY AND UNDERSCORED ON PURPOSE. Mojo has no
    visibility modifiers, so `_proven` is the strongest available statement of
    "the only legitimate producer is `join_key_cse_aliases`, in this file".
    The join-probe key-CSE test names it once, deliberately, to falsify
    the execution-frame guard with a well-formed map — the one case where
    fabricating a map IS the test.

    ⚠ MOVABLE, NOT COPYABLE. There is no reason to duplicate a map, and a
    silent copy on a per-morsel path is exactly the kind of cost that hides
    under a detection floor.

    THE INDEX SPACE (unchanged): element `c` indexes the BUILD batch's columns
    and its value is the PROBE column index that build column `c` duplicates on
    every emitted row, or `-1`. Length is `build_batch.num_columns()` for a
    non-empty map, and `0` when nothing is shareable."""

    var _aliases: List[Int]

    def __init__(out self, *, var _proven: List[Int]):
        """⛔ PRIVATE. `join_key_cse_aliases` is the only legitimate caller; see
        the struct docstring. Naming this from a kernel that is not an INNER
        equi-join is the defect this type exists to make unstateable."""
        self._aliases = _proven^

    @always_inline
    def __len__(self) -> Int:
        """Number of BUILD columns the map covers. `0` means "nothing is
        shareable": every column is gathered."""
        return len(self._aliases)

    @always_inline
    def alias_of(self, build_col: Int) -> Int:
        """The PROBE column index build column `build_col` duplicates, or `-1`.

        TOTAL, not raising: an out-of-range column reads `-1` (= "gather it"),
        so a schema/map length disagreement degrades to the plain gather rather
        than to an exception on a hot path. The bounds check belongs with the
        data, not at the assemble's call site."""
        if build_col < 0 or build_col >= len(self._aliases):
            return -1
        return self._aliases[build_col]


# =============================================================================
# The eligibility predicate
# =============================================================================


@always_inline
def _cse_admits_type(at: ArrowType) -> Bool:
    """True iff "the two key columns compared equal" implies "the two key
    columns hold the same BYTES" for this Arrow type.

    STRING / BINARY: the probe's equality re-check is a byte compare over the
    decoded arrays, so equal implies byte-equal by construction.

    Fixed-width INTEGERS: the key extract widens to Int64 and the chain walk
    compares those Int64s; for a given width+signedness that map is injective,
    so equal implies byte-equal.

    Everything else is refused — see the file header for the per-type reason."""
    return (
        at == ArrowType.STRING
        or at == ArrowType.BINARY
        or at == ArrowType.INT8
        or at == ArrowType.INT16
        or at == ArrowType.INT32
        or at == ArrowType.INT64
        or at == ArrowType.UINT8
        or at == ArrowType.UINT16
        or at == ArrowType.UINT32
        or at == ArrowType.UINT64
    )


@always_inline
def _cse_null_free(imm col: Column[HeapRegion]) -> Bool:
    """True iff this column provably holds no NULLs.

    No bitmap at all is the strong case. A bitmap with `null_count == 0` is
    admitted too: `Column._null_count` is maintained by every constructor on
    this path (the gather recomputes it, `share()` and `deep_copy()` carry it,
    the sliced window recomputes it from a popcount) and is never a
    "-1 = unknown" sentinel."""
    if not col._validity:
        return True
    return col._null_count == 0


@always_inline
def _cse_col_index(imm schema: Schema, imm name: String) -> Int:
    """Index of `name` in `schema`, or -1 when absent.

    `Schema.column_index` RAISES on absence; a missing key name is not this
    file's error to raise (the join kernel raises on it long before), so this
    returns a sentinel and the caller declines."""
    for i in range(schema.num_columns()):
        if schema.field_name(i) == name:
            return i
    return -1


def join_key_cse_aliases(
    imm probe_batch: RecordBatch,
    imm build_batch: RecordBatch,
    left_keys: List[String],
    right_keys: List[String],
    join_type: UInt8,
) raises -> JoinKeyAliasMap:
    """Compute the BUILD-side output alias map for a probe-then-build FULL
    join output.

    ★ THIS IS THE ONLY PRODUCER OF A `JoinKeyAliasMap`. The return type is a
    distinct type rather than a `List[Int]` precisely so that "a map exists"
    and "a map was proved here" are the same statement — see the type's
    docstring for the two non-equi-join kernels that share the assemble frame
    and must never be able to construct one.

    Args:
        probe_batch: The LEFT/probe batch, whose columns are emitted first and
            in schema order.
        build_batch: The RIGHT/build batch, whose columns are emitted after.
        left_keys: Probe-side key column NAMES, in declared order.
        right_keys: Build-side key column names; pairs POSITIONALLY with
            `left_keys` (the composite hash mixes keys positionally, so this
            pairing is the join's own).
        join_type: One of the `JOIN_*` constants. Anything but `JOIN_INNER`
            returns an empty map.

    Returns:
        A `JoinKeyAliasMap` of length 0 when nothing is shareable — the caller
        then gathers every column. Otherwise one
        of length `build_batch.num_columns()` whose element `c` is the PROBE
        column index that build column `c` duplicates on every emitted row, or
        `-1`.

    ⚠ THE INDEX SPACE. Element `c` indexes `build_batch`'s columns and its value
    indexes `probe_batch`'s columns. It is only meaningful for an assemble that
    emits probe column `i` at output position `i` — i.e. the full
    `[probe..., build...]` output. A projected assemble must not be handed this.

    ⚠ NOT A HINT. Every entry is a claim that two output columns are
    byte-identical. Everything that can make that false is checked here; see the
    file header for the list and the reason for each."""
    if join_type != JOIN_INNER:
        _cse_note_decline()
        return JoinKeyAliasMap(_proven=List[Int]())
    var n_keys = len(left_keys)
    if n_keys == 0 or len(right_keys) != n_keys:
        _cse_note_decline()
        return JoinKeyAliasMap(_proven=List[Int]())
    var n_build_cols = build_batch.num_columns()
    var aliases = List[Int](capacity=n_build_cols)
    for _ in range(n_build_cols):
        aliases.append(-1)

    var any = False
    for k in range(n_keys):
        # A key name that is not a column of its own side is not this file's
        # error to raise — the join kernel will have raised long before. Skip.
        var l_idx = _cse_col_index(probe_batch.schema, left_keys[k])
        var r_idx = _cse_col_index(build_batch.schema, right_keys[k])
        if r_idx < 0 or r_idx >= n_build_cols:
            _cse_note_decline()
            continue
        if l_idx < 0 or l_idx >= probe_batch.num_columns():
            _cse_note_decline()
            continue

        ref lc = probe_batch.column_at(l_idx)
        ref rc = build_batch.column_at(r_idx)
        if lc.arrow_type != rc.arrow_type:
            _cse_note_decline()
            continue
        if not _cse_admits_type(lc.arrow_type):
            _cse_note_decline()
            continue
        # PHYSICAL SHAPE. The gather emits a validity bitmap iff its source has
        # one, so the shared column must come from a source with the SAME
        # disposition or the two output columns would differ physically even
        # though every value agrees.
        if lc._validity.__bool__() != rc._validity.__bool__():
            _cse_note_decline()
            continue
        if not _cse_null_free(lc) or not _cse_null_free(rc):
            _cse_note_decline()
            continue

        aliases[r_idx] = l_idx
        any = True

    if not any:
        return JoinKeyAliasMap(_proven=List[Int]())
    return JoinKeyAliasMap(_proven=aliases^)


# =============================================================================
# The counters — the STRUCTURAL falsifier
# =============================================================================
#
# Same `_Global` + `Atomic` idiom as `join_index_window_counter.mojo`:
# no environment read, no `unsafe_from_address` laundering, no wildcard-origin
# field.
#
#   * `shared_columns` — output columns emitted by SHARING instead of gathering.
#     Zero for every query whose shape is ineligible. The lever's fire
#     count.
#   * `shared_bytes`   — the DATA bytes those shares did not materialise, read
#     off the shared column's own data buffer. This is the quantity the lever
#     exists to remove, and it is measured from the column that was actually
#     emitted rather than predicted from a row count.
#   * `gathered_columns` — output columns emitted by GATHERING. The denominator;
#     it makes `shared + gathered == columns emitted` a conservation check a
#     test can assert, so a share that also gathers (or a gather that is skipped
#     without a share) is visible.
#   * `declines`       — eligibility checks that refused. A non-zero value with
#     zero shares says the shape was seen and rejected, which is a different
#     fact from "the code never ran".
# =============================================================================


def _init_jkc_shared_cols() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn: allocate the SHARED-COLUMNS counter once per process.
    """
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


def _init_jkc_shared_bytes() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn: allocate the SHARED-BYTES counter once per process."""
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


def _init_jkc_gathered_cols() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn: allocate the GATHERED-COLUMNS counter once."""
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


def _init_jkc_declines() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn: allocate the DECLINES counter once per process."""
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _JKC_SHARED_COLS = _Global[
    "komira_core_join_key_cse_shared_cols", _init_jkc_shared_cols
]
comptime _JKC_SHARED_BYTES = _Global[
    "komira_core_join_key_cse_shared_bytes", _init_jkc_shared_bytes
]
comptime _JKC_GATHERED_COLS = _Global[
    "komira_core_join_key_cse_gathered_cols", _init_jkc_gathered_cols
]
comptime _JKC_DECLINES = _Global[
    "komira_core_join_key_cse_declines", _init_jkc_declines
]


@always_inline
def join_key_cse_note_shares(columns: Int, data_bytes: Int) raises:
    """Record an ASSEMBLE's output columns emitted by SHARING, and the data
    bytes those shares did not materialise.

    ⚠ TAKES A BATCH, NOT ONE COLUMN, ON PURPOSE. The caller accumulates in
    locals and flushes once, so the cost is TWO relaxed `fetch_add`s per
    assemble rather than two per COLUMN. A join assembles once per morsel, so
    a per-column atomic multiplies into tens of thousands of increments per
    query -- a cost small enough to hide under a timing noise floor, which is
    exactly why it is avoided by construction rather than by measurement."""
    # SAFETY: FFI carve-out — `get_or_create_ptr` targets KGEN-runtime static
    # storage (process-lifetime); the wildcard is the stdlib `_Global` API's own
    # return type, confined to this helper.
    var gc = _JKC_SHARED_COLS.get_or_create_ptr()
    _ = gc[][].fetch_add(Int64(columns))
    var gb = _JKC_SHARED_BYTES.get_or_create_ptr()
    _ = gb[][].fetch_add(Int64(data_bytes))


@always_inline
def join_key_cse_note_gathers(columns: Int) raises:
    """Record an ASSEMBLE's output columns emitted by GATHERING (the
    denominator). Batched for the reason in `join_key_cse_note_shares`."""
    # SAFETY: FFI carve-out (see `join_key_cse_note_shares`).
    var gg = _JKC_GATHERED_COLS.get_or_create_ptr()
    _ = gg[][].fetch_add(Int64(columns))


@always_inline
def _cse_note_decline() raises:
    """Record ONE eligibility refusal."""
    # SAFETY: FFI carve-out (see `join_key_cse_note_shares`).
    var gd = _JKC_DECLINES.get_or_create_ptr()
    _ = gd[][].fetch_add(Int64(1))


def join_key_cse_shared_columns() raises -> Int:
    """Output columns emitted by SHARING since the last reset."""
    # SAFETY: FFI carve-out (see `join_key_cse_note_shares`).
    var gc = _JKC_SHARED_COLS.get_or_create_ptr()
    return Int(gc[][].load())


def join_key_cse_shared_bytes() raises -> Int:
    """Data bytes the shares did NOT materialise, summed."""
    # SAFETY: FFI carve-out (see `join_key_cse_note_shares`).
    var gb = _JKC_SHARED_BYTES.get_or_create_ptr()
    return Int(gb[][].load())


def join_key_cse_gathered_columns() raises -> Int:
    """Output columns emitted by GATHERING since the last reset."""
    # SAFETY: FFI carve-out (see `join_key_cse_note_shares`).
    var gg = _JKC_GATHERED_COLS.get_or_create_ptr()
    return Int(gg[][].load())


def join_key_cse_declines() raises -> Int:
    """Eligibility checks that REFUSED since the last reset."""
    # SAFETY: FFI carve-out (see `join_key_cse_note_shares`).
    var gd = _JKC_DECLINES.get_or_create_ptr()
    return Int(gd[][].load())


def reset_join_key_cse_counters() raises:
    """Reset all four process-wide counters to 0 (test setup)."""
    # SAFETY: FFI carve-out (see `join_key_cse_note_shares`).
    var gc = _JKC_SHARED_COLS.get_or_create_ptr()
    gc[][].store(Scalar[DType.int64](0))
    var gb = _JKC_SHARED_BYTES.get_or_create_ptr()
    gb[][].store(Scalar[DType.int64](0))
    var gg = _JKC_GATHERED_COLS.get_or_create_ptr()
    gg[][].store(Scalar[DType.int64](0))
    var gd = _JKC_DECLINES.get_or_create_ptr()
    gd[][].store(Scalar[DType.int64](0))

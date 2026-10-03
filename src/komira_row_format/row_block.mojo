# =============================================================================
# row_block.mojo — slow-path packed-row primitive
# =============================================================================
#
# The full encoder/decoder method set on RowBlock, with a SIMD-load /
# per-lane-store recipe for the fast DType subset (I64 / F64 / I32 / F32 /
# I16 / I8 / U8) and a scalar body for the smaller, lower-traffic widths.
#
# Layout:
#   RowBlock      — packed-row storage primitive (OwnedAlignedBuffer-backed
#                   fixed cells + OwnedAlignedBuffer-backed var blob).
#   RowLayout     — per-segment runtime descriptor (ColDescriptor list +
#                   stride + validity_offset + var_offsets_table).
#                   Held under Optional[OwnedPointer[RowLayout]] (NOT inlined
#                   by value into Row*State structs).
#   ColDescriptor — TrivialRegisterPassable per-column kind/dtype/width/
#                   offset metadata.
#   RowHashAggTable — slow arm of `_HashAggVariant`; agg-major upsert
#                     skeleton (the aggregate-op ladder is evaluated once per
#                     op per batch, not once per row).
#
# Encapsulation invariants:
#   * Zero UnsafePointer in any public signature on RowBlock — origin-poly
#     `_row_base_ptr_mut[o]` / `_row_base_ptr_ro[_mut, o]` accessors are
#     PRIVATE (leading underscore + file-internal).
#   * Zero wildcard origin (no MutExternalOrigin / MutAnyOrigin / ...).
#   * Zero unsafe_from_address.
#   * Zero ArcPointer (parallelize is fork-join synchronous; per-segment
#     state under a single OwnedPointer suffices).
#   * Per-DType encoder/decoder methods are METHODS on RowBlock, NOT free
#     functions accepting raw pointers.
#   * RowLayout is held in a separate Optional[OwnedPointer[RowLayout]]
#     slot and passed into hot methods via `ref [lo] RowLayout`.
#
# Encoder shape: for I64/F64/I32/F32 the `write_fixed_dt_batch` body is
# "SIMD-LOAD W lanes per chunk + `comptime for lane in range(W)` per-lane
# stride STORE" (LLVM cannot synthesize a SIMD scatter over a runtime stride).
# =============================================================================

from std.sys import size_of
from std.utils import Variant
from std.memory import bitcast

from komira_core.instr.keyeq_census import keyeq_record, KEYEQ_ROWBLOCK_MEMCMP
from komira_core.simd.byte_class.byte_equal import bytes_equal
from komira_core.arrow.owned_aligned_buffer import OwnedAlignedBuffer
from komira_core.arrow.shared_aligned_buffer import SharedAlignedBuffer
from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_core.arrow.string_builder import ArrowStringBuilder
from komira_core.arrow.schema import Field, Schema, SchemaBuilder
from komira_core.collections.batch_view import (
    BatchView, BoolColView, ColView, Decimal128CellView,
)
from komira_core.collections.byte_view import ByteView
from komira_core.io.heap_region import HeapRegion
from komira_core.collections.string_column_view import (
    BinaryColumnView,
    StringColumnView,
)
from komira_core.eval.float_quotient_order import (
    canonical_bits_f64,
    canonicalize_f32,
)


# -----------------------------------------------------------------------------
# Column-kind constants
# -----------------------------------------------------------------------------
# Kept as `UInt8` value constants on the @register_passable trivial
# ColDescriptor. Runtime-N column dispatch ladders branch on these.
# Adding a new var-kind (e.g. COL_LIST / COL_STRUCT) is a 1-line addition
# here + 1 new method on RowBlock.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# ⭐ The ROW-FORMAT twin of the check in
# `komira_engine_operators.column_format_storage`. Read that file's
# `VAR_DESC_OFFSET_MAX` block first; the mechanism, the failure mode and the
# reason the refusal lives in `reserve_var_bytes` are stated there once.
#
# In one line: a var-width cell here is the SAME 8-byte descriptor,
# `(length << 32) | (offset & 0xFFFFFFFF)`, over a 64-bit `var_storage_used`
# cursor, so a heap past 4 GiB truncates the recorded offset into a byte range
# that is still INSIDE the live allocation — every bounds check passes and the
# cell names another row's bytes.
#
# ⚠ THE CONSTANT IS DUPLICATED ON PURPOSE, NOT SHARED. `komira_row_format` deps only
# `komira_core`; importing the operators' copy would put
# the engine tower underneath the row format and invert the dependency. Two
# declarations of one number is the lesser defect, and both name the other.
#
# ⚠ REACHABILITY IS NOT "one batch". `RowHashAggTable`'s `rows` is an
# ACCUMULATOR — `komira_engine_dispatch.agg_spill_driver` builds one per
# spill run and `from_spilled_group_rows` reloads a whole image into it — so
# this heap is bounded by the GROUP COUNT of a spilled aggregate, not by a
# morsel.
# -----------------------------------------------------------------------------

comptime VAR_DESC_OFFSET_MAX: Int = 0xFFFFFFFF
"""Largest byte offset (and payload length) a row-format var-width descriptor
cell can represent: 4_294_967_295. UNSIGNED 32 bits.

⛔ NOT `ARROW_INT32_OFFSET_MAX` (2_147_483_647, SIGNED) — different field,
different sign, and that one already has its own guard and its own promotion
path. Twin of `komira_engine_operators.column_format_storage`'s constant of the
same name; keep them equal."""


@no_inline
def _raise_row_var_offset_ceiling(used: Int, additional: Int) raises:
    """Cold: a row-format var-storage append whose resulting cursor would not
    fit the descriptor's 32-bit offset field."""
    raise Error(
        "RowBlock.reserve_var_bytes: append would put the var-storage cursor"
        " at " + String(used + additional) + " bytes, past the "
        + String(VAR_DESC_OFFSET_MAX)
        + "-byte ceiling of the var-width descriptor cell's 32-bit offset"
        " field (used=" + String(used) + ", additional=" + String(additional)
        + "). Refused rather than truncated: a wrapped offset stays inside the"
        " live allocation, so it would silently name ANOTHER ROW'S BYTES"
        " instead of raising."
    )


comptime COL_FIXED: UInt8 = 1
"""Fixed-width column kind (i64 / f64 / i32 / f32 / i16 / i8 / u8 / ...)."""

comptime COL_VAR_STRING: UInt8 = 2
"""Variable-width UTF8 string column kind (offset into RowBlock.var blob)."""

comptime COL_VAR_BINARY: UInt8 = 3
"""Variable-width binary column kind (offset into RowBlock.var blob)."""

comptime COL_DECIMAL128: UInt8 = 4
"""128-bit decimal column kind (modeled as 2× UInt64 cells)."""

comptime COL_LIST: UInt8 = 5
"""Nested LIST column kind (depth-1: LIST<primitive>, LIST<string>,
LIST<STRUCT<flat>>). A var-cell like COL_VAR_STRING: the 8-byte
(var_offset:u32, n_elems:u32) descriptor in the fixed region points at a
LIST payload record in `_var_storage`. NULL list is encoded with
the `_LIST_NULL_SENTINEL` n_elems value; empty list is n_elems==0."""

comptime _LIST_NULL_SENTINEL: Int = 0xFFFFFFFF
"""Sentinel `n_elems` value (u32 max) marking a NULL LIST cell, distinct
from an empty list (n_elems==0). Real lists never reach 2^32-1 elements in
a single row cell (the var-storage offset field is u32-bounded anyway)."""

comptime COL_STRUCT: UInt8 = 6
"""Nested STRUCT<flat> column kind (depth-1). A var-cell whose
(var_offset:u32, length:u32) descriptor points at one self-describing
STRUCT record in `_var_storage`: a struct-null flag byte, a
field-validity sub-bitmap, then each flat field serialized in declared
order (fixed primitive = LE width bytes; var-string = u32 length prefix +
payload). The same record format is the element of a LIST<STRUCT<flat>>."""


comptime COL_FIXED_KEY64: UInt8 = 7
"""CANONICAL 8-BYTE GROUP-KEY cell over a source column that is NOT already 8
exact bytes.

⭐ WHY A KIND AND NOT JUST A DTYPE. `RowHashAggTable` hashes and compares a
group key by the RAW BYTES of the fixed key region (`_hash_row_bytes` /
`_row_bytes_equal`), and `emit_to_record_batch` reads every key cell back
through `read_fixed[int64]`. Both are exactly right for an INT64 key and both
are WRONG for anything narrower or floating: a `write_i32_batch` into an 8-byte
cell leaves 4 bytes of whatever the scratch block last held (so two EQUAL keys
can hash APART), and a raw F64 key splits `+0.0` from `-0.0` and scatters every
NaN into its own group.

A `COL_FIXED_KEY64` descriptor says: the SOURCE column has `dtype_tag`, the CELL
is 8 bytes, and `_dispatch_encode_key_col` writes a CANONICAL INJECTIVE
surrogate into all 8 of them — narrow ints VALUE-widened to Int64, floats
canonicalised (`-0.0 -> +0.0`, every NaN -> the one canonical NaN, the model
`builtin_hash_fns` / DuckDB already use) and then bitcast. Equal values give
equal bytes and unequal values give unequal bytes, so the byte-keyed directory
is CORRECT over them and the CALLER inverts the surrogate on the way out.

⛔ NO PRE-EXISTING LAYOUT USES THIS KIND, so every encode that exists today
moves exactly the bytes it moved before. The producer is
`agg_spill_driver._build_row_layout`; the inverse is
`agg_spill_driver._decode_surrogate_key_column`. Adding one without the other
publishes a surrogate as if it were the value."""


# -----------------------------------------------------------------------------
# DType-tag constants
# -----------------------------------------------------------------------------
# Discriminates fixed-width DTypes inside COL_FIXED. Mirrors
# `komira_expr.runtime_expr_bool`'s `RT_*` tags but covers the
# DType domain (not the Expr-node domain).
# -----------------------------------------------------------------------------

comptime COL_FLAG_KEY_NULLABLE: UInt16 = 1
"""`ColDescriptor.flags` bit: this KEY column's SOURCE SCHEMA declares it
nullable, so its encoder must discriminate NULL from the cell's byte twin
(`''` for a string, `0` for an int). Mirrors the col-untyped
`ColDescriptor.validity_tracked` the spill driver copies it from; see
`ColDescriptor.key_nullable` for why the DECLARED question is the right one."""


comptime DT_I64: UInt8 = 1
comptime DT_F64: UInt8 = 2
comptime DT_I32: UInt8 = 3
comptime DT_F32: UInt8 = 4
comptime DT_I16: UInt8 = 5
comptime DT_I8: UInt8 = 6
comptime DT_U8: UInt8 = 7
comptime DT_STRING: UInt8 = 8
comptime DT_U16: UInt8 = 9
comptime DT_U32: UInt8 = 10
comptime DT_U64: UInt8 = 11
comptime DT_DATE32: UInt8 = 12  # represented as i32 cells under the hood
comptime DT_DECIMAL128: UInt8 = 13  # 16 bytes, modeled as 2× u64 cells
comptime DT_BOOL: UInt8 = 14  # 1 byte per cell (NOT bit-packed in RowBlock)
comptime DT_DATE64: UInt8 = 15  # 8 bytes, represented as i64 cells under the hood
comptime DT_TIMESTAMP_NS: UInt8 = 16  # 8 bytes, i64 storage
comptime DT_TIMESTAMP_US: UInt8 = 17  # 8 bytes, i64 storage
comptime DT_TIMESTAMP_MS: UInt8 = 18  # 8 bytes, i64 storage
comptime DT_TIMESTAMP_S: UInt8 = 19  # 8 bytes, i64 storage
comptime DT_BINARY: UInt8 = 20  # var-width binary (offset into RowBlock.var blob)
# The ColDescriptor.dtype_tag
# value stamped for an in-scope nested column. These map to the COL_LIST /
# COL_STRUCT cell kinds; the FULL element/field type detail (LIST<i64> vs
# LIST<string> vs LIST<STRUCT>, the STRUCT field shape) is NOT representable in
# the single-byte dtype tag and is carried out-of-band (the row-streaming
# segment's nested-col-type sidecar / the col-side runtime ListArray/StructArray
# at gather time). Depth-1 only; MAP + recursion never reach these tags.
comptime DT_LIST: UInt8 = 21  # nested LIST cell (COL_LIST kind, 8-byte descriptor)
comptime DT_STRUCT: UInt8 = 22  # nested STRUCT cell (COL_STRUCT kind, 8-byte desc)


# -----------------------------------------------------------------------------
# THE NULL-DISCRIMINATOR TAG ON A VAR-WIDTH GROUP KEY.
# -----------------------------------------------------------------------------
#
# ⛔ WHY A TAG BYTE EXISTS AT ALL. A var-width key cell is an 8-byte
# (offset, length) descriptor and the directory folds the PAYLOAD, not the cell
# (`_hash_row_bytes` / `_row_bytes_equal`). `StringColumnView.get()` reads
# `offsets[row]..offsets[row+1]` and NEVER consults validity, so a NULL key
# encodes as a ZERO-LENGTH payload — byte-identical to the literal empty string,
# hence the same hash and the SAME GROUP. That is a silently wrong aggregate,
# and it is a DIVERGENCE rather than a gap: the in-memory untyped hash-agg this
# route replaces above `_agg_inmem_max_rows()` gives a NULL key its own group
# (`hash_agg_untyped._hash_single_col`'s `_NULL_KEY_HASH` arm, guarded by
# `desc.validity_tracked`), which is what SQL says and what DuckDB answers. A
# query must not change its answer because it crossed a row-count ceiling.
#
# ⭐ WHY THE DISCRIMINATOR LIVES IN THE PAYLOAD AND NOT IN THE DESCRIPTOR. Every
# primitive between the encode and the drain — `_hash_row_bytes`,
# `_row_bytes_equal`, `copy_var_string_cell`, the spill image, the grace-hash
# repartition's compacted heap — already treats the payload as OPAQUE BYTES and
# is therefore correct for the tagged form with NO CHANGE. A sentinel in the
# descriptor's length field would instead have to be understood by every one of
# them (and by the shared `var_string_span_at` reader), which is five more
# places for a NULL to be read as a 4-billion-byte string.
#
# ⇒ EVERY var-width KEY cell carries exactly one leading tag byte, NULL or not,
# so the encode has one shape and the drain has one strip. It is NOT written by
# the general `write_var_string_batch` / `write_var_string_cell` data-column
# encoders — a KEY is the only cell whose identity has to survive a hash.
comptime _VAR_KEY_TAG_VALUE: UInt8 = 0
"""Leading payload byte of a NON-NULL var-width key cell; the key's own bytes
follow it."""

comptime _VAR_KEY_TAG_NULL: UInt8 = 1
"""Leading payload byte of a NULL var-width key cell, whose payload is the tag
and nothing else. Distinct from `_VAR_KEY_TAG_VALUE` + zero bytes (the EMPTY
STRING), which is the whole point."""


# -----------------------------------------------------------------------------
# Agg-op constants
# -----------------------------------------------------------------------------
# These are the slow-path-side mirrors of the fast-path agg-op set
# enumerated at `komira_agg.agg_op_traits`. The slow-path runtime
# branches on these per-batch (NOT per-row).
# -----------------------------------------------------------------------------

comptime AGG_SUM_I64: UInt8 = 1


def row_sum_i64_overflow_message() -> String:
    """The row format's by-name refusal for a `sum(<int64>)` cell whose total
    leaves INT64. Worded after
    `komira_engine_operators.int_sum_overflow.int_sum_overflow_message`, which
    this layer cannot import; its lead clause is the same so a reader crossing
    routes reads one diagnosis."""
    return String(
        "integer sum() overflowed INT64 (row-format SUM cell: the >4M-row"
        " resident spill route). The total is outside"
        " [-9223372036854775808, 9223372036854775807] and this engine's"
        " int-family sum() output column is INT64, so there is no value to"
        " return. DuckDB answers this shape by promoting sum(<integer>) to"
        " HUGEINT (128-bit); this route does not yet, and returning the"
        " wrapped 64-bit total would be a silent wrong answer. On this route"
        " an avg() over the same column refuses too (its SUM half is this"
        " cell), and a partial total can leave INT64 where the final one"
        " would not."
    )
comptime AGG_SUM_F64: UInt8 = 2
comptime AGG_COUNT: UInt8 = 3
comptime AGG_MIN_I64: UInt8 = 4
comptime AGG_MAX_I64: UInt8 = 5
comptime AGG_MIN_F64: UInt8 = 6
comptime AGG_MAX_F64: UInt8 = 7
comptime AGG_AVG_F64: UInt8 = 8

# Narrow and 32-bit aggregate ops.
comptime AGG_SUM_I32: UInt8 = 9
comptime AGG_SUM_F32: UInt8 = 10
comptime AGG_SUM_U32: UInt8 = 11
comptime AGG_SUM_U64: UInt8 = 12
comptime AGG_MIN_F32: UInt8 = 13
comptime AGG_MAX_F32: UInt8 = 14
comptime AGG_MIN_I32: UInt8 = 15
comptime AGG_MAX_I32: UInt8 = 16
comptime AGG_MIN_U32: UInt8 = 17
comptime AGG_MAX_U32: UInt8 = 18
comptime AGG_MIN_U64: UInt8 = 19
comptime AGG_MAX_U64: UInt8 = 20
comptime AGG_AVG_I64: UInt8 = 21
comptime AGG_AVG_I32: UInt8 = 22
comptime AGG_AVG_F32: UInt8 = 23
comptime AGG_AVG_U32: UInt8 = 24
comptime AGG_AVG_U64: UInt8 = 25
comptime AGG_MIN_I16: UInt8 = 26
comptime AGG_MAX_I16: UInt8 = 27
comptime AGG_MIN_U16: UInt8 = 28
comptime AGG_MAX_U16: UInt8 = 29
comptime AGG_MIN_I8: UInt8 = 30
comptime AGG_MAX_I8: UInt8 = 31
comptime AGG_MIN_U8: UInt8 = 32
comptime AGG_MAX_U8: UInt8 = 33
comptime AGG_COUNT_NONNULL: UInt8 = 34


@always_inline
def _agg_state_is_f64(op_tag: UInt8) -> Bool:
    """True iff this agg op accumulates its state cell as FLOAT64 bytes.

    The single source of truth for "how do I read this cell back", shared by
    `emit_to_record_batch`. It agrees BY CONSTRUCTION with the three sites that
    WRITE the cell — `_init_agg_cells` (`write_fixed[float64]` / `MAX_FINITE` /
    `MIN_FINITE` sentinels), `_dispatch_agg_kernel` (routes to the
    `_agg_*_dt_batch[DType.float64]` kernels) and `_merge_agg_cells` (combines
    with float adds / float compares). Adding an F64 op to any of those three
    without adding it here re-opens the bit-pattern emit this predicate exists
    to close, so keep the four lists together.

    AVG_F64 is included because its CELL is an f64 running sum
    (`_agg_avg_f64_batch` delegates to `_agg_sum_dt_batch[float64]`). ⚠ That is
    a statement about the cell's BYTES, not about AVG being finalized — this
    table keeps no divisor cell, so an AVG emitted from here is the SUM, not the
    mean. That is why `agg_spill_driver.spill_route_supported` admits SUM/MIN/MAX
    over F64 and still DECLINES AVG."""
    return (
        op_tag == AGG_SUM_F64
        or op_tag == AGG_MIN_F64
        or op_tag == AGG_MAX_F64
        or op_tag == AGG_AVG_F64
    )


# =============================================================================
# ColDescriptor — TrivialRegisterPassable per-column metadata
# =============================================================================
#
# 8 bytes (UInt8 kind + UInt8 dtype_tag + UInt16 fixed_width +
# UInt16 offset_in_row + UInt16 reserved). The runtime-N outer loop in
# `RowHashAggTable.upsert_batch` walks `layout.col_descriptors` and branches
# on `kind` + `dtype_tag` per column. The cardinality is bounded by the
# largest realistic GROUP BY arity (~16 cols); the dispatch ladder fires
# once per (column, batch), NOT per row.
# =============================================================================


struct ColDescriptor(
    TrivialRegisterPassable,
    Copyable,
    ImplicitlyCopyable,
    Movable,
    Deinitable,
):
    """Per-column kind + DType metadata for the slow-path row format.

    Storage layout (8 bytes total):
        kind            UInt8   — COL_FIXED / COL_VAR_STRING / ...
        dtype_tag       UInt8   — DT_I64 / DT_F64 / ... (within COL_FIXED)
        fixed_width     UInt16  — bytes for COL_FIXED; 4 for VAR offset
        offset_in_row   UInt16  — byte offset within fixed_storage row
        flags           UInt16  — COL_FLAG_* bitset (was `_reserved` padding)

    Fields are public Copyable scalars; the struct conforms to
    `TrivialRegisterPassable` so it passes by value through the
    runtime-N column dispatch ladder with zero indirection.

    Constructed once at SDK lowering time via `RowLayout.build_from_plan`;
    never mutated thereafter.
    """

    var kind: UInt8
    var dtype_tag: UInt8
    var fixed_width: UInt16
    var offset_in_row: UInt16
    var flags: UInt16

    @always_inline
    def __init__(
        out self,
        kind: UInt8,
        dtype_tag: UInt8,
        fixed_width: UInt16,
        offset_in_row: UInt16,
        flags: UInt16 = UInt16(0),
    ):
        """Construct a ColDescriptor with the given kind/dtype/width/offset.

        `flags` defaults to 0, which is byte-identical to the `_reserved = 0`
        a reserved slot carries — every construction site that omits it means
        non-nullable."""
        self.kind = kind
        self.dtype_tag = dtype_tag
        self.fixed_width = fixed_width
        self.offset_in_row = offset_in_row
        self.flags = flags

    @always_inline
    def key_nullable(self) -> Bool:
        """Is this KEY column DECLARED nullable by its source schema?

        ⭐ THE DECLARED QUESTION, DELIBERATELY — and this is a correctness
        argument, not an optimisation. The in-memory untyped hash-agg that
        serves this same query BELOW `_agg_inmem_max_rows()` consults validity
        only under `ColDescriptor.validity_tracked`
        (`hash_agg_untyped._hash_single_col`, and `any_key_null_observed`'s
        docstring states the same rule for every fast fold): a key DECLARED
        non-nullable is folded BY ITS BYTES there even if the batch happens to
        carry a bitmap. A spill route that instead asked the batch would give a
        DIFFERENT ANSWER for that shape — which is the very thing this rule
        exists to prevent, just with the sign flipped. So the routes are made to
        ask the SAME question, and a key column whose declaration says
        non-nullable encodes by its bytes alone."""
        return (self.flags & COL_FLAG_KEY_NULLABLE) != UInt16(0)


# =============================================================================
# RowLayout — per-segment runtime descriptor (held on an RBS slot)
# =============================================================================
#
# Built ONCE at SDK lowering time per segment; per-segment-immutable
# during the hot loop. Held under RBS slot `row_layout:
# Optional[OwnedPointer[RowLayout]]` (NOT inlined by value into Row*State
# structs); passed into hot methods via `ref [lo] RowLayout` where
# `lo: Origin[mut=False]`. Multiple `RowHashAggTable` instances under one
# Tracer (parallel morsels) share one layout — no independent copies.
# =============================================================================


struct RowLayout(Movable, Deinitable):
    """Per-segment column-layout descriptor for the slow path.

    Built once at SDK lowering and held under a separate
    Optional[OwnedPointer[RowLayout]] slot on RBS. Hot methods
    (encode_batch / upsert_batch / ...) take a borrowed
    `ref [lo] RowLayout` — never an owned by-value copy.

    Fields:
        key_descriptors:        ColDescriptor per N_key cols.
        payload_descriptors:    ColDescriptor per N_payload cols (for
                                join/agg state).
        fixed_row_stride:       Bytes per row in RowBlock's fixed_storage.
        validity_offset:        Byte offset of validity bitmap within
                                fixed-row.
        has_var_width:          True iff any descriptor is COL_VAR_*.
        var_offsets_table:      Per-(row × var-col) offsets into
                                RowBlock.var_storage. Held on RowLayout, not
                                RowBlock, so RowBlock stays an arity-erased
                                cell-storage primitive.
    """

    var key_descriptors: List[ColDescriptor]
    var payload_descriptors: List[ColDescriptor]
    var fixed_row_stride: Int
    var validity_offset: Int
    var has_var_width: Bool
    var has_validity: Bool
    var var_offsets_table: List[Int]

    def __init__(out self):
        """Empty layout. Used by `build_from_plan` to seed the descriptor
        list before populating it; SDK lowering then calls
        `add_key_col` / `add_payload_col` per column.
        """
        self.key_descriptors = List[ColDescriptor]()
        self.payload_descriptors = List[ColDescriptor]()
        self.fixed_row_stride = 0
        self.validity_offset = 0
        self.has_var_width = False
        self.has_validity = False
        self.var_offsets_table = List[Int]()

    @staticmethod
    @always_inline
    def validity_bytes_for(n_cols: Int) -> Int:
        """Number of validity-bitmap bytes for `n_cols` logical columns
        (`ceil(n_cols/8)`). 0 columns => 0 bytes."""
        return (n_cols + 7) >> 3

    def enable_validity(mut self):
        """Mark this layout as nullable: a `ceil(N_cols/8)`-byte validity
        bitmap region is reserved at `validity_offset` (== the current
        fixed-cell sum) and the stride grows by that amount. Call AFTER all
        descriptors are added and `set_fixed_row_stride` has set the cell sum.

        Idempotent guard: a second call is a no-op (the region is already
        reserved)."""
        if self.has_validity:
            return
        self.has_validity = True
        var n_cols = self.key_descriptors.__len__() + self.payload_descriptors.__len__()
        self.validity_offset = self.fixed_row_stride
        self.fixed_row_stride += Self.validity_bytes_for(n_cols)

    def add_key_col(mut self, desc: ColDescriptor):
        """Append a key-column ColDescriptor. Caller is responsible for
        computing the correct `offset_in_row` (running offset over
        all prior key+payload descriptors).
        """
        self.key_descriptors.append(desc)
        if desc.kind == COL_VAR_STRING or desc.kind == COL_VAR_BINARY:
            self.has_var_width = True

    def add_payload_col(mut self, desc: ColDescriptor):
        """Append a payload-column ColDescriptor (agg state slot, join
        payload, sort tiebreaker, etc.).
        """
        self.payload_descriptors.append(desc)
        if desc.kind == COL_VAR_STRING or desc.kind == COL_VAR_BINARY:
            self.has_var_width = True

    def set_fixed_row_stride(mut self, stride: Int):
        """Final row stride after all key+payload descriptors are added."""
        self.fixed_row_stride = stride

    def n_key_cols(self) -> Int:
        return self.key_descriptors.__len__()

    def n_payload_cols(self) -> Int:
        return self.payload_descriptors.__len__()


# =============================================================================
# RowBlock — packed-row storage primitive
# =============================================================================
#
# (origin-poly accessors + DT-only comptime + capacity contract). Two OwnedAlignedBuffer-backed regions:
#   `_fixed_storage`  — row-major fixed cells, 64-B aligned for SIMD-friendly
#                       scatter on x86_64 / NEON.
#   `_var_storage`    — var-width blob (string / binary payloads).
#
# ENCAPSULATION RULE: cell access goes through the typed-poly methods
# below (`read_fixed[DT]` / `write_fixed[DT]` / `read_var` / `write_*_batch[DT]`).
# No public accessor returns a raw pointer. Internal callers under
# `row_format/*` use `_typed_ptr_ro` / `_typed_ptr_mut` on the inner
# OwnedAlignedBuffer (NEVER `OwnedAlignedBuffer.unsafe_ptr()`).
# =============================================================================


struct RowBlock(Movable, Deinitable):
    """Packed-row storage primitive for the slow path.

    Per-row layout:
        [validity_bitmap (ceil(N_cols/8) bytes)
         | fixed_cells (sum of ColDescriptor.fixed_width)
         | var_offsets  (N_var × 4 bytes)]

    Var-width data lives in `_var_storage`; offsets index into it via
    RowLayout's `var_offsets_table`.

    Constructed once per segment (one RowBlock per RowHashAggTable arm or
    RowJoinProbeState arm). Lifetime tied to the Variant arm slot on RBS.

    Capacity contract (G_E2): `with_capacity` is the only public ctor;
    per-batch encode reserves capacity ONCE before the row loop, never
    inside it. `reserve_rows` / `reserve_var_bytes` are amortized-doubling
    regrow primitives called BEFORE the per-batch encode kernel; inner
    loops are capacity-safe by precondition.
    """

    # ─── Storage fields ──────────────────────────────────────────────────

    # Fields are `OwnedAlignedBuffer`. Storage is single-owner heap (no Arc
    # refcount traffic needed — RowBlock is owned by an RBS variant arm,
    # never shared). OAB's public API is a superset of OLD AB's for the
    # methods used here (`reserve`, `view_ro`, `view_mut`, `write_u8_at`,
    # `write_u64_le_at`, `read_u8_at`, `read_u64_le_at`, `set_typed`,
    # `set_length`, `length`, `capacity`). Encapsulation rule still
    # honored: cell access remains via origin-poly `view_ro`/`view_mut`
    # then a typed `_unsafe_ptr` inside the same-module helper — public
    # methods still return refs / typed scalars only.
    var _fixed_storage: OwnedAlignedBuffer
    """Row-major fixed cells, 64-B aligned for SIMD-friendly scatter."""

    var _var_storage: OwnedAlignedBuffer
    """Var-width blob; addressed by RowLayout.var_offsets_table."""

    var n_rows: Int
    """Logical row count (≤ capacity)."""

    var capacity: Int
    """Max rows BEFORE regrow. Capacity contract: row loop precondition is
    `n_rows + W ≤ capacity` for any per-batch SIMD chunk."""

    var var_storage_used: Int
    """Bytes consumed in _var_storage."""

    var var_storage_capacity: Int
    """Max bytes BEFORE var-regrow. Capacity contract analog."""

    var fixed_row_stride: Int
    """Bytes per row in _fixed_storage. Cached from RowLayout to avoid
    a layout deref in the hot row loop."""

    var var_key_offsets: List[Int]
    """VAR-WIDTH GROUP-KEY CELL OFFSETS inside this block's KEY region
 — EMPTY for every layout that shipped before it.

    ⛔⛔ THIS FIELD IS WHAT MAKES A STRING GROUP KEY HASH ITS BYTES. A
    `COL_VAR_STRING` cell in the fixed region is an 8-byte (offset, length)
    DESCRIPTOR into `_var_storage`; `_hash_row_bytes` / `_row_bytes_equal`
    key a group by the RAW BYTES of the key region, so over a descriptor they
    would key the group by WHERE the payload happens to sit. Two rows carrying
    the SAME string but appended at different var-storage offsets would then
    hash and compare APART and SPLIT INTO SEPARATE GROUPS — a silently WRONG
    aggregate, not an error. Listing the descriptor offsets here makes both
    primitives SKIP those 8 bytes and fold the PAYLOAD instead, so byte
    equality is string equality again.

    Ascending offsets, each `< key_stride`, each naming an 8-byte cell. The
    producer is `agg_spill_driver._build_row_layout` via
    `RowHashAggTable.set_var_key_offsets`, which stamps the SAME list onto the
    group-row block, the per-batch probe block, and every spill/restore shell —
    a block whose list disagrees with the block it is compared against is a
    wrong-wiring bug, which is why the list travels with the bytes (the spill
    image, `combine`, and the grace-hash repartition all carry it)."""

    # ─── Ctor + capacity contract ───────────────────────────────────

    def __init__(out self, fixed_row_stride: Int):
        """Empty-shell ctor; callers should use `with_capacity` and
        `reserve_rows` / `reserve_var_bytes` to pre-size before any
        per-batch encode.
        """
        self._fixed_storage = OwnedAlignedBuffer(0)
        self._var_storage = OwnedAlignedBuffer(0)
        self.n_rows = 0
        self.capacity = 0
        self.var_storage_used = 0
        self.var_storage_capacity = 0
        self.fixed_row_stride = fixed_row_stride
        self.var_key_offsets = List[Int]()

    @staticmethod
    def with_capacity(
        n_rows: Int,
        var_bytes: Int,
        fixed_row_stride: Int,
    ) raises -> RowBlock:
        """Pre-size to expected row count + var-storage byte budget.

        Caller computes `n_rows × fixed_row_stride` for fixed; uses a
        heuristic for var (e.g. AVG_STRING_LEN × n_rows × n_var_cols).
        Both OwnedAlignedBuffer regions are 64-B aligned for SIMD-
        friendly scatter on x86_64 / NEON.
        """
        var rb = RowBlock(fixed_row_stride)
        if n_rows > 0 and fixed_row_stride > 0:
            rb._fixed_storage.reserve(n_rows * fixed_row_stride)
            rb._sync_fixed_length()
            rb.capacity = n_rows
        if var_bytes > 0:
            rb._var_storage.reserve(var_bytes)
            rb._sync_var_length()
            rb.var_storage_capacity = var_bytes
        return rb^

    # ─── LENGTH-DESYNC FIX ─────────────────────────────────────────────────
    #
    # `OwnedAlignedBuffer.reserve` preserves only `keep = _length` bytes on a
    # doubling regrow (`memcpy` of `keep` bytes) and `memset`-zeroes the rest.
    # The capacity-only growth primitives below (`reserve_rows` /
    # `ensure_capacity_rows` / `reserve_var_bytes` / `with_capacity`) grow the
    # buffer's `_capacity` but, prior to this fix, left `_length` at 0 — so
    # EVERY regrow wiped all previously-written rows. Past the 16,384 -> 32,768
    # fixed-row regrow this zeroed 16,384 rows, which the row hash-agg then
    # re-inserted as phantom key-0 groups (over-production: 26,384 vs 10,000).
    #
    # The fix admits the FULL reserved byte extent into the buffer's `_length`
    # window after every grow (the same contract `PrimitiveArray` uses on the
    # column path via `buf.set_length(length * elem_size)`). Once `_length`
    # covers the allocated capacity, the regrow `memcpy` preserves ALL written
    # bytes. Setting `_length == capacity` (rather than tracking the exact
    # written-row extent) is correct and cheaper: writes only ever land within
    # `[0, capacity)`, so preserving the whole capacity on regrow never loses
    # data and the tail bytes are harmless (they are overwritten before being
    # admitted as live rows via `set_n_rows`).

    @always_inline
    def _sync_fixed_length(mut self):
        """Admit the full reserved fixed-storage byte extent into the
        buffer's `_length` window so a later `reserve` regrow preserves all
        written rows. See the LENGTH-DESYNC FIX block above.
        """
        self._fixed_storage.set_length(Int64(self._fixed_storage.capacity()))

    @always_inline
    def _sync_var_length(mut self):
        """Var-storage analog of `_sync_fixed_length`."""
        self._var_storage.set_length(Int64(self._var_storage.capacity()))

    @always_inline
    def reserve_rows(mut self, additional: Int) raises:
        """Amortized-doubling regrow for the fixed-cells region.

        Called BEFORE the per-batch encode kernel — NEVER inside the
        row loop. The row loop's inner SIMD chunk is capacity-safe by
        precondition.

        Semantics: APPEND-style. Ensures `n_rows + additional` rows
        fit. Use this when extending the live row count (e.g.
        RowHashAggTable.upsert_batch when inserting NEW group rows).
        For "ensure at least N rows fit" semantics that compose across
        multiple per-DType writes to the SAME rows, use
        `ensure_capacity_rows(min_rows)` instead.
        """
        if self.n_rows + additional > self.capacity:
            var new_cap = max(self.capacity * 2, self.n_rows + additional)
            if new_cap < 16:
                new_cap = 16
            self._fixed_storage.reserve(new_cap * self.fixed_row_stride)
            self._sync_fixed_length()
            self.capacity = new_cap

    @always_inline
    def ensure_capacity_rows(mut self, min_rows: Int) raises:
        """ABSOLUTE-capacity ensure: grow until ≥ min_rows fit; no-op
        otherwise. Composes correctly when multiple per-DType encoders
        write to the SAME row range at different col_offset_in_row
        positions (multi-DType packed-offset pattern).

        Distinct from `reserve_rows(additional)` (APPEND semantics).
        Needed by the multi-DType packed
        row layout). Closes a latent bug where per-DType
        `write_*_batch` calls compose by re-growing the buffer mid-
        sequence and clobbering previously-written cells.
        """
        if min_rows > self.capacity:
            var new_cap = max(self.capacity * 2, min_rows)
            if new_cap < 16:
                new_cap = 16
            self._fixed_storage.reserve(new_cap * self.fixed_row_stride)
            self._sync_fixed_length()
            self.capacity = new_cap

    @always_inline
    def reserve_var_bytes(mut self, additional: Int) raises:
        """Amortized-doubling regrow for the var-storage region.

        Called BEFORE the per-batch encode kernel; mirrors reserve_rows.
        """
        # One compare against a comptime constant on a
        # never-taken branch, stated on the RESULTING cursor (so both halves of
        # every descriptor this block goes on to write are representable) and
        # placed BEFORE the growth allocation.
        if self.var_storage_used + additional > VAR_DESC_OFFSET_MAX:
            _raise_row_var_offset_ceiling(self.var_storage_used, additional)
            return
        if self.var_storage_used + additional > self.var_storage_capacity:
            var new_cap = max(
                self.var_storage_capacity * 2,
                self.var_storage_used + additional,
            )
            if new_cap < 64:
                new_cap = 64
            self._var_storage.reserve(new_cap)
            self._sync_var_length()
            self.var_storage_capacity = new_cap

    @always_inline
    def set_n_rows(mut self, n: Int):
        """Set the logical row count after an encode pass.

        Caller invariant: `n ≤ self.capacity`. Capacity is guaranteed by
        the pre-encode `reserve_rows` call (capacity contract).
        """
        self.n_rows = n

    # ─── Origin-polymorphic INTERNAL accessors ──────────────────────

    @always_inline
    def _row_base_ptr_mut[
        o: Origin[mut=True], //,
    ](ref [o] self, row: Int) -> UnsafePointer[UInt8, o]:
        """Return a mutable byte pointer to row `row`'s fixed-cell base.

        SAFETY: pointer origin = `origin_of(self)`; valid only while
        `self` is alive. Caller ensures `row < n_rows`. INTERNAL
        ACCESSOR — public API callers must use
        `read_fixed` / `write_fixed` / `read_var` / `write_*_batch`.

        Origin-poly — preserves ASAP-destruction
        tracking through the row-loop hot path; no wildcard origin.

        Parameters:
            o: The receiver's origin (inferred from `self`'s borrow).
        """
        # SAFETY: pointer arithmetic is bounded by the row precondition
        # (`row < n_rows`) + the buffer's allocated capacity (caller-
        # enforced via `reserve_rows` before the encode kernel runs).
        # Moved off the wildcard-origin shim
        # `_typed_ptr_mut[DType.uint8]` onto origin-tied
        # `view_mut()._unsafe_ptr()` (uint8-direct — `view_mut` returns
        # ByteView[origin_of(self._fixed_storage)] whose `_unsafe_ptr`
        # is `UnsafePointer[UInt8, origin_of(self._fixed_storage)]`).
        # We then widen to the receiver origin `o` via
        # `unsafe_origin_cast[o]()` — same widening as before; only
        # the upstream accessor changes. NOT wildcard — `o` is the
        # caller's concrete `Origin[mut=True]` parameter.
        var base = self._fixed_storage.view_mut()._unsafe_ptr(
        ).unsafe_origin_cast[o]()
        return base + row * self.fixed_row_stride

    @always_inline
    def _row_base_ptr_ro[
        _mut: Bool, o: Origin[mut=_mut], //,
    ](ref [o] self, row: Int) -> UnsafePointer[UInt8, o]:
        """Return a read-only-or-mutable byte pointer to row `row`'s
        fixed-cell base.

        Mut-poly + origin-poly; returned pointer's mutability follows
        the caller's borrow on `self`. Use this when the consumer
        accepts any-mut origin (read-only decoders).

        Parameters:
            _mut: Inferred from the receiver origin's mutability.
            o: The receiver's origin (inferred from `self`'s borrow).
        """
        # SAFETY: same as `_row_base_ptr_mut` — pointer is bounded by
        # the precondition + caller-enforced reserve.
        # Moved off the wildcard-origin shim
        # `_typed_ptr_ro[DType.uint8]` onto origin-tied
        # `view_ro()._unsafe_ptr()` (uint8-direct; `view_ro` returns
        # ByteView[origin_of(self._fixed_storage)] with mut polarity
        # inferred from `self`'s borrow). Widen mut to `_mut` via
        # `unsafe_mut_cast[_mut]()` (the receiver's borrow polarity
        # may be either; the view_ro infers from the receiver), then
        # widen origin to caller's `o` via `unsafe_origin_cast[o]()`.
        var base = self._fixed_storage.view_ro()._unsafe_ptr(
        ).unsafe_mut_cast[_mut]().unsafe_origin_cast[o]()
        return base + row * self.fixed_row_stride

    @always_inline
    def _var_base_ptr_mut[
        o: Origin[mut=True], //,
    ](ref [o] self) -> UnsafePointer[UInt8, o]:
        """Internal accessor — mutable base of the var-storage blob.

        SAFETY: pointer origin = `origin_of(self)`; caller passes a
        byte offset within `[0, var_storage_used)`.
        """
        # SAFETY: same widening pattern as `_row_base_ptr_mut` against
        # `_var_storage`; bounded by `var_storage_used`.
        # Moved off the wildcard-origin shim
        # `_typed_ptr_mut[DType.uint8]` onto origin-tied
        # `view_mut()._unsafe_ptr()` (uint8-direct).
        return (
            self._var_storage.view_mut()._unsafe_ptr()
            .unsafe_origin_cast[o]()
        )

    @always_inline
    def _var_base_ptr_ro[
        _mut: Bool, o: Origin[mut=_mut], //,
    ](ref [o] self) -> UnsafePointer[UInt8, o]:
        """Internal accessor — read-only base of the var-storage blob."""
        # SAFETY: as `_var_base_ptr_mut`.
        # Moved off the wildcard-origin shim
        # `_typed_ptr_ro[DType.uint8]` onto origin-tied
        # `view_ro()._unsafe_ptr()` (uint8-direct; receiver-inferred
        # mut polarity widened to `_mut` for the mut-poly accessor).
        return (
            self._var_storage.view_ro()._unsafe_ptr()
            .unsafe_mut_cast[_mut]()
            .unsafe_origin_cast[o]()
        )

    # ─── Public typed cell access (DT-only comptime) ─────────────────

    @always_inline
    def read_fixed[DT: DType](self, row: Int, col_offset_in_row: Int) -> Scalar[DT]:
        """DT-only comptime monomorphization scalar read.

        Column offset is RUNTIME — the outer loop in row_format encoders
        is runtime-N over columns, so col_offset_in_row cannot be a
        comptime parameter (RowLayout has `List[ColDescriptor]` and is
        not register-passable).

        Parameters:
            DT: Comptime DType (DType.int64 / DType.float64 / ...).
        """
        # ALIGNMENT-SAFETY:
        # cells are byte-packed at their runtime `col_offset_in_row`, so a
        # 16-byte DType (int128 / DECIMAL128) can land at an offset that is
        # only 8-byte aligned (e.g. a payload cell at offset 8). A bare
        # `bitcast[Scalar[DT]]()[0]` carries `align_of[Scalar[DT]]()` (== 16
        # for int128) load metadata, so LLVM is free to emit an ALIGNED SSE
        # move (`vmovdqa`) that #GP-faults on a 16-misaligned address. Force
        # `alignment=1` (unaligned) — the same guard `OwnedAlignedBuffer`'s
        # typed accessors already apply. Negligible cost for the fast subset
        # (scalar unaligned loads on an aligned address are free on x86/NEON).
        var p = self._row_base_ptr_ro(row) + col_offset_in_row
        return p.bitcast[Scalar[DT]]().load[alignment=1]()

    @always_inline
    def write_fixed[
        DT: DType
    ](mut self, row: Int, col_offset_in_row: Int, value: Scalar[DT]):
        """DT-only comptime monomorphization scalar write.

        Parameters:
            DT: Comptime DType.
        """
        # ALIGNMENT-SAFETY: see
        # `read_fixed` — force `alignment=1` so a 16-byte cell at a
        # 16-misaligned byte offset never lowers to an aligned `vmovdqa`
        # store that faults.
        var p = self._row_base_ptr_mut(row) + col_offset_in_row
        p.bitcast[Scalar[DT]]().store[alignment=1](value)

    def append_rows_from(
        mut self, imm src: RowBlock, src_start: Int, n_take: Int
    ) raises:
        """Bulk-memcpy `n_take` whole rows from `src` (starting at row
        `src_start`) into `self`, appended after `self.n_rows`.

        Fast copy. Replaces the scalar
        `for r: for b in range(stride): read_fixed/write_fixed` loop with a
        SINGLE `copy_from_view_at` memcpy over the contiguous `n_take * stride`
        fixed-cell byte run. Both blocks MUST share `fixed_row_stride` and be
        FIXED-WIDTH only (no var-width storage) — the contiguous-run identity
        copy is only valid when the whole row is a packed fixed region and the
        source rows are laid out identically to the destination.

        SAFETY: pointer arithmetic is confined to this module's
        `OwnedAlignedBuffer` bulk-copy primitive (`copy_from_view_at` over a
        `view_range_ro` sub-view); no raw pointer crosses a module boundary.
        """
        if n_take <= 0:
            return
        if self.fixed_row_stride != src.fixed_row_stride:
            raise Error(
                "RowBlock.append_rows_from: stride mismatch (dst "
                + String(self.fixed_row_stride)
                + " vs src "
                + String(src.fixed_row_stride)
                + ")"
            )
        if self.var_storage_used != 0 or src.var_storage_used != 0:
            raise Error(
                "RowBlock.append_rows_from: var-width blocks are not bulk-"
                "copyable (var offsets are not position-stable)."
            )
        var stride = self.fixed_row_stride
        var base = self.n_rows
        self.reserve_rows(n_take)
        var n_bytes = n_take * stride
        var dst_byte_off = base * stride
        var src_byte_off = src_start * stride
        self._fixed_storage.copy_from_view_at(
            dst_byte_off, src._fixed_storage.view_range_ro(src_byte_off, n_bytes)
        )
        self.n_rows = base + n_take

    def copy_row_fixed_from(
        mut self, dst_row: Int, imm src: RowBlock, src_row: Int
    ) raises:
        """Copy ONE row's whole fixed region from `src` into `self`.

        The var-width companion of `append_rows_from` (which refuses var blocks
        outright because a bulk multi-row memcpy cannot rebase descriptors).
        Here the caller copies row-at-a-time and follows each copy with a
        `copy_var_string_cell` per var cell, which DOES rebase — so the pair is
        the correct move for a block that owns a var heap. Caller has reserved
        `dst_row` (capacity contract).
        """
        if self.fixed_row_stride != src.fixed_row_stride:
            raise Error(
                "RowBlock.copy_row_fixed_from: stride mismatch (dst "
                + String(self.fixed_row_stride)
                + " vs src " + String(src.fixed_row_stride) + ")"
            )
        var stride = self.fixed_row_stride
        self._fixed_storage.copy_from_view_at(
            dst_row * stride,
            src._fixed_storage.view_range_ro(src_row * stride, stride),
        )

    # ─── Per-DType ENCODE methods (SIMD-LOAD, per-lane store) ─────────────
    #
    # Contiguous SIMD-LOAD of W lanes per chunk; a comptime for loop emits
    # per-lane stride STOREs (LLVM cannot synthesize SIMD scatter over a
    # runtime stride). For the fast subset (I64/F64/I32/F32) this is the
    # canonical hand-staged shape — the autovec doesn't fire on unit-stride
    # numeric loops in Mojo 1.0.0b1.
    #
    # The smaller widths (I16 / I8 / U8 / U16) carry a scalar body
    # (lower-traffic; not on the encoder perf gate). The
    # signature is in place for a v2 SIMD upgrade.
    #
    # All encoder methods take `col: ColView[DT, bo]` (typed columnar
    # source view) + `col_offset_in_row: Int` (runtime byte offset within
    # the fixed-cell region).
    # ---------------------------------------------------------------------

    def write_fixed_dt_batch[
        bo: Origin[mut=False], //, DT: DType, W: Int,
    ](mut self, col: ColView[DT, bo], col_offset_in_row: Int) raises:
        """Comptime-monomorphized fixed-width encoder.

        Receiver origin (`origin_of(self)`) propagates through
        `_row_base_ptr_mut` to the bitcast store — no wildcard. `W` is
        the SIMD lane count; caller passes `simd_width_of[DT]()`.

        contiguous SIMD-LOAD W lanes per chunk; per-lane
        stride STORE under `@parameter for lane in range(W)`. Tail loop
        for `n_rows % W` rows is scalar.

        Parameters:
            DT: Comptime DType.
            W: Comptime SIMD lane count.
            bo: Borrow origin of the source ColView.
        """
        var n = col.length()
        var n_chunks = n // W
        # Ensure capacity for n rows — ABSOLUTE semantics so multiple
        # per-DType writes at different col_offset_in_row positions
        # compose without clobbering previously-written cells.
        self.ensure_capacity_rows(n)
        # Stage 1: SIMD-LOAD W lanes per chunk; per-lane stride STORE.
        for c in range(n_chunks):
            var base_row = c * W
            var lanes = col.load[W](base_row)
            comptime for lane in range(W):
                var p = self._row_base_ptr_mut(base_row + lane) + col_offset_in_row
                # ALIGNMENT-SAFETY (see `read_fixed`): force unaligned store so
                # a 16-byte DT at a 16-misaligned byte offset never lowers to an
                # aligned `vmovdqa` that #GP-faults.
                p.bitcast[Scalar[DT]]().store[alignment=1](lanes[lane])
        # Tail (scalar for n % W rows).
        var tail_start = n_chunks * W
        for row in range(tail_start, n):
            var v: Scalar[DT] = col.load[1](row)[0]
            self.write_fixed[DT](row, col_offset_in_row, v)
        if n > self.n_rows:
            self.n_rows = n

    @always_inline
    def write_i64_batch[bo: Origin[mut=False], //](
        mut self, col: ColView[DType.int64, bo], col_offset_in_row: Int
    ) raises:
        """I64 fast-DType encoder. SIMD-staged via the canonical W=8
        lane chunk on AVX-512 / W=2 on NEON-2.
        """
        self.write_fixed_dt_batch[DType.int64, 8](col, col_offset_in_row)

    @always_inline
    def write_f64_batch[bo: Origin[mut=False], //](
        mut self, col: ColView[DType.float64, bo], col_offset_in_row: Int
    ) raises:
        """F64 fast-DType encoder. Same shape as `write_i64_batch`."""
        self.write_fixed_dt_batch[DType.float64, 8](col, col_offset_in_row)

    @always_inline
    def write_i32_batch[bo: Origin[mut=False], //](
        mut self, col: ColView[DType.int32, bo], col_offset_in_row: Int
    ) raises:
        """I32 fast-DType encoder. SIMD-staged via W=16 on AVX-512."""
        self.write_fixed_dt_batch[DType.int32, 16](col, col_offset_in_row)

    @always_inline
    def write_f32_batch[bo: Origin[mut=False], //](
        mut self, col: ColView[DType.float32, bo], col_offset_in_row: Int
    ) raises:
        """F32 fast-DType encoder. Same shape as `write_i32_batch`."""
        self.write_fixed_dt_batch[DType.float32, 16](col, col_offset_in_row)

    @always_inline
    def write_i16_batch[bo: Origin[mut=False], //](
        mut self, col: ColView[DType.int16, bo], col_offset_in_row: Int
    ) raises:
        """I16 encoder — SIMD-staged via W=32 on AVX-512 / NEON.

        Uses the canonical `write_fixed_dt_batch[DT, W]`
        SIMD-LOAD-per-lane-store recipe with W=32 lanes for 2-byte cells.
        """
        self.write_fixed_dt_batch[DType.int16, 32](col, col_offset_in_row)

    @always_inline
    def write_i8_batch[bo: Origin[mut=False], //](
        mut self, col: ColView[DType.int8, bo], col_offset_in_row: Int
    ) raises:
        """I8 encoder — SIMD-staged via W=64 on AVX-512.

        W=64 lanes for 1-byte cells.
        """
        self.write_fixed_dt_batch[DType.int8, 64](col, col_offset_in_row)

    @always_inline
    def write_u8_batch[bo: Origin[mut=False], //](
        mut self, col: ColView[DType.uint8, bo], col_offset_in_row: Int
    ) raises:
        """U8 encoder — SIMD-staged via W=64; mirrors `write_i8_batch`."""
        self.write_fixed_dt_batch[DType.uint8, 64](col, col_offset_in_row)

    @always_inline
    def write_u16_batch[bo: Origin[mut=False], //](
        mut self, col: ColView[DType.uint16, bo], col_offset_in_row: Int
    ) raises:
        """U16 encoder — SIMD-staged via W=32; mirrors `write_i16_batch`."""
        self.write_fixed_dt_batch[DType.uint16, 32](col, col_offset_in_row)

    @always_inline
    def write_u32_batch[bo: Origin[mut=False], //](
        mut self, col: ColView[DType.uint32, bo], col_offset_in_row: Int
    ) raises:
        """U32 encoder — SIMD-staged via W=16."""
        self.write_fixed_dt_batch[DType.uint32, 16](col, col_offset_in_row)

    @always_inline
    def write_u64_batch[bo: Origin[mut=False], //](
        mut self, col: ColView[DType.uint64, bo], col_offset_in_row: Int
    ) raises:
        """U64 encoder — SIMD-staged via W=8."""
        self.write_fixed_dt_batch[DType.uint64, 8](col, col_offset_in_row)

    @always_inline
    def write_date32_batch[bo: Origin[mut=False], //](
        mut self, col: ColView[DType.int32, bo], col_offset_in_row: Int
    ) raises:
        """Date32 encoder — same storage as I32; SIMD-staged W=16."""
        self.write_fixed_dt_batch[DType.int32, 16](col, col_offset_in_row)

    @always_inline
    def write_date64_batch[bo: Origin[mut=False], //](
        mut self, col: ColView[DType.int64, bo], col_offset_in_row: Int
    ) raises:
        """Date64 encoder — same storage as I64; SIMD-staged W=8.

        Arrow Date64 is stored as Int64 ms
        since epoch. RowBlock stores it as 8-byte cell (identical
        storage to I64). Semantic distinction is held at the
        ColDescriptor.dtype_tag layer (DT_DATE64).
        """
        self.write_fixed_dt_batch[DType.int64, 8](col, col_offset_in_row)

    @always_inline
    def write_timestamp_ns_batch[bo: Origin[mut=False], //](
        mut self, col: ColView[DType.int64, bo], col_offset_in_row: Int
    ) raises:
        """Timestamp_ns encoder — 8 bytes, i64 storage; SIMD-staged W=8.

        Arrow timestamp_ns is Int64 nanoseconds since epoch.
        """
        self.write_fixed_dt_batch[DType.int64, 8](col, col_offset_in_row)

    @always_inline
    def write_timestamp_us_batch[bo: Origin[mut=False], //](
        mut self, col: ColView[DType.int64, bo], col_offset_in_row: Int
    ) raises:
        """Timestamp_us encoder — 8 bytes, i64 storage; SIMD-staged W=8."""
        self.write_fixed_dt_batch[DType.int64, 8](col, col_offset_in_row)

    @always_inline
    def write_timestamp_ms_batch[bo: Origin[mut=False], //](
        mut self, col: ColView[DType.int64, bo], col_offset_in_row: Int
    ) raises:
        """Timestamp_ms encoder — 8 bytes, i64 storage; SIMD-staged W=8."""
        self.write_fixed_dt_batch[DType.int64, 8](col, col_offset_in_row)

    @always_inline
    def write_timestamp_s_batch[bo: Origin[mut=False], //](
        mut self, col: ColView[DType.int64, bo], col_offset_in_row: Int
    ) raises:
        """Timestamp_s encoder — 8 bytes, i64 storage; SIMD-staged W=8."""
        self.write_fixed_dt_batch[DType.int64, 8](col, col_offset_in_row)

    def write_bool_batch[bo: Origin[mut=False], //](
        mut self, col: BoolColView[bo], col_offset_in_row: Int
    ) raises:
        """Bool encoder — 1 byte per cell (NOT bit-packed in RowBlock).

        Bool is stored as 1 byte (0x00 / 0x01)
        per cell in RowBlock for simplicity. The Arrow source is
        bit-packed (BoolColView.load returns SIMD[bool, W]); RowBlock
        stores the unpacked byte form. SIMD-staged W=64 — load 64
        boolean bits per chunk; per-lane STORE writes 1 byte each.

        Note on lifetime: the BoolColView load[W] body raises (origin-
        sensitive bit-unpack); we wrap the chunk in a try/raise pattern
        to preserve `raises` semantics through the @parameter for body.
        """
        var n = col.length()
        var W: Int = 64
        var n_chunks = n // W
        # ABSOLUTE-capacity semantics — see `write_fixed_dt_batch` rationale.
        self.ensure_capacity_rows(n)
        for c in range(n_chunks):
            var base_row = c * W
            var lanes = col.load[64](base_row)
            comptime for lane in range(64):
                var p = self._row_base_ptr_mut(base_row + lane) + col_offset_in_row
                # Store 1 byte: 0x01 if True, 0x00 if False.
                var bit: Bool = lanes[lane]
                p.bitcast[Scalar[DType.uint8]]()[0] = Scalar[DType.uint8](
                    1 if bit else 0
                )
        var tail_start = n_chunks * W
        for row in range(tail_start, n):
            var bit: Bool = col.load_bit(row)
            self.write_fixed[DType.uint8](
                row, col_offset_in_row, Scalar[DType.uint8](1 if bit else 0)
            )
        if n > self.n_rows:
            self.n_rows = n

    # ─── The CANONICAL 8-BYTE GROUP-KEY encoders ────
    #
    # Reached ONLY through a `COL_FIXED_KEY64` key descriptor (see that
    # constant's docstring for the full argument). Each writes ALL EIGHT bytes
    # of the cell with an INJECTIVE surrogate for the source value, so the
    # byte-keyed directory groups exactly the values SQL says are equal.
    #
    # ⛔ THESE ARE NOT `write_<dt>_batch` AND MUST NOT BE FOLDED INTO THEM. The
    # `write_<dt>_batch` family writes the source's NATURAL width (4 bytes for
    # I32, 2 for I16, ...) because its callers pack cells at that width. These
    # write 8 bytes from a narrower source ON PURPOSE, which is a different
    # contract, not a wider default.

    def write_widen_i64_key_batch[
        bo: Origin[mut=False], //, DT: DType, W: Int,
    ](mut self, col: ColView[DT, bo], col_offset_in_row: Int) raises:
        """VALUE-widen a narrow integer source column into 8-byte I64 key cells.

        Same SIMD-load / per-lane-store staging as `write_fixed_dt_batch`, but
        the store is `Scalar[int64]` after a widening `cast`, so the cell holds
        the VALUE (sign-extended for a signed source, zero-extended for an
        unsigned one) rather than the source's narrow bytes plus whatever was
        already at the remaining offsets.

        Parameters:
            DT: Comptime source DType.
            W: Comptime SIMD lane count for DT.
            bo: Borrow origin of the source ColView.
        """
        var n = col.length()
        var n_chunks = n // W
        self.ensure_capacity_rows(n)
        for c in range(n_chunks):
            var base_row = c * W
            var lanes = col.load[W](base_row)
            comptime for lane in range(W):
                var p = (
                    self._row_base_ptr_mut(base_row + lane) + col_offset_in_row
                )
                # ALIGNMENT-SAFETY (see `read_fixed`): unaligned store.
                p.bitcast[Scalar[DType.int64]]().store[alignment=1](
                    lanes[lane].cast[DType.int64]()
                )
        var tail_start = n_chunks * W
        for row in range(tail_start, n):
            var v: Scalar[DT] = col.load[1](row)[0]
            self.write_fixed[DType.int64](
                row, col_offset_in_row, v.cast[DType.int64]()
            )
        if n > self.n_rows:
            self.n_rows = n

    def write_f64_canon_key_batch[bo: Origin[mut=False], //](
        mut self, col: ColView[DType.float64, bo], col_offset_in_row: Int
    ) raises:
        """CANONICALISE an F64 source column into 8-byte key cells.

        ⭐ THIS IS THE F64 GROUP-KEY CORRECTNESS CLIFF, CLOSED. A raw bitcast
        of the source float is NOT a valid group key: IEEE-754 gives `-0.0` a
        different bit pattern from `+0.0` while `==` calls them equal (so a
        byte-keyed directory would emit TWO groups where SQL has one), and
        every NaN payload/sign is a distinct pattern while `==` calls NaN
        unequal to itself (so NaNs scatter one-per-row, and a NaN key would not
        even round-trip a lookup). `canonical_bits_f64` collapses both —
        `-0.0 -> +0.0`, every NaN -> `0x7FF8000000000000` — which is DuckDB's
        model and the same primitive `builtin_hash_fns.HashF64` already uses.
        Scalar per row: the canonicalisation is two branches, not a blend."""
        var n = col.length()
        self.ensure_capacity_rows(n)
        for row in range(n):
            var v: Float64 = col.load[1](row)[0]
            self.write_fixed[DType.uint64](
                row, col_offset_in_row, canonical_bits_f64(v)
            )
        if n > self.n_rows:
            self.n_rows = n

    def write_f32_canon_key_batch[bo: Origin[mut=False], //](
        mut self, col: ColView[DType.float32, bo], col_offset_in_row: Int
    ) raises:
        """CANONICALISE an F32 source column into 8-byte key cells.

        Canonicalised IN F32 FIRST (`canonicalize_f32`, so an f32 `-0.0` and
        every f32 NaN collapse under the f32 model) and only then widened to
        f64. The widening is exact and injective on every finite f32, so two
        f32 values are byte-equal here iff they are equal under the f32 model.
        The second `canonical_bits_f64` is belt-and-braces on the NaN it
        already produced."""
        var n = col.length()
        self.ensure_capacity_rows(n)
        for row in range(n):
            var v: Float32 = col.load[1](row)[0]
            var cv: Float32 = canonicalize_f32(v)
            self.write_fixed[DType.uint64](
                row, col_offset_in_row, canonical_bits_f64(Float64(cv))
            )
        if n > self.n_rows:
            self.n_rows = n

    def write_bool_key64_batch[bo: Origin[mut=False], //](
        mut self, col: BoolColView[bo], col_offset_in_row: Int
    ) raises:
        """Widen a BOOL source column into 8-byte I64 key cells (0 / 1).

        `write_bool_batch` writes ONE byte, which is right for a 1-byte cell and
        wrong for an 8-byte key cell (7 bytes would carry scratch). Scalar loop
        via `load_bit` — a group key over a boolean has at most two groups, so
        there is nothing here worth SIMD-staging."""
        var n = col.length()
        self.ensure_capacity_rows(n)
        for row in range(n):
            var bit: Bool = col.load_bit(row)
            self.write_fixed[DType.int64](
                row, col_offset_in_row, Scalar[DType.int64](1 if bit else 0)
            )
        if n > self.n_rows:
            self.n_rows = n

    def write_decimal128_batch[bo: Origin[mut=False], //](
        mut self,
        col_lo: Decimal128CellView[bo],
        col_hi: Decimal128CellView[bo],
        col_offset_in_row: Int,
    ) raises:
        """Decimal128 encoder — 16 bytes per cell (LO|HI u64 pair).

        Layout:
        Decimal128 is modeled as TWO sequential u64 cells in RowBlock. The
        encoder writes LO at `col_offset_in_row + 0` and HI at
        `col_offset_in_row + 8`.

        C-w3 DECIMAL128-STRIDE FIX: `col_lo` / `col_hi` are now
        `Decimal128CellView`s that read the correct half of the 16-byte Arrow
        cell (`row * 16 + {0,8}`) — the prior `ColView[DType.uint64]` pair had
        an 8-byte stride that mis-read every row >= 1. Per-row scalar copy (the
        two-half write is not a contiguous SIMD run since lo/hi land at
        different row-cell offsets).

        Caller invariant: `col_lo.length() == col_hi.length()`.
        """
        var n = col_lo.length()
        if col_hi.length() != n:
            raise Error(
                "RowBlock.write_decimal128_batch: lo.length()="
                + String(n) + " != hi.length()="
                + String(col_hi.length())
            )
        self.ensure_capacity_rows(n)
        for row in range(n):
            var lo = col_lo.load[1](row)[0]
            var hi = col_hi.load[1](row)[0]
            self.write_fixed[DType.uint64](row, col_offset_in_row, lo)
            self.write_fixed[DType.uint64](row, col_offset_in_row + 8, hi)
        if n > self.n_rows:
            self.n_rows = n

    def write_var_string_batch[bo: Origin[mut=False], //](
        mut self,
        col: StringColumnView[bo],
        col_offset_in_row: Int,
    ) raises:
        """Var-width string encoder.

        Per-row encode writes an 8-byte
        (offset, length) descriptor cell into the row's fixed-cell region
        at `col_offset_in_row`; payload bytes are appended to
        `_var_storage`. Low 4 bytes = offset, high 4 bytes = length
        (little-endian) — symmetric with the
        `ColumnFormatStorage.write_slot_str` cell layout.

        Capacity contract:
          - Caller MUST call `ensure_capacity_rows(n)` (or
            `reserve_rows(additional)`) before this method to size
            `_fixed_storage` for the row range.
          - This method calls `reserve_var_bytes(total_payload)` BEFORE
            the inner per-row loop; the inner loop is capacity-safe by
            precondition.

        Parameters:
            bo: Borrow origin of the source `StringColumnView`.
        """
        var n = col.length()
        if n == 0:
            return
        # Pre-compute total payload bytes so the var-heap grows ONCE
        # (amortized doubling); inner loop is capacity-safe.
        var total_bytes = col.n_data_bytes()
        self.reserve_var_bytes(total_bytes)
        # Per-row encode: copy bytes to var-storage; write 8B desc cell.
        for row in range(n):
            var sv = col.get(row)
            var length = sv.length()
            var dst_off = self.var_storage_used
            # Byte-by-byte copy. The byte_at(i) accessor re-derives the
            # column ref each call; LLVM hoists the ref-deref out of the
            # inner loop under @always_inline on the parent batch.
            # A libc memcpy + bulk ByteView accessor would cut the copy
            # cost (a SIMD string comparator + bulk byte ops).
            for i in range(length):
                self._var_storage.write_u8_at(dst_off + i, sv.byte_at(i))
            self.var_storage_used = dst_off + length
            # Write 8B (offset, length) descriptor cell at
            # (row, col_offset_in_row).
            var desc_cell: UInt64 = (
                UInt64(Int(length)) << 32
            ) | (UInt64(Int(dst_off)) & UInt64(0xFFFFFFFF))
            var byte_off = row * self.fixed_row_stride + col_offset_in_row
            self._fixed_storage.write_u64_le_at(byte_off, desc_cell)

    # ─── The NULL-DISCRIMINATING var-width KEY cell primitives ──
    #
    # Siblings of the three general var-string writers above, and deliberately
    # NOT a widening of them: a DATA column's cell carries its bytes, a KEY
    # cell carries a leading `_VAR_KEY_TAG_*` byte so that NULL and `''` are
    # not the same payload. See the tag constants' block comment for why the
    # discriminator lives in the payload rather than in the descriptor.
    # ----------------------------------------------------------------------

    def write_var_string_key_batch[bo: Origin[mut=False], //](
        mut self,
        col: StringColumnView[bo],
        col_offset_in_row: Int,
    ) raises:
        """Var-width KEY encoder — `write_var_string_batch` plus the leading
        `_VAR_KEY_TAG_VALUE` byte on every cell.

        Writes every row as NON-NULL. The caller overwrites the NULL rows
        afterwards with `write_var_string_key_null_cell`, which is why this
        stays the bulk one-pass shape for the (overwhelmingly common) column
        that declares no nullability at all.

        Capacity contract is `write_var_string_batch`'s, with one extra byte
        reserved per row for the tag.

        Parameters:
            bo: Borrow origin of the source `StringColumnView`.
        """
        var n = col.length()
        if n == 0:
            return
        self.reserve_var_bytes(col.n_data_bytes() + n)
        for row in range(n):
            var sv = col.get(row)
            var length = sv.length()
            var dst_off = self.var_storage_used
            self._var_storage.write_u8_at(dst_off, _VAR_KEY_TAG_VALUE)
            for i in range(length):
                self._var_storage.write_u8_at(dst_off + 1 + i, sv.byte_at(i))
            self.var_storage_used = dst_off + 1 + length
            var desc_cell: UInt64 = (
                UInt64(Int(length + 1)) << 32
            ) | (UInt64(Int(dst_off)) & UInt64(0xFFFFFFFF))
            var byte_off = row * self.fixed_row_stride + col_offset_in_row
            self._fixed_storage.write_u64_le_at(byte_off, desc_cell)

    def write_var_string_key_cell(
        mut self, row: Int, col_offset_in_row: Int, bytes: Span[UInt8, _]
    ) raises:
        """Write one NON-NULL var-width KEY cell (tag byte + `bytes`).

        The per-CELL sibling of `write_var_string_key_batch`, used by the
        DICTIONARY arm of `_dispatch_encode_key_col` — which resolves a code to
        its bytes one row at a time and must land byte-identically to the flat
        arm, tag included."""
        var length = len(bytes)
        self.reserve_var_bytes(length + 1)
        var dst_off = self.var_storage_used
        self._var_storage.write_u8_at(dst_off, _VAR_KEY_TAG_VALUE)
        if length > 0:
            self._var_storage.copy_from_span_at(dst_off + 1, bytes)
        self.var_storage_used = dst_off + 1 + length
        var desc_cell: UInt64 = (UInt64(length + 1) << 32) | (
            UInt64(dst_off) & UInt64(0xFFFFFFFF)
        )
        var byte_off = row * self.fixed_row_stride + col_offset_in_row
        self._fixed_storage.write_u64_le_at(byte_off, desc_cell)

    def write_var_string_key_null_cell(
        mut self, row: Int, col_offset_in_row: Int
    ) raises:
        """Write one NULL var-width KEY cell: a payload of exactly the
        `_VAR_KEY_TAG_NULL` byte.

        ⭐ THIS IS WHAT MAKES ALL NULLS ONE GROUP AND KEEPS THEM OFF `''`. Every
        NULL key in the query produces the SAME single-byte payload, so the
        directory folds them together; no non-NULL key can produce it, because
        every non-NULL payload starts with `_VAR_KEY_TAG_VALUE`. That is the
        spill route's spelling of `hash_agg_untyped`'s `_NULL_KEY_HASH` — same
        semantics, reached through byte equality instead of a bitmap read.

        Overwriting a cell this block already wrote (the bulk-then-patch shape
        `_dispatch_encode_key_col` uses) ORPHANS that cell's earlier payload
        bytes in the var heap. That is deliberate and bounded: the heap being
        patched is the per-batch PROBE block's, which is reset per batch, and a
        group block never learns the difference because `copy_var_string_cell`
        re-appends only the payload the descriptor still names."""
        self.reserve_var_bytes(1)
        var dst_off = self.var_storage_used
        self._var_storage.write_u8_at(dst_off, _VAR_KEY_TAG_NULL)
        self.var_storage_used = dst_off + 1
        var desc_cell: UInt64 = (UInt64(1) << 32) | (
            UInt64(dst_off) & UInt64(0xFFFFFFFF)
        )
        var byte_off = row * self.fixed_row_stride + col_offset_in_row
        self._fixed_storage.write_u64_le_at(byte_off, desc_cell)

    def var_string_key_is_null_at(
        self, row: Int, col_offset_in_row: Int
    ) raises -> Bool:
        """True iff the var-width KEY cell at (`row`, `col_offset_in_row`) is
        the NULL group's cell.

        RAISES on a cell with a zero-length payload rather than answering. Every
        writer above emits at least the tag byte, so a tagless cell means a KEY
        was encoded through a DATA-column writer — the exact confusion that
        would put NULL and `''` back in one group, and the last place it can
        still be caught loudly."""
        var byte_off = row * self.fixed_row_stride + col_offset_in_row
        var desc_cell = self._fixed_storage.read_u64_le_at(byte_off)
        var offset = Int(desc_cell & UInt64(0xFFFFFFFF))
        var length = Int(desc_cell >> 32)
        if length < 1:
            raise Error(
                "RowBlock.var_string_key_is_null_at: the var-width KEY cell at"
                " row " + String(row) + ", offset " + String(col_offset_in_row)
                + " carries a zero-length payload, so it has no"
                " NULL-discriminator tag byte — it was written by a DATA-column"
                " encoder (`write_var_string_batch` / `write_var_string_cell`)"
                " instead of by `write_var_string_key_*`."
            )
        return self._var_storage.read_u8_at(offset) == _VAR_KEY_TAG_NULL

    @always_inline
    def var_string_key_payload_at[
        _mut: Bool, o: Origin[mut=_mut], //,
    ](ref [o] self, row: Int, col_offset_in_row: Int) -> Span[UInt8, o]:
        """BORROWED view of one var-width KEY cell's payload WITHOUT its tag
        byte — i.e. the key's own bytes, which is what the drain publishes.

        The `var_string_span_at` of the KEY family. A NULL cell yields a
        zero-length span; callers ask `var_string_key_is_null_at` FIRST, because
        a zero-length span is also what the EMPTY STRING yields.

        SAFETY: identical to `var_string_span_at` — `_var_base_ptr_ro` is this
        struct's origin-tied var-blob base accessor and the descriptor-write
        contract in `write_var_string_key_*` guarantees
        `offset + length <= var_storage_used <= capacity`, with `length >= 1`
        for every cell those writers produce. The raw pointer does NOT escape;
        it is consumed here into a `Span` carrying the caller's borrow origin
        `o`. The `max(...)` clamp keeps a corrupt descriptor from producing a
        NEGATIVE length (which would widen the span, not narrow it); the loud
        report of that case is `var_string_key_is_null_at`.
        """
        var byte_off = row * self.fixed_row_stride + col_offset_in_row
        var desc_cell = self._fixed_storage.read_u64_le_at(byte_off)
        var offset = Int(desc_cell & UInt64(0xFFFFFFFF))
        var length = Int(desc_cell >> 32)
        return Span[UInt8, o](
            unsafe_ptr=self._var_base_ptr_ro() + offset + 1,
            length=max(length - 1, 0),
        )

    def write_var_binary_batch[bo: Origin[mut=False], //](
        mut self,
        col: BinaryColumnView[bo],
        col_offset_in_row: Int,
    ) raises:
        """Var-width binary encoder. Same shape as `write_var_string_batch`
        (semantic distinction only -- bytes are NOT validated as UTF-8).
        """
        var n = col.length()
        if n == 0:
            return
        var total_bytes = col.n_data_bytes()
        self.reserve_var_bytes(total_bytes)
        for row in range(n):
            var sv = col.get(row)
            var length = sv.length()
            var dst_off = self.var_storage_used
            for i in range(length):
                self._var_storage.write_u8_at(dst_off + i, sv.byte_at(i))
            self.var_storage_used = dst_off + length
            var desc_cell: UInt64 = (
                UInt64(Int(length)) << 32
            ) | (UInt64(Int(dst_off)) & UInt64(0xFFFFFFFF))
            var byte_off = row * self.fixed_row_stride + col_offset_in_row
            self._fixed_storage.write_u64_le_at(byte_off, desc_cell)

    def read_var_string_at(
        self, row: Int, col_offset_in_row: Int
    ) raises -> List[UInt8]:
        """Decode one var-string cell at (row, col_offset_in_row) as a
        copied `List[UInt8]`.

        Production decoder paired with `write_var_string_batch`. Reads
        the 8B (offset, length) descriptor cell from the row's fixed
        region; copies `length` bytes from `_var_storage` into a fresh
        `List[UInt8]`.

        Raises:
            On `row` out of `[0, n_rows)`.
        """
        if row < 0 or row >= self.n_rows:
            raise Error(
                "RowBlock.read_var_string_at: row out of range [0, "
                + String(self.n_rows)
                + ")"
            )
        var byte_off = row * self.fixed_row_stride + col_offset_in_row
        var desc_cell = self._fixed_storage.read_u64_le_at(byte_off)
        var offset = Int(desc_cell & UInt64(0xFFFFFFFF))
        var length = Int(desc_cell >> 32)
        # One sized alloc + one bulk extend, not a
        # `read_u8_at` + `append` PER BYTE against a `List` that started at zero
        # capacity (so every cell also paid log2(len) reallocs).
        var out = List[UInt8](capacity=length)
        if length > 0:
            out.extend(self._var_storage.view_range_ro(offset, length).into_span())
        return out^

    @always_inline
    def var_string_span_at[
        _mut: Bool, o: Origin[mut=_mut], //,
    ](ref [o] self, row: Int, col_offset_in_row: Int) -> Span[UInt8, o]:
        """BORROWED view of one var-string cell's payload — the zero-copy
        sibling of `read_var_string_at`.

        CSVPERF-VARFAST. `read_var_string_at` returns an OWNED
        `List[UInt8]`, which is the right primitive when the bytes must outlive
        the block. The row->column finalize bridge is the opposite case: it
        reads a cell and IMMEDIATELY memcpies it into an Arrow string builder,
        so the owned copy is pure overhead — one heap allocation per CELL, i.e.
        ~126M allocations for a 6M-row x 21-col passthrough.

        This is NOT an additive parallel API: it is the
        borrow-vs-own pair (`as_slice` vs `to_vec`), and the two have different
        lifetimes by design. The returned Span is tied to `o` = the borrow of
        `self`, so the compiler refuses any use after the block dies; there is
        NO wildcard origin and no `UnsafePointer` in the signature.

        The caller must pass a `row` in `[0, n_rows)` — unlike
        `read_var_string_at` this accessor does not raise, because it sits in a
        per-cell finalize loop whose bound the caller already established.
        """
        var byte_off = row * self.fixed_row_stride + col_offset_in_row
        var desc_cell = self._fixed_storage.read_u64_le_at(byte_off)
        var offset = Int(desc_cell & UInt64(0xFFFFFFFF))
        var length = Int(desc_cell >> 32)
        # SAFETY: `_var_base_ptr_ro` is this struct's established origin-tied
        # var-blob base accessor (the same one every other var-cell reader
        # uses); the descriptor-write contract in `write_var_string_cell`
        # guarantees `offset + length <= var_storage_used <= capacity`. The raw
        # pointer does NOT escape — it is consumed here into a `Span` carrying
        # the caller's borrow origin `o`, so the compiler tracks liveness
        # against `self`. `view_range_ro` cannot be used directly: it returns a
        # view over `origin_of(self._var_storage)`, a FIELD sub-origin that does
        # not implicitly widen to the whole-struct borrow `o`.
        return Span[UInt8, o](
            unsafe_ptr=self._var_base_ptr_ro() + offset, length=length
        )

    # ─── Per-CELL var-string primitives ─
    #
    # The `write_var_string_batch` encoder above is COLUMN-driven (it walks a
    # whole `StringColumnView` and writes one column's cells across all rows).
    # The row-streaming path (the row-streaming segment / the CSV RowBlock reader /
    # the row runtime breakers) builds RowBlocks ROW-AT-A-TIME and copies rows
    # BETWEEN RowBlocks, so it needs a per-CELL write + a var-aware row copy.
    # These mirror the batch encoder's cell layout exactly (8-byte
    # (offset, length) descriptor cell at `col_offset_in_row`; low 4B offset,
    # high 4B length, little-endian) so a per-cell write is byte-identical to
    # a batch write for the same value.
    # ---------------------------------------------------------------------

    def write_var_string_cell(
        mut self, row: Int, col_offset_in_row: Int, bytes: Span[UInt8, _]
    ) raises:
        """Write one var-string cell at (row, col_offset_in_row).

        Appends `bytes` to `_var_storage` and writes the 8-byte
        (offset, length) descriptor cell into the row's fixed region. The
        caller MUST have reserved fixed-row capacity for `row` (capacity contract);
        this method grows `_var_storage` as needed.

        The payload append is ONE `memcpy`
        (`OwnedAlignedBuffer.copy_from_span_at`), not a `write_u8_at` loop. That
        loop cost a call + an offset computation PER BYTE on every var cell of
        every row-native CSV / JSONL read. `reserve_var_bytes` immediately above
        already establishes `dst_off + length <= capacity`, which is exactly
        `copy_from_span_at`'s documented precondition — so this is a same-bytes
        rewrite under the same contract, not a widening of it.
        """
        var length = len(bytes)
        self.reserve_var_bytes(length)
        var dst_off = self.var_storage_used
        self._var_storage.copy_from_span_at(dst_off, bytes)
        self.var_storage_used = dst_off + length
        var desc_cell: UInt64 = (UInt64(length) << 32) | (
            UInt64(dst_off) & UInt64(0xFFFFFFFF)
        )
        var byte_off = row * self.fixed_row_stride + col_offset_in_row
        self._fixed_storage.write_u64_le_at(byte_off, desc_cell)

    def copy_var_string_cell(
        mut self,
        dst_row: Int,
        dst_col_offset_in_row: Int,
        imm src: RowBlock,
        src_row: Int,
        src_col_offset_in_row: Int,
    ) raises:
        """Copy one var-string cell from `src` into `self`, re-appending the
        payload bytes into `self._var_storage` (var offsets are NOT
        position-stable across blocks, so the bytes must be copied, not the
        descriptor cell).

        Used by the row-streaming row copy (`_append_block`) and the breaker
        emit paths when the column is varlen. The caller MUST have reserved
        fixed-row capacity for `dst_row`.

        The payload move is ONE `memcpy`,
        not a `read_u8_at`/`write_u8_at` call PAIR plus two offset computations
        PER BYTE. This is the same rewrite `write_var_string_cell` immediately
        above already took (CSVPERF-VARFAST) and for the same reason, but this
        one sits on a hotter path: the var-width STRING group key puts it on
        the innermost per-group step of the grace-hash spill route —
        `_copy_key_into_row` on every insert miss, `_copy_full_row_from` on
        every combine miss, and once per surviving row per sub-partition in
        `partition_group_rows_to_sab`.

        ⛔ THE REBASE IS NOT PART OF WHAT CHANGED, AND MUST NOT BE. The
        descriptor is still rewritten to `dst_off` — this block's OWN var
        cursor — because var offsets are not position-stable across blocks.
        Dropping that while keeping the faster payload move is a SILENT WRONG
        GROUP KEY, not a crash: the stale offset still lands inside the
        destination heap and still reads. `test_row_block_var_string_copy.mojo`
        is the guard, and it was shown to fail 5/5 against exactly that variant.
        """
        var src_byte_off = (
            src_row * src.fixed_row_stride + src_col_offset_in_row
        )
        var desc_cell = src._fixed_storage.read_u64_le_at(src_byte_off)
        var src_off = Int(desc_cell & UInt64(0xFFFFFFFF))
        var length = Int(desc_cell >> 32)
        self.reserve_var_bytes(length)
        var dst_off = self.var_storage_used
        if length > 0:
            self._var_storage.copy_from_span_at(
                dst_off,
                src._var_storage.view_range_ro(src_off, length).into_span(),
            )
        self.var_storage_used = dst_off + length
        var new_desc: UInt64 = (UInt64(length) << 32) | (
            UInt64(dst_off) & UInt64(0xFFFFFFFF)
        )
        var dst_byte_off = (
            dst_row * self.fixed_row_stride + dst_col_offset_in_row
        )
        self._fixed_storage.write_u64_le_at(dst_byte_off, new_desc)

    def copy_nested_cell(
        mut self,
        dst_row: Int,
        dst_col_offset_in_row: Int,
        imm src: RowBlock,
        src_row: Int,
        src_col_offset_in_row: Int,
        col_kind: UInt8,
        elem_kind: UInt8,
        elem_width: Int,
    ) raises:
        """Copy one nested (COL_LIST / COL_STRUCT) cell
        from `src` into `self`, re-appending the WHOLE self-describing payload
        bytes into `self._var_storage` (var offsets are NOT position-stable
        across blocks — the descriptor's `var_offset` must be rewritten to
        `self`'s fresh offset).

        Unlike `copy_var_string_cell`, the descriptor's high-4-byte `count`
        field is NOT a byte length for a LIST cell (it is the element count, or
        `_LIST_NULL_SENTINEL`); the payload byte length is recomputed from the
        cell's self-describing layout via `_nested_payload_byte_len`. The
        descriptor `(var_off, count)` pair is copied verbatim EXCEPT `var_off` is
        rebased to `self`'s var-storage cursor.

        `col_kind` is COL_LIST or COL_STRUCT; for COL_LIST `elem_kind` selects
        the element format (COL_FIXED => LIST<primitive> with `elem_width`-byte
        elements; COL_VAR_STRING / COL_STRUCT => var-of-var blob layout) — these
        come from the segment's nested-col-type sidecar. For COL_STRUCT the
        descriptor `count` IS the record byte length, so `elem_*` are ignored.
        """
        var src_byte_off = (
            src_row * src.fixed_row_stride + src_col_offset_in_row
        )
        var desc_cell = src._fixed_storage.read_u64_le_at(src_byte_off)
        var src_off = Int(desc_cell & UInt64(0xFFFFFFFF))
        var count = Int(desc_cell >> 32)
        var payload_len = RowBlock._nested_payload_byte_len(
            src, src_off, count, col_kind, elem_kind, elem_width
        )
        self.reserve_var_bytes(payload_len)
        var dst_off = self.var_storage_used
        for i in range(payload_len):
            self._var_storage.write_u8_at(
                dst_off + i, src._var_storage.read_u8_at(src_off + i)
            )
        self.var_storage_used = dst_off + payload_len
        # Rebase the descriptor's var_offset to the new cursor; keep `count`.
        var new_desc: UInt64 = (UInt64(count) << 32) | (
            UInt64(dst_off) & UInt64(0xFFFFFFFF)
        )
        var dst_byte_off = (
            dst_row * self.fixed_row_stride + dst_col_offset_in_row
        )
        self._fixed_storage.write_u64_le_at(dst_byte_off, new_desc)

    @staticmethod
    def _nested_payload_byte_len(
        imm src: RowBlock,
        var_off: Int,
        count: Int,
        col_kind: UInt8,
        elem_kind: UInt8,
        elem_width: Int,
    ) -> Int:
        """Compute the total var-storage byte length of one nested cell's
        self-describing payload (copy helper). `count` is the descriptor's
        high-4-byte field (element count for LIST, record byte length for
        STRUCT). Mirrors the byte budgets `write_list_*_cell` /
        `serialize_struct_record` allocate, so a copy is byte-exact."""
        if col_kind == COL_STRUCT:
            # Descriptor `count` IS the struct record byte length (incl. the
            # struct-null flag byte / field bitmap / per-field slots).
            return count
        # COL_LIST. A NULL list (sentinel) has NO payload.
        if count == _LIST_NULL_SENTINEL:
            return 0
        var n = count
        var bitmap_bytes = (n + 7) >> 3
        if elem_kind == COL_FIXED or elem_kind == COL_DECIMAL128:
            # LIST<primitive>: [validity sub-bitmap][n × elem_width].
            return bitmap_bytes + n * elem_width
        # LIST<string> / LIST<STRUCT>: [validity][(n+1) u32 offsets][blob].
        # The blob length is offsets[n] (the last cumulative offset).
        var offs_off = var_off + bitmap_bytes
        var blob_len = 0
        if n > 0:
            blob_len = Int(src._var_storage.read_u32_le_at(offs_off + n * 4))
        return bitmap_bytes + (n + 1) * 4 + blob_len

    def var_string_cell_equal(
        imm self,
        row_a: Int,
        col_offset_a: Int,
        imm other: RowBlock,
        row_b: Int,
        col_offset_b: Int,
    ) raises -> Bool:
        """Byte-lexicographic equality of two var-string cells (possibly in
        different RowBlocks). Used by breaker key equality for STRING keys."""
        var off_a = row_a * self.fixed_row_stride + col_offset_a
        var desc_a = self._fixed_storage.read_u64_le_at(off_a)
        var vo_a = Int(desc_a & UInt64(0xFFFFFFFF))
        var len_a = Int(desc_a >> 32)
        var off_b = row_b * other.fixed_row_stride + col_offset_b
        var desc_b = other._fixed_storage.read_u64_le_at(off_b)
        var vo_b = Int(desc_b & UInt64(0xFFFFFFFF))
        var len_b = Int(desc_b >> 32)
        if len_a != len_b:
            return False
        for i in range(len_a):
            if self._var_storage.read_u8_at(
                vo_a + i
            ) != other._var_storage.read_u8_at(vo_b + i):
                return False
        return True

    def var_string_cell_fnv1a(
        imm self, row: Int, col_offset_in_row: Int
    ) -> UInt64:
        """FNV-1a 64-bit hash of one var-string cell's payload bytes.

        Matches the byte-hash convention the column-path string hashers use
        (FNV-1a over the raw UTF-8 bytes) so a STRING group/distinct key
        hashes identically regardless of orientation."""
        var byte_off = row * self.fixed_row_stride + col_offset_in_row
        var desc = self._fixed_storage.read_u64_le_at(byte_off)
        var vo = Int(desc & UInt64(0xFFFFFFFF))
        var length = Int(desc >> 32)
        var h: UInt64 = 0xCBF29CE484222325
        for i in range(length):
            h = (h ^ UInt64(Int(self._var_storage.read_u8_at(vo + i)))) * (
                0x100000001B3
            )
        return h

    def var_string_cell_cmp(
        imm self,
        row_a: Int,
        col_offset_a: Int,
        imm other: RowBlock,
        row_b: Int,
        col_offset_b: Int,
    ) raises -> Int:
        """Byte-lexicographic compare of two var-string cells. Returns -1 if
        a < b, 0 if equal, 1 if a > b. Used by the row SORT breaker for STRING
        sort keys (the byte-lex order matches the column path's STRING sort)."""
        var off_a = row_a * self.fixed_row_stride + col_offset_a
        var desc_a = self._fixed_storage.read_u64_le_at(off_a)
        var vo_a = Int(desc_a & UInt64(0xFFFFFFFF))
        var len_a = Int(desc_a >> 32)
        var off_b = row_b * other.fixed_row_stride + col_offset_b
        var desc_b = other._fixed_storage.read_u64_le_at(off_b)
        var vo_b = Int(desc_b & UInt64(0xFFFFFFFF))
        var len_b = Int(desc_b >> 32)
        var m = len_a if len_a < len_b else len_b
        for i in range(m):
            var ba = self._var_storage.read_u8_at(vo_a + i)
            var bb = other._var_storage.read_u8_at(vo_b + i)
            if ba < bb:
                return -1
            if ba > bb:
                return 1
        if len_a < len_b:
            return -1
        if len_a > len_b:
            return 1
        return 0

    # ─── Per-CELL validity primitives ─
    #
    # The row-streaming path (Path 4) stores an OPTIONAL per-row validity
    # bitmap as a trailing byte region inside `_fixed_storage`, AFTER the
    # fixed-cell region. The bitmap is `ceil(N_cols/8)` bytes per row at byte
    # offset `validity_offset` within the row (RowLayout owns the offset; it
    # equals the sum of fixed-cell widths). The bitmap is present iff the
    # layout is nullable (`RowLayout.has_validity`) — non-null numeric/STRING
    # rows carry NO validity bytes and pay nothing (the stride == sum of cell
    # widths, the existing fast-copy paths are unchanged).
    #
    # CONVENTION: internally bit=1 means NULL, bit=0 means VALID. This matches
    # the memset-zero default (a freshly-reserved row is all-valid with no
    # explicit write), so the writer only flips a bit ON when a null is
    # observed. The bridge inverts to the Arrow convention (bit=1 == valid)
    # when emitting a nullable column, so the external output is byte-identical
    # to the column path.
    #
    # The bitmap travels INSIDE the row, so the whole-row memcpy fast copy
    # (`append_rows_from`) carries validity bits correctly when both blocks
    # share the same nullable layout. The per-cell copy paths
    # (`copy_var_string_cell` callers, `_append_block` slow path) copy the bit
    # explicitly via `copy_cell_validity`.
    # ---------------------------------------------------------------------

    @always_inline
    def set_cell_null(
        mut self, row: Int, validity_offset: Int, col_idx: Int
    ):
        """Mark logical column `col_idx` of `row` as NULL (set bit=1).

        `validity_offset` is the byte offset of the row's validity bitmap
        (== `RowLayout.validity_offset`). `col_idx` indexes the LOGICAL
        column (not a byte offset). Caller guarantees the layout is nullable
        (the validity region is reserved within the stride).
        """
        var byte_off = (
            row * self.fixed_row_stride + validity_offset + (col_idx >> 3)
        )
        var cur = self._fixed_storage.read_u8_at(byte_off)
        self._fixed_storage.write_u8_at(
            byte_off, cur | (UInt8(1) << UInt8((col_idx & 7)))
        )

    @always_inline
    def is_cell_null(
        self, row: Int, validity_offset: Int, col_idx: Int
    ) -> Bool:
        """True iff logical column `col_idx` of `row` is NULL (bit=1)."""
        var byte_off = (
            row * self.fixed_row_stride + validity_offset + (col_idx >> 3)
        )
        var cur = self._fixed_storage.read_u8_at(byte_off)
        return ((cur >> UInt8((col_idx & 7))) & 1) == 1

    def copy_cell_validity(
        mut self,
        dst_row: Int,
        dst_validity_offset: Int,
        dst_col_idx: Int,
        imm src: RowBlock,
        src_row: Int,
        src_validity_offset: Int,
        src_col_idx: Int,
    ):
        """Copy one logical column's null bit from `src` into `self`.

        Used by the per-cell row-copy paths (`_append_block` slow path,
        project) when the layout is nullable. The fast whole-row memcpy path
        already carries the bits inside the row bytes."""
        if src.is_cell_null(src_row, src_validity_offset, src_col_idx):
            self.set_cell_null(dst_row, dst_validity_offset, dst_col_idx)

    # ─── Nested cell primitives ─
    #
    # Depth-1 nested cell layout for COL_LIST / COL_STRUCT. See
    # Scope bounds:
    # in-scope bounds: LIST<primitive>, LIST<string> (var-of-var), STRUCT<flat>,
    # LIST<STRUCT<flat>>. MAP and arbitrary recursion depth are OUT OF SCOPE
    # (the readers / scan widening hard-raise per the existing nested-type deferral
    # style; these primitives never SEE those shapes).
    #
    # All nested cells reuse the existing var-cell discipline: an 8-byte
    # (var_offset:u32, count:u32) descriptor in the row's fixed region at
    # `col_offset_in_row` (byte-identical machinery to `write_var_string_cell`),
    # whose `var_offset` points at a self-describing payload record in
    # `_var_storage`. The payload formats:
    #
    #   LIST<primitive>  payload @ var_offset:
    #     [validity sub-bitmap: ceil(n/8) bytes; bit=1 => element NULL]
    #     [n × elem_width bytes, element values back-to-back, little-endian]
    #   descriptor count field = n_elems (or _LIST_NULL_SENTINEL for a NULL list).
    #
    #   LIST<string>     payload @ var_offset (the var-of-var, high-bug-density):
    #     [validity sub-bitmap: ceil(n/8) bytes]
    #     [offsets: (n+1) × u32 LE, Arrow-style cumulative, relative to blob start]
    #     [blob: concatenated element UTF-8 bytes]
    #   descriptor count field = n_elems (or _LIST_NULL_SENTINEL).
    #
    #   STRUCT<flat>     payload @ var_offset = ONE struct record (see below).
    #   descriptor length field = record byte length (0 means the descriptor
    #   itself encodes a NULL struct — see `write_struct_null_cell`).
    #
    #   STRUCT record (self-describing, the LIST<STRUCT> element unit too):
    #     [1 byte: struct-null flag — 1 == NULL struct (record ends here)]
    #     [field-validity sub-bitmap: ceil(k/8) bytes; bit=1 => field NULL]
    #     for each field in declared order:
    #       fixed primitive : `fixed_width` bytes, value LE
    #       var-string      : u32 LE length prefix + that many payload bytes
    #   A NULL field still reserves its fixed/length slot (zeroed) so the
    #   record is positional + fixed-shape per the field-spec.
    #
    # CONVENTION: element/field validity bit=1 means NULL (matches the row
    # validity convention `set_cell_null`: memset-zero default == all-valid,
    # writer only flips a bit ON for an observed null). The row→col gather
    # inverts to Arrow's bit=1==valid when emitting ListArray /
    # StructArray, exactly as the top-level validity bridge does.
    #
    # ENCAPSULATION: zero UnsafePointer in any signature below. Pointer
    # arithmetic is confined to the same-module `_var_storage` /
    # `_fixed_storage` (OwnedAlignedBuffer) typed-LE accessors — the public
    # cell methods take/return only Span / List / typed scalars (mirror of
    # `write_var_string_cell` / `read_var_string_at`).
    # ---------------------------------------------------------------------

    def _write_nested_desc_cell(
        mut self, row: Int, col_offset_in_row: Int, var_off: Int, count: Int
    ):
        """Write the 8-byte (var_offset:u32, count:u32) descriptor cell into
        the row's fixed region. Same packing as `write_var_string_cell`
        (low 4 bytes = offset, high 4 bytes = count, little-endian)."""
        var desc_cell: UInt64 = (UInt64(count) << 32) | (
            UInt64(var_off) & UInt64(0xFFFFFFFF)
        )
        var byte_off = row * self.fixed_row_stride + col_offset_in_row
        self._fixed_storage.write_u64_le_at(byte_off, desc_cell)

    @always_inline
    def _read_nested_desc_cell(
        self, row: Int, col_offset_in_row: Int
    ) -> Tuple[Int, Int]:
        """Decode the (var_offset, count) descriptor cell. Returns
        (var_off, count)."""
        var byte_off = row * self.fixed_row_stride + col_offset_in_row
        var desc_cell = self._fixed_storage.read_u64_le_at(byte_off)
        var var_off = Int(desc_cell & UInt64(0xFFFFFFFF))
        var count = Int(desc_cell >> 32)
        return (var_off, count)

    # ─── LIST<primitive> ────────────────────────────────────────────────

    def write_list_primitive_cell[
        DT: DType
    ](
        mut self,
        row: Int,
        col_offset_in_row: Int,
        values: Span[Scalar[DT], _],
        elem_nulls: Span[Bool, _],
    ) raises:
        """Write one LIST<primitive> cell at (row, col_offset_in_row).

        `values[i]` is element i; `elem_nulls[i]` True iff element i is NULL.
        `len(elem_nulls)` must equal `len(values)`. Payload (validity sub-
        bitmap + element values) is appended to `_var_storage`; the 8-byte
        descriptor cell is written into the row's fixed region. The caller
        MUST have reserved fixed-row capacity for `row` (capacity contract).

        For an empty list pass empty spans (n_elems==0). For a NULL list use
        `write_list_null_cell` instead.
        """
        var n = len(values)
        if len(elem_nulls) != n:
            raise Error(
                "RowBlock.write_list_primitive_cell: values len "
                + String(n)
                + " != elem_nulls len "
                + String(len(elem_nulls))
            )
        var elem_w = size_of[Scalar[DT]]()
        var bitmap_bytes = (n + 7) >> 3
        var payload_bytes = bitmap_bytes + n * elem_w
        self.reserve_var_bytes(payload_bytes)
        var base = self.var_storage_used
        # Zero the validity sub-bitmap (memset default == all-valid).
        for b in range(bitmap_bytes):
            self._var_storage.write_u8_at(base + b, UInt8(0))
        # Elements + element-null bits.
        var elems_off = base + bitmap_bytes
        for i in range(n):
            if elem_nulls[i]:
                var bidx = base + (i >> 3)
                var cur = self._var_storage.read_u8_at(bidx)
                self._var_storage.write_u8_at(
                    bidx, cur | (UInt8(1) << UInt8((i & 7)))
                )
            self._write_le_scalar[DT](elems_off + i * elem_w, values[i])
        self.var_storage_used = base + payload_bytes
        self._write_nested_desc_cell(row, col_offset_in_row, base, n)

    def read_list_primitive_at[
        DT: DType
    ](
        self, row: Int, col_offset_in_row: Int
    ) raises -> Tuple[List[Scalar[DT]], List[Bool]]:
        """Decode one LIST<primitive> cell. Returns (values, elem_nulls).

        For a NULL list (`is_list_null` True) both lists are empty; callers
        should test `is_list_null` first. For an empty list both are empty."""
        if row < 0 or row >= self.n_rows:
            raise Error(
                "RowBlock.read_list_primitive_at: row out of range [0, "
                + String(self.n_rows) + ")"
            )
        var off_count = self._read_nested_desc_cell(row, col_offset_in_row)
        var base = off_count[0]
        var n = off_count[1]
        var vals = List[Scalar[DT]]()
        var nulls = List[Bool]()
        if n == _LIST_NULL_SENTINEL or n == 0:
            return (vals^, nulls^)
        var elem_w = size_of[Scalar[DT]]()
        var bitmap_bytes = (n + 7) >> 3
        var elems_off = base + bitmap_bytes
        for i in range(n):
            var bit = self._var_storage.read_u8_at(base + (i >> 3))
            nulls.append(((bit >> UInt8((i & 7))) & 1) == 1)
            vals.append(self._read_le_scalar[DT](elems_off + i * elem_w))
        return (vals^, nulls^)

    # ─── LIST<string> (var-of-var; the high-bug-density cell) ────────────

    def write_list_string_cell(
        mut self,
        row: Int,
        col_offset_in_row: Int,
        elems: List[List[UInt8]],
        elem_nulls: Span[Bool, _],
    ) raises:
        """Write one LIST<string> cell at (row, col_offset_in_row).

        `elems[i]` is element i's UTF-8 bytes; `elem_nulls[i]` True iff
        element i is NULL (its bytes, if any, are ignored). Payload layout:
        validity sub-bitmap, then (n+1) u32 cumulative offsets, then the
        concatenated blob. The caller MUST have reserved fixed-row capacity.

        Empty list = empty `elems` + empty `elem_nulls`. NULL list uses
        `write_list_null_cell`."""
        var n = len(elems)
        if len(elem_nulls) != n:
            raise Error(
                "RowBlock.write_list_string_cell: elems len "
                + String(n) + " != elem_nulls len "
                + String(len(elem_nulls))
            )
        var bitmap_bytes = (n + 7) >> 3
        var offs_bytes = (n + 1) * 4
        var blob_bytes = 0
        for i in range(n):
            if not elem_nulls[i]:
                blob_bytes += len(elems[i])
        var payload_bytes = bitmap_bytes + offs_bytes + blob_bytes
        self.reserve_var_bytes(payload_bytes)
        var base = self.var_storage_used
        for b in range(bitmap_bytes):
            self._var_storage.write_u8_at(base + b, UInt8(0))
        var offs_off = base + bitmap_bytes
        var blob_off = offs_off + offs_bytes
        # Cumulative offsets (relative to blob start) + blob bytes + null bits.
        var cursor = 0
        for i in range(n):
            self._var_storage.write_u32_le_at(
                offs_off + i * 4, UInt32(cursor)
            )
            if elem_nulls[i]:
                var bidx = base + (i >> 3)
                var cur = self._var_storage.read_u8_at(bidx)
                self._var_storage.write_u8_at(
                    bidx, cur | (UInt8(1) << UInt8((i & 7)))
                )
            else:
                ref bytes = elems[i]
                var m = len(bytes)
                for j in range(m):
                    self._var_storage.write_u8_at(
                        blob_off + cursor + j, bytes[j]
                    )
                cursor += m
        self._var_storage.write_u32_le_at(
            offs_off + n * 4, UInt32(cursor)
        )
        self.var_storage_used = base + payload_bytes
        self._write_nested_desc_cell(row, col_offset_in_row, base, n)

    def read_list_string_at(
        self, row: Int, col_offset_in_row: Int
    ) raises -> Tuple[List[List[UInt8]], List[Bool]]:
        """Decode one LIST<string> cell. Returns (elems, elem_nulls). NULL
        elements decode to an empty byte list with `elem_nulls[i]` True."""
        if row < 0 or row >= self.n_rows:
            raise Error(
                "RowBlock.read_list_string_at: row out of range [0, "
                + String(self.n_rows) + ")"
            )
        var off_count = self._read_nested_desc_cell(row, col_offset_in_row)
        var base = off_count[0]
        var n = off_count[1]
        var elems = List[List[UInt8]]()
        var nulls = List[Bool]()
        if n == _LIST_NULL_SENTINEL or n == 0:
            return (elems^, nulls^)
        var bitmap_bytes = (n + 7) >> 3
        var offs_off = base + bitmap_bytes
        var blob_off = offs_off + (n + 1) * 4
        for i in range(n):
            var bit = self._var_storage.read_u8_at(base + (i >> 3))
            var is_null = ((bit >> UInt8((i & 7))) & 1) == 1
            nulls.append(is_null)
            var start = Int(self._var_storage.read_u32_le_at(offs_off + i * 4))
            var end = Int(
                self._var_storage.read_u32_le_at(offs_off + (i + 1) * 4)
            )
            var b = List[UInt8]()
            if not is_null:
                for j in range(start, end):
                    b.append(self._var_storage.read_u8_at(blob_off + j))
            elems.append(b^)
        return (elems^, nulls^)

    # ─── NULL list / list-presence ──────────────────────────────────────

    def write_list_null_cell(mut self, row: Int, col_offset_in_row: Int):
        """Mark a LIST cell (of any element type) NULL: descriptor count is
        `_LIST_NULL_SENTINEL`, no var-payload appended. Distinct from an
        empty list (count==0)."""
        self._write_nested_desc_cell(
            row, col_offset_in_row, 0, _LIST_NULL_SENTINEL
        )

    @always_inline
    def is_list_null(self, row: Int, col_offset_in_row: Int) -> Bool:
        """True iff the LIST cell at (row, col_offset_in_row) is a NULL list
        (count == `_LIST_NULL_SENTINEL`)."""
        var off_count = self._read_nested_desc_cell(row, col_offset_in_row)
        return off_count[1] == _LIST_NULL_SENTINEL

    @always_inline
    def list_len(self, row: Int, col_offset_in_row: Int) -> Int:
        """Element count of the LIST cell. Returns 0 for an empty OR a NULL
        list (test `is_list_null` to disambiguate)."""
        var off_count = self._read_nested_desc_cell(row, col_offset_in_row)
        if off_count[1] == _LIST_NULL_SENTINEL:
            return 0
        return off_count[1]

    # ─── STRUCT<flat> ───────────────────────────────────────────────────

    def write_struct_null_cell(
        mut self, row: Int, col_offset_in_row: Int
    ) raises:
        """Mark a STRUCT cell NULL: the descriptor encodes a 1-byte record
        consisting solely of the struct-null flag. The flag byte (value 1)
        is appended to `_var_storage` and the descriptor length is 1, so
        `is_struct_null` reads it back without a field-spec."""
        self.reserve_var_bytes(1)
        var base = self.var_storage_used
        self._var_storage.write_u8_at(base, UInt8(1))
        self.var_storage_used = base + 1
        self._write_nested_desc_cell(row, col_offset_in_row, base, 1)

    @always_inline
    def is_struct_null(self, row: Int, col_offset_in_row: Int) -> Bool:
        """True iff the STRUCT cell is NULL (struct-null flag byte set)."""
        var off_count = self._read_nested_desc_cell(row, col_offset_in_row)
        var base = off_count[0]
        return self._var_storage.read_u8_at(base) == UInt8(1)

    def read_struct_record_bytes(
        self, row: Int, col_offset_in_row: Int
    ) raises -> List[UInt8]:
        """Read the raw serialized STRUCT record bytes
        for the STRUCT cell at (row, col_offset_in_row). The descriptor's
        high-4-byte `count` field is the record byte length; the record is a
        standalone, self-describing STRUCT record (the same byte format as a
        LIST<STRUCT> element + `serialize_struct_record` output), decodable via
        the free `struct_record_*` helpers. Used by the row→col gather to scatter
        STRUCT cells into a StructArray."""
        if row < 0 or row >= self.n_rows:
            raise Error(
                "RowBlock.read_struct_record_bytes: row out of range [0, "
                + String(self.n_rows) + ")"
            )
        var off_count = self._read_nested_desc_cell(row, col_offset_in_row)
        var base = off_count[0]
        var rec_len = off_count[1]
        var out = List[UInt8]()
        for i in range(rec_len):
            out.append(self._var_storage.read_u8_at(base + i))
        return out^

    def write_struct_record_cell(
        mut self,
        row: Int,
        col_offset_in_row: Int,
        fields: List[ColDescriptor],
        fixed_vals: List[UInt64],
        var_vals: List[List[UInt8]],
        field_nulls: Span[Bool, _],
    ) raises:
        """Write one STRUCT<flat> cell at (row, col_offset_in_row).

        `fields` is the per-field spec (declared order). For each field:
          * COL_FIXED         — value comes from `fixed_vals[fixed_idx]` as a
                                raw little-endian u64 reservoir; only the low
                                `field.fixed_width` bytes are written. Callers
                                bitcast the typed scalar into the u64 (e.g.
                                `_scalar_to_u64`).
          * COL_VAR_STRING    — bytes come from `var_vals[var_idx]`.
        `field_nulls[f]` True iff field f is NULL (its slot is still written,
        zeroed). Indexing into `fixed_vals` / `var_vals` advances per kind.

        Encodes the self-describing STRUCT record (struct-null flag 0 +
        field-validity bitmap + per-field slots) into `_var_storage`. Builds
        the record bytes via the shared `serialize_struct_record` free
        function so an inline STRUCT cell and a LIST<STRUCT> element are
        byte-identical."""
        var rec = serialize_struct_record(
            fields, fixed_vals, var_vals, field_nulls, False
        )
        var rec_len = len(rec)
        self.reserve_var_bytes(rec_len)
        var base = self.var_storage_used
        for b in range(rec_len):
            self._var_storage.write_u8_at(base + b, rec[b])
        self.var_storage_used = base + rec_len
        self._write_nested_desc_cell(row, col_offset_in_row, base, rec_len)

    def read_struct_fixed_field[
        DT: DType
    ](
        self,
        row: Int,
        col_offset_in_row: Int,
        fields: List[ColDescriptor],
        field_idx: Int,
    ) raises -> Scalar[DT]:
        """Decode the `field_idx`-th flat field (must be COL_FIXED) of a
        STRUCT cell as Scalar[DT]. Caller passes the same `fields` spec used
        to write. Returns the raw value (test `is_struct_field_null` for the
        null bit)."""
        var rec = self._struct_record_base(row, col_offset_in_row)
        var slot = self._struct_field_slot_offset(rec, fields, field_idx)
        return self._read_le_scalar[DT](slot)

    def read_struct_string_field(
        self,
        row: Int,
        col_offset_in_row: Int,
        fields: List[ColDescriptor],
        field_idx: Int,
    ) raises -> List[UInt8]:
        """Decode the `field_idx`-th flat field (must be COL_VAR_STRING) of a
        STRUCT cell as its UTF-8 bytes."""
        var rec = self._struct_record_base(row, col_offset_in_row)
        var slot = self._struct_field_slot_offset(rec, fields, field_idx)
        var m = Int(self._var_storage.read_u32_le_at(slot))
        var out = List[UInt8]()
        for j in range(m):
            out.append(self._var_storage.read_u8_at(slot + 4 + j))
        return out^

    @always_inline
    def is_struct_field_null(
        self,
        row: Int,
        col_offset_in_row: Int,
        field_idx: Int,
    ) raises -> Bool:
        """True iff field `field_idx` of the STRUCT cell is NULL."""
        var rec = self._struct_record_base(row, col_offset_in_row)
        var bit = self._var_storage.read_u8_at(rec + 1 + (field_idx >> 3))
        return ((bit >> UInt8((field_idx & 7))) & 1) == 1

    # ─── LIST<STRUCT<flat>> ─────────────────────────────────────────────
    #
    # A LIST whose elements are STRUCT records. The list payload is:
    #   [validity sub-bitmap: ceil(n/8) bytes]
    #   [offsets: (n+1) × u32 LE cumulative, relative to records-blob start]
    #   [records blob: n STRUCT records back-to-back]
    # This is structurally identical to LIST<string> with the element blob
    # being struct records instead of UTF-8 bytes — so it reuses the exact
    # var-of-var offset bookkeeping (the high-bug-density path), validated by
    # the same offset machinery the LIST<string> tests exercise.

    def write_list_struct_cell(
        mut self,
        row: Int,
        col_offset_in_row: Int,
        fields: List[ColDescriptor],
        records: List[List[UInt8]],
        elem_nulls: Span[Bool, _],
    ) raises:
        """Write one LIST<STRUCT<flat>> cell. `records[i]` is the pre-
        serialized STRUCT record bytes for element i (build via
        `serialize_struct_record`); `elem_nulls[i]` True iff element i is a
        NULL struct.

        NOTE: this is layout-level — the caller serializes each struct
        element to bytes once (so LIST<STRUCT> is exactly LIST<bytes-record>
        at the storage layer); the struct-record byte format is the same one
        `write_struct_record_cell` writes inline. `fields` is accepted for
        API symmetry / validation and to document the element shape."""
        _ = fields  # documents element shape; records are pre-serialized
        var n = len(records)
        if len(elem_nulls) != n:
            raise Error(
                "RowBlock.write_list_struct_cell: records len "
                + String(n) + " != elem_nulls len "
                + String(len(elem_nulls))
            )
        var bitmap_bytes = (n + 7) >> 3
        var offs_bytes = (n + 1) * 4
        var blob_bytes = 0
        for i in range(n):
            if not elem_nulls[i]:
                blob_bytes += len(records[i])
        var payload_bytes = bitmap_bytes + offs_bytes + blob_bytes
        self.reserve_var_bytes(payload_bytes)
        var base = self.var_storage_used
        for b in range(bitmap_bytes):
            self._var_storage.write_u8_at(base + b, UInt8(0))
        var offs_off = base + bitmap_bytes
        var blob_off = offs_off + offs_bytes
        var cursor = 0
        for i in range(n):
            self._var_storage.write_u32_le_at(
                offs_off + i * 4, UInt32(cursor)
            )
            if elem_nulls[i]:
                var bidx = base + (i >> 3)
                var cb = self._var_storage.read_u8_at(bidx)
                self._var_storage.write_u8_at(
                    bidx, cb | (UInt8(1) << UInt8((i & 7)))
                )
            else:
                ref rb = records[i]
                var m = len(rb)
                for j in range(m):
                    self._var_storage.write_u8_at(
                        blob_off + cursor + j, rb[j]
                    )
                cursor += m
        self._var_storage.write_u32_le_at(
            offs_off + n * 4, UInt32(cursor)
        )
        self.var_storage_used = base + payload_bytes
        self._write_nested_desc_cell(row, col_offset_in_row, base, n)

    def read_list_struct_at(
        self, row: Int, col_offset_in_row: Int
    ) raises -> Tuple[List[List[UInt8]], List[Bool]]:
        """Decode one LIST<STRUCT<flat>> cell. Returns (records, elem_nulls)
        where `records[i]` is element i's serialized STRUCT record bytes
        (decode each via `struct_record_field_*` helpers). NULL elements
        decode to an empty byte list with `elem_nulls[i]` True."""
        # Storage layout identical to LIST<string>; reuse its decoder.
        return self.read_list_string_at(row, col_offset_in_row)

    # ─── Nested private helpers (pointer-arith confined here) ────────────

    @always_inline
    def _write_le_scalar[
        DT: DType
    ](mut self, var_off: Int, value: Scalar[DT]):
        """Write a Scalar[DT] little-endian into `_var_storage` at `var_off`.

        SAFETY: bitcasts the scalar to its matching-width unsigned reservoir
        (comptime branch on `sizeof`) and writes `sizeof` bytes via the
        OwnedAlignedBuffer typed-LE accessors. All pointer arithmetic is
        inside `_var_storage` (same-module)."""
        var raw = self._scalar_to_u64[DT](value)
        var w = size_of[Scalar[DT]]()
        for b in range(w):
            self._var_storage.write_u8_at(
                var_off + b, UInt8((raw >> UInt64((b * 8))) & UInt64(0xFF))
            )

    @always_inline
    def _read_le_scalar[
        DT: DType
    ](self, var_off: Int) -> Scalar[DT]:
        """Read a Scalar[DT] little-endian from `_var_storage` at `var_off`."""
        var w = size_of[Scalar[DT]]()
        var raw: UInt64 = 0
        for b in range(w):
            raw |= UInt64(Int(self._var_storage.read_u8_at(var_off + b))) << UInt64(
                b * 8
            )
        return self._u64_to_scalar[DT](raw)

    @staticmethod
    @always_inline
    def _scalar_to_u64[DT: DType](value: Scalar[DT]) -> UInt64:
        """Reinterpret a Scalar[DT] as a UInt64 reservoir (low `sizeof` bytes
        meaningful). Comptime branch on width selects the matching unsigned
        bitcast so float bit-patterns survive round-trip."""
        comptime if size_of[Scalar[DT]]() == 8:
            return bitcast[DType.uint64, 1](value)
        elif size_of[Scalar[DT]]() == 4:
            return UInt64(bitcast[DType.uint32, 1](value))
        elif size_of[Scalar[DT]]() == 2:
            return UInt64(bitcast[DType.uint16, 1](value))
        else:
            return UInt64(bitcast[DType.uint8, 1](value))

    @staticmethod
    @always_inline
    def _u64_to_scalar[DT: DType](raw: UInt64) -> Scalar[DT]:
        """Inverse of `_scalar_to_u64`: reinterpret the low `sizeof` bytes of
        `raw` back into a Scalar[DT]."""
        comptime if size_of[Scalar[DT]]() == 8:
            return bitcast[DT, 1](UInt64(raw))
        elif size_of[Scalar[DT]]() == 4:
            return bitcast[DT, 1](UInt32(raw & UInt64(0xFFFFFFFF)))
        elif size_of[Scalar[DT]]() == 2:
            return bitcast[DT, 1](UInt16(raw & UInt64(0xFFFF)))
        else:
            return bitcast[DT, 1](UInt8(raw & UInt64(0xFF)))

    @staticmethod
    @always_inline
    def pack_fixed_field[DT: DType](value: Scalar[DT]) -> UInt64:
        """Public helper: pack a typed fixed-width STRUCT field value into the
        raw u64 reservoir `write_struct_record_cell` expects in `fixed_vals`.
        Float bit-patterns survive (LE bit-identical round-trip)."""
        return Self._scalar_to_u64[DT](value)

    @always_inline
    def _struct_record_base(self, row: Int, col_offset_in_row: Int) -> Int:
        """Var-storage offset of the STRUCT record for this cell."""
        var off_count = self._read_nested_desc_cell(row, col_offset_in_row)
        return off_count[0]

    def _struct_field_slot_offset(
        self,
        rec_base: Int,
        fields: List[ColDescriptor],
        field_idx: Int,
    ) raises -> Int:
        """Walk the STRUCT record from `rec_base` to the byte offset of
        field `field_idx`'s slot (the value for fixed, the u32 length prefix
        for var-string). Variable-length fields force a sequential walk."""
        var k = len(fields)
        var fvb = (k + 7) >> 3
        var cur = rec_base + 1 + fvb
        for f in range(field_idx):
            ref desc = fields[f]
            if desc.kind == COL_FIXED or desc.kind == COL_DECIMAL128:
                cur += Int(desc.fixed_width)
            elif desc.kind == COL_VAR_STRING or desc.kind == COL_VAR_BINARY:
                var m = Int(self._var_storage.read_u32_le_at(cur))
                cur += 4 + m
            else:
                raise Error(
                    "RowBlock._struct_field_slot_offset: unsupported nested "
                    "field kind " + String(Int(desc.kind))
                )
        return cur

    # ─── Per-DType DECODE methods (row-major → columnar gather) ─────────
    #
    # gather direction is the harder one — strided LOAD into a
    # SIMD reg via per-lane scalar loads, then contiguous SIMD STORE to
    # an OwnedAlignedBuffer-backed destination column. AVX-512: `vpgatherqq`
    # gathers 8 stride-aligned i64 lanes in one op (~10 cy throughput).
    # NEON: emulate via `ld1 {v0.d}[lane]` × W per chunk.
    #
    # The decoders return a fresh `List[Scalar[DT]]` of length `n_rows`
    # (the gather destination). Callers transfer the contents into an
    # OwnedAlignedBuffer-backed PrimitiveArray for the output RecordBatch
    # column. A SIMD-LOAD-per-lane stride pattern writing directly into an
    # OwnedAlignedBuffer at the call-site is a possible later step.
    # ---------------------------------------------------------------------

    @always_inline
    def read_fixed_dt_batch[
        DT: DType, W: Int
    ](self, col_offset_in_row: Int) -> List[Scalar[DT]]:
        """Comptime-monomorphized decoder. Gathers `n_rows` scalars from
        column at `col_offset_in_row` into a fresh List[Scalar[DT]].

        per-lane scalar load through stride; collect into a
        SIMD register; SIMD STORE to the destination buffer. The body
        uses scalar per-row gather (correct shape; SIMD-staged path
        is a later perf step — the body shape is in place
        for the gate to fire on).

        Parameters:
            DT: Comptime DType.
            W: Comptime SIMD lane count (unused by the scalar body;
               kept for signature stability).
        """
        var n = self.n_rows
        var out = List[Scalar[DT]](capacity=n)
        _ = W  # comptime param threaded through for a SIMD body
        for row in range(n):
            out.append(self.read_fixed[DT](row, col_offset_in_row))
        return out^

    @always_inline
    def read_i64_batch(self, col_offset_in_row: Int) -> List[Scalar[DType.int64]]:
        return self.read_fixed_dt_batch[DType.int64, 8](col_offset_in_row)

    @always_inline
    def read_f64_batch(
        self, col_offset_in_row: Int
    ) -> List[Scalar[DType.float64]]:
        return self.read_fixed_dt_batch[DType.float64, 8](col_offset_in_row)

    @always_inline
    def read_i32_batch(self, col_offset_in_row: Int) -> List[Scalar[DType.int32]]:
        return self.read_fixed_dt_batch[DType.int32, 16](col_offset_in_row)

    @always_inline
    def read_f32_batch(
        self, col_offset_in_row: Int
    ) -> List[Scalar[DType.float32]]:
        return self.read_fixed_dt_batch[DType.float32, 16](col_offset_in_row)

    @always_inline
    def read_i16_batch(self, col_offset_in_row: Int) -> List[Scalar[DType.int16]]:
        return self.read_fixed_dt_batch[DType.int16, 32](col_offset_in_row)

    @always_inline
    def read_i8_batch(self, col_offset_in_row: Int) -> List[Scalar[DType.int8]]:
        return self.read_fixed_dt_batch[DType.int8, 64](col_offset_in_row)

    @always_inline
    def read_u8_batch(self, col_offset_in_row: Int) -> List[Scalar[DType.uint8]]:
        return self.read_fixed_dt_batch[DType.uint8, 64](col_offset_in_row)

    @always_inline
    def read_u16_batch(
        self, col_offset_in_row: Int
    ) -> List[Scalar[DType.uint16]]:
        return self.read_fixed_dt_batch[DType.uint16, 32](col_offset_in_row)

    @always_inline
    def read_u32_batch(
        self, col_offset_in_row: Int
    ) -> List[Scalar[DType.uint32]]:
        return self.read_fixed_dt_batch[DType.uint32, 16](col_offset_in_row)

    @always_inline
    def read_u64_batch(
        self, col_offset_in_row: Int
    ) -> List[Scalar[DType.uint64]]:
        return self.read_fixed_dt_batch[DType.uint64, 8](col_offset_in_row)

    @always_inline
    def read_date32_batch(
        self, col_offset_in_row: Int
    ) -> List[Scalar[DType.int32]]:
        return self.read_fixed_dt_batch[DType.int32, 16](col_offset_in_row)

    @always_inline
    def read_date64_batch(
        self, col_offset_in_row: Int
    ) -> List[Scalar[DType.int64]]:
        """Date64 decoder — same storage as I64."""
        return self.read_fixed_dt_batch[DType.int64, 8](col_offset_in_row)

    @always_inline
    def read_timestamp_ns_batch(
        self, col_offset_in_row: Int
    ) -> List[Scalar[DType.int64]]:
        """Timestamp_ns decoder — i64 storage."""
        return self.read_fixed_dt_batch[DType.int64, 8](col_offset_in_row)

    @always_inline
    def read_timestamp_us_batch(
        self, col_offset_in_row: Int
    ) -> List[Scalar[DType.int64]]:
        """Timestamp_us decoder — i64 storage."""
        return self.read_fixed_dt_batch[DType.int64, 8](col_offset_in_row)

    @always_inline
    def read_timestamp_ms_batch(
        self, col_offset_in_row: Int
    ) -> List[Scalar[DType.int64]]:
        """Timestamp_ms decoder — i64 storage."""
        return self.read_fixed_dt_batch[DType.int64, 8](col_offset_in_row)

    @always_inline
    def read_timestamp_s_batch(
        self, col_offset_in_row: Int
    ) -> List[Scalar[DType.int64]]:
        """Timestamp_s decoder — i64 storage."""
        return self.read_fixed_dt_batch[DType.int64, 8](col_offset_in_row)

    def read_bool_batch(
        self, col_offset_in_row: Int
    ) -> List[Bool]:
        """Bool decoder — read 1 byte per cell, return List[Bool].

        Bool is stored as 1 byte (0x00 / 0x01)
        per cell in RowBlock; this decoder unpacks the byte form back
        into a Bool list (caller transfers to a bit-packed
        BooleanArray at the call site).
        """
        var n = self.n_rows
        var out = List[Bool](capacity=n)
        for row in range(n):
            var v: Scalar[DType.uint8] = self.read_fixed[DType.uint8](
                row, col_offset_in_row
            )
            out.append(Int(v) != 0)
        return out^

    def read_decimal128_batch_lo(
        self, col_offset_in_row: Int
    ) -> List[Scalar[DType.uint64]]:
        """Decimal128 LOW-64 decoder — read LO u64 cells at offset+0.

        Decimal128 is modeled as two u64
        cells (LO at offset+0, HI at offset+8). Split into TWO decoder
        methods (LO + HI) rather than one Tuple return per Mojo 1.0.0b1
        limitation: tuple destructure `var (a, b) = func()` on owned-
        return tuples fails with "List is not ImplicitlyCopyable".
        Callers compose LO + HI at the call site to reconstruct the
        128-bit value.
        """
        return self.read_fixed_dt_batch[DType.uint64, 8](col_offset_in_row)

    def read_decimal128_batch_hi(
        self, col_offset_in_row: Int
    ) -> List[Scalar[DType.uint64]]:
        """Decimal128 HIGH-64 decoder — read HI u64 cells at offset+8.

        See `read_decimal128_batch_lo` for the LO/HI split rationale.
        """
        return self.read_fixed_dt_batch[DType.uint64, 8](col_offset_in_row + 8)

    def read_var_string_batch(
        self, col_offset_in_row: Int
    ) raises -> List[Scalar[DType.uint8]]:
        """Var-width string decoder.

        Gathers ALL bytes from ALL rows' var-cells into one flat
        `List[Scalar[DType.uint8]]` — the production callers (the
        SortBuffer drain + DistinctState drain) consume this as
        a byte stream and rebuild the Arrow StringArray via
        `from_buffers`.

        For per-row decode (`(offset, length)` pair + bytes), use
        `read_var_string_at(row, col_offset_in_row)` instead.
        """
        var out = List[Scalar[DType.uint8]]()
        var n = self.n_rows
        for row in range(n):
            var byte_off = row * self.fixed_row_stride + col_offset_in_row
            var desc_cell = self._fixed_storage.read_u64_le_at(byte_off)
            var offset = Int(desc_cell & UInt64(0xFFFFFFFF))
            var length = Int(desc_cell >> 32)
            for i in range(length):
                out.append(
                    Scalar[DType.uint8](
                        self._var_storage.read_u8_at(offset + i)
                    )
                )
        return out^

    def read_var_binary_batch(
        self, col_offset_in_row: Int
    ) raises -> List[Scalar[DType.uint8]]:
        """Var-width binary decoder. Same shape as `read_var_string_batch`."""
        return self.read_var_string_batch(col_offset_in_row)


# =============================================================================
# STRUCT record (de)serialization — free functions
# =============================================================================
#
# A self-describing STRUCT<flat> record as a standalone byte string. The SAME
# format `RowBlock.write_struct_record_cell` writes inline, factored out so a
# LIST<STRUCT<flat>> element can be serialized to bytes ONCE and fed to
# `RowBlock.write_list_struct_cell`. The element bytes a `read_list_struct_at`
# returns are decoded back via the `struct_record_*` readers here.
#
# Record bytes:
#   [1 byte: struct-null flag — 1 == NULL struct (record ends here)]
#   [field-validity sub-bitmap: ceil(k/8) bytes; bit=1 => field NULL]
#   for each field in declared order:
#     fixed primitive : `fixed_width` bytes, value LE
#     var-string      : u32 LE length prefix + that many payload bytes
#
# Encapsulation: operate on `List[UInt8]` / `Span[UInt8]` only — zero
# UnsafePointer, zero pointer arithmetic crosses any boundary.
# =============================================================================


def serialize_struct_record(
    fields: List[ColDescriptor],
    fixed_vals: List[UInt64],
    var_vals: List[List[UInt8]],
    field_nulls: Span[Bool, _],
    is_struct_null: Bool = False,
) raises -> List[UInt8]:
    """Serialize one STRUCT<flat> value into a standalone record `List[UInt8]`.

    `fixed_vals[fixed_idx]` is the raw LE u64 reservoir for each COL_FIXED
    field (pack via `RowBlock.pack_fixed_field`); `var_vals[var_idx]` is the
    bytes for each COL_VAR_STRING field. If `is_struct_null` is True the
    record is a single flag byte (value 1)."""
    var out = List[UInt8]()
    if is_struct_null:
        out.append(UInt8(1))
        return out^
    var k = len(fields)
    if len(field_nulls) != k:
        raise Error(
            "serialize_struct_record: fields len " + String(k)
            + " != field_nulls len " + String(len(field_nulls))
        )
    out.append(UInt8(0))  # struct present
    var fvb = (k + 7) >> 3
    var bmp_start = len(out)
    for _b in range(fvb):
        out.append(UInt8(0))
    var fixed_idx = 0
    var var_idx = 0
    for f in range(k):
        if field_nulls[f]:
            out[bmp_start + (f >> 3)] = out[bmp_start + (f >> 3)] | (
                UInt8(1) << UInt8((f & 7))
            )
        ref desc = fields[f]
        if desc.kind == COL_FIXED or desc.kind == COL_DECIMAL128:
            var w = Int(desc.fixed_width)
            var raw = fixed_vals[fixed_idx]
            for b in range(w):
                out.append(UInt8((raw >> UInt64((b * 8))) & UInt64(0xFF)))
            fixed_idx += 1
        elif desc.kind == COL_VAR_STRING or desc.kind == COL_VAR_BINARY:
            var m = 0 if field_nulls[f] else len(var_vals[var_idx])
            out.append(UInt8(m & 0xFF))
            out.append(UInt8((m >> 8) & 0xFF))
            out.append(UInt8((m >> 16) & 0xFF))
            out.append(UInt8((m >> 24) & 0xFF))
            if not field_nulls[f]:
                ref bytes = var_vals[var_idx]
                for j in range(len(bytes)):
                    out.append(bytes[j])
            var_idx += 1
        else:
            raise Error(
                "serialize_struct_record: unsupported nested field kind "
                + String(Int(desc.kind))
                + " (depth-1 flat only; recursion is not supported)"
            )
    return out^


@always_inline
def struct_record_is_null(rec: Span[UInt8, _]) -> Bool:
    """True iff a serialized STRUCT record is a NULL struct."""
    return rec[0] == UInt8(1)


@always_inline
def struct_record_field_null(rec: Span[UInt8, _], field_idx: Int) -> Bool:
    """True iff field `field_idx` of a serialized STRUCT record is NULL."""
    return ((rec[1 + (field_idx >> 3)] >> UInt8((field_idx & 7))) & 1) == 1


def _struct_record_slot_offset(
    rec: Span[UInt8, _], fields: List[ColDescriptor], field_idx: Int
) raises -> Int:
    """Byte offset of field `field_idx`'s slot within a serialized record."""
    var k = len(fields)
    var cur = 1 + ((k + 7) >> 3)
    for f in range(field_idx):
        ref desc = fields[f]
        if desc.kind == COL_FIXED or desc.kind == COL_DECIMAL128:
            cur += Int(desc.fixed_width)
        elif desc.kind == COL_VAR_STRING or desc.kind == COL_VAR_BINARY:
            var m = (
                Int(rec[cur])
                | (Int(rec[cur + 1]) << 8)
                | (Int(rec[cur + 2]) << 16)
                | (Int(rec[cur + 3]) << 24)
            )
            cur += 4 + m
        else:
            raise Error(
                "_struct_record_slot_offset: unsupported nested field kind "
                + String(Int(desc.kind))
            )
    return cur


def struct_record_fixed_field[
    DT: DType
](rec: Span[UInt8, _], fields: List[ColDescriptor], field_idx: Int) raises -> Scalar[DT]:
    """Decode field `field_idx` (COL_FIXED) of a serialized STRUCT record."""
    var slot = _struct_record_slot_offset(rec, fields, field_idx)
    var w = size_of[Scalar[DT]]()
    var raw: UInt64 = 0
    for b in range(w):
        raw |= UInt64(Int(rec[slot + b])) << UInt64((b * 8))
    return RowBlock._u64_to_scalar[DT](raw)


def struct_record_string_field(
    rec: Span[UInt8, _], fields: List[ColDescriptor], field_idx: Int
) raises -> List[UInt8]:
    """Decode field `field_idx` (COL_VAR_STRING) of a serialized STRUCT
    record as its UTF-8 bytes."""
    var slot = _struct_record_slot_offset(rec, fields, field_idx)
    var m = (
        Int(rec[slot])
        | (Int(rec[slot + 1]) << 8)
        | (Int(rec[slot + 2]) << 16)
        | (Int(rec[slot + 3]) << 24)
    )
    var out = List[UInt8]()
    for j in range(m):
        out.append(rec[slot + 4 + j])
    return out^


# =============================================================================
# Row-bytes hash function (xxh3-64 scalar reference) + row-bytes equality
# =============================================================================
#
# Shared by `RowHashAggTable` and the row join build / probe tables, so
# all of them use one implementation.
#
# The hash function reads the byte range `[row*stride .. row*stride+stride)`
# from the RowBlock's fixed_storage (via `_row_base_ptr_ro`) and folds the
# bytes via xxh3-64 (scalar reference variant; see `xxh3.mojo` for the
# BSD-2-Clause port from upstream xxHash).
#
# FNV-1a 64-bit byte-fold was replaced by xxh3-64 (the scalar reference
# variant). Same call signature; consumers (RowHashAggTable /
# RowJoinBuildTable / RowJoinProbeState) do not move.
#
# Cross-version stability: xxh3-64 SCALAR REFERENCE variant produces
# byte-identical output on every little-endian architecture (Linux x86_64
# + macOS arm64 verified by KAT). SIMD-staged variants are explicitly NOT
# used here (they emit different intermediate bytes on AVX-512 vs NEON);
# A future version may add a SIMD path gated by a runtime CPU-feature check.
#
# Encapsulation: these are FREE FUNCTIONS (not methods on RowBlock) because
# the hash domain is "KEY bytes only" — the caller (RowHashAggTable /
# RowJoinBuildTable / RowJoinProbeState) knows the key_stride; RowBlock
# itself is arity-erased and shouldn't carry hash-domain semantics.
# =============================================================================

from komira_row_format.xxh3 import _xxh3_64_dispatch, XXH3_MAX_KEY_LEN
from komira_row_format.row_directory import RowDirectory


@always_inline
def _hash_var_payload[
    o: Origin[mut=False], //,
](payload: Span[UInt8, o], seed: UInt64) -> UInt64:
    """Chain one var-cell payload into `seed`.

    ⛔ WHY CHUNKED. `_xxh3_64_dispatch` is documented to produce an INCORRECT
    result above `XXH3_MAX_KEY_LEN` (240) rather than raise — the fixed-width
    key strides it was written for are schema-bounded, but a STRING key is
    bounded by the DATA and a 300-byte value is ordinary. So a payload longer
    than the cap is folded 240 bytes at a time, each chunk seeded by the last.

    ⭐ A COLLISION HERE IS NOT A WRONG ANSWER. The directory follows every hash
    hit with `_row_bytes_equal`, which compares the payload EXACTLY, so the only
    property this function owes is DETERMINISM: equal bytes -> equal hash, in
    the probe block, the group block, every restored spill shell and every
    grace-hash sub-partition. Chunk-chaining is deterministic at every length,
    which is what makes same-key-same-subpartition hold for a string key."""
    var h = seed
    var off = 0
    var rem = len(payload)
    # SAFETY: the pointer is derived from the caller's borrowed Span and is
    # consumed entirely within this frame by the sibling xxh3 kernel — the same
    # intra-package private hand-off `_hash_row_bytes` makes for the fixed
    # region. Every chunk read is inside `[0, len(payload))`.
    var base = payload.unsafe_ptr()
    while rem > XXH3_MAX_KEY_LEN:
        h = _xxh3_64_dispatch(base + off, XXH3_MAX_KEY_LEN, h)
        off += XXH3_MAX_KEY_LEN
        rem -= XXH3_MAX_KEY_LEN
    return _xxh3_64_dispatch(base + off, rem, h)


@always_inline
def _hash_row_bytes[
    o: Origin[mut=False], //,
](ref [o] keys: RowBlock, row: Int, key_stride: Int) -> UInt64:
    """xxh3-64 scalar reference hash over `key_stride` bytes starting at
    `keys[row]`.

    Uses the xxh3-64 scalar reference. See
    `xxh3.mojo` for the ported xxh3 kernel + BSD-2-Clause attribution.

    Length contract: `key_stride` is bounded by the row's schema; for
    The practical upper limit is composite-30-I64 = 240 bytes.
    The xxh3 dispatcher silently routes any `key_stride > 128` through
    the 129..240 path; callers above 240B will produce a hash without
    full mixing (the streaming long-key path is not implemented). A
    debug_assert below catches the overrun in debug builds.

    SAFETY: `row < keys.n_rows` precondition (caller-enforced via the
    per-batch insert/probe loop). The byte pointer's origin is bound by
    the inner `_row_base_ptr_ro` accessor (concrete origin `o`); the
    pointer is passed to the private `_xxh3_64_dispatch` sibling kernel
    in `xxh3.mojo` (intra-package, both `_`-prefixed private names; no
    raw pointer crosses a PUBLIC API surface).
    """
    debug_assert(
        key_stride <= XXH3_MAX_KEY_LEN,
        "_hash_row_bytes: key_stride exceeds xxh3 scalar-reference cap",
    )
    # SAFETY: byte pointer is the RowBlock-internal accessor;
    # origin `o` is the borrow origin propagated by `_row_base_ptr_ro`'s
    # mut-poly + origin-poly signature.
    var base = keys._row_base_ptr_ro(row)
    var n_var = len(keys.var_key_offsets)
    if n_var == 0:
        # ⭐ THE FIXED-KEY PATH. Every layout without var-width keys has an
        # EMPTY `var_key_offsets`, so it takes exactly one call over the
        # fixed key bytes.
        return _xxh3_64_dispatch(base, key_stride, UInt64(0))
    # ⛔ VAR-WIDTH KEY: fold the PAYLOAD, never the (offset, length) DESCRIPTOR.
    # The descriptor says WHERE the string sits in THIS block's var heap, which
    # is an artifact of insertion order and differs between the probe block, the
    # group block and every restored spill shell. Hashing it would give the same
    # string a different hash in each of them and scatter one group into many.
    # So: hash the fixed key bytes AROUND each descriptor cell, then chain each
    # payload's own bytes into the seed.
    var h = UInt64(0)
    var cur = 0
    for i in range(n_var):
        var vo = keys.var_key_offsets[i]
        if vo > cur:
            h = _xxh3_64_dispatch(base + cur, vo - cur, h)
        cur = vo + 8
    if key_stride > cur:
        h = _xxh3_64_dispatch(base + cur, key_stride - cur, h)
    for i in range(n_var):
        h = _hash_var_payload(
            keys.var_string_span_at(row, keys.var_key_offsets[i]), h
        )
    return h


# Key-byte equality uses NO size threshold between an inline loop and a libc
# `memcmp` call. `external_call["memcmp"] == 0` is rewritten by LLVM to `bcmp`,
# and under a hermetic Zig toolchain `bcmp` resolves to compiler_rt's
# byte-at-a-time loop, so a "call memcmp above N bytes" branch picks between two
# byte loops and only adds call overhead. Both widths route to
# `komira_core.simd.byte_class.byte_equal.bytes_equal`, which is
# `@always_inline` and issues no call at any width.
#
# `key_stride` is a RUNTIME value here, so the whole ladder is inlined at this
# call site and the width only selects which rung executes:
#   key_stride  rungs taken by `bytes_equal`
#   ----------  ------------------------------------------------
#      4        movl/cmpl x2 (overlapping; at n == 4 the same block)
#      8        movq/cmpq x2 (same, at n == 8)
#     12        movq/cmpq x2, overlapping [0,8) + [4,12)
#     16        vmovdqu + vpxor <mem> + vptest, x2 (same block twice)
#     24        the 16-byte rung over [0,16) and [8,24)
#     32        one 32-byte bulk block, rem == 0
# `key_stride` is the sum of the key columns' fixed cell widths, so these
# are the widths that occur.
#
# The one real cost is CODE SIZE: the ladder is ~61 instructions inlined at
# every call site. Weigh that before converting a hot site with one-byte keys.


@always_inline
def _row_bytes_equal[
    o1: Origin[mut=False], o2: Origin[mut=False], //,
](
    ref [o1] keys_a: RowBlock,
    row_a: Int,
    ref [o2] keys_b: RowBlock,
    row_b: Int,
    key_stride: Int,
) -> Bool:
    """True iff `keys_a[row_a]` and `keys_b[row_b]` share the same
    `key_stride` bytes.

    ONE arm, at every width: the shared SIMD byte-equality primitive
    `komira_core.simd.byte_class.byte_equal.bytes_equal`. See the note above
    for why the two-arm form and its 16-byte threshold are gone.

    SAFETY: `_row_base_ptr_ro` returns a pointer whose origin is the caller's
    borrow on the RowBlock (`o1` / `o2`); each row's readable extent is at
    least `fixed_row_stride >= key_stride` bytes, so the `key_stride`-length
    Span below is in bounds. The pointers are wrapped in Spans at the call and
    do not escape.
    """
    var pa = keys_a._row_base_ptr_ro(row_a)
    var pb = keys_b._row_base_ptr_ro(row_b)
    var n_var = len(keys_a.var_key_offsets)
    if n_var == 0:
        # The fixed-key path (empty list on every layout without var-width
        # keys).
        var _eq = bytes_equal(
            Span[UInt8, o1](unsafe_ptr=pa, length=key_stride),
            Span[UInt8, o2](unsafe_ptr=pb, length=key_stride),
        )
        keyeq_record(KEYEQ_ROWBLOCK_MEMCMP, key_stride, key_stride, _eq)
        return _eq
    # ⛔ VAR-WIDTH KEY — the descriptor bytes are NOT part of the key's
    # identity (see `_hash_row_bytes`). Compare the fixed bytes AROUND each
    # descriptor cell, then the payloads themselves. This is the exact
    # comparison the directory needs: byte equality of the payload IS string
    # equality, so a hash collision costs a probe step and never a wrong group.
    var eq = True
    var cur = 0
    for i in range(n_var):
        var vo = keys_a.var_key_offsets[i]
        if vo > cur and not bytes_equal(
            Span[UInt8, o1](unsafe_ptr=pa + cur, length=vo - cur),
            Span[UInt8, o2](unsafe_ptr=pb + cur, length=vo - cur),
        ):
            eq = False
        cur = vo + 8
    if (
        eq
        and key_stride > cur
        and not bytes_equal(
            Span[UInt8, o1](unsafe_ptr=pa + cur, length=key_stride - cur),
            Span[UInt8, o2](unsafe_ptr=pb + cur, length=key_stride - cur),
        )
    ):
        eq = False
    if eq:
        for i in range(n_var):
            # Deliberately `keys_a`'s offset list on BOTH sides: the two blocks
            # carry the same declaration by construction, and reading
            # `keys_b`'s would index out of bounds on a wrong-wiring bug
            # instead of comparing the cells the caller meant.
            # `var_string_span_at` is the block's own borrowed-payload reader,
            # so LENGTH is compared by `bytes_equal` along with the bytes —
            # which is what makes byte equality STRING equality for the mixed-
            # length keys this path exists to serve.
            var vo = keys_a.var_key_offsets[i]
            if not bytes_equal(
                keys_a.var_string_span_at(row_a, vo),
                keys_b.var_string_span_at(row_b, vo),
            ):
                eq = False
                break
    keyeq_record(KEYEQ_ROWBLOCK_MEMCMP, key_stride, key_stride, eq)
    return eq


# =============================================================================
# Centralized key-encode dispatch ladder
# =============================================================================
#
# dispatch fires ONCE per (col, batch); inner
# row loop is fixed-DType + SIMD-vectorizable via the LANDED
# write_<dt>_batch methods on RowBlock.
# =============================================================================


def _dispatch_encode_key_col[
    bo: Origin[mut=False], //,
](
    mut probe_keys: RowBlock,
    batch: BatchView[bo],
    desc: ColDescriptor,
    src_col_idx: Int,
) raises:
    """Dispatch one key column's encode based on desc.kind + desc.dtype_tag.

    Reads the typed ColView from the batch and writes via the matching
    RowBlock.write_<dt>_batch kernel. STRING keys encode their payload
    into the var heap; BINARY keys raise (not yet supported).
    """
    var off = Int(desc.offset_in_row)
    if desc.kind == COL_FIXED:
        if desc.dtype_tag == DT_I64:
            probe_keys.write_i64_batch(batch.col_i64(src_col_idx), off)
        elif desc.dtype_tag == DT_F64:
            probe_keys.write_f64_batch(batch.col_f64(src_col_idx), off)
        elif desc.dtype_tag == DT_U64:
            probe_keys.write_u64_batch(batch.col_u64(src_col_idx), off)
        elif desc.dtype_tag == DT_DATE64:
            probe_keys.write_date64_batch(batch.col_date64(src_col_idx), off)
        elif desc.dtype_tag == DT_TIMESTAMP_NS:
            probe_keys.write_timestamp_ns_batch(batch.col_timestamp_ns(src_col_idx), off)
        elif desc.dtype_tag == DT_TIMESTAMP_US:
            probe_keys.write_timestamp_us_batch(batch.col_timestamp_us(src_col_idx), off)
        elif desc.dtype_tag == DT_TIMESTAMP_MS:
            probe_keys.write_timestamp_ms_batch(batch.col_timestamp_ms(src_col_idx), off)
        elif desc.dtype_tag == DT_TIMESTAMP_S:
            probe_keys.write_timestamp_s_batch(batch.col_timestamp_s(src_col_idx), off)
        elif desc.dtype_tag == DT_I32:
            probe_keys.write_i32_batch(batch.col_i32(src_col_idx), off)
        elif desc.dtype_tag == DT_F32:
            probe_keys.write_f32_batch(batch.col_f32(src_col_idx), off)
        elif desc.dtype_tag == DT_U32:
            probe_keys.write_u32_batch(batch.col_u32(src_col_idx), off)
        elif desc.dtype_tag == DT_DATE32:
            probe_keys.write_date32_batch(batch.col_date32(src_col_idx), off)
        elif desc.dtype_tag == DT_I16:
            probe_keys.write_i16_batch(batch.col_i16(src_col_idx), off)
        elif desc.dtype_tag == DT_U16:
            probe_keys.write_u16_batch(batch.col_u16(src_col_idx), off)
        elif desc.dtype_tag == DT_I8:
            probe_keys.write_i8_batch(batch.col_i8(src_col_idx), off)
        elif desc.dtype_tag == DT_U8:
            probe_keys.write_u8_batch(batch.col_u8(src_col_idx), off)
        elif desc.dtype_tag == DT_BOOL:
            probe_keys.write_bool_batch(batch.col_bool(src_col_idx), off)
        else:
            raise Error(
                "_dispatch_encode_key_col: unknown DType tag "
                + String(Int(desc.dtype_tag))
                + " for COL_FIXED key col " + String(src_col_idx)
            )
    elif desc.kind == COL_FIXED_KEY64:
        # The CANONICAL 8-byte group-key surrogate.
        # `desc.dtype_tag` names the SOURCE column's type; the CELL is always 8
        # bytes and ALL EIGHT are written. See `COL_FIXED_KEY64`.
        #
        # ⛔ DT_I64 / DT_U64 / DT_DATE64 / DT_TIMESTAMP_* ARE DELIBERATELY NOT
        # HERE. Those sources already occupy 8 exact bytes, so plain `COL_FIXED`
        # is byte-injective for them and the producer keeps using it — routing
        # them through a second spelling would be two encoders for one contract.
        if desc.dtype_tag == DT_I32 or desc.dtype_tag == DT_DATE32:
            probe_keys.write_widen_i64_key_batch[DType.int32, 16](
                batch.col_i32(src_col_idx), off
            )
        elif desc.dtype_tag == DT_I16:
            probe_keys.write_widen_i64_key_batch[DType.int16, 32](
                batch.col_i16(src_col_idx), off
            )
        elif desc.dtype_tag == DT_I8:
            probe_keys.write_widen_i64_key_batch[DType.int8, 64](
                batch.col_i8(src_col_idx), off
            )
        elif desc.dtype_tag == DT_U8:
            probe_keys.write_widen_i64_key_batch[DType.uint8, 64](
                batch.col_u8(src_col_idx), off
            )
        elif desc.dtype_tag == DT_U16:
            probe_keys.write_widen_i64_key_batch[DType.uint16, 32](
                batch.col_u16(src_col_idx), off
            )
        elif desc.dtype_tag == DT_U32:
            probe_keys.write_widen_i64_key_batch[DType.uint32, 16](
                batch.col_u32(src_col_idx), off
            )
        elif desc.dtype_tag == DT_F64:
            probe_keys.write_f64_canon_key_batch(batch.col_f64(src_col_idx), off)
        elif desc.dtype_tag == DT_F32:
            probe_keys.write_f32_canon_key_batch(batch.col_f32(src_col_idx), off)
        elif desc.dtype_tag == DT_BOOL:
            probe_keys.write_bool_key64_batch(batch.col_bool(src_col_idx), off)
        else:
            raise Error(
                "_dispatch_encode_key_col: COL_FIXED_KEY64 has no canonical"
                " 8-byte surrogate for DType tag "
                + String(Int(desc.dtype_tag))
                + " (key col " + String(src_col_idx) + ")"
            )
    elif desc.kind == COL_DECIMAL128:
        probe_keys.write_decimal128_batch(
            batch.col_decimal128_lo(src_col_idx),
            batch.col_decimal128_hi(src_col_idx),
            off,
        )
    elif desc.kind == COL_VAR_STRING:
        # ⭐ THE VAR-WIDTH GROUP KEY. `write_var_string_batch`
        # below is the production encoder for row-native CSV/JSONL reads.
        # Beyond the ENCODE, a KEY needs three
        # things, all of which exist:
        #   * `_hash_row_bytes` / `_row_bytes_equal` fold the PAYLOAD rather
        #     than the (offset, length) descriptor (`RowBlock.var_key_offsets`);
        #   * `RowHashAggTable._copy_key_into_row` re-appends the payload into
        #     the GROUP block's own var heap on an insert miss, so a group owns
        #     its bytes independently of the per-batch probe block;
        #   * the spill image, the grace-hash repartition and the drain carry
        #     the var heap instead of the descriptor.
        # Admitting this arm WITHOUT those is the silent-wrong-answer shape the
        # `agg_spill_driver` header describes, not a partial capability.
        #
        # ⛔⛔ THE DICTIONARY PROBE IS NOT OPTIONAL, AND IT IS NOT A NULL CHECK.
        # A STRING column can arrive DICTIONARY-ENCODED (int32 codes + a packed
        # dict page) under a schema field that still says STRING — the
        # inconsistent shape `test_inmem_probe_dict_flat_reconcile` reproduces,
        # and the reason `hash_agg_untyped` probes `col_is_string_dict` at every
        # one of its own STRING-key sites. `StringColumnView` over such a column
        # does NOT raise: the dict's offsets buffer IS the column's `_offsets`,
        # so `col_str(...).get(row)` reads DICT ENTRY `row` and returns a
        # perfectly well-formed string that belongs to a different row. Every
        # group would then be keyed by the wrong value — silently. So the code
        # path is selected by the column's PHYSICAL layout, never by the schema.
        #
        # ⛔⛔ AND THE VALIDITY PASS IS NOT OPTIONAL EITHER — SAME CLASS OF
        # DEFECT, SAME SILENCE. `StringColumnView.get()` reads
        # `offsets[row]..offsets[row+1]` and never consults the validity bitmap,
        # so a NULL key arrives here as a ZERO-LENGTH payload: byte-identical to
        # the literal empty string, hashed the same, compared equal, folded into
        # the SAME GROUP. The in-memory route this one replaces above the
        # `_agg_inmem_max_rows()` ceiling gives NULL its own group
        # (`hash_agg_untyped._hash_single_col` -> `_NULL_KEY_HASH`), which is
        # what SQL and DuckDB say, so the spill route answering `''` would make
        # ONE query return TWO answers depending on its row count. The
        # `write_var_string_key_*` family's tag byte is what keeps them apart.
        var n_key_rows = batch.n_rows()
        probe_keys.ensure_capacity_rows(n_key_rows)
        if batch.col_is_string_dict(src_col_idx):
            for row in range(n_key_rows):
                # Resolve code -> bytes per row (the `col_string_dict_value_at`
                # seam, same as the in-mem sink). The payload is appended to the
                # probe block's own heap exactly as the flat arm appends it, so
                # everything downstream — hash, compare, copy, spill, drain —
                # sees one shape and never learns the source was encoded.
                probe_keys.write_var_string_key_cell(
                    row,
                    off,
                    batch.col_string_dict_value_at(
                        src_col_idx,
                        batch.col_string_dict_code_at(src_col_idx, row),
                    ).into_span(),
                )
        else:
            probe_keys.write_var_string_key_batch(
                batch.col_str(src_col_idx), off
            )
        # THE NULL PATCH, second pass and gated on the batch's own bitmap.
        # `col_any_null` is O(1) for a column with no validity buffer and one
        # 64-bit load per 64 rows otherwise, against a fold that reads every row
        # of every key — so the no-NULL column (the overwhelmingly common one)
        # keeps the single bulk pass above and pays a bitmap probe, not a
        # per-row branch. Patching AFTER the write rather than branching inside
        # it is what lets both encode arms — flat and dictionary — stay one
        # shape each.
        if desc.key_nullable() and batch.col_any_null(
            src_col_idx, n_key_rows
        ):
            for row in range(n_key_rows):
                if batch.col_is_null(src_col_idx, row):
                    probe_keys.write_var_string_key_null_cell(row, off)
    elif desc.kind == COL_VAR_BINARY:
        raise Error(
            "_dispatch_encode_key_col: COL_VAR_BINARY key not yet supported "
            "(binary keys are not encoded into the row format)"
        )
    else:
        raise Error(
            "_dispatch_encode_key_col: unknown col kind "
            + String(Int(desc.kind))
        )


# =============================================================================
# RowHashAggTable — slow-path hash-agg
# =============================================================================
#
# (agg-major loop; RowLayout borrowed by ref).
# Slow-arm of `_HashAggVariant`: arity-erased hash aggregation over
# row-encoded keys. Any (K, AggOps, DTypes) plan that doesn't fit the
# fast cube routes here.
#
# The struct + agg-major upsert_batch dispatch ladder. The inner
# per-batch kernels are scalar (signature shape is the
# load-bearing item for the dispatch; perf-staging of the per-batch
# kernels is future work).
# =============================================================================


struct RowHashAggTable(Movable, Deinitable):
    """Slow-path hash-agg over row-encoded keys.

    Held as the slow-arm of `_HashAggVariant` on RBS (zero
    new RBS heap-owning fields; mutual exclusion of fast/slow is type-
    enforced by the Variant carrier). One instance per slow-path
    HASH_AGG segment.

    Fields:
        directory:          Shared open-addressing slot directory
                            (`RowDirectory`; owns the pow2 grow + rehash +
                            slot mechanics shared across the row-format
                            family).
        rows:               RowBlock of group-key rows + agg-state cells
                            (one logical row per group). Per-row layout:
                            [key cells | agg-state cells].
        probe_keys:         Scratch RowBlock holding the encoded probe-
                            row keys for the current batch (mirror of
                            RowJoinProbeState.probe_keys; avoids re-
                            alloc per batch).
        slots_buf:          Per-batch probe-result slots (length n_rows
                            of the input batch); element[i] == row-index
                            in `rows` for the matched/inserted group.
                            Avoids re-allocating per batch.
        key_stride:         Cached key-row stride (bytes per key tuple).
        agg_op_tags:        Per-agg op constant (AGG_SUM_I64 / AGG_COUNT /
                            AGG_MIN_I64 / AGG_MAX_I64 / ...). Length =
                            N_aggs.
        agg_col_offsets:    Per-agg byte offset in `rows`'s row payload
                            region. Length = N_aggs.

    NOTE: RowLayout is NOT embedded by value; it's held on a
    separate RBS slot under `Optional[OwnedPointer[RowLayout]]` and
    passed to `upsert_batch` via `ref [lo] RowLayout` — same shape
    across all morsel instances under one Tracer (no per-instance copy).
    """

    var directory: RowDirectory
    var rows: RowBlock
    var probe_keys: RowBlock
    var slots_buf: List[Int]
    var key_stride: Int
    var agg_op_tags: List[UInt8]
    var agg_col_offsets: List[Int]
    var var_key_offsets: List[Int]
    """The VAR-WIDTH key-cell offsets (see `RowBlock.var_key_offsets`).
    EMPTY unless `set_var_key_offsets` was called, which keeps every
    fixed-key shape on the fixed-key code path."""

    def __init__(out self, key_stride: Int, fixed_row_stride: Int):
        """Empty-shell ctor; SDK lowering populates `agg_op_tags` and
        `agg_col_offsets` from the RowLayout descriptor and calls
        `reserve(initial_capacity)` before any feed.

        Args:
            key_stride: Bytes per key tuple (== sum of key-col widths).
                The hash function reads exactly this many bytes from
                each row's key region.
            fixed_row_stride: Bytes per row in `rows` — `key_stride`
                plus sum of agg-state cell widths.
        """
        self.directory = RowDirectory()
        self.rows = RowBlock(fixed_row_stride)
        self.probe_keys = RowBlock(key_stride)
        self.slots_buf = List[Int]()
        self.key_stride = key_stride
        self.agg_op_tags = List[UInt8]()
        self.agg_col_offsets = List[Int]()
        self.var_key_offsets = List[Int]()

    def set_var_key_offsets(mut self, imm offsets: List[Int]):
        """Declare which key cells are VAR-WIDTH (offsets into the key region).

        ⛔ STAMPS ALL THREE BLOCKS AT ONCE, AND THAT IS THE POINT. The group
        block, the per-batch probe block and (via `var_key_offsets` being
        carried into every spill shell) each restored run must agree, because
        `_hash_row_bytes` / `_row_bytes_equal` read the list off the BLOCK they
        are handed. One block disagreeing would hash a descriptor against a
        payload and split a group.

        Called once, after construction, by `agg_spill_driver._fold_spill_over_
        batches`. A no-op for every all-fixed-width key (the list is empty)."""
        self.var_key_offsets = List[Int]()
        for i in range(len(offsets)):
            self.var_key_offsets.append(offsets[i])
        self.rows.var_key_offsets = self._var_key_offsets_copy()
        self.probe_keys.var_key_offsets = self._var_key_offsets_copy()

    def _var_key_offsets_copy(self) -> List[Int]:
        var out = List[Int]()
        for i in range(len(self.var_key_offsets)):
            out.append(self.var_key_offsets[i])
        return out^

    @always_inline
    def has_var_keys(self) -> Bool:
        return len(self.var_key_offsets) > 0

    def add_agg(mut self, op_tag: UInt8, col_offset: Int):
        """Register an aggregator slot. Called at SDK lowering time per
        agg op declared on the plan.
        """
        self.agg_op_tags.append(op_tag)
        self.agg_col_offsets.append(col_offset)

    def n_aggs(self) -> Int:
        return self.agg_op_tags.__len__()

    def n_groups(self) -> Int:
        """Number of distinct group rows currently in the table."""
        return self.rows.n_rows

    def reserve(mut self, estimated_n_rows: Int) raises:
        """Pre-size `rows` + directory (mirror of `RowJoinBuildTable.reserve`).

        Caller provides an upper bound for the number of distinct groups.
        Directory grows to 2x rounded up to power of 2 (load factor ≤ 0.5).
        """
        self.rows.reserve_rows(estimated_n_rows)
        self.directory.reserve(estimated_n_rows)

    def seed_ungrouped_empty_group(mut self) raises:
        """Insert exactly one group row with identity agg-state cells.

        SQL standard: an UNGROUPED aggregate
        (empty GROUP BY) over zero input rows MUST still emit one output row
        — COUNT(*) → 0, SUM/MIN/MAX → identity sentinel (the slow-path agg
        cells are non-nullable, so SUM/MIN/MAX emit their
        init sentinel rather than NULL; only COUNT is exercised by the
        regression test). Caller MUST only invoke this when:
            * `n_groups()` == 0 (table never observed any input row), and
            * the agg is ungrouped (key_stride == 0 / layout.n_key_cols() == 0).
        With a zero-width key, the inserted row carries no key bytes; only
        the agg-state cells are written, via the same `_init_agg_cells`
        identity-init used on the upsert miss path. The directory is left
        untouched (no future upsert can occur after finalize, and a 0-key
        ungrouped table never probes by key).
        """
        var new_row = self.rows.n_rows
        self.rows.reserve_rows(1)
        # Zero-key ungrouped group: no key bytes to copy (key_stride == 0).
        # Initialize agg-state cells to their per-op identity values.
        self._init_agg_cells(new_row)
        self.rows.set_n_rows(new_row + 1)

    def upsert_batch[
        bo: Origin[mut=False], lo: Origin[mut=False], //,
    ](
        mut self,
        batch: BatchView[bo],
        key_col_idxs: List[Int],
        payload_col_idxs: List[Int],
        ref [lo] layout: RowLayout,
    ) raises:
        """Upsert one batch of (key-cols, payload-cols) into the
        hash table.

        Hot loop (mirror of RowJoinBuildTable.build_batch_i64_inner):
          Step 1 — encode probe-side keys into scratch `probe_keys` RowBlock.
          Step 2 — per row, hash + linear-probe `directory`:
            * On miss: copy key bytes from probe_keys[row] → rows[next_slot],
                       initialize agg-state cells for the new group,
                       record slot in directory.
            * On hit:  slots_buf[row] = matched slot.
          Step 3 — agg-major dispatch: for each agg op, walk slots_buf
                   and update self.rows[slot].agg_cells[col_off] from
                   the source batch column.

        Scope: I64 keys + (I64 payload columns) per agg. Agg ops
        supported: AGG_SUM_I64, AGG_COUNT, AGG_MIN_I64, AGG_MAX_I64.
        F64 / multi-DType / AVG / COUNT_DISTINCT / variance/skew/kurt are
        future work (signatures hold; per-batch kernels left as stubs
        ladder).

        Caller invariants:
            * len(key_col_idxs) == layout.n_key_cols().
            * len(payload_col_idxs) == self.n_aggs() (one source col per
              agg op; for AGG_COUNT the col is read but not used).
            * Every key col is DT_I64; every payload col is DT_I64.
            * `self.agg_op_tags` + `self.agg_col_offsets` populated via
              `add_agg` before the first batch.

        Parameters:
            bo: Origin of the input BatchView.
            lo: Origin of the borrowed RowLayout (held under an RBS
                slot).
        """
        var n_rows_in = batch.n_rows()
        if n_rows_in == 0:
            return

        # Reset per-batch scratch state.
        # Fresh probe_keys RowBlock per batch (cheap — OwnedAlignedBuffer alloc
        # once per batch + scalar encode loop for n_rows_in rows).
        var ks = self.key_stride
        self.probe_keys = RowBlock(ks)
        # The probe block is rebuilt per batch, so it has to be
        # re-stamped per batch or a var key would hash its descriptor here and
        # its payload in `self.rows` — the two sides of the very comparison the
        # upsert is about.
        self.probe_keys.var_key_offsets = self._var_key_offsets_copy()
        self.probe_keys.reserve_rows(n_rows_in)
        self.slots_buf = List[Int](capacity=n_rows_in)
        for _ in range(n_rows_in):
            self.slots_buf.append(-1)

        # Step 1: encode probe keys into the scratch RowBlock.
        # Encoded via the centralized _dispatch_encode_key_col free
        # function, which covers every fixed-width DType and STRING keys;
        # BINARY keys raise (not yet supported).
        var n_key = layout.n_key_cols()
        for k in range(n_key):
            var desc = layout.key_descriptors[k]
            _dispatch_encode_key_col(
                self.probe_keys, batch, desc, key_col_idxs[k]
            )

        # Auto-init + pre-grow for the worst case (all new groups). The
        # actual count may be smaller after dedup; the grow is a no-op if
        # capacity already suffices. `ensure_cap` rehashes existing groups at
        # the new mask (it hashes rows from `self.rows`).
        self.directory.ensure_cap(self.rows, self.rows.n_rows + n_rows_in, ks)

        # Step 2: hash + linear-probe upsert (loop body drives the directory
        # through the slot helpers; the upsert-on-miss policy stays here).
        for row in range(n_rows_in):
            var h = _hash_row_bytes(self.probe_keys, row, ks)
            var slot = self.directory.slot_for(h)
            var matched_row: Int
            while True:
                var existing = self.directory.get(slot)
                if existing == -1:
                    # Miss — insert new group.
                    var new_row = self.rows.n_rows
                    self.rows.reserve_rows(1)
                    # Copy key bytes from probe_keys[row] → rows[new_row].
                    self._copy_key_into_row(row, new_row, ks)
                    # Zero-init agg-state cells (key bytes already written;
                    # agg cells are the payload region of the row beyond
                    # `ks` bytes). Agg cells are I64; we
                    # init SUM/COUNT to 0, MIN to INT64_MAX, MAX to
                    # INT64_MIN. Per-op init is keyed off `agg_op_tags`.
                    self._init_agg_cells(new_row)
                    self.rows.set_n_rows(new_row + 1)
                    self.directory.set(slot, new_row)
                    matched_row = new_row
                    break
                # Compare key bytes against the existing slot's row.
                if _row_bytes_equal(
                    self.probe_keys, row,
                    self.rows, existing,
                    ks,
                ):
                    matched_row = existing
                    break
                slot = self.directory.next_slot(slot)
            self.slots_buf[row] = matched_row

        # Step 3: AGG-MAJOR dispatch ladder.
        # The outer loop fires once per AGG OP, NOT per row.
        # That is the point of the agg-major loop — branch predictor learns the
        # ladder once per batch rather than 6M times per query.
        var n_aggs = self.agg_op_tags.__len__()
        for a in range(n_aggs):
            var op = self.agg_op_tags[a]
            var slot_off = self.agg_col_offsets[a]
            # Route via the centralized _dispatch_agg_kernel —
            # covers I64/F64/I32/F32/U32/U64/narrow + COUNT/AVG (~34 arms).
            self._dispatch_agg_kernel(
                op, batch, payload_col_idxs[a], slot_off, n_rows_in
            )

    @always_inline
    def _copy_key_into_row(
        mut self, probe_row: Int, dest_row: Int, ks: Int
    ) raises:
        """Copy `ks` key bytes from `self.probe_keys[probe_row]` to
        `self.rows[dest_row]`. Internal helper for upsert miss path.

        SAFETY: both rows are bounded by their respective n_rows / capacity
        contracts (the caller ensured capacity via reserve_rows). The
        probe_keys row was written by `write_i64_batch` above, and the
        dest row is in `[0, capacity)` — beyond current n_rows but
        within the reserved region.
        """
        # SAFETY: byte-by-byte copy under concrete origins. Both pointers
        # are obtained via the internal `_row_base_ptr_*` accessors which
        # widen to the receiver origin (concrete `o`, not wildcard).
        var src = self.probe_keys._row_base_ptr_ro(probe_row)
        var dst = self.rows._row_base_ptr_mut(dest_row)
        for i in range(ks):
            dst[i] = src[i]
        # ⛔ THE SPILL-CRITICAL HALF. The `ks` bytes just copied
        # include each var key's (offset, length) DESCRIPTOR, which points into
        # the PROBE block's var heap — a block that is thrown away at the end of
        # this batch. `copy_var_string_cell` re-appends the payload into
        # `self.rows`'s OWN heap and rewrites the descriptor to the new offset,
        # so the group owns its key bytes for the rest of its life (across every
        # later batch, the spill image, and the grace-hash repartition).
        for i in range(len(self.var_key_offsets)):
            var vo = self.var_key_offsets[i]
            self.rows.copy_var_string_cell(
                dest_row, vo, self.probe_keys, probe_row, vo
            )

    @always_inline
    def _init_agg_cells(mut self, row: Int):
        """Zero-init / sentinel-init all agg-state cells for a freshly-
        inserted group row.

        Per-op init:
            AGG_SUM_I64 / AGG_COUNT → 0
            AGG_MIN_I64             → INT64_MAX
            AGG_MAX_I64             → INT64_MIN
        F64 ops carry stubbed inits at the same shape; future work.
        """
        var n_aggs = self.agg_op_tags.__len__()
        for a in range(n_aggs):
            var op = self.agg_op_tags[a]
            var off = self.agg_col_offsets[a]
            # ─── COUNT / SUM / AVG → 0 (zero-init OK, write explicit) ────
            if op == AGG_COUNT or op == AGG_COUNT_NONNULL:
                self.rows.write_fixed[DType.int64](row, off, Scalar[DType.int64](0))
            elif op == AGG_SUM_I64 or op == AGG_AVG_I64:
                self.rows.write_fixed[DType.int64](row, off, Scalar[DType.int64](0))
            elif op == AGG_SUM_F64 or op == AGG_AVG_F64:
                self.rows.write_fixed[DType.float64](row, off, Scalar[DType.float64](0.0))
            elif op == AGG_SUM_I32 or op == AGG_AVG_I32:
                self.rows.write_fixed[DType.int32](row, off, Scalar[DType.int32](0))
            elif op == AGG_SUM_F32 or op == AGG_AVG_F32:
                self.rows.write_fixed[DType.float32](row, off, Scalar[DType.float32](0.0))
            elif op == AGG_SUM_U32 or op == AGG_AVG_U32:
                self.rows.write_fixed[DType.uint32](row, off, Scalar[DType.uint32](0))
            elif op == AGG_SUM_U64 or op == AGG_AVG_U64:
                self.rows.write_fixed[DType.uint64](row, off, Scalar[DType.uint64](0))
            # ─── MIN — sentinel = max-of-DT ─────────────────────────────
            elif op == AGG_MIN_I64:
                # INT64_MAX = 2^63 - 1
                self.rows.write_fixed[DType.int64](
                    row, off, Scalar[DType.int64](9223372036854775807)
                )
            elif op == AGG_MIN_F64:
                self.rows.write_fixed[DType.float64](
                    row, off, Scalar[DType.float64].MAX_FINITE
                )
            elif op == AGG_MIN_I32:
                self.rows.write_fixed[DType.int32](
                    row, off, Scalar[DType.int32](2147483647)
                )
            elif op == AGG_MIN_F32:
                self.rows.write_fixed[DType.float32](
                    row, off, Scalar[DType.float32].MAX_FINITE
                )
            elif op == AGG_MIN_U32:
                self.rows.write_fixed[DType.uint32](
                    row, off, Scalar[DType.uint32](4294967295)
                )
            elif op == AGG_MIN_U64:
                self.rows.write_fixed[DType.uint64](
                    row, off, Scalar[DType.uint64](18446744073709551615)
                )
            elif op == AGG_MIN_I16:
                self.rows.write_fixed[DType.int16](
                    row, off, Scalar[DType.int16](32767)
                )
            elif op == AGG_MIN_U16:
                self.rows.write_fixed[DType.uint16](
                    row, off, Scalar[DType.uint16](65535)
                )
            elif op == AGG_MIN_I8:
                self.rows.write_fixed[DType.int8](
                    row, off, Scalar[DType.int8](127)
                )
            elif op == AGG_MIN_U8:
                self.rows.write_fixed[DType.uint8](
                    row, off, Scalar[DType.uint8](255)
                )
            # ─── MAX — sentinel = min-of-DT ─────────────────────────────
            elif op == AGG_MAX_I64:
                # INT64_MIN = -2^63 (literal can't parse in one go).
                self.rows.write_fixed[DType.int64](
                    row, off, Scalar[DType.int64](-9223372036854775807 - 1)
                )
            elif op == AGG_MAX_F64:
                self.rows.write_fixed[DType.float64](
                    row, off, Scalar[DType.float64].MIN_FINITE
                )
            elif op == AGG_MAX_I32:
                self.rows.write_fixed[DType.int32](
                    row, off, Scalar[DType.int32](-2147483648)
                )
            elif op == AGG_MAX_F32:
                self.rows.write_fixed[DType.float32](
                    row, off, Scalar[DType.float32].MIN_FINITE
                )
            elif op == AGG_MAX_U32:
                self.rows.write_fixed[DType.uint32](row, off, Scalar[DType.uint32](0))
            elif op == AGG_MAX_U64:
                self.rows.write_fixed[DType.uint64](row, off, Scalar[DType.uint64](0))
            elif op == AGG_MAX_U16:
                self.rows.write_fixed[DType.uint16](row, off, Scalar[DType.uint16](0))
            elif op == AGG_MAX_U8:
                self.rows.write_fixed[DType.uint8](row, off, Scalar[DType.uint8](0))
            elif op == AGG_MAX_I16:
                self.rows.write_fixed[DType.int16](
                    row, off, Scalar[DType.int16](-32768)
                )
            elif op == AGG_MAX_I8:
                self.rows.write_fixed[DType.int8](
                    row, off, Scalar[DType.int8](-128)
                )
            else:
                # Unknown op tag — leave zero (OwnedAlignedBuffer is zero-init).
                pass

    # ─── Per-batch per-op SIMD-stagable inner kernels ──
    #
    # These are the "inner stage 2" callees of the agg-major dispatch
    # ladder: scalar bodies for the I64 + COUNT
    # quartet (SUM / COUNT / MIN / MAX). F64 + AVG kernels carry stubs
    # awaiting widening.
    # ---------------------------------------------------------------------

    @always_inline
    def _agg_sum_i64_batch[
        bo: Origin[mut=False], //,
    ](
        mut self,
        batch: BatchView[bo],
        src_col_idx: Int,
        slot_off: Int,
        n_rows_in: Int,
    ) raises:
        """SUM(i64) per-batch update.

        For each row in `[0, n_rows_in)`, read the source column value
        and add it to the agg cell at `slot_off` in the corresponding
        group row (`self.slots_buf[row]`).

        ⛔ A CHECKED ADD. This cell is the
        >4M-row resident SPILL route's `sum(<int64>)` (and the SUM half of its
        `avg`), and `prev + v` WRAPPED silently -- a group total past INT64
        answered a wrapped number where every other grouped route folds an
        exact 128-bit total and answers or refuses by name. The overflow bit
        is OR-folded branch-free and checked ONCE per batch; a total that
        leaves INT64 REFUSES BY NAME (`row_sum_i64_overflow_message`).
        ⚠ A PARTIAL can overflow where the final total would not (MAX + 1 - 1):
        that is a refusal where DuckDB answers, never a wrong number. The
        16-byte exact cell that removes it is the remaining work.
        """
        var col = batch.col_i64(src_col_idx)
        var ovf = Int64(0)
        for row in range(n_rows_in):
            var slot = self.slots_buf[row]
            var v = col.load[1](row)[0]
            var prev = self.rows.read_fixed[DType.int64](slot, slot_off)
            var r = prev + v
            # Two's-complement: the add overflowed iff BOTH operands' signs
            # differ from the result's sign.
            ovf |= (prev ^ r) & (v ^ r)
            self.rows.write_fixed[DType.int64](slot, slot_off, r)
        if ovf < 0:
            raise Error(row_sum_i64_overflow_message())

    @always_inline
    def _agg_count_batch(mut self, slot_off: Int, n_rows_in: Int):
        """COUNT per-batch update (DT-erased — increment by 1 per row).

        NULL-aware COUNT (skip NULLs) is a future widening; the
        inputs are all-non-null per the lowering's I64-only
        gate, so plain increment is correct.
        """
        for row in range(n_rows_in):
            var slot = self.slots_buf[row]
            var prev = self.rows.read_fixed[DType.int64](slot, slot_off)
            self.rows.write_fixed[DType.int64](
                slot, slot_off, prev + Scalar[DType.int64](1)
            )

    @always_inline
    def _agg_min_i64_batch[
        bo: Origin[mut=False], //,
    ](
        mut self,
        batch: BatchView[bo],
        src_col_idx: Int,
        slot_off: Int,
        n_rows_in: Int,
    ) raises:
        """MIN(i64) per-batch update."""
        var col = batch.col_i64(src_col_idx)
        for row in range(n_rows_in):
            var slot = self.slots_buf[row]
            var v = col.load[1](row)[0]
            var prev = self.rows.read_fixed[DType.int64](slot, slot_off)
            if v < prev:
                self.rows.write_fixed[DType.int64](slot, slot_off, v)

    @always_inline
    def _agg_max_i64_batch[
        bo: Origin[mut=False], //,
    ](
        mut self,
        batch: BatchView[bo],
        src_col_idx: Int,
        slot_off: Int,
        n_rows_in: Int,
    ) raises:
        """MAX(i64) per-batch update."""
        var col = batch.col_i64(src_col_idx)
        for row in range(n_rows_in):
            var slot = self.slots_buf[row]
            var v = col.load[1](row)[0]
            var prev = self.rows.read_fixed[DType.int64](slot, slot_off)
            if v > prev:
                self.rows.write_fixed[DType.int64](slot, slot_off, v)

    # ─── Comptime-DT base kernels (SoA-friendly) ───────────────

    @always_inline
    def _agg_sum_dt_batch[
        bo: Origin[mut=False], //, DT: DType,
    ](
        mut self,
        col: ColView[DT, bo],
        slot_off: Int,
        n_rows_in: Int,
    ) raises:
        """SUM[DT] per-batch update."""
        for row in range(n_rows_in):
            var slot = self.slots_buf[row]
            var v = col.load[1](row)[0]
            var prev = self.rows.read_fixed[DT](slot, slot_off)
            self.rows.write_fixed[DT](slot, slot_off, prev + v)

    @always_inline
    def _agg_min_dt_batch[
        bo: Origin[mut=False], //, DT: DType,
    ](
        mut self,
        col: ColView[DT, bo],
        slot_off: Int,
        n_rows_in: Int,
    ) raises:
        """MIN[DT] per-batch update."""
        for row in range(n_rows_in):
            var slot = self.slots_buf[row]
            var v = col.load[1](row)[0]
            var prev = self.rows.read_fixed[DT](slot, slot_off)
            if v < prev:
                self.rows.write_fixed[DT](slot, slot_off, v)

    @always_inline
    def _agg_max_dt_batch[
        bo: Origin[mut=False], //, DT: DType,
    ](
        mut self,
        col: ColView[DT, bo],
        slot_off: Int,
        n_rows_in: Int,
    ) raises:
        """MAX[DT] per-batch update."""
        for row in range(n_rows_in):
            var slot = self.slots_buf[row]
            var v = col.load[1](row)[0]
            var prev = self.rows.read_fixed[DT](slot, slot_off)
            if v > prev:
                self.rows.write_fixed[DT](slot, slot_off, v)

    # ─── F64 named entry points ──────────────────────────────────────────

    @always_inline
    def _agg_sum_f64_batch[bo: Origin[mut=False], //](
        mut self, batch: BatchView[bo], src_col_idx: Int, slot_off: Int, n_rows_in: Int
    ) raises:
        """SUM(f64) per-batch update."""
        self._agg_sum_dt_batch[DType.float64](
            batch.col_f64(src_col_idx), slot_off, n_rows_in
        )

    @always_inline
    def _agg_min_f64_batch[bo: Origin[mut=False], //](
        mut self, batch: BatchView[bo], src_col_idx: Int, slot_off: Int, n_rows_in: Int
    ) raises:
        """MIN(f64) per-batch update."""
        self._agg_min_dt_batch[DType.float64](
            batch.col_f64(src_col_idx), slot_off, n_rows_in
        )

    @always_inline
    def _agg_max_f64_batch[bo: Origin[mut=False], //](
        mut self, batch: BatchView[bo], src_col_idx: Int, slot_off: Int, n_rows_in: Int
    ) raises:
        """MAX(f64) per-batch update."""
        self._agg_max_dt_batch[DType.float64](
            batch.col_f64(src_col_idx), slot_off, n_rows_in
        )

    @always_inline
    def _agg_avg_f64_batch[bo: Origin[mut=False], //](
        mut self, batch: BatchView[bo], src_col_idx: Int, slot_off: Int, n_rows_in: Int
    ) raises:
        """AVG(f64) per-batch update — accumulates SUM; finalize divides."""
        self._agg_sum_dt_batch[DType.float64](
            batch.col_f64(src_col_idx), slot_off, n_rows_in
        )

    @always_inline
    def _agg_avg_i64_batch[bo: Origin[mut=False], //](
        mut self, batch: BatchView[bo], src_col_idx: Int, slot_off: Int, n_rows_in: Int
    ) raises:
        """AVG(i64) — accumulates SUM."""
        self._agg_sum_dt_batch[DType.int64](
            batch.col_i64(src_col_idx), slot_off, n_rows_in
        )

    # ─── I32 named entry points ──────────────────────────────────────────

    @always_inline
    def _agg_sum_i32_batch[bo: Origin[mut=False], //](
        mut self, batch: BatchView[bo], src_col_idx: Int, slot_off: Int, n_rows_in: Int
    ) raises:
        """SUM(i32) per-batch update."""
        self._agg_sum_dt_batch[DType.int32](
            batch.col_i32(src_col_idx), slot_off, n_rows_in
        )

    @always_inline
    def _agg_min_i32_batch[bo: Origin[mut=False], //](
        mut self, batch: BatchView[bo], src_col_idx: Int, slot_off: Int, n_rows_in: Int
    ) raises:
        """MIN(i32) per-batch update."""
        self._agg_min_dt_batch[DType.int32](
            batch.col_i32(src_col_idx), slot_off, n_rows_in
        )

    @always_inline
    def _agg_max_i32_batch[bo: Origin[mut=False], //](
        mut self, batch: BatchView[bo], src_col_idx: Int, slot_off: Int, n_rows_in: Int
    ) raises:
        """MAX(i32) per-batch update."""
        self._agg_max_dt_batch[DType.int32](
            batch.col_i32(src_col_idx), slot_off, n_rows_in
        )

    @always_inline
    def _agg_avg_i32_batch[bo: Origin[mut=False], //](
        mut self, batch: BatchView[bo], src_col_idx: Int, slot_off: Int, n_rows_in: Int
    ) raises:
        """AVG(i32) — accumulates SUM."""
        self._agg_sum_dt_batch[DType.int32](
            batch.col_i32(src_col_idx), slot_off, n_rows_in
        )

    # ─── F32 named entry points ──────────────────────────────────────────

    @always_inline
    def _agg_sum_f32_batch[bo: Origin[mut=False], //](
        mut self, batch: BatchView[bo], src_col_idx: Int, slot_off: Int, n_rows_in: Int
    ) raises:
        """SUM(f32) per-batch update."""
        self._agg_sum_dt_batch[DType.float32](
            batch.col_f32(src_col_idx), slot_off, n_rows_in
        )

    @always_inline
    def _agg_min_f32_batch[bo: Origin[mut=False], //](
        mut self, batch: BatchView[bo], src_col_idx: Int, slot_off: Int, n_rows_in: Int
    ) raises:
        """MIN(f32) per-batch update."""
        self._agg_min_dt_batch[DType.float32](
            batch.col_f32(src_col_idx), slot_off, n_rows_in
        )

    @always_inline
    def _agg_max_f32_batch[bo: Origin[mut=False], //](
        mut self, batch: BatchView[bo], src_col_idx: Int, slot_off: Int, n_rows_in: Int
    ) raises:
        """MAX(f32) per-batch update."""
        self._agg_max_dt_batch[DType.float32](
            batch.col_f32(src_col_idx), slot_off, n_rows_in
        )

    @always_inline
    def _agg_avg_f32_batch[bo: Origin[mut=False], //](
        mut self, batch: BatchView[bo], src_col_idx: Int, slot_off: Int, n_rows_in: Int
    ) raises:
        """AVG(f32) — accumulates SUM."""
        self._agg_sum_dt_batch[DType.float32](
            batch.col_f32(src_col_idx), slot_off, n_rows_in
        )

    # ─── U32 / U64 named entry points ────────────────────────────────────

    @always_inline
    def _agg_sum_u32_batch[bo: Origin[mut=False], //](
        mut self, batch: BatchView[bo], src_col_idx: Int, slot_off: Int, n_rows_in: Int
    ) raises:
        """SUM(u32) per-batch update."""
        self._agg_sum_dt_batch[DType.uint32](
            batch.col_u32(src_col_idx), slot_off, n_rows_in
        )

    @always_inline
    def _agg_min_u32_batch[bo: Origin[mut=False], //](
        mut self, batch: BatchView[bo], src_col_idx: Int, slot_off: Int, n_rows_in: Int
    ) raises:
        """MIN(u32) per-batch update."""
        self._agg_min_dt_batch[DType.uint32](
            batch.col_u32(src_col_idx), slot_off, n_rows_in
        )

    @always_inline
    def _agg_max_u32_batch[bo: Origin[mut=False], //](
        mut self, batch: BatchView[bo], src_col_idx: Int, slot_off: Int, n_rows_in: Int
    ) raises:
        """MAX(u32) per-batch update."""
        self._agg_max_dt_batch[DType.uint32](
            batch.col_u32(src_col_idx), slot_off, n_rows_in
        )

    @always_inline
    def _agg_avg_u32_batch[bo: Origin[mut=False], //](
        mut self, batch: BatchView[bo], src_col_idx: Int, slot_off: Int, n_rows_in: Int
    ) raises:
        """AVG(u32) — accumulates SUM."""
        self._agg_sum_dt_batch[DType.uint32](
            batch.col_u32(src_col_idx), slot_off, n_rows_in
        )

    @always_inline
    def _agg_sum_u64_batch[bo: Origin[mut=False], //](
        mut self, batch: BatchView[bo], src_col_idx: Int, slot_off: Int, n_rows_in: Int
    ) raises:
        """SUM(u64) per-batch update."""
        self._agg_sum_dt_batch[DType.uint64](
            batch.col_u64(src_col_idx), slot_off, n_rows_in
        )

    @always_inline
    def _agg_min_u64_batch[bo: Origin[mut=False], //](
        mut self, batch: BatchView[bo], src_col_idx: Int, slot_off: Int, n_rows_in: Int
    ) raises:
        """MIN(u64) per-batch update."""
        self._agg_min_dt_batch[DType.uint64](
            batch.col_u64(src_col_idx), slot_off, n_rows_in
        )

    @always_inline
    def _agg_max_u64_batch[bo: Origin[mut=False], //](
        mut self, batch: BatchView[bo], src_col_idx: Int, slot_off: Int, n_rows_in: Int
    ) raises:
        """MAX(u64) per-batch update."""
        self._agg_max_dt_batch[DType.uint64](
            batch.col_u64(src_col_idx), slot_off, n_rows_in
        )

    @always_inline
    def _agg_avg_u64_batch[bo: Origin[mut=False], //](
        mut self, batch: BatchView[bo], src_col_idx: Int, slot_off: Int, n_rows_in: Int
    ) raises:
        """AVG(u64) — accumulates SUM."""
        self._agg_sum_dt_batch[DType.uint64](
            batch.col_u64(src_col_idx), slot_off, n_rows_in
        )

    # ─── Narrow widths I16/U16/I8/U8 — MIN/MAX only ─────────────────────

    @always_inline
    def _agg_min_i16_batch[bo: Origin[mut=False], //](
        mut self, batch: BatchView[bo], src_col_idx: Int, slot_off: Int, n_rows_in: Int
    ) raises:
        """MIN(i16) per-batch update."""
        self._agg_min_dt_batch[DType.int16](
            batch.col_i16(src_col_idx), slot_off, n_rows_in
        )

    @always_inline
    def _agg_max_i16_batch[bo: Origin[mut=False], //](
        mut self, batch: BatchView[bo], src_col_idx: Int, slot_off: Int, n_rows_in: Int
    ) raises:
        """MAX(i16) per-batch update."""
        self._agg_max_dt_batch[DType.int16](
            batch.col_i16(src_col_idx), slot_off, n_rows_in
        )

    @always_inline
    def _agg_min_u16_batch[bo: Origin[mut=False], //](
        mut self, batch: BatchView[bo], src_col_idx: Int, slot_off: Int, n_rows_in: Int
    ) raises:
        """MIN(u16) per-batch update."""
        self._agg_min_dt_batch[DType.uint16](
            batch.col_u16(src_col_idx), slot_off, n_rows_in
        )

    @always_inline
    def _agg_max_u16_batch[bo: Origin[mut=False], //](
        mut self, batch: BatchView[bo], src_col_idx: Int, slot_off: Int, n_rows_in: Int
    ) raises:
        """MAX(u16) per-batch update."""
        self._agg_max_dt_batch[DType.uint16](
            batch.col_u16(src_col_idx), slot_off, n_rows_in
        )

    @always_inline
    def _agg_min_i8_batch[bo: Origin[mut=False], //](
        mut self, batch: BatchView[bo], src_col_idx: Int, slot_off: Int, n_rows_in: Int
    ) raises:
        """MIN(i8) per-batch update."""
        self._agg_min_dt_batch[DType.int8](
            batch.col_i8(src_col_idx), slot_off, n_rows_in
        )

    @always_inline
    def _agg_max_i8_batch[bo: Origin[mut=False], //](
        mut self, batch: BatchView[bo], src_col_idx: Int, slot_off: Int, n_rows_in: Int
    ) raises:
        """MAX(i8) per-batch update."""
        self._agg_max_dt_batch[DType.int8](
            batch.col_i8(src_col_idx), slot_off, n_rows_in
        )

    @always_inline
    def _agg_min_u8_batch[bo: Origin[mut=False], //](
        mut self, batch: BatchView[bo], src_col_idx: Int, slot_off: Int, n_rows_in: Int
    ) raises:
        """MIN(u8) per-batch update."""
        self._agg_min_dt_batch[DType.uint8](
            batch.col_u8(src_col_idx), slot_off, n_rows_in
        )

    @always_inline
    def _agg_max_u8_batch[bo: Origin[mut=False], //](
        mut self, batch: BatchView[bo], src_col_idx: Int, slot_off: Int, n_rows_in: Int
    ) raises:
        """MAX(u8) per-batch update."""
        self._agg_max_dt_batch[DType.uint8](
            batch.col_u8(src_col_idx), slot_off, n_rows_in
        )

    # ─── COUNT_NONNULL — this treats all rows valid ──────────────────

    @always_inline
    def _agg_count_nonnull_batch[bo: Origin[mut=False], //](
        mut self, batch: BatchView[bo], src_col_idx: Int, slot_off: Int, n_rows_in: Int
    ) raises:
        """COUNT(col) NULL-aware. This treats all rows valid; the
        validity-bit check is a future widening once SDK lowering threads
        validity through the dispatch."""
        _ = batch
        _ = src_col_idx
        self._agg_count_batch(slot_off, n_rows_in)

    # ─── Centralized agg dispatch ──────────────────

    @always_inline
    def _dispatch_agg_kernel[bo: Origin[mut=False], //](
        mut self,
        op: UInt8,
        batch: BatchView[bo],
        src_col_idx: Int,
        slot_off: Int,
        n_rows_in: Int,
    ) raises:
        """Dispatch one agg op-tag to its per-DType kernel.

        Mojo jump-table note: long if/elif
        on a UInt8 op compiles to a jump table; the ladder is read once
        per (agg, batch). Cost is negligible vs per-row agg compute.
        """
        # I64 ops
        if op == AGG_SUM_I64:
            self._agg_sum_i64_batch(batch, src_col_idx, slot_off, n_rows_in)
        elif op == AGG_MIN_I64:
            self._agg_min_i64_batch(batch, src_col_idx, slot_off, n_rows_in)
        elif op == AGG_MAX_I64:
            self._agg_max_i64_batch(batch, src_col_idx, slot_off, n_rows_in)
        elif op == AGG_AVG_I64:
            self._agg_avg_i64_batch(batch, src_col_idx, slot_off, n_rows_in)
        # COUNT (DT-erased)
        elif op == AGG_COUNT:
            self._agg_count_batch(slot_off, n_rows_in)
        elif op == AGG_COUNT_NONNULL:
            self._agg_count_nonnull_batch(batch, src_col_idx, slot_off, n_rows_in)
        # F64 ops
        elif op == AGG_SUM_F64:
            self._agg_sum_f64_batch(batch, src_col_idx, slot_off, n_rows_in)
        elif op == AGG_MIN_F64:
            self._agg_min_f64_batch(batch, src_col_idx, slot_off, n_rows_in)
        elif op == AGG_MAX_F64:
            self._agg_max_f64_batch(batch, src_col_idx, slot_off, n_rows_in)
        elif op == AGG_AVG_F64:
            self._agg_avg_f64_batch(batch, src_col_idx, slot_off, n_rows_in)
        # I32 ops
        elif op == AGG_SUM_I32:
            self._agg_sum_i32_batch(batch, src_col_idx, slot_off, n_rows_in)
        elif op == AGG_MIN_I32:
            self._agg_min_i32_batch(batch, src_col_idx, slot_off, n_rows_in)
        elif op == AGG_MAX_I32:
            self._agg_max_i32_batch(batch, src_col_idx, slot_off, n_rows_in)
        elif op == AGG_AVG_I32:
            self._agg_avg_i32_batch(batch, src_col_idx, slot_off, n_rows_in)
        # F32 ops
        elif op == AGG_SUM_F32:
            self._agg_sum_f32_batch(batch, src_col_idx, slot_off, n_rows_in)
        elif op == AGG_MIN_F32:
            self._agg_min_f32_batch(batch, src_col_idx, slot_off, n_rows_in)
        elif op == AGG_MAX_F32:
            self._agg_max_f32_batch(batch, src_col_idx, slot_off, n_rows_in)
        elif op == AGG_AVG_F32:
            self._agg_avg_f32_batch(batch, src_col_idx, slot_off, n_rows_in)
        # U32 ops
        elif op == AGG_SUM_U32:
            self._agg_sum_u32_batch(batch, src_col_idx, slot_off, n_rows_in)
        elif op == AGG_MIN_U32:
            self._agg_min_u32_batch(batch, src_col_idx, slot_off, n_rows_in)
        elif op == AGG_MAX_U32:
            self._agg_max_u32_batch(batch, src_col_idx, slot_off, n_rows_in)
        elif op == AGG_AVG_U32:
            self._agg_avg_u32_batch(batch, src_col_idx, slot_off, n_rows_in)
        # U64 ops
        elif op == AGG_SUM_U64:
            self._agg_sum_u64_batch(batch, src_col_idx, slot_off, n_rows_in)
        elif op == AGG_MIN_U64:
            self._agg_min_u64_batch(batch, src_col_idx, slot_off, n_rows_in)
        elif op == AGG_MAX_U64:
            self._agg_max_u64_batch(batch, src_col_idx, slot_off, n_rows_in)
        elif op == AGG_AVG_U64:
            self._agg_avg_u64_batch(batch, src_col_idx, slot_off, n_rows_in)
        # Narrow widths (I16/U16/I8/U8) — MIN/MAX only
        elif op == AGG_MIN_I16:
            self._agg_min_i16_batch(batch, src_col_idx, slot_off, n_rows_in)
        elif op == AGG_MAX_I16:
            self._agg_max_i16_batch(batch, src_col_idx, slot_off, n_rows_in)
        elif op == AGG_MIN_U16:
            self._agg_min_u16_batch(batch, src_col_idx, slot_off, n_rows_in)
        elif op == AGG_MAX_U16:
            self._agg_max_u16_batch(batch, src_col_idx, slot_off, n_rows_in)
        elif op == AGG_MIN_I8:
            self._agg_min_i8_batch(batch, src_col_idx, slot_off, n_rows_in)
        elif op == AGG_MAX_I8:
            self._agg_max_i8_batch(batch, src_col_idx, slot_off, n_rows_in)
        elif op == AGG_MIN_U8:
            self._agg_min_u8_batch(batch, src_col_idx, slot_off, n_rows_in)
        elif op == AGG_MAX_U8:
            self._agg_max_u8_batch(batch, src_col_idx, slot_off, n_rows_in)
        else:
            # Unknown op tag — slow-path no-op (SDK lowering should
            # never emit an unrecognized tag).
            pass

    # ─── Drain method (emit_to_record_batch) ─────────────────────────────

    def emit_to_record_batch[
        lo: Origin[mut=False], //,
    ](
        self,
        ref [lo] layout: RowLayout,
        key_names: List[String],
        agg_names: List[String],
    ) raises -> Optional[RecordBatch]:
        """Drain the HAG into a fresh RecordBatch.

        Output schema: [key_cols..., agg_cols...] in the order given by
        `key_names` + `agg_names`. Group KEY cells are I64. Each AGG cell's
        emitted arrow type is chosen from that agg's registered op_tag by
        `_agg_state_is_f64` — the F64-STATE quartet {SUM_F64, MIN_F64, MAX_F64,
        AVG_F64} emits FLOAT64, every other op emits INT64 exactly as before.

        ⛔ WHY THIS IS OP-DRIVEN AND NOT A PARAMETER. The
        state cell an F64 agg accumulates into IS float64 bytes — `_init_agg_cells`
        writes `write_fixed[float64]`, `_dispatch_agg_kernel` routes to
        `_agg_sum_dt_batch[float64]`, and `_merge_agg_cells` combines it with
        float adds. Emitting those same 8 bytes through `read_fixed[int64]` does
        not "lose precision", it publishes the IEEE-754 BIT PATTERN as an
        integer — `sum(l_extendedprice)` would come back as ~4.6e18. So the
        int64 read was never a narrower-but-valid emit for an F64 op; it was
        unreachable-by-gate garbage. This makes the emit agree with the cell.

        ⚠ NOT WIDENED HERE: the narrow-state ops (I32/F32/U32/U64/I16/U8/...)
        write sub-8-byte cells and still read back through `read_fixed[int64]`.
        They are unreachable through the only production caller (the spill
        driver's `spill_route_supported` gate) and are left EXACTLY as they were
        — this change is additive, so no existing emit moves a byte.

        BORROWS `self` (read-only) — the body only READS group rows + agg
        cells and builds a FRESH RecordBatch; it never mutates table state.
        Immutable-`self` is load-bearing for `RowHashAggSegment`'s
        `BreakerStateCombinable.drain_to_record_batch(self)` conformance,
        whose trait method borrows `self` immutably; a `mut self`
        emit could not be reached from an immutable-`self` trait drain. The
        change is strictly more permissive — any existing `mut`-bound caller
        (e.g. a hash-agg finalize) can still call it.

        Returns:
            Some(rb) with n_rows == self.n_groups(); None if no groups.
        """
        var n_groups_v = self.n_groups()
        if n_groups_v == 0:
            return None
        var n_key = layout.n_key_cols()
        var n_aggs = self.agg_op_tags.__len__()
        if len(key_names) != n_key:
            raise Error(
                "RowHashAggTable.emit_to_record_batch: key_names length "
                + String(len(key_names)) + " != layout.n_key_cols "
                + String(n_key)
            )
        if len(agg_names) != n_aggs:
            raise Error(
                "RowHashAggTable.emit_to_record_batch: agg_names length "
                + String(len(agg_names)) + " != agg_op_tags length "
                + String(n_aggs)
            )

        var sb = SchemaBuilder()
        for k in range(n_key):
            # A var-width key emits the STRING it actually holds. The
            # INT64 field below is right for every key cell whose 8 bytes ARE
            # the value (or a canonical surrogate the driver inverts); for a
            # COL_VAR_STRING cell those 8 bytes are a heap (offset, length) and
            # publishing them as an integer would hand the caller the ADDRESS
            # of its group key instead of the key.
            if layout.key_descriptors[k].kind == COL_VAR_STRING:
                # NULLABLE, because a var-width key can BE the NULL
                # group (`_VAR_KEY_TAG_NULL`) and a non-nullable field would
                # misdescribe the validity bitmap the builder below attaches.
                # This is the INTERMEDIATE schema; the spill driver's
                # `_rebuild_drain_batch` republishes the caller's `out_schema`
                # field over the column it moves across, so nothing downstream
                # inherits this flag.
                sb.add_field(
                    Field(String(key_names[k]), ArrowType.STRING, True)
                )
            else:
                sb.add_field(
                    Field(String(key_names[k]), ArrowType.INT64, False)
                )
        for a in range(n_aggs):
            if _agg_state_is_f64(self.agg_op_tags[a]):
                sb.add_field(
                    Field(String(agg_names[a]), ArrowType.FLOAT64, False)
                )
            else:
                sb.add_field(Field(String(agg_names[a]), ArrowType.INT64, False))
        var schema = sb.build()

        var rbb = RecordBatchBuilder.with_capacity(n_key + n_aggs)

        # Emit key columns — read each group row's key cells.
        for k in range(n_key):
            var desc = layout.key_descriptors[k]
            var off = Int(desc.offset_in_row)
            if desc.kind == COL_VAR_STRING:
                # Resolve each group's descriptor against THIS table's var heap
                # and push the payload bytes. `copy_var_string_cell` guaranteed
                # on every insert / combine / restore that the bytes live in
                # this block, so the read is local by construction.
                var sbld = ArrowStringBuilder()
                sbld.reserve_rows(n_groups_v)
                sbld.reserve_bytes(self.rows.var_storage_used)
                for row in range(n_groups_v):
                    # Ask the TAG first, then publish the payload
                    # WITHOUT it. A NULL group and the `''` group both carry a
                    # zero-length payload here — the tag is the only thing that
                    # tells them apart, which is exactly why it is written.
                    # `var_string_key_payload_at` is the KEY family's
                    # zero-copy cell reader (the tag-stripping sibling of
                    # `var_string_span_at`): a borrowed Span tied to this block,
                    # no per-group heap allocation, no `UnsafePointer` spelled
                    # here.
                    if self.rows.var_string_key_is_null_at(row, off):
                        sbld.push_null()
                    else:
                        sbld.push_bytes(
                            self.rows.var_string_key_payload_at(row, off)
                        )
                rbb.add_column(sbld^.build())
                continue
            var values = List[Scalar[DType.int64]](capacity=n_groups_v)
            for row in range(n_groups_v):
                var v = self.rows.read_fixed[DType.int64](row, off)
                values.append(v)
            rbb.add_column(
                Column.from_primitive[DType.int64](
                    PrimitiveArray[DType.int64].from_list(values)
                )
            )

        # Emit agg columns — each read back through the DType its own op
        # accumulated into (see `_agg_state_is_f64`).
        for a in range(n_aggs):
            var off = self.agg_col_offsets[a]
            if _agg_state_is_f64(self.agg_op_tags[a]):
                var fvalues = List[Scalar[DType.float64]](capacity=n_groups_v)
                for row in range(n_groups_v):
                    var fv = self.rows.read_fixed[DType.float64](row, off)
                    fvalues.append(fv)
                rbb.add_column(
                    Column.from_primitive[DType.float64](
                        PrimitiveArray[DType.float64].from_list(fvalues)
                    )
                )
            else:
                var values = List[Scalar[DType.int64]](capacity=n_groups_v)
                for row in range(n_groups_v):
                    var v = self.rows.read_fixed[DType.int64](row, off)
                    values.append(v)
                rbb.add_column(
                    Column.from_primitive[DType.int64](
                        PrimitiveArray[DType.int64].from_list(values)
                    )
                )

        var rb = rbb.build(schema^)
        return Optional[RecordBatch](rb^)

    # ─── Cross-instance combine (BreakerStateCombinable backing) ──
    #
    # The re-hash / re-probe merge of one worker's per-segment HAG table into
    # another. The engine-side `RowHashAggSegment` wrapper
    # (`komira_engine_operators.row_hash_agg_segment`) delegates its
    # `BreakerStateCombinable.combine` to THIS method. The method lives on the
    # table (not the engine wrapper) because the merge manipulates the table's
    # OWN private hashing helpers (`_hash_row_bytes` / `_row_bytes_equal` /
    # `_ensure_directory_cap` / `_copy_key_into_row`) — module-private free
    # functions the engine layer cannot reach. Adding it here keeps the unsafe
    # hashing internals encapsulated and exposes a safe by-value combine.
    # ----------------------------------------------------------------------

    def combine(mut self, var other: Self) raises:
        """Merge `other`'s group rows into `self`, BY KEY (re-hash/re-probe).

        Byte-identical-to-single-worker contract (Decision B(a), re-hash):
        for input partitioned into row-sets R_a / R_b, building table A over
        R_a and table B over R_b then `A.combine(B^)` yields the EXACT same
        accumulated state — hence the EXACT same `emit_to_record_batch`
        output — as building one table over (R_a ++ R_b). The fold is BY KEY
        (each of `other`'s group rows is re-hashed against `self`'s
        directory), never by raw bucket slot — the two tables hash
        independently, so a per-slot fold would corrupt buckets.

        Per-agg merge semantics (keyed off `agg_op_tags`, identical for both
        tables under one query plan):
            SUM / COUNT / AVG-state  -> add the two state cells
            MIN                      -> min of the two state cells
            MAX                      -> max of the two state cells

        Caller invariants:
            * `self.key_stride == other.key_stride`
            * `self.agg_op_tags == other.agg_op_tags`
            * `self.agg_col_offsets == other.agg_col_offsets`
            * `self.rows.fixed_row_stride == other.rows.fixed_row_stride`
        These hold by construction — both per-worker tables are built from
        the same RowLayout under one segment plan. A mismatch raises (a
        wrong-wiring guard).

        After this call `other` is consumed (owned `var`); `self` carries the
        merged state.
        """
        var ks = self.key_stride
        if other.key_stride != ks:
            raise Error(
                "RowHashAggTable.combine: key_stride mismatch ("
                + String(ks) + " vs " + String(other.key_stride) + ")"
            )
        var n_aggs = self.agg_op_tags.__len__()
        if other.agg_op_tags.__len__() != n_aggs:
            raise Error(
                "RowHashAggTable.combine: agg arity mismatch ("
                + String(n_aggs) + " vs "
                + String(other.agg_op_tags.__len__()) + ")"
            )

        var other_groups = other.n_groups()
        if other_groups == 0:
            return

        # Auto-init + pre-grow for the worst case (every other-group is new
        # in self). `ensure_cap` rehashes self's existing groups at the new
        # mask (hashing rows from `self.rows`).
        self.directory.ensure_cap(self.rows, self.rows.n_rows + other_groups, ks)

        # Re-probe each of `other`'s group rows into `self`'s directory by
        # key bytes; merge agg-state cells on hit, copy the group on miss.
        for og in range(other_groups):
            var h = _hash_row_bytes(other.rows, og, ks)
            var slot = self.directory.slot_for(h)
            var matched_row: Int
            var was_miss = False
            while True:
                var existing = self.directory.get(slot)
                if existing == -1:
                    # Miss — copy the whole group row (key cells + agg
                    # state cells) from `other` into a fresh `self` row.
                    # A brand-new group adopts `other`'s accumulated state
                    # wholesale; no per-cell merge needed.
                    var new_row = self.rows.n_rows
                    self.rows.reserve_rows(1)
                    self._copy_full_row_from(other.rows, og, new_row)
                    self.rows.set_n_rows(new_row + 1)
                    self.directory.set(slot, new_row)
                    matched_row = new_row
                    was_miss = True
                    break
                if _row_bytes_equal(
                    other.rows, og, self.rows, existing, ks
                ):
                    matched_row = existing
                    break
                slot = self.directory.next_slot(slot)

            # On a HIT (group pre-existed in self), merge the agg-state
            # cells associatively. On a MISS the fresh row already carries
            # other's state, so skip the merge.
            if not was_miss:
                self._merge_agg_cells(matched_row, other.rows, og)

    @always_inline
    def _copy_full_row_from(
        mut self, src_rows: RowBlock, src_row: Int, dst_row: Int
    ) raises:
        """Copy the FULL packed row (key cells + agg-state cells) from
        `src_rows[src_row]` into `self.rows[dst_row]`.

        Used by `combine`'s miss path: a new group adopts `other`'s already-
        accumulated state wholesale (no merge needed for a brand-new group).
        """
        # SAFETY: byte-by-byte copy under concrete origins via the internal
        # `_row_base_ptr_*` accessors (concrete receiver origin, not
        # wildcard). Bounded by the reserve_rows precondition + the shared
        # fixed_row_stride invariant.
        var stride = self.rows.fixed_row_stride
        var src = src_rows._row_base_ptr_ro(src_row)
        var dst = self.rows._row_base_ptr_mut(dst_row)
        for i in range(stride):
            dst[i] = src[i]
        # Same reason as `_copy_key_into_row` — `other`'s var heap is
        # dropped when the shell table dies, so the adopted group re-appends its
        # key payload into `self.rows`'s heap and gets a rewritten descriptor.
        for i in range(len(self.var_key_offsets)):
            var vo = self.var_key_offsets[i]
            self.rows.copy_var_string_cell(dst_row, vo, src_rows, src_row, vo)

    @always_inline
    def _merge_agg_cells(
        mut self, self_row: Int, other_rows: RowBlock, other_row: Int
    ) raises:
        """Merge `other_rows[other_row]`'s agg-state cells into
        `self.rows[self_row]` per the registered op semantics.

        SUM/COUNT/AVG-state -> add; MIN -> min; MAX -> max. The state cells
        are all I64-or-F64 width-8; the op ladder mirrors
        `_init_agg_cells` / `_dispatch_agg_kernel`.
        """
        var n_aggs = self.agg_op_tags.__len__()
        for a in range(n_aggs):
            var op = self.agg_op_tags[a]
            var off = self.agg_col_offsets[a]
            # F64 SUM/AVG-state combine = add (float).
            if op == AGG_SUM_F64 or op == AGG_AVG_F64:
                var s = self.rows.read_fixed[DType.float64](self_row, off)
                var o = other_rows.read_fixed[DType.float64](other_row, off)
                self.rows.write_fixed[DType.float64](self_row, off, s + o)
            elif op == AGG_MIN_F64:
                var s = self.rows.read_fixed[DType.float64](self_row, off)
                var o = other_rows.read_fixed[DType.float64](other_row, off)
                if o < s:
                    self.rows.write_fixed[DType.float64](self_row, off, o)
            elif op == AGG_MAX_F64:
                var s = self.rows.read_fixed[DType.float64](self_row, off)
                var o = other_rows.read_fixed[DType.float64](other_row, off)
                if o > s:
                    self.rows.write_fixed[DType.float64](self_row, off, o)
            # MIN (I64) — min of the two partials.
            elif op == AGG_MIN_I64:
                var s = self.rows.read_fixed[DType.int64](self_row, off)
                var o = other_rows.read_fixed[DType.int64](other_row, off)
                if o < s:
                    self.rows.write_fixed[DType.int64](self_row, off, o)
            # MAX (I64) — max of the two partials.
            elif op == AGG_MAX_I64:
                var s = self.rows.read_fixed[DType.int64](self_row, off)
                var o = other_rows.read_fixed[DType.int64](other_row, off)
                if o > s:
                    self.rows.write_fixed[DType.int64](self_row, off, o)
            else:
                # SUM_I64 / COUNT / AVG_I64-state / unknown -> add (I64).
                # COUNT merge = add the two counts; SUM merge = add the two
                # sums; both are associative I64 adds.
                var s = self.rows.read_fixed[DType.int64](self_row, off)
                var o = other_rows.read_fixed[DType.int64](other_row, off)
                var r = s + o
                # ⛔ The SUM_I64 merge is CHECKED too:
                # the spill route re-aggregates its spilled partial runs
                # through this arm, so two in-range partials whose total leaves
                # INT64 wrapped here. Refused by name, like the batch kernel.
                if op == AGG_SUM_I64 and ((s ^ r) & (o ^ r)) < 0:
                    raise Error(row_sum_i64_overflow_message())
                self.rows.write_fixed[DType.int64](self_row, off, r)

    # ─── Partial-agg spill seam ────────────────────────────────
    #
    # Option B (partial-agg-spill + combine): when the runtime-stage HAG
    # exceeds its memory budget, the accumulated PARTIAL table is spilled to
    # disk as a fixed-stride row image (its group rows, byte-identical to
    # `self.rows`'s live extent), then the table is reset and accumulation
    # continues — bounded memory. In finalize, every spilled partial run is
    # restored into a shell table and folded into the surviving table via the
    # EXISTING `combine` (re-hash/re-probe BY KEY) — byte-identical to the
    # un-spilled single-table accumulation.
    #
    # These three methods are the encapsulated spill seam. They live on the
    # table (not the engine spill-state) because they manipulate the table's
    # OWN private byte storage (`rows._fixed_storage`) + the row stride /
    # agg-registration invariants. The engine spill-state (`RowHashAggSpillState`
    # in `komira_engine_operators.runtime.row_hash_agg_spill`) deals only
    # in `SharedAlignedBuffer` bytes (a `komira_core` type) + the THSPILL2
    # codec — no `RowBlock` internals cross the module boundary.
    # ----------------------------------------------------------------------

    def agg_estimated_bytes(self) -> Int:
        """Approximate in-memory footprint of the accumulated table (bytes).

        `n_groups * fixed_row_stride` (the live group-row bytes) plus the
        directory's slot table (`capacity * 8` for the `List[Int]` slots).
        Polled by the spill trigger after each upsert; cheap (two field reads).
        """
        var rows_bytes = self.n_groups() * self.rows.fixed_row_stride
        var dir_bytes = self.directory.capacity() * 8
        # ⭐ THE STRING HEAP IS THE FOOTPRINT FOR A VAR-WIDTH KEY. The
        # fixed row holds an 8-byte descriptor whatever the key's length, so
        # without this term a 200-byte-key table reports ~4% of what it occupies
        # and the spill trigger never fires — the aggregate would be "spillable"
        # and still OOM, which is the failure this route exists to prevent.
        # Zero for every all-fixed-width key, so no shipped budget moves.
        return rows_bytes + dir_bytes + self.rows.var_storage_used

    def spill_group_rows_sab(
        self,
    ) raises -> SharedAlignedBuffer[HeapRegion]:
        """Copy the live group-row bytes into a fresh owned heap buffer.

        Returns a `SharedAlignedBuffer[HeapRegion]` holding exactly
        `n_groups() * fixed_row_stride` bytes — the packed group rows (key
        cells + agg-state cells), byte-identical to `self.rows`'s live extent.
        The caller (`RowHashAggSpillState`) wraps these bytes in a
        `NativeRowBlock` and THSPILL2-encodes them. `self` is NOT mutated
        (the caller resets the table separately via `reset_keep_aggs`).

        The `_fixed_storage` `_length` is padded to capacity (see the
        LENGTH-DESYNC FIX), so we slice the source view to the LIVE byte count
        before the copy — the spilled body holds only real group rows.
        """
        if self.has_var_keys():
            return Self._pack_image(self.rows, self.n_groups())
        var live_bytes = self.n_groups() * self.rows.fixed_row_stride
        var oab = OwnedAlignedBuffer(live_bytes)
        if live_bytes > 0:
            var src_full = self.rows._fixed_storage.view_ro()
            var src_live = src_full.sub(0, live_bytes)
            oab.copy_from_view(src_live)
        else:
            oab.set_length(0)
        return SharedAlignedBuffer[HeapRegion].from_owned(oab^)

    # --- The VAR-WIDTH packed-row image --------------------------
    #
    # A FIXED-ROW-ONLY IMAGE LOSES A STRING KEY ENTIRELY. The shipped image is
    # `n_groups * fixed_row_stride` bytes and nothing else, because for a
    # fixed-width key the row IS the key. A var key's row holds an 8-byte
    # (offset, length) descriptor into a var HEAP that the image does not carry,
    # so restoring one would resolve every key against whatever bytes happened
    # to be at those offsets in the fresh block -- garbage keys, silently.
    #
    # So when (and ONLY when) the layout declares var keys, the image is
    # SELF-CONTAINED and carries its heap:
    #
    #     [0 .. 8)        u64 LE  n_groups
    #     [8 .. 8+F)      F = n_groups * fixed_row_stride   the packed rows
    #     [8+F .. 8+F+V)  V var-heap bytes, descriptors index from its base
    #
    # The 8-byte count header is what lets the engine stop deriving
    # `n_groups = len(bytes) // fixed_row_stride` -- true of the shipped image,
    # false the moment a heap is appended. An all-fixed-width layout produces
    # and consumes the OLD image unchanged (no header, no heap), so every
    # spilled byte of every shape that shipped is untouched.
    # ----------------------------------------------------------------------

    comptime _VAR_IMAGE_HEADER_BYTES: Int = 8

    @staticmethod
    def _pack_image(
        imm src: RowBlock, n_rows_live: Int
    ) raises -> SharedAlignedBuffer[HeapRegion]:
        """Serialize `src`'s first `n_rows_live` rows + its var heap as the
        self-contained var-key image described above."""
        var stride = src.fixed_row_stride
        var fixed_bytes = n_rows_live * stride
        var var_bytes = src.var_storage_used
        var total = Self._VAR_IMAGE_HEADER_BYTES + fixed_bytes + var_bytes
        var oab = OwnedAlignedBuffer(total)
        oab.set_length(Int64(total))
        oab.write_u64_le_at(0, UInt64(n_rows_live))
        if fixed_bytes > 0:
            oab.copy_from_view_at(
                Self._VAR_IMAGE_HEADER_BYTES,
                src._fixed_storage.view_range_ro(0, fixed_bytes),
            )
        if var_bytes > 0:
            oab.copy_from_view_at(
                Self._VAR_IMAGE_HEADER_BYTES + fixed_bytes,
                src._var_storage.view_range_ro(0, var_bytes),
            )
        return SharedAlignedBuffer[HeapRegion].from_owned(oab^)

    @staticmethod
    def image_group_count(
        bytes: ByteView[_], fixed_row_stride: Int, has_var_keys: Bool
    ) raises -> Int:
        """Group count of a packed image -- the ONE place the two image shapes
        are told apart, so no caller re-derives it by division.

        `len(bytes) // fixed_row_stride` is correct for the fixed-width image
        and WRONG for the var image (it would count the heap as rows). The
        engine-side shell builders route through here instead."""
        if not has_var_keys:
            if fixed_row_stride <= 0:
                return 0
            return bytes.len() // fixed_row_stride
        if bytes.len() < Self._VAR_IMAGE_HEADER_BYTES:
            raise Error(
                "RowHashAggTable.image_group_count: var-key image is "
                + String(bytes.len())
                + " bytes -- shorter than its 8-byte group-count header."
            )
        return Int(bytes.read_u64_le_at(0))

    @staticmethod
    def from_spilled_group_rows(
        bytes: ByteView[_],
        n_groups: Int,
        key_stride: Int,
        fixed_row_stride: Int,
        agg_op_tags: List[UInt8],
        agg_col_offsets: List[Int],
        var var_key_offsets: List[Int],
    ) raises -> Self:
        """Rebuild a shell table from spilled group-row bytes.

        The returned table holds `n_groups` group rows loaded verbatim from
        `bytes` (key cells + already-aggregated agg-state cells), with the
        agg-op registration copied so the agg-state offsets are interpretable.
        The directory is left EMPTY: this shell is used ONLY as the `other`
        argument to `combine`, which re-hashes/re-probes each row from
        `other.rows` and never reads `other.directory`. Restore is therefore a
        bytes-in + n_rows-set, no directory rebuild.

        `bytes.len()` MUST equal `n_groups * fixed_row_stride` (the spill
        body length); a mismatch raises (corruption guard).
        """
        var fixed_bytes = n_groups * fixed_row_stride
        var has_var = len(var_key_offsets) > 0
        var table = Self(key_stride, fixed_row_stride)
        for a in range(len(agg_op_tags)):
            table.add_agg(agg_op_tags[a], agg_col_offsets[a])
        # STAMP BEFORE THE ROWS LAND. `set_var_key_offsets` reaches into
        # `table.rows`, so it has to run while the block is still the fresh one
        # -- a shell whose rows arrived before the declaration would be handed
        # to `combine` hashing descriptors.
        table.set_var_key_offsets(var_key_offsets)
        if not has_var:
            if bytes.len() != fixed_bytes:
                raise Error(
                    "RowHashAggTable.from_spilled_group_rows: body length "
                    + String(bytes.len())
                    + " != n_groups * fixed_row_stride "
                    + String(fixed_bytes)
                )
            if n_groups > 0:
                table.rows.reserve_rows(n_groups)
                # Copy the packed rows into the fresh block's fixed storage.
                table.rows._fixed_storage.copy_from_view_at(0, bytes)
                table.rows.set_n_rows(n_groups)
            return table^
        # Var-key image: [u64 n_groups][fixed rows][var heap].
        var hdr = Self._VAR_IMAGE_HEADER_BYTES
        var min_len = hdr + fixed_bytes
        if bytes.len() < min_len:
            raise Error(
                "RowHashAggTable.from_spilled_group_rows: var-key image is "
                + String(bytes.len())
                + " bytes, shorter than the 8-byte header + n_groups *"
                " fixed_row_stride " + String(min_len)
            )
        var stamped = Int(bytes.read_u64_le_at(0))
        if stamped != n_groups:
            raise Error(
                "RowHashAggTable.from_spilled_group_rows: var-key image header"
                " says " + String(stamped) + " groups, caller says "
                + String(n_groups) + " (corruption / wrong-image guard)"
            )
        var var_bytes = bytes.len() - min_len
        if n_groups > 0:
            table.rows.reserve_rows(n_groups)
            table.rows._fixed_storage.copy_from_view_at(
                0, bytes.sub(hdr, fixed_bytes)
            )
            table.rows.set_n_rows(n_groups)
        if var_bytes > 0:
            table.rows.reserve_var_bytes(var_bytes)
            table.rows._var_storage.copy_from_view_at(
                0, bytes.sub(min_len, var_bytes)
            )
            table.rows.var_storage_used = var_bytes
        return table^

    # ─── Spill recursion — grace-hash repartition ───────────────
    #
    # When the single-level fold's MERGED table would overflow the memory
    # budget (distinct-key cardinality so high that even one budget-bounded
    # run's groups, re-merged across all runs, blow the budget), the finalize
    # path repartitions the spilled runs by key-hash into K sub-partitions and
    # re-aggregates each sub-partition independently (each fits ~budget). This
    # method is the bucketing seam: it routes THIS shell table's group rows to
    # one sub-partition `part` of `n_parts` by the SAME `_hash_row_bytes` the
    # directory + `combine` use — so the same key ALWAYS lands in the same
    # sub-partition across every run (byte-identical bucketing → correctness).
    #
    # `_hash_row_bytes` is a module-private free fn the engine spill-state
    # cannot reach; exposing the bucketing as a method here keeps the hash
    # encapsulated (the engine layer deals only in SAB bytes + K + part).
    # ----------------------------------------------------------------------

    @always_inline
    def group_row_subpartition(
        self, row: Int, n_parts: Int, hash_shift: Int
    ) -> Int:
        """Sub-partition index in `[0, n_parts)` for group row `row`.

        Uses the SAME `_hash_row_bytes` (over `key_stride` key bytes) that the
        directory + `combine` use, so a given key maps to the SAME bucket
        across every spilled run and the surviving table — the invariant that
        makes the grace-hash repartition correct (same-key-same-subpartition).

        `hash_shift` selects which hash bits drive the split: depth-0 uses the
        low bits (`hash >> 0`), deeper recursion levels shift by
        `depth * log2(n_parts)` so an over-budget sub-partition re-splits on
        FRESH bits (re-applying the same low bits would map every already-in-
        bucket row to the same child and never converge). Callers pass
        `hash_shift = depth * bits_per_level`.
        """
        var h = _hash_row_bytes(self.rows, row, self.key_stride)
        return Int((h >> UInt64(hash_shift)) % UInt64(n_parts))

    def partition_group_rows_to_sab(
        self,
        n_parts: Int,
        part: Int,
        hash_shift: Int,
    ) raises -> SharedAlignedBuffer[HeapRegion]:
        """Copy this table's group rows hashing to sub-partition `part` into a
        fresh owned heap buffer (the packed-row image for that sub-partition).

        One pass over `self.rows`: each group row whose
        `(hash >> hash_shift) % n_parts == part` is copied verbatim (key cells +
        already-aggregated agg-state cells) into the output buffer, preserving
        the fixed row stride. The result is a `NativeRowBlock`-shaped row image
        for that sub-partition, suitable to THSPILL2-encode + later
        `from_spilled_group_rows` + `combine`.

        `self` is NOT mutated. The returned buffer holds
        `count(part) * fixed_row_stride` bytes (possibly zero).
        """
        var stride = self.rows.fixed_row_stride
        var n_groups_v = self.n_groups()
        # Pass 1: count rows landing in `part` (to size the output exactly).
        var n_part = 0
        for row in range(n_groups_v):
            if self.group_row_subpartition(row, n_parts, hash_shift) == part:
                n_part += 1
        if self.has_var_keys():
            # A SUBSET of rows needs a COMPACTED heap -- the fragment
            # must not drag the whole table's payload bytes, and the surviving
            # descriptors must be rebased onto what it does carry. Route the
            # rows through a scratch block so the existing
            # `copy_var_string_cell` does the rebasing, then pack that block.
            var frag = RowBlock(stride)
            frag.var_key_offsets = self._var_key_offsets_copy()
            if n_part > 0:
                frag.ensure_capacity_rows(n_part)
                var w = 0
                for row in range(n_groups_v):
                    if (
                        self.group_row_subpartition(row, n_parts, hash_shift)
                        == part
                    ):
                        frag.copy_row_fixed_from(w, self.rows, row)
                        for i in range(len(self.var_key_offsets)):
                            var vo = self.var_key_offsets[i]
                            frag.copy_var_string_cell(w, vo, self.rows, row, vo)
                        w += 1
                frag.set_n_rows(n_part)
            return Self._pack_image(frag, n_part)
        var out_bytes = n_part * stride
        var oab = OwnedAlignedBuffer(out_bytes)
        if out_bytes == 0:
            oab.set_length(0)
            return SharedAlignedBuffer[HeapRegion].from_owned(oab^)
        oab.set_length(Int64(out_bytes))
        # Pass 2: copy each matching row's `stride` bytes at the next slot.
        var src_full = self.rows._fixed_storage.view_ro()
        var dst_off = 0
        for row in range(n_groups_v):
            if self.group_row_subpartition(row, n_parts, hash_shift) == part:
                var src_row = src_full.sub(row * stride, stride)
                oab.copy_from_view_at(dst_off, src_row)
                dst_off += stride
        return SharedAlignedBuffer[HeapRegion].from_owned(oab^)

    def reset_keep_aggs(mut self) raises:
        """Drain the table to empty while keeping the agg registration.

        Recycles the table for the next accumulation run after a spill: the
        group rows + directory are reset to empty, but `key_stride`,
        `agg_op_tags`, and `agg_col_offsets` are preserved (the next run's
        layout is identical). Mirror of `RowSortBuffer.reset_keep_directions`.
        """
        self.rows = RowBlock(self.rows.fixed_row_stride)
        self.directory = RowDirectory()
        self.probe_keys = RowBlock(self.key_stride)
        self.slots_buf = List[Int]()
        # The recycled blocks are FRESH, so the var-key declaration has
        # to be re-stamped — a spilled-and-recycled table that lost it would
        # hash descriptors for every run after the first.
        self.rows.var_key_offsets = self._var_key_offsets_copy()
        self.probe_keys.var_key_offsets = self._var_key_offsets_copy()


# =============================================================================
# _HashAggVariant alias — slow-arm carrier
# =============================================================================
#
# The `_HashAggVariant` carrier on RBS holds either a fast-path arm or
# the slow-arm `RowHashAggTable`. Mutual exclusion is type-enforced
# (Variant holds exactly one arm).
#
# The fast arm is currently a placeholder; realistic
# `_HashAggSegmentPayload[KB, *Aggs]` arms would replace it once a variadic
# `HashAggTable[KB, *Aggs]` substrate exists.
# =============================================================================


struct _HashAggVariantPlaceholderArm(Movable, Deinitable):
    """Placeholder arm — keeps `_HashAggVariant` 2-arm + valid.

    Mojo 1.0.0b1 `Variant[A, B, ...]` requires ≥2 arms for tag
    discrimination. Realistic fast-path arms would replace this
    placeholder.

    The runtime never instantiates this arm — the routing predicate only
    sets the Variant to the `RowHashAggTable` arm (slow path).
    """

    var _unused: Int

    def __init__(out self):
        self._unused = 0


comptime _HashAggVariant = Variant[
    # Placeholder fast-arm.
    _HashAggVariantPlaceholderArm,
    # The slow arm — RowHashAggTable (ONE arm of the Variant carrier;
    # zero new RBS fields).
    RowHashAggTable,
]
"""Slow-path-extended HashAgg Variant carrier.

Holds either a fast-path arm (currently a placeholder) OR the slow-arm
`RowHashAggTable`.

Lifetime on RBS:
    var hash_agg_payload: Optional[OwnedPointer[_HashAggVariant]]

Mutual exclusion is type-enforced (a Variant holds exactly one arm at
a time); the morsel executor's per-segment feed/drain dispatch matches
on the Variant arm via `Variant.isa[T]()`.
"""

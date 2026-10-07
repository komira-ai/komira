# =============================================================================
# comptime_decoder.mojo — @parameter SHAPE_KIND cascade.
# =============================================================================
#
# The runtime ActionTableInterpreter (`action_table.mojo`) pays a per-FIELD,
# per-ROW dispatch tax: for every record it re-walks the action list, runs an
# `if/elif` cascade on the FieldAction Int8 kind, copies the ReadFieldData out
# of an Optional, re-checks the nullable-union ordering, then runs a SECOND
# `if/elif` cascade on the avro_kind to pick the typed read + a THIRD Optional
# unwrap to reach the accumulator arm. arrow-rs #9211 quantifies this per-field
# dispatch as ~3× headroom.
#
# This module erases that tax for a finite set of HOT pre-known schema shapes via
# `@parameter` monomorphization. A runtime classifier maps the writer-schema
# shape → a scalar `SHAPE_KIND: Int ∈ {0..7}` at OCF-open; the call site
# dispatches into a `@parameter`-specialized decode loop where the per-field
# dispatch is resolved at COMPILE time, not per row.
#
# Mechanism (NOT SIMD — a SIMD varint decoder measured slower):
#   - The per-column (avro_kind → accumulator) binding is computed ONCE, out of
#     the per-row loop, into a typed `_ColPlan` vector. The per-row inner loop
#     issues the typed read directly off that plan with NO per-field Int8
#     cascade and NO per-row ReadFieldData copy.
#   - The comptime SHAPE_KIND selects the loop STRUCTURE: STRUCT_OF_N_PRIMS
#     skips the nullable-union tag read entirely (no union on the wire);
#     STRUCT_OF_NULLABLE_PRIMS reads the 2-branch union tag per field. The
#     branch is chosen at compile time per SHAPE_KIND — no per-row branch on
#     "is this column nullable".
#   - SHAPE_KIND_UNKNOWN (= -1, the long tail) routes UNCHANGED through the
#     runtime ActionTableInterpreter. Never wrong, just not specialized.
#
# Idiom precedent: the CSV reader's `_dispatch_scan[Q, SCANNER_VARIANT]`.
# NO byte-erased fn-ptr dispatch (no trampolines); NO @parameter
# recursion (the compiler rejects it).
#
# Encapsulation: no UnsafePointer crosses any module boundary. The decoder
# consumes a borrowed block-payload Span via the AvroByteReader cursor and
# accumulates into the same owned ColumnAccVariant slab the runtime path uses,
# so the output RecordBatch is byte-identical.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_collections.slab import Slab

from .action_table import (
    ActionTableInterpreter,
    ColumnAccVariant,
    ReadFieldData,
    ResolutionTable,
    ACC_I32,
    ACC_I64,
    ACC_F32,
    ACC_F64,
    ACC_BOOL,
    ACC_STRING,
    ACC_BINARY,
    ACC_DECIMAL,
    NULL_NONE,
    NULL_FIRST,
    NULL_SECOND,
)
from .avro_schema import (
    AvroSchema,
    AVRO_KIND_NULL,
    AVRO_KIND_BOOLEAN,
    AVRO_KIND_INT,
    AVRO_KIND_LONG,
    AVRO_KIND_FLOAT,
    AVRO_KIND_DOUBLE,
    AVRO_KIND_BYTES,
    AVRO_KIND_STRING,
    AVRO_KIND_RECORD,
    AVRO_KIND_ENUM,
    AVRO_KIND_ARRAY,
    AVRO_KIND_MAP,
    AVRO_KIND_UNION,
    AVRO_KIND_FIXED,
)
from .varint_decode_scalar import AvroByteReader
from std.time import perf_counter_ns


# =============================================================================
# SHAPE_KIND enumeration.
# =============================================================================

comptime SHAPE_KIND_UNKNOWN: Int = -1
comptime SHAPE_KIND_KAFKA_EVENT_ROW: Int = 0  # struct of (long ts, string id, T payload)
comptime SHAPE_KIND_STRUCT_OF_1_INT: Int = 1
comptime SHAPE_KIND_STRUCT_OF_N_PRIMS: Int = 2  # all-primitive flat NON-null struct
comptime SHAPE_KIND_STRUCT_OF_NULLABLE_PRIMS: Int = 3  # all-nullable-primitive struct
comptime SHAPE_KIND_TPCH_LINEITEM_SHAPE: Int = 4  # mixed primitive/decimal/date
comptime SHAPE_KIND_OPTIONAL_STRING_ARRAY: Int = 5
comptime SHAPE_KIND_TWO_LEVEL_NESTED_RECORD: Int = 6
comptime SHAPE_KIND_SINGLE_UNION_NULL_T: Int = 7

# Highest specialized SHAPE_KIND the call-site bridge enumerates.
comptime SHAPE_KIND_MAX: Int = 7


# =============================================================================
# `classify_avro_shape` — runtime classifier (OCF-open time).
# =============================================================================
#
# Inspects the writer-schema shape (IDENTITY resolution, so reader ==
# writer) and returns a SHAPE_KIND_* Int. Returns SHAPE_KIND_UNKNOWN for any
# shape not in the hot set — that path falls back to the runtime interpreter.
#
# Scope (IDENTITY only): the two hot shapes with a real specialized
# decoder are STRUCT_OF_N_PRIMS (all non-null scalar columns) and
# STRUCT_OF_NULLABLE_PRIMS (all columns nullable scalar). STRUCT_OF_1_INT is a
# 1-column instance of STRUCT_OF_N_PRIMS. The remaining shape kinds
# (KAFKA_EVENT_ROW / TPCH_LINEITEM / OPTIONAL_STRING_ARRAY /
# TWO_LEVEL_NESTED_RECORD / SINGLE_UNION_NULL_T) classify here but
# route through the runtime interpreter via SHAPE_KIND_UNKNOWN fallback if they
# carry shapes the specialized arms don't cover (decimal / bytes / nested). The
# classifier is intentionally conservative: it ONLY returns a specialized
# SHAPE_KIND when every column is a comptime-decodable scalar, so the
# specialized arm can never be handed a column it can't decode.


def _is_decodable_scalar_kind(k: Int) -> Bool:
    """True iff the (un-unioned) wire kind is a flat scalar the specialized
    arms decode directly (no decimal / fixed / nested)."""
    return (
        k == AVRO_KIND_BOOLEAN
        or k == AVRO_KIND_INT
        or k == AVRO_KIND_LONG
        or k == AVRO_KIND_FLOAT
        or k == AVRO_KIND_DOUBLE
        or k == AVRO_KIND_STRING
        or k == AVRO_KIND_BYTES
    )


@fieldwise_init
struct _ColShape(Copyable, Movable):
    """The decoded shape of one top-level record field (after collapsing a
    nullable 2-branch union). `inner_kind` is the wire kind of the value;
    `nullability` is NULL_NONE / NULL_FIRST / NULL_SECOND; `has_logical` is
    True iff the value node carries a non-empty logicalType (decimal / uuid /
    date / timestamp / ...)."""

    var inner_kind: Int
    var nullability: Int8
    var has_logical: Bool


def _field_shape(schema: AvroSchema, type_idx: Int) raises -> _ColShape:
    """Collapse a field's type node into (inner_kind, nullability, has_logical).
    Mirrors `_build_read_field` / `_field_type_info` in action_table.mojo but
    returns only the scalar shape the classifier needs."""
    var n = schema.node(type_idx)
    if n.kind == AVRO_KIND_UNION:
        if len(n.children) == 2:
            var c0 = schema.node(n.children[0])
            var c1 = schema.node(n.children[1])
            if c0.kind == AVRO_KIND_NULL:
                var inner = schema.node(n.children[1])
                return _ColShape(inner.kind, NULL_FIRST, inner.logical_type.byte_length() > 0)
            elif c1.kind == AVRO_KIND_NULL:
                var inner = schema.node(n.children[0])
                return _ColShape(inner.kind, NULL_SECOND, inner.logical_type.byte_length() > 0)
        # n>=3 / no-null union — not a hot shape.
        return _ColShape(AVRO_KIND_UNION, NULL_NONE, False)
    return _ColShape(n.kind, NULL_NONE, n.logical_type.byte_length() > 0)


def classify_avro_shape(schema: AvroSchema) raises -> Int:
    """Classify the writer schema into a SHAPE_KIND_* Int (identity resolution).

    Returns SHAPE_KIND_STRUCT_OF_N_PRIMS when the root is a record whose every
    field is a NON-null decodable scalar; SHAPE_KIND_STRUCT_OF_NULLABLE_PRIMS
    when every field is a NULLABLE decodable scalar; SHAPE_KIND_STRUCT_OF_1_INT
    for the 1-int special case (a sub-case of N_PRIMS, surfaced
    separately). Returns SHAPE_KIND_UNKNOWN for anything else — the runtime
    interpreter fallback (never wrong, just not specialized)."""
    var root = schema.node(schema.root())
    if root.kind != AVRO_KIND_RECORD:
        return SHAPE_KIND_UNKNOWN
    var nf = len(root.children)
    if nf == 0:
        return SHAPE_KIND_UNKNOWN

    var all_non_null = True
    var all_nullable = True
    for i in range(nf):
        var cs = _field_shape(schema, root.children[i])
        if not _is_decodable_scalar_kind(cs.inner_kind):
            return SHAPE_KIND_UNKNOWN  # decimal / fixed / nested / n>=3 union
        if cs.has_logical:
            # A logicalType (decimal-over-bytes, uuid, date, timestamp, ...) can
            # rebind the accumulator (e.g. bytes+decimal -> _DecimalAcc), which
            # the specialized scalar arm does NOT handle. Conservatively fall
            # back to the runtime interpreter (never wrong, just not specialized).
            return SHAPE_KIND_UNKNOWN
        if cs.nullability == NULL_NONE:
            all_nullable = False
        else:
            all_non_null = False

    if all_non_null:
        if nf == 1:
            var cs0 = _field_shape(schema, root.children[0])
            if cs0.inner_kind == AVRO_KIND_INT:
                return SHAPE_KIND_STRUCT_OF_1_INT
        return SHAPE_KIND_STRUCT_OF_N_PRIMS
    if all_nullable:
        return SHAPE_KIND_STRUCT_OF_NULLABLE_PRIMS
    # Mixed null/non-null scalar struct: still decodable by the nullable arm's
    # per-column nullability flag, but the two specialized arms are
    # "all-non-null" and "all-nullable". A mixed struct falls back to runtime.
    return SHAPE_KIND_UNKNOWN


@always_inline
def is_hot_shape(shape_kind: Int) -> Bool:
    """True iff `shape_kind` has a specialized decoder arm (vs the
    runtime fallback). STRUCT_OF_1_INT / N_PRIMS / NULLABLE_PRIMS are hot."""
    return (
        shape_kind == SHAPE_KIND_STRUCT_OF_1_INT
        or shape_kind == SHAPE_KIND_STRUCT_OF_N_PRIMS
        or shape_kind == SHAPE_KIND_STRUCT_OF_NULLABLE_PRIMS
    )


# =============================================================================
# Per-column decode plan — built ONCE per decode, out of the per-row loop.
# =============================================================================
#
# This is the heart of the specialization: the (avro_kind → accumulator arm)
# binding for each output column is resolved once here, not per row. The per-
# row inner loop reads straight off this plan with no per-field Int8 cascade
# and no per-row ReadFieldData copy.

@fieldwise_init
struct _ColPlan(Copyable, Movable):
    var wire_kind: Int  # AVRO_KIND_* of the value (un-unioned)
    var nullability: Int8  # NULL_NONE / NULL_FIRST / NULL_SECOND


def _build_col_plans(table: ResolutionTable) raises -> List[_ColPlan]:
    """Derive the per-output-column decode plan from the resolution table's
    out_specs. Identity resolution: one out_spec per output column, in order."""
    var plans = List[_ColPlan]()
    for i in range(len(table.out_specs)):
        var rfd = table.out_specs[i].copy()
        plans.append(_ColPlan(rfd.avro_kind, rfd.nullability))
    return plans^


# =============================================================================
# Specialized typed-read helper — issues ONE scalar read into ONE accumulator.
# =============================================================================
#
# Used by both specialized arms. The `wire_kind` here is the per-column kind
# from the plan (computed once). Inside the per-row loop this is a small fixed
# if/elif over a stable per-column value — NOT the per-row, per-field
# ReadFieldData copy + Int8 FieldAction cascade the runtime path pays. The hot
# inner work (the typed read + accumulator push) is identical to the runtime
# path's `_read_value`; what the specialization removes is everything AROUND it.

@always_inline
def _read_scalar_into(
    mut acc: ColumnAccVariant,
    mut reader: AvroByteReader[_],
    wire_kind: Int,
) raises:
    # SAFETY: the accumulator arm matches `wire_kind` by construction — the
    # classifier only returns a specialized SHAPE_KIND when every column is a
    # decodable scalar, and the accumulators were created from the same
    # out_specs the plan is derived from.
    if wire_kind == AVRO_KIND_INT:
        acc.i32.value().push(reader.read_int())
    elif wire_kind == AVRO_KIND_LONG:
        acc.i64.value().push(reader.read_long())
    elif wire_kind == AVRO_KIND_BOOLEAN:
        acc.boolean.value().push(reader.read_boolean())
    elif wire_kind == AVRO_KIND_FLOAT:
        acc.f32.value().push(reader.read_float())
    elif wire_kind == AVRO_KIND_DOUBLE:
        acc.f64.value().push(reader.read_double())
    elif wire_kind == AVRO_KIND_STRING:
        acc.string.value().push_bytes(reader.read_string_span())
    else:  # AVRO_KIND_BYTES
        acc.binary.value().push(reader.read_bytes())


# =============================================================================
# `decode_block_comptime[SHAPE_KIND]` — the @parameter cascade.
# =============================================================================


@always_inline
def decode_block_comptime[
    SHAPE_KIND: Int
](
    mut accs: Slab[ColumnAccVariant],
    plans: List[_ColPlan],
    payload: Span[UInt8, _],
    object_count: Int,
) raises:
    """Decode one block payload via the comptime-specialized loop for
    `SHAPE_KIND`. The accumulators + plans are shared with the runtime path so
    the output is byte-identical.

    @parameter if/elif/else over a scalar comptime Int — same shape as CSV's
    `_dispatch_scan[Q, SCANNER_VARIANT]`."""
    var reader = AvroByteReader(payload)
    var ncols = len(plans)

    comptime if (
        SHAPE_KIND == SHAPE_KIND_STRUCT_OF_N_PRIMS
        or SHAPE_KIND == SHAPE_KIND_STRUCT_OF_1_INT
    ):
        # ALL-NON-NULL flat scalar struct. NO union tag on the wire for any
        # column: the per-row loop skips the nullability read entirely (chosen
        # at COMPILE time — no per-row "is this column nullable" branch). Per-
        # field type dispatch is the stable per-column plan kind, hoisted out
        # of the per-row clone the runtime path pays.
        for _r in range(object_count):
            for c in range(ncols):
                _read_scalar_into(accs[c], reader, plans[c].wire_kind)

    elif SHAPE_KIND == SHAPE_KIND_STRUCT_OF_NULLABLE_PRIMS:
        # ALL-NULLABLE flat scalar struct. Every column is a 2-branch
        # union[null,T] / union[T,null]: read the union tag, route null vs
        # value. The per-column nullability ordering is the stable plan value.
        for _r in range(object_count):
            for c in range(ncols):
                var nb = plans[c].nullability
                var tag = reader.read_long()
                var is_null: Bool
                if nb == NULL_FIRST:
                    is_null = tag == 0  # branch 0 == null
                else:  # NULL_SECOND
                    is_null = tag == 1  # branch 1 == null
                if is_null:
                    accs[c].push_null()
                else:
                    _read_scalar_into(accs[c], reader, plans[c].wire_kind)

    else:
        # SHAPE_KIND_UNKNOWN (and any non-hot kind): this arm is unreachable in
        # production because the call-site bridge only enters this function for
        # hot shapes (is_hot_shape guard). Kept as a defensive no-op so the
        # cascade is total. The real long-tail fallback runs the runtime
        # ActionTableInterpreter at the call site (decode_avro_bytes_comptime).
        pass


# =============================================================================
# `decode_avro_bytes_comptime` — runtime → comptime dispatch BRIDGE.
# =============================================================================
#
# This is the production entry the AvroOcfReader read path calls. The
# runtime classifier returns a
# SHAPE_KIND; the bridge enumerates the comptime arms and dispatches into the
# matching specialized loop. The long tail (SHAPE_KIND_UNKNOWN / non-hot)
# routes through the runtime ActionTableInterpreter UNCHANGED — never wrong.


@always_inline
def _decode_one_block(
    mut accs: Slab[ColumnAccVariant],
    plans: List[_ColPlan],
    payload: Span[UInt8, _],
    object_count: Int,
    shape_kind: Int,
) raises:
    """Dispatch one block payload into the matching comptime-specialized arm.
    Origin-poly over `payload` so both the borrowed-file (null codec) and the
    owned-decompressed-buffer cases share one call site."""
    if shape_kind == SHAPE_KIND_STRUCT_OF_1_INT:
        decode_block_comptime[SHAPE_KIND_STRUCT_OF_1_INT](
            accs, plans, payload, object_count
        )
    elif shape_kind == SHAPE_KIND_STRUCT_OF_N_PRIMS:
        decode_block_comptime[SHAPE_KIND_STRUCT_OF_N_PRIMS](
            accs, plans, payload, object_count
        )
    else:  # SHAPE_KIND_STRUCT_OF_NULLABLE_PRIMS
        decode_block_comptime[SHAPE_KIND_STRUCT_OF_NULLABLE_PRIMS](
            accs, plans, payload, object_count
        )


def decode_avro_bytes_comptime(
    bytes: Span[UInt8, _],
    *,
    print_timing: Bool = False,
) raises -> RecordBatch:
    """Read an entire Avro OCF byte stream into one RecordBatch, taking the
    comptime SHAPE_KIND fast path for hot shapes and falling back to the
    runtime ActionTableInterpreter for the long tail.

    Identity resolution. Byte-identical output to
    `read_avro_bytes` for every shape (the fast path shares accumulators with
    the runtime path; the fallback IS the runtime path).

    `print_timing` (default False) prints a per-phase breakdown (setup /
    decompress / reserve / decode-loop / build) for a hot-shape file; it is
    read once per file, never per row."""
    from .avro_codec import decompress_block, AVRO_CODEC_NULL
    from .ocf_block_scan import scan_ocf_blocks_after_header
    from .ocf_header import decode_ocf_header

    var header = decode_ocf_header(bytes)
    var schema = header.parse_schema()
    var shape_kind = classify_avro_shape(schema)
    # null codec: the on-disk block bytes ARE the decode payload — decode
    # straight from the borrowed file Span, skipping the whole-file
    # byte-by-byte copy decompress_block(NULL) would do.
    var is_null_codec = header.codec_tag == AVRO_CODEC_NULL

    if not is_hot_shape(shape_kind):
        # Long-tail fallback — the runtime primary path, UNCHANGED. This is the
        # exact code `read_avro_bytes` runs.
        var table = ResolutionTable.identity(schema)
        var interp = ActionTableInterpreter(table^)
        var fblocks = scan_ocf_blocks_after_header(bytes, header)
        for bi in range(len(fblocks)):
            var blk = fblocks[bi].copy()
            var raw = bytes[blk.payload_offset : blk.payload_offset + blk.payload_len]
            if is_null_codec:
                interp.decode_block(raw, Int(blk.object_count))
            else:
                var decompressed = decompress_block(header.codec_tag, raw)
                interp.decode_block(Span(decompressed), Int(blk.object_count))
        return interp.build_batch()

    # Hot path: build the accumulator slab + per-column plan ONCE, then run the
    # comptime-specialized per-block loop.
    var _dbg = print_timing
    var _t0 = perf_counter_ns()
    var table = ResolutionTable.identity(schema)
    var plans = _build_col_plans(table)
    var accs = Slab[ColumnAccVariant]()
    for i in range(len(table.out_specs)):
        var rfd = table.out_specs[i].copy()
        accs.append(ColumnAccVariant.create(rfd))

    var blocks = scan_ocf_blocks_after_header(bytes, header)
    var _ns_setup = Int(perf_counter_ns() - _t0)

    # Reserve each accumulator ONCE to the file's TOTAL row count, computed
    # from the block index up front. A per-block reserve(cur+object_count)
    # triggers ~log2(N) doubling reallocs per column and re-runs the
    # current_len()/reserve loop once per block per column. Summing the
    # object_counts (already in the block index, no extra I/O) lets every
    # column allocate exactly once: zero reallocs in the hot loop.
    #
    # UNTRUSTED INPUT. Both terms of this sum are wire
    # varints and neither is bounded by the file. The sum is the SAME
    # allocation-size hazard the per-block path has (see
    # `ActionTableInterpreter.decode_block`), amplified: a handful of 16-byte
    # empty blocks can name any Int64 total, which then flows into
    # `reserve(total_rows)` -> `PrimitiveArray.allocate` -> an unchecked
    # `length * elem_size` multiply that wraps. Bound each block's contribution
    # by its payload length (>= 1 payload byte per record in every schema this
    # decoder supports) so the reserve is a hint about real data, and let the
    # decode raise `TRUNCATED` if the count was a lie.
    var total_rows = 0
    for bi in range(len(blocks)):
        var claimed = Int(blocks[bi].object_count)
        var credible = blocks[bi].payload_len
        total_rows += claimed if claimed < credible else credible
    var _ns_reserve = 0
    var _tr0 = perf_counter_ns()
    for c in range(len(accs)):
        accs[c].reserve(total_rows)
    _ns_reserve += Int(perf_counter_ns() - _tr0)

    var _ns_decompress = 0
    var _ns_decode = 0
    for bi in range(len(blocks)):
        var blk = blocks[bi].copy()
        var raw = bytes[blk.payload_offset : blk.payload_offset + blk.payload_len]
        var _td0 = perf_counter_ns()
        # null codec: decode directly from `raw` (no copy). Other codecs
        # materialize an owned decompressed buffer first.
        var decompressed = List[UInt8]()
        if not is_null_codec:
            decompressed = decompress_block(header.codec_tag, raw)
        var _td1 = perf_counter_ns()
        _ns_decompress += Int(_td1 - _td0)
        var _td2 = perf_counter_ns()
        # Comptime cascade: enumerate hot SHAPE_KINDs; the runtime shape_kind
        # selects which specialized (compile-time) arm runs. Pass the borrowed
        # `raw` span for the null codec; the owned decompressed buffer otherwise.
        # Branch on codec FIRST so the two payload spans keep distinct origins
        # (raw borrows the file; decompressed borrows the local buffer).
        if is_null_codec:
            _decode_one_block(
                accs, plans, raw, Int(blk.object_count), shape_kind
            )
        else:
            _decode_one_block(
                accs, plans, Span(decompressed), Int(blk.object_count),
                shape_kind,
            )
        _ns_decode += Int(perf_counter_ns() - _td2)

    # Emit the RecordBatch from the shared accumulators + table schema.
    var _tb0 = perf_counter_ns()
    var ncols = len(accs)
    var builder = RecordBatchBuilder.with_capacity(ncols)
    for i in range(ncols):
        builder.add_column(accs[i].build())
    var result = builder.build(table.out_schema.copy())
    var _ns_build = Int(perf_counter_ns() - _tb0)
    if _dbg:
        print(
            "[AVRO_TIMING] setup=", _ns_setup // 1000, "us",
            " decompress=", _ns_decompress // 1000, "us",
            " reserve=", _ns_reserve // 1000, "us",
            " decode_loop=", _ns_decode // 1000, "us",
            " build=", _ns_build // 1000, "us",
        )
    return result^

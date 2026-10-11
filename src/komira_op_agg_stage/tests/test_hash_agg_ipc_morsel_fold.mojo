# =============================================================================
# test_hash_agg_ipc_morsel_fold.mojo
#   -- ARROW-IPC container FILL vs the copy-on-read reader: BYTE-ORACLE.
#
# THE SEAM UNDER TEST: `IpcMorselFill` / `IpcMorselView`
#   (`komira_arrow_ipc.ipc_morsel_fill`) -- the ZERO-COPY
#   Arrow-IPC arm of the format-blind `MorselView` operator feed. The fill
#   records, per column, where the values bytes live INSIDE the IPC message
#   body; reads go straight out of those bytes. There is no `Column`
#   allocation, no `RecordBatch` construction, and no arena staging on that
#   path -- which is exactly why it needs a byte-oracle against the reader that
#   DOES all of those things.
#
# FOUR paths + one INDEPENDENT oracle (independent-oracle discipline: a
# self-equivalence over ONE shared kernel is blind to a bug in that kernel):
#   (A) SOURCE     -- `fold_scalar_view[BatchView]` over the ORIGINAL
#                     RecordBatch, before it ever hits the wire.
#   (B) COPY-READ  -- encode -> `decode_record_batch_message` (the production
#                     copy-on-read decoder) -> RecordBatch -> BatchView -> fold.
#   (C) ZERO-COPY  -- encode -> `IpcMorselFill.fill_from_frame` ->
#                     `fold_scalar_view[IpcMorselView]`. THE NEW PATH.
#   (D) PER-CELL   -- every (col, row) read through `IpcMorselView` compared
#                     BIT-for-BIT (float64 bitcast to int64 -- not
#                     almost-equal) against the copy-on-read decoder's cell.
#   (O) INDEPENDENT-- the hand-computed closed form SUM(1..N) / COUNT==N.
#
# Plus three property tests the zero-copy path must not get wrong:
#   §2 validity  -- a nullable column's Arrow validity bitmap read straight out
#                   of the frame must agree cell-for-cell with the decoder.
#   §3 refill    -- the container is PERSISTENT: fill -> read -> fill again in
#                   the SAME container must produce the second batch's values
#                   (reset-not-reconstruct), and the pre-refill view must be
#                   caught as STALE by the generation guard.
#   §4 decline   -- a var-len (STRING) column beside numeric columns must be
#                   marked DECLINED and must NOT shift the numeric columns'
#                   buffer cursor (the fill still serves its numeric neighbors).
#
# FALSIFIER shape: any drift between this fill's buffer-cursor arithmetic and
# the decoder's (`_buffer_count_for` / `_fixed_width_bytes_for`, deliberately
# duplicated) misaligns `values_pos` and breaks (C)==(B) and (D).
#
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_almost_equal,
    assert_true,
    assert_false,
)

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow_ipc.ipc_encoder_dispatch import encode_record_batch_message
from komira_arrow_ipc.ipc_decoder_dispatch import decode_record_batch_message
from komira_arrow_ipc.ipc_morsel_fill import (
    IpcMorselFill,
    IpcMorselView,
    ipc_morsel_view_over,
    ipc_fixed_width_bytes,
    ipc_buffer_count,
)
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import SchemaBuilder, Field
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_arrow.string_array import StringArray
from komira_arrow.batch_view import BatchView
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion

from komira_op_agg_stage.agg_column import AggBlock, AggSlot, agg_slot
from komira_op_agg_stage.hash_agg import HashAggTable
from komira_op_agg_stage.key_block import KeyTupleScalar
from komira_op_agg_state.agg_state_slab import SumF64, CountF64
from komira_agg.hash_agg_op_aggregator import HashAggOpF64Agg


comptime _N = 22  # 5 full W=4 chunks + a 2-row scalar tail.

# The 0-key SUM(v@1) + COUNT(v@1) table type (value column at index 1).
comptime _Sum = AggSlot[HashAggOpF64Agg[SumF64, 1]]
comptime _Cnt = AggSlot[HashAggOpF64Agg[CountF64, 1]]
comptime _Table = HashAggTable[KeyTupleScalar, _Sum, _Cnt]


def _fresh_table() raises -> _Table:
    return _Table(
        AggBlock[_Sum, _Cnt](
            agg_slot[HashAggOpF64Agg[SumF64, 1]](HashAggOpF64Agg[SumF64, 1]()),
            agg_slot[HashAggOpF64Agg[CountF64, 1]](
                HashAggOpF64Agg[CountF64, 1]()
            ),
        )
    )


# --- fixtures ---------------------------------------------------------------


def _kv_schema_types() -> List[ArrowType]:
    var t = List[ArrowType]()
    t.append(ArrowType.INT64)
    t.append(ArrowType.FLOAT64)
    return t^


def _kv_columns(n: Int, base: Int) raises -> Slab[Column[HeapRegion]]:
    """2 columns: key Int64 @0 (all zero -- the 0-key agg ignores it) + value
    Float64 @1 with `val[i] = base + i + 1`."""
    var karr = PrimitiveArray[DType.int64].allocate(n)
    var varr = PrimitiveArray[DType.float64].allocate(n)
    for i in range(n):
        karr.store[1](i, SIMD[DType.int64, 1](0))
        varr.store[1](i, SIMD[DType.float64, 1](Float64(base + i + 1)))
    var cols = Slab[Column[HeapRegion]]()
    cols.append(Column.from_primitive[DType.int64](karr^))
    cols.append(Column.from_primitive[DType.float64](varr^))
    return cols^


def _kv_record_batch(n: Int, base: Int) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    sb.add_field(Field(String("v"), ArrowType.FLOAT64, False))
    return RecordBatch.from_typed_columns_slab(sb.build(), _kv_columns(n, base))


def _encode(var cols: Slab[Column[HeapRegion]]) raises -> SharedAlignedBuffer[
    HeapRegion
]:
    return encode_record_batch_message(cols^)


def _decode_to_batch(
    var frame: SharedAlignedBuffer[HeapRegion],
    schema_types: List[ArrowType],
    var schema_fields: List[String],
    var schema_arrow: List[ArrowType],
) raises -> RecordBatch:
    """PRODUCTION copy-on-read decode: frame -> Slab[Column] -> RecordBatch."""
    var cols = decode_record_batch_message(frame^, schema_types)
    var sb = SchemaBuilder()
    for i in range(len(schema_fields)):
        sb.add_field(Field(schema_fields[i], schema_arrow[i], True))
    return RecordBatch.from_typed_columns_slab(sb.build(), cols^)


def _kv_field_names() -> List[String]:
    var f = List[String]()
    f.append(String("k"))
    f.append(String("v"))
    return f^


# --- fold drivers -----------------------------------------------------------


def _sum_of(batch: RecordBatch) raises -> Float64:
    return batch.column_as_primitive_float64(0).load[1](0)[0]


def _cnt_of(batch: RecordBatch) raises -> Float64:
    return batch.column_as_primitive_float64(1).load[1](0)[0]


def _fold_batchview(batch: RecordBatch) raises -> RecordBatch:
    var table = _fresh_table()
    var bv = BatchView(batch)
    table.fold_scalar_view(bv)
    var out = table.drain_to_record_batch()
    return out.take()


def _fold_ipcview(fill: IpcMorselFill) raises -> RecordBatch:
    """THE NEW PATH: `fold_scalar_view[IpcMorselView]` -- the SAME comptime-
    monomorphized kernel, reading the Arrow IPC message body directly."""
    var table = _fresh_table()
    var iv = ipc_morsel_view_over(fill)
    table.fold_scalar_view(iv)
    var out = table.drain_to_record_batch()
    return out.take()


@always_inline
def _bits(x: Float64) -> Int64:
    """Reinterpret a Float64 as its IEEE-754 bit pattern -- the BIT-exact
    comparison primitive (assert_almost_equal would hide a low-bit drift)."""
    return x.to_bits().cast[DType.int64]()


# =============================================================================
# §1 -- THE BYTE-ORACLE: source == copy-on-read == zero-copy == closed form
# =============================================================================


def test_ipc_zero_copy_fill_byte_equiv() raises:
    """CORE BYTE-ORACLE. The 0-key scalar-agg fold over (A) the pre-wire
    RecordBatch, (B) the production copy-on-read IPC decode, and (C) the new
    ZERO-COPY `IpcMorselFill` must all fold to the SAME (SUM, COUNT), equal to
    the INDEPENDENT closed form; and (D) every individual cell read through
    `IpcMorselView` must be BIT-identical to the decoder's cell.

    FALSIFIER: a wrong `values_pos` (buffer-cursor drift vs the decoder's
    `_buffer_count_for`) shifts the zero-copy reads by one buffer and breaks
    both (C)==(B) and (D)."""
    var types = _kv_schema_types()

    # (A) the source batch, before it hits the wire.
    var a = _fold_batchview(_kv_record_batch(_N, 0))

    # One encoded frame, shared by (B) and (C) -- the SAME bytes.
    var frame = _encode(_kv_columns(_N, 0))
    var frame_for_decode = frame.share()

    # (B) production copy-on-read decode.
    var decoded = _decode_to_batch(
        frame_for_decode^, types, _kv_field_names(), _kv_schema_types()
    )
    var b = _fold_batchview(decoded)

    # (C) ZERO-COPY container fill.
    var fill = IpcMorselFill()
    var ok = fill.fill_from_frame(frame^, types)
    assert_true(ok, "IpcMorselFill must accept an uncompressed numeric batch")
    assert_equal(fill.num_rows(), _N, "fill row count == batch row count")
    assert_equal(fill.num_cols(), 2, "fill column count == schema column count")
    assert_false(fill.col_is_declined(0), "int64 key column is FLAT")
    assert_false(fill.col_is_declined(1), "float64 value column is FLAT")
    var c = _fold_ipcview(fill)

    # (O) independent closed form: SUM(i+1 for i in 0..N-1) = N*(N+1)/2.
    var oracle_sum = Float64(_N * (_N + 1) // 2)  # 253
    var oracle_cnt = Float64(_N)

    assert_almost_equal(_sum_of(a), oracle_sum, msg="(A) source SUM == closed form")
    assert_almost_equal(_cnt_of(a), oracle_cnt, msg="(A) source COUNT == closed form")
    assert_almost_equal(_sum_of(b), oracle_sum, msg="(B) copy-on-read SUM == closed form")
    assert_almost_equal(_cnt_of(b), oracle_cnt, msg="(B) copy-on-read COUNT == closed form")
    assert_almost_equal(
        _sum_of(c), oracle_sum,
        msg="(C) ZERO-COPY IpcMorselView SUM == closed form",
    )
    assert_almost_equal(
        _cnt_of(c), oracle_cnt,
        msg="(C) ZERO-COPY IpcMorselView COUNT == closed form",
    )

    # (C) == (B): bit-exact against the production reader on identical bytes.
    assert_equal(
        _bits(_sum_of(c)), _bits(_sum_of(b)),
        msg="zero-copy fold SUM must be BIT-identical to the copy-on-read"
        " decoder's fold over the same frame",
    )
    assert_equal(
        _bits(_cnt_of(c)), _bits(_cnt_of(b)),
        msg="zero-copy fold COUNT must be BIT-identical to the copy-on-read"
        " decoder's fold",
    )

    # (D) PER-CELL bit-equality, both columns, every row.
    var view = ipc_morsel_view_over(fill)
    var dec_k = decoded.column_as_primitive_int64(0)
    var dec_v = decoded.column_as_primitive_float64(1)
    for i in range(_N):
        assert_equal(
            Int(view.col_scalar_nonraising[DType.int64](0, i)),
            Int(dec_k.load[1](i)[0]),
            msg="int64 cell mismatch at row " + String(i),
        )
        assert_equal(
            _bits(view.col_scalar_nonraising[DType.float64](1, i)),
            _bits(dec_v.load[1](i)[0]),
            msg="float64 cell BIT mismatch at row " + String(i),
        )

    # SIMD read agrees with the scalar read (the vector arm the fold uses).
    comptime W = 4
    var lane = view.col_scalar_simd[DType.float64, W](1, 0)
    for j in range(W):
        assert_equal(
            _bits(lane[j]),
            _bits(dec_v.load[1](j)[0]),
            msg="SIMD lane " + String(j) + " != scalar cell",
        )


# =============================================================================
# §2 -- validity: the frame's Arrow bitmap, read in place
# =============================================================================


def test_ipc_fill_validity_matches_decoder() raises:
    """A nullable Float64 column's validity bitmap is read STRAIGHT OUT of the
    IPC body by the fill. Every `col_is_null(col, row)` must agree with the
    copy-on-read decoder's `PrimitiveArray.is_null`, and the non-null values
    must be bit-identical.

    FALSIFIER: an off-by-one in the LSB-first bit indexing, or using the
    validity buffer's offset where the values buffer's belongs, flips the
    null pattern."""
    var n = 19
    var karr = PrimitiveArray[DType.int64].allocate(n)
    var varr = PrimitiveArray[DType.float64].allocate_nullable(n)
    for i in range(n):
        karr.store[1](i, SIMD[DType.int64, 1](Int64(i)))
        varr.set(i, Float64(i * 3 + 1))
    # Scattered nulls -- crosses byte boundaries (rows 0, 5, 10, 15).
    for i in range(n):
        if i % 5 == 0:
            varr._set_null(i)

    var cols = Slab[Column[HeapRegion]]()
    cols.append(Column.from_primitive[DType.int64](karr^))
    cols.append(Column.from_primitive[DType.float64](varr^))

    var types = _kv_schema_types()
    var frame = _encode(cols^)
    var frame_for_decode = frame.share()
    var decoded = _decode_to_batch(
        frame_for_decode^, types, _kv_field_names(), _kv_schema_types()
    )

    var fill = IpcMorselFill()
    var ok = fill.fill_from_frame(frame^, types)
    assert_true(ok, "nullable numeric batch must fill")
    var view = ipc_morsel_view_over(fill)

    var dec_v = decoded.column_as_primitive_float64(1)
    var seen_null = 0
    for i in range(n):
        var want_null = dec_v.is_null(i)
        var got_null = view.col_is_null(1, i)
        assert_equal(
            got_null, want_null,
            msg="validity mismatch at row " + String(i),
        )
        if want_null:
            seen_null += 1
        else:
            assert_equal(
                _bits(view.col_scalar_nonraising[DType.float64](1, i)),
                _bits(dec_v.load[1](i)[0]),
                msg="non-null value BIT mismatch at row " + String(i),
            )
    # Discriminator: the fixture MUST actually carry nulls, else the assert
    # above is vacuous.
    assert_equal(seen_null, 4, "fixture must carry exactly 4 nulls")

    # The all-valid key column takes the no-bitmap fast path.
    assert_false(
        view.col_numeric[DType.int64](0).has_validity(),
        "an all-valid column must report no validity bitmap",
    )
    assert_true(
        view.col_numeric[DType.float64](1).has_validity(),
        "a column with nulls must report a validity bitmap",
    )


# =============================================================================
# §3 -- the container is PERSISTENT: refill, and the stale-view guard
# =============================================================================


def test_ipc_fill_refill_is_reset_not_reconstruct() raises:
    """ONE `IpcMorselFill`, filled twice. The second fill must serve the SECOND
    frame's values (not stale first-frame bytes), and the generation must have
    advanced -- the reset-not-reconstruct property that makes this container
    reusable across a pull loop.

    FALSIFIER: a fill that forgets to swap `frame` (or to reset `n_rows`)
    returns the first batch's SUM on the second read."""
    var types = _kv_schema_types()
    var fill = IpcMorselFill()

    var f1 = _encode(_kv_columns(_N, 0))  # values 1..22 -> SUM 253
    assert_true(fill.fill_from_frame(f1^, types), "first fill")
    var gen1 = fill.gen()
    var r1 = _fold_ipcview(fill)

    var f2 = _encode(_kv_columns(_N, 100))  # values 101..122 -> SUM 2453
    assert_true(fill.fill_from_frame(f2^, types), "refill into the SAME fill")
    var gen2 = fill.gen()
    var r2 = _fold_ipcview(fill)

    assert_almost_equal(_sum_of(r1), Float64(253.0), msg="first fill SUM")
    assert_almost_equal(
        _sum_of(r2), Float64(2453.0),
        msg="refill must serve the SECOND frame's values (stale frame ->"
        " 253 again)",
    )
    assert_true(gen2 > gen1, "a refill must advance the generation stamp")

    # Stale-view guard: a view stamped before the refill is invalid after it.
    var fill2 = IpcMorselFill()
    var f3 = _encode(_kv_columns(_N, 0))
    assert_true(fill2.fill_from_frame(f3^, types), "fill for the stale probe")
    var stale_gen = ipc_morsel_view_over(fill2).generation()
    fill2.reset()
    var after = ipc_morsel_view_over(fill2)
    assert_true(after.is_valid(), "a freshly-taken view is valid")
    assert_true(
        stale_gen != after.generation(),
        "a view taken before reset() must NOT share the post-reset generation"
        " (the stale-view guard would not fire)",
    )


# =============================================================================
# §4 -- honest DECLINE: a var-len column beside numerics
# =============================================================================


def test_ipc_fill_declines_varlen_without_shifting_numerics() raises:
    """A STRING column carries THREE wire buffers (validity + offsets + data)
    while a numeric carries two. The fill must mark it DECLINED *and* advance
    the buffer cursor by 3, so the numeric column that FOLLOWS it still reads
    its own bytes.

    FALSIFIER: advancing by 2 past the string column shifts every subsequent
    column's `values_pos` by one buffer -- caught here by the trailing
    numeric's cell comparison against the copy-on-read decoder."""
    var n = 12
    var s_vals = List[String]()
    var v_vals = List[Scalar[DType.float64]]()
    for i in range(n):
        s_vals.append(String("row-") + String(i))
        v_vals.append(Float64(i * 7 + 3))

    var cols = Slab[Column[HeapRegion]]()
    cols.append(
        Column.from_string(StringArray[HeapRegion].from_strings(s_vals))
    )
    cols.append(
        Column.from_primitive[DType.float64](
            PrimitiveArray[DType.float64].from_list(v_vals)
        )
    )

    var types = List[ArrowType]()
    types.append(ArrowType.STRING)
    types.append(ArrowType.FLOAT64)

    # Sanity-pin the duplicated wire-shape table this fill depends on.
    assert_equal(ipc_buffer_count(ArrowType.STRING), 3, "STRING = 3 buffers")
    assert_equal(ipc_buffer_count(ArrowType.FLOAT64), 2, "FLOAT64 = 2 buffers")
    assert_equal(ipc_fixed_width_bytes(ArrowType.STRING), 0, "STRING not fixed-width")
    assert_equal(ipc_fixed_width_bytes(ArrowType.BOOL), 0, "BOOL is bit-packed")

    var frame = _encode(cols^)
    var frame_for_decode = frame.share()

    var names = List[String]()
    names.append(String("s"))
    names.append(String("v"))
    var arrow = List[ArrowType]()
    arrow.append(ArrowType.STRING)
    arrow.append(ArrowType.FLOAT64)
    var decoded = _decode_to_batch(frame_for_decode^, types, names^, arrow^)

    var fill = IpcMorselFill()
    assert_true(
        fill.fill_from_frame(frame^, types),
        "a batch with a var-len column still fills (per-column decline)",
    )
    var view = ipc_morsel_view_over(fill)
    assert_true(view.col_is_declined(0), "STRING column must DECLINE")
    assert_false(
        view.col_is_declined(1),
        "the numeric column AFTER a var-len column must still be FLAT",
    )

    var dec_v = decoded.column_as_primitive_float64(1)
    for i in range(n):
        assert_equal(
            _bits(view.col_scalar_nonraising[DType.float64](1, i)),
            _bits(dec_v.load[1](i)[0]),
            msg="post-var-len numeric cell BIT mismatch at row "
            + String(i)
            + " (buffer cursor did not advance by 3 past the STRING column)",
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

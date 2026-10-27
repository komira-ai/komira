# =============================================================================
# The concat UNIFIES per-batch string dictionaries in O(total) and emits the
# pair-wise fold's dictionary, byte for byte
# =============================================================================
#
# `concat_record_batches_column_parallel` runs
# `concat_dict_unify.unify_string_dict_columns` before `_concat_impl`: every
# batch's STRING dictionary is merged (parallel local interning over batch
# ranges + a serial in-order merge), each batch's codes are rewritten to the
# merged ids as INT32, the ordinary (tiled) concat runs, and the result is
# re-labelled as ONE DICTIONARY column.
#
# WHAT THIS FILE KILLS:
#   §1  a merged dictionary in any order but the pair-wise fold's first-seen
#       (batch, entry) order — including a duplicated entry in the SEED
#       dictionary, which must keep its ordinal — compared buffer for buffer
#       against the fold (`ConcatOptions(dict_unify=False)`) over 40 batches, i.e.
#       FOUR local-interning tasks, so the merge across tasks is exercised;
#   §2  a remap that mis-maps a code: every row's VALUE is checked against an
#       independent oracle, across a zero-row batch in the middle;
#   §3  a null row whose code is dereferenced, or whose validity is lost;
#   §4  the MIXED case: one batch whose chunk fell back to plain STRING — every
#       dictionary batch is densified and the column comes back STRING, with
#       every value right;
#   §5  the ROUTE: the unify / densify witness counters move, and do NOT move
#       with the kill switch off;
#   §6  a null row whose cached null count is 0 while its bitmap says null;
#   §7  densifying past the Int32 offset ceiling;
#   §8  no unify fork while a pool dispatch is live;
#   §9  ten fresh pools in a row (destroy-recreate).

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from komira_arrow.string_array import StringArray
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.local_dispatcher import _OnPoolDispatchGuard
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime

from komira_engine_runtime.concat_dict_unify import (
    concat_dict_densified_count,
    concat_dict_unified_count,
    reset_concat_dict_unify_counters,
)
from komira_engine_runtime.concat_options import ConcatOptions
from komira_engine_runtime.streaming_concat_parallel import (
    concat_record_batches_column_parallel,
)


comptime _WORKERS: Int = 4
comptime _N_BATCHES: Int = 40


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


# =============================================================================
# Fixtures
# =============================================================================


def _vocab(i: Int) -> String:
    if i == 0:
        return String("")
    if i % 7 == 0:
        return String("ÄÖÜ-") + String(i)
    return String("model-") + String(i)


def _batch_rows(b: Int) -> Int:
    if b == 13:
        return 0  # a zero-row batch in the middle
    return 500 + (b * 37) % 400


def _row_value(b: Int, r: Int) -> String:
    """Batch b sees a batch-specific slice of a 90-value vocabulary."""
    return _vocab(((b * 11) + (r * r * 3) + r) % (20 + (b % 5) * 14))


def _is_null(b: Int, r: Int, nullable: Bool) -> Bool:
    return nullable and (r % 17 == 5)


struct _Batch(Movable):
    var vals: List[String]
    var nulls: List[Bool]
    var dict_col: Column[HeapRegion]

    def __init__(out self, b: Int, nullable: Bool, lie: Bool = False) raises:
        var n = _batch_rows(b)
        var vals = List[String](capacity=n)
        var nulls = List[Bool](capacity=n)
        for r in range(n):
            vals.append(_row_value(b, r))
            nulls.append(_is_null(b, r, nullable))
        # The batch's PRIVATE dictionary: its distinct values in a batch-
        # specific rotated order; batch 0 also repeats one value (the seed
        # dictionary's duplicate must keep its ordinal).
        var distinct = List[String]()
        for r in range(n):
            var seen = False
            for d in range(len(distinct)):
                if distinct[d] == vals[r]:
                    seen = True
                    break
            if not seen:
                distinct.append(vals[r])
        var dv = List[String]()
        var nd = len(distinct)
        for d in range(nd):
            dv.append(distinct[(d + b * 3) % max(nd, 1)])
        if b == 0 and nd > 1:
            dv.append(dv[1])  # a duplicate entry, never referenced by a row
        var codes = List[Int32](capacity=n)
        var valid = List[Bool](capacity=n)
        for r in range(n):
            var c = 0
            for d in range(nd):
                if dv[d] == vals[r]:
                    c = d
                    break
            if nulls[r]:
                c = 9_999  # garbage: a NULL row's code must never be read
            codes.append(Int32(c))
            valid.append(not nulls[r])
        var idx = PrimitiveArray[DType.int32].from_list(codes)
        if nullable:
            var vbm = Bitmap.create_all_valid(n)
            var nc = 0
            for r in range(n):
                if not valid[r]:
                    vbm.clear(r)
                    nc += 1
            idx.validity = Optional[Bitmap[HeapRegion]](vbm^)
            idx.null_count = nc
        var sda = StringDictionaryArray.from_parts(
            idx^, StringArray.from_strings(dv)
        )
        self.dict_col = Column.from_dictionary(sda)
        if lie:
            # The validity bitmap is right and the cached null count is not.
            self.dict_col._null_count = 0
        self.vals = vals^
        self.nulls = nulls^


def _make_batches(
    nullable: Bool,
    plain_batch: Int,
    mut all_vals: List[String],
    mut all_nulls: List[Bool],
    lie: Bool = False,
) raises -> Slab[RecordBatch]:
    """40 batches of (k: DICTIONARY, v: INT64). `plain_batch >= 0` makes that
    batch's k a plain STRING column (a PLAIN-fallback chunk)."""
    var out = Slab[RecordBatch].create(_N_BATCHES)
    var vbase = 0
    for b in range(_N_BATCHES):
        var fx = _Batch(b, nullable, lie)
        var n = len(fx.vals)
        var ints = List[Int64](capacity=n)
        for r in range(n):
            ints.append(Int64(vbase + r))
        vbase += n
        var rbb = RecordBatchBuilder.with_capacity(2)
        var sb = SchemaBuilder()
        if b == plain_batch:
            var valid = List[Bool](capacity=n)
            for r in range(n):
                valid.append(not fx.nulls[r])
            rbb.add_column(
                Column.from_string(
                    StringArray.from_strings_with_validity(fx.vals, valid)
                )
            )
            sb.add_field(Field("k", ArrowType.STRING, nullable))
        else:
            rbb.add_column(fx.dict_col.share())
            sb.add_field(Field("k", ArrowType.DICTIONARY, nullable))
        rbb.add_column(
            Column.from_primitive[DType.int64](
                PrimitiveArray[DType.int64].from_list(ints)
            )
        )
        sb.add_field(Field("v", ArrowType.INT64, False))
        out.append(rbb.build(sb.build()))
        for r in range(n):
            all_vals.append(fx.vals[r])
            all_nulls.append(fx.nulls[r])
    return out^


def _drive(
    var batches: Slab[RecordBatch], options: ConcatOptions = ConcatOptions()
) raises -> RecordBatch:
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=_WORKERS,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    var ct = CancellationToken.new()
    ref disp = runtime.dispatcher()
    var out = concat_record_batches_column_parallel(
        batches^, disp, ct^, options
    )
    _ = runtime^
    return out^


def _value_at(imm c: Column[HeapRegion], r: Int) raises -> String:
    """Row r's value through the DICTIONARY buffers, read raw."""
    var code = Int(c._data.get_typed[Int32](c._offset + r))
    var s = Int(c._offsets.value().get_typed[Int32](code))
    var e = Int(c._offsets.value().get_typed[Int32](code + 1))
    var bytes = List[UInt8](capacity=e - s)
    for i in range(s, e):
        bytes.append(c._dict_data.value().read_u8_at(i))
    return String(StringSlice(unsafe_from_utf8=Span(bytes)))


def _assert_values(
    imm out: RecordBatch,
    imm vals: List[String],
    imm nulls: List[Bool],
    tag: String,
) raises:
    assert_equal(out.num_rows(), len(vals), tag + ": row count")
    ref kc = out.column_at(0)
    var vi = out.column_at(1).as_primitive[DType.int64]()
    # Materialised ONCE: `column_as_string` builds a whole StringArray.
    var dense = Optional[StringArray[HeapRegion]](None)
    if kc.arrow_type != ArrowType.DICTIONARY:
        dense = Optional[StringArray[HeapRegion]](out.column_as_string(0))
    for r in range(len(vals)):
        assert_equal(Int(vi.get(r)), r, tag + ": v row " + String(r))
        if nulls[r]:
            assert_true(
                kc._validity and not kc._validity.value().test(kc._offset + r),
                tag + ": row " + String(r) + " must be NULL",
            )
            continue
        if kc._validity:
            assert_true(
                kc._validity.value().test(kc._offset + r),
                tag + ": row " + String(r) + " must be valid",
            )
        var got: String
        if kc.arrow_type == ArrowType.DICTIONARY:
            got = _value_at(kc, r)
        else:
            got = dense.value().get(r)
        assert_equal(got, vals[r], tag + ": k row " + String(r))


# =============================================================================
# §1 — THE PAIR-WISE FOLD'S DICTIONARY, BUFFER FOR BUFFER
# =============================================================================


def test_unify_equals_the_pairwise_fold_buffer_for_buffer() raises:
    reset_concat_dict_unify_counters()
    var fv = List[String]()
    var fn_ = List[Bool]()
    var fold = _drive(
        _make_batches(False, -1, fv, fn_), ConcatOptions(dict_unify=False)
    )
    assert_equal(concat_dict_unified_count(), 0, "gate OFF: no unify")
    var uv = List[String]()
    var un = List[Bool]()
    var uni = _drive(_make_batches(False, -1, uv, un))
    assert_equal(concat_dict_unified_count(), 1, "ROUTE: one column unified")
    ref fc = fold.column_at(0)
    ref uc = uni.column_at(0)
    assert_true(fc.arrow_type == ArrowType.DICTIONARY, "fold: DICTIONARY")
    assert_true(uc.arrow_type == ArrowType.DICTIONARY, "unify: DICTIONARY")
    assert_true(
        uni.schema.field_at(0).arrow_type == ArrowType.DICTIONARY,
        "unify: the schema field is restored to DICTIONARY",
    )
    assert_equal(uc._dict_size, fc._dict_size, "merged dictionary size")
    for d in range(fc._dict_size + 1):
        assert_equal(
            Int(uc._offsets.value().get_typed[Int32](d)),
            Int(fc._offsets.value().get_typed[Int32](d)),
            "merged dictionary offset " + String(d),
        )
    var nbytes = Int(fc._offsets.value().get_typed[Int32](fc._dict_size))
    for i in range(nbytes):
        assert_equal(
            Int(uc._dict_data.value().read_u8_at(i)),
            Int(fc._dict_data.value().read_u8_at(i)),
            "merged dictionary byte " + String(i),
        )
    assert_equal(uni.num_rows(), fold.num_rows(), "rows")
    for r in range(fold.num_rows()):
        assert_equal(
            Int(uc._data.get_typed[Int32](uc._offset + r)),
            Int(fc._data.get_typed[Int32](fc._offset + r)),
            "code of row " + String(r),
        )
    _assert_values(uni, uv, un, "unify")


# =============================================================================
# §2 + §3 — VALUES AND NULLS AGAINST AN INDEPENDENT ORACLE
# =============================================================================


def test_unify_keeps_every_value_and_every_null() raises:
    reset_concat_dict_unify_counters()
    var vals = List[String]()
    var nulls = List[Bool]()
    var out = _drive(_make_batches(True, -1, vals, nulls))
    assert_equal(concat_dict_unified_count(), 1, "ROUTE: one column unified")
    assert_true(
        out.column_at(0).arrow_type == ArrowType.DICTIONARY, "DICTIONARY out"
    )
    _assert_values(out, vals, nulls, "nullable")


# =============================================================================
# §4 — MIXED DICTIONARY / PLAIN: DENSIFIED, EVERY VALUE RIGHT
# =============================================================================


def test_mixed_nullable_dictionary_and_plain_keeps_every_null() raises:
    reset_concat_dict_unify_counters()
    var vals = List[String]()
    var nulls = List[Bool]()
    var out = _drive(_make_batches(True, 21, vals, nulls))
    assert_equal(concat_dict_densified_count(), 1, "ROUTE: densified")
    assert_true(out.column_at(0).arrow_type == ArrowType.STRING, "STRING out")
    _assert_values(out, vals, nulls, "mixed nullable")


def test_mixed_dictionary_and_plain_is_densified() raises:
    reset_concat_dict_unify_counters()
    var vals = List[String]()
    var nulls = List[Bool]()
    var out = _drive(_make_batches(False, 21, vals, nulls))
    assert_equal(concat_dict_densified_count(), 1, "ROUTE: densified")
    assert_equal(concat_dict_unified_count(), 0, "and not unified")
    assert_true(out.column_at(0).arrow_type == ArrowType.STRING, "STRING out")
    _assert_values(out, vals, nulls, "mixed")


# =============================================================================
# §6 — A NULL ROW'S CODE IS NEVER READ, WHATEVER THE CACHED NULL COUNT SAYS
# =============================================================================
#
# The nullable fixtures put code 9,999 (outside every dictionary) under each
# null row. A column whose validity bitmap is right but whose cached null count
# is 0 must still skip those rows, on both the unify remap and the densify.


def test_unify_skips_null_rows_when_the_null_count_is_unknown() raises:
    reset_concat_dict_unify_counters()
    var vals = List[String]()
    var nulls = List[Bool]()
    var out = _drive(_make_batches(True, -1, vals, nulls, True))
    assert_equal(concat_dict_unified_count(), 1, "ROUTE: one column unified")
    _assert_values(out, vals, nulls, "unify, null count 0")


def test_densify_skips_null_rows_when_the_null_count_is_unknown() raises:
    reset_concat_dict_unify_counters()
    var vals = List[String]()
    var nulls = List[Bool]()
    var out = _drive(_make_batches(True, 21, vals, nulls, True))
    assert_equal(concat_dict_densified_count(), 1, "ROUTE: densified")
    _assert_values(out, vals, nulls, "densify, null count 0")


# =============================================================================
# §7 — DENSIFYING PAST THE INT32 OFFSET CEILING IS REFUSED
# =============================================================================
#
# Densifying writes one copy of an entry's bytes per row, so a mixed column can
# need more bytes than any single batch holds. The fixture's expanded column is
# tens of kilobytes; a 1,000-byte trip point stands in for 2 GiB.


def test_densify_past_the_offset_ceiling_is_refused() raises:
    var vals = List[String]()
    var nulls = List[Bool]()
    var message = String("")
    var raised = False
    try:
        var out = _drive(
            _make_batches(False, 21, vals, nulls),
            ConcatOptions(offset_promote_at=1000),
        )
        _ = out^
    except e:
        raised = True
        message = String(e)
    if not raised:
        raise Error("a densified column past the ceiling was accepted")
    assert_true(
        "ArrowOffsetOverflow" in message, "refused for another reason: " + message
    )


# =============================================================================
# §8 — NO UNIFY FORK UNDER A LIVE POOL DISPATCH
# =============================================================================
#
# Both unify passes fork. From inside a pool task that raises "nested dispatch
# detected", so the unify stands down and the pair-wise fold runs. The test
# holds the dispatcher's on-pool guard (the process-global depth a pool task
# runs under); `test_unify_equals_the_pairwise_fold_buffer_for_buffer` is the
# control that the same input unifies without it.


def test_unify_stands_down_under_a_pool_dispatch() raises:
    reset_concat_dict_unify_counters()
    var vals = List[String]()
    var nulls = List[Bool]()
    var batches = _make_batches(False, -1, vals, nulls)
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=_WORKERS,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    var ct = CancellationToken.new()
    ref disp = runtime.dispatcher()
    var guard = _OnPoolDispatchGuard()
    var out = concat_record_batches_column_parallel(batches^, disp, ct^)
    guard.keepalive()
    assert_equal(concat_dict_unified_count(), 0, "no unify fork under the guard")
    assert_true(
        out.column_at(0).arrow_type == ArrowType.DICTIONARY, "DICTIONARY out"
    )
    _assert_values(out, vals, nulls, "fold under a pool dispatch")
    _ = runtime^


# =============================================================================
# §9 — DESTROY-RECREATE
# =============================================================================


def test_unify_destroy_recreate_soak() raises:
    """Ten fresh pools in a row, each torn down after a unified concat; the
    nullable fixture alternates with the mixed one."""
    for it in range(10):
        reset_concat_dict_unify_counters()
        var vals = List[String]()
        var nulls = List[Bool]()
        var mixed = it % 2 == 1
        var out = _drive(_make_batches(True, 21 if mixed else -1, vals, nulls))
        if mixed:
            assert_equal(concat_dict_densified_count(), 1, "iteration " + String(it))
        else:
            assert_equal(concat_dict_unified_count(), 1, "iteration " + String(it))
        _assert_values(out, vals, nulls, "soak iteration " + String(it))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

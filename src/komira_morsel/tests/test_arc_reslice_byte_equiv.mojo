# =============================================================================
# tests/engine/test_arc_reslice_byte_equiv.mojo
#
# VECTOR-NATIVE INC-3 (, design §B.1) — byte-identity oracle for the
# zero-copy Arc-share reslice: `Column.slice(start, len)` (Arc refcount++, NO
# memcpy) + `split_record_batch`. The reslice is UNCONDITIONAL (default-on since
# the flip; both the `KOMIRA_ARC_RESLICE` opt-in and the
# `KOMIRA_ARC_RESLICE_OFF` kill-switch are deleted), so this file is now THE
# byte-identity guard for the lever — it needs no env flag to reach either arm.
#
# THE LEVER. The RG->chunk reslice in `split_record_batch` becomes an Arc
# refcount bump instead of a per-column memcpy (`_slice_fixed_width`, ~7.5% of
# q1's profile). `Column.slice` shares the SharedAlignedBuffer (Arc) and views
# `[start, start+len)` via `_offset`; downstream accessors honor `_offset`.
#
# THE GATE. A sliced column must read BYTE-IDENTICALLY to the source column at
# the shifted index: `slice(start,len)[i] == source[start+i]` for every layout
# `supports_zero_copy_slice()` admits (fixed-width numeric / temporal / DECIMAL /
# DICTIONARY). Plain STRING/BINARY (accessors ignore `_offset`) are NOT admitted
# and are proven to fall back correctly by the split-level differential.
#
# Independent oracle: the source column is read directly at `start+i` (no reuse
# of the slice path), so a bug in `_offset` honoring is caught, not masked.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_core.arrow.string_array import StringArray
from komira_core.arrow.dictionary_array import StringDictionaryArray
from komira_core.collections.batch_view import BatchView
from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import SchemaBuilder, Field, RecordBatchBuilder
from komira_core.collections.slab import Slab
from komira_morsel.morsel import Morsel, split_record_batch


def _build_q1ish_batch(n: Int) raises -> RecordBatch:
    """3-col batch mirroring q1's fold columns: col0 = INT32 (l_shipdate-like),
    col1 = FLOAT64 (aggregand), col2 = DICTIONARY(string) (group key)."""
    var i32s = List[Int32]()
    var f64s = List[Float64]()
    var codes = List[Int32]()
    var dict_vals = List[String]()
    dict_vals.append(String("A"))
    dict_vals.append(String("N"))
    dict_vals.append(String("R"))
    for r in range(n):
        i32s.append(Int32(10000 + r))
        f64s.append(Float64(r) * 1.5 + 0.25)
        codes.append(Int32(r % 3))

    var sb = SchemaBuilder()
    sb.add_field(Field("shipdate", ArrowType.INT32, False))
    sb.add_field(Field("price", ArrowType.FLOAT64, False))
    sb.add_field(Field("rf", ArrowType.DICTIONARY, False))
    var b = RecordBatchBuilder.with_capacity(3)
    b.add_column(
        Column.from_primitive[DType.int32](
            PrimitiveArray[DType.int32].from_list(i32s)
        )
    )
    b.add_column(
        Column.from_primitive[DType.float64](
            PrimitiveArray[DType.float64].from_list(f64s)
        )
    )
    b.add_column(
        Column.from_dictionary(
            StringDictionaryArray(
                PrimitiveArray[DType.int32].from_list(codes)^,
                StringArray.from_strings(dict_vals)^,
                n,
            )
        )
    )
    return b.build(sb.build())


def _assert_slice_reads_match_source(
    imm src: RecordBatch, start: Int, length: Int
) raises:
    """Slice each admitted column via `Column.slice` and assert every read equals
    the SOURCE column read at `start+i` (independent oracle)."""
    var sliced_i32 = src.column_at(0).slice(start, length)
    var sliced_f64 = src.column_at(1).slice(start, length)
    var sliced_dict = src.column_at(2).slice(start, length)

    # Put the sliced columns into a fresh batch so BatchView accessors read them
    # with their new `_offset`.
    var sb = SchemaBuilder()
    sb.add_field(Field("shipdate", ArrowType.INT32, False))
    sb.add_field(Field("price", ArrowType.FLOAT64, False))
    sb.add_field(Field("rf", ArrowType.DICTIONARY, False))
    var bb = RecordBatchBuilder.with_capacity(3)
    bb.add_column(sliced_i32^)
    bb.add_column(sliced_f64^)
    bb.add_column(sliced_dict^)
    var sliced_batch = bb.build(sb.build())

    assert_equal(sliced_batch.num_rows(), length, "slice row count")

    var sv = BatchView(sliced_batch)
    var ov = BatchView(src)
    for i in range(length):
        assert_equal(
            Int(sv.col_i32(0).load[1](i)[0]),
            Int(ov.col_i32(0).load[1](start + i)[0]),
            "i32 slice[i] == source[start+i]",
        )
        assert_equal(
            sv.col_f64(1).load[1](i)[0],
            ov.col_f64(1).load[1](start + i)[0],
            "f64 slice[i] == source[start+i]",
        )
        assert_equal(
            sv.col_string_dict_code_at(2, i),
            ov.col_string_dict_code_at(2, start + i),
            "dict code slice[i] == source[start+i]",
        )


def test_column_slice_reads_byte_identical() raises:
    var rb = _build_q1ish_batch(200)
    # A few windows, including an interior slice with non-zero start.
    _assert_slice_reads_match_source(rb, 0, 200)
    _assert_slice_reads_match_source(rb, 0, 64)
    _assert_slice_reads_match_source(rb, 64, 64)
    _assert_slice_reads_match_source(rb, 130, 70)
    _assert_slice_reads_match_source(rb, 199, 1)


def test_split_diverts_nullable_to_copy_slice() raises:
    """split_record_batch must divert NULLABLE columns to the COPY slice, keeping
    the copy-path invariant (`_offset == 0`, validity rebased to bit 0) that raw
    `validity.test(i)` readers rely on ().

    A zero-copy `Column.slice` shares the WHOLE-column validity bitmap and carries
    `_offset > 0`, so a valid-row lookup on the result is `validity.test(_offset+i)`,
    NOT `validity.test(i)`. That is correct for the offset-honoring consumers
    (`as_primitive` etc.), but silently misreads under the raw `validity.test(i)`
    readers. Nullable columns therefore take the copy slice (which rebases validity
    to a fresh 0-based window bitmap and returns `_offset == 0`); the non-nullable
    (perf-critical) path keeps zero-copy.

    This guard reads each split morsel's validity via the RAW `validity.test(i)`
    convention AND asserts `_offset == 0`.
      FAILED ON pre-fix code (when the reslice was reached via the old
      `KOMIRA_ARC_RESLICE=1` opt-in): the nullable column was Arc-sliced
      (`_offset > 0`, shared whole-column validity), so `validity.test(i)` read
      the wrong bit (`morsel=1 row=0 global=64 mismatch`). Post-fix the nullable
      diversion is unconditional, so this guard is live on the DEFAULT path."""
    var n = 257  # 5 morsels of 64 + tail of 1 — exercises non-zero start offsets.
    var morsel_size = 64
    var arr = PrimitiveArray[DType.int64].allocate_nullable(n)
    var ptr = arr._typed_ptr_mut()
    var src_valid = List[Bool]()
    for i in range(n):
        ptr[i] = Int64(1000 + i)
        # ~alternating + every-7th null pattern (mixed validity).
        var is_null = (i & 1) == 1 or (i % 7 == 0)
        if is_null:
            arr._set_null(i)
        src_valid.append(not is_null)
    var col = Column.from_primitive(arr^)

    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    var bb = RecordBatchBuilder.with_capacity(1)
    bb.add_column(col^)
    var batch = bb.build(sb.build())

    var morsels = split_record_batch(batch^, morsel_size)

    var ridx = 0
    for m in range(len(morsels)):
        ref morsel = morsels[m]
        ref morsel_batch = morsel.batch
        ref morsel_col = morsel_batch.column_at(0)
        # Nullable columns must land on the copy path: `_offset == 0`.
        assert_equal(
            morsel_col._offset, 0,
            "nullable morsel column must be copy-sliced (_offset == 0)",
        )
        for i in range(morsel_col._length):
            var got_valid = True
            if morsel_col._validity:
                # RAW `test(i)` read — correct ONLY when `_offset == 0`.
                got_valid = morsel_col._validity.value().test(i)
            assert_equal(
                got_valid, src_valid[ridx],
                "morsel=" + String(m) + " row=" + String(i)
                + " global=" + String(ridx) + " raw validity.test(i) mismatch",
            )
            ridx += 1
    assert_equal(ridx, n, "all rows accounted for")


def test_supports_zero_copy_slice_layout_gate() raises:
    """The whitelist admits the q1 fold layouts (INT32/FLOAT64/DICTIONARY) and
    rejects plain STRING (accessors ignore `_offset`)."""
    var rb = _build_q1ish_batch(8)
    assert_true(rb.column_at(0).supports_zero_copy_slice(), "INT32 admitted")
    assert_true(rb.column_at(1).supports_zero_copy_slice(), "FLOAT64 admitted")
    assert_true(rb.column_at(2).supports_zero_copy_slice(), "DICTIONARY admitted")

    # A plain STRING column must be rejected (copy fallback).
    var strs = List[String]()
    strs.append(String("aa"))
    strs.append(String("bb"))
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, False))
    var bb = RecordBatchBuilder.with_capacity(1)
    bb.add_column(Column.from_string(StringArray.from_strings(strs)^))
    var srb = bb.build(sb.build())
    assert_true(
        not srb.column_at(0).supports_zero_copy_slice(),
        "plain STRING rejected (copy fallback)",
    )


def test_split_morsel_schemas_are_independent() raises:
    """Every morsel owns its OWN Schema — the hoisted template is COPIED per
    morsel, never shared or moved into one of them.

    ★ WHAT THIS GUARDS, and why it is not a tautology.

    `split_record_batch` used to rebuild the morsel Schema from scratch inside
    the per-morsel loop (a `Field` reconstruction per column into a
    15-parallel-`List` `SchemaBuilder`, then a copy of that into a 17-`List`
    `Schema`). MEASURED on q21's 3.79 M-row probe that was 8.60 ms of the
    split's 17.10 ms — half the window — for a value that does not vary across
    the loop. It is now built ONCE and `.copy()`-ed per morsel.

    That hoist introduces a hazard the old shape could not have: a template
    that is SHARED rather than copied. It would look correct on every value and
    every row count, and it would break the one thing `RecordBatchBuilder.build`
    does to a schema it is handed — the DICTIONARY-vs-STRING reconcile, which
    writes `schema._arrow_types[i]` in place. Under sharing, morsel 0's
    reconcile would reach back into every other morsel's schema.

    The assertion is therefore INDEPENDENCE, expressed through the public
    mutator: write metadata onto morsel 0's schema and require morsels 1..n-1
    not to see it. FAILS on any implementation that hands out the template by
    reference, by move-into-the-last-morsel, or by a shallow copy; PASSES on
    both the old per-morsel rebuild and the current copy-per-morsel, which is
    the correct relationship — this is a guard on the NEW degree of freedom,
    not a falsifier of the old code.
    """
    var rb = _build_q1ish_batch(64)
    var morsels = split_record_batch(rb^, 16)
    var n = len(morsels)
    # The split must actually have happened: with one morsel the independence
    # claim is vacuous.
    assert_equal(n, 4, "64 rows at 16/morsel = 4 morsels")

    # `MorselArray.__getitem__` hands out an IMMUTABLE ref, so the mutation
    # below needs owned morsels; `drain_morsels_into` is the public move-out.
    var owned = Slab[Morsel].create(n)
    morsels.drain_morsels_into(owned)
    assert_equal(len(owned), n, "all morsels drained")

    # PREMISE: no morsel starts with the probe key.
    for m in range(n):
        assert_true(
            not owned[m].batch.schema.has_metadata(String("probe")),
            "no morsel starts with the probe metadata key",
        )

    owned[0].batch.schema.set_metadata(String("probe"), String("m0"))

    assert_true(
        owned[0].batch.schema.has_metadata(String("probe")),
        "the mutation landed on morsel 0",
    )
    for m in range(1, n):
        assert_true(
            not owned[m].batch.schema.has_metadata(String("probe")),
            "morsel schemas are independent — mutating one must not reach"
            " another",
        )
        # And the copies are still complete: names + types survive the hoist.
        assert_equal(owned[m].batch.num_columns(), 3)
        assert_equal(owned[m].batch.schema.field_name(0), String("shipdate"))
        assert_equal(owned[m].batch.schema.field_name(1), String("price"))
        assert_equal(owned[m].batch.schema.field_name(2), String("rf"))
        assert_true(
            owned[m].batch.schema.field_arrow_type(2) == ArrowType.DICTIONARY,
            "DICTIONARY survives the hoisted-template copy",
        )
        assert_equal(owned[m].batch.num_rows(), 16, "row geometry unchanged")


def main() raises:
    var suite = TestSuite()
    suite.test[test_column_slice_reads_byte_identical]()
    suite.test[test_split_diverts_nullable_to_copy_slice]()
    suite.test[test_supports_zero_copy_slice_layout_gate]()
    suite.test[test_split_morsel_schemas_are_independent]()
    suite^.run()
